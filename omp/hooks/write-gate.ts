// write-gate.ts — the OMP write gate, counterpart of claude/hooks/approval-gate.sh.
//
// Same doctrine, omp mechanics: the main session is the orchestrator. It
// plans, delegates writes to subagents, and ships. Reading is never gated.
// Write capability is gated behind Aaron's armed marker
// (<repo>/.omp/plan-approved, touched after he approves a plan, removed at
// turn end) plus a plan file carrying the required shape, and shipping
// (git push, gh pr create/merge) additionally requires the pipeline
// EXECUTED -> VERIFIED -> REVIEWED to have run in this session.
//
// Command and plan judgments are NOT reimplemented here: this hook execs
// aidata/gate/scan-bash.sh and aidata/gate/check-plan.sh, the single source
// extracted from approval-gate.sh. Missing or failing scripts fail CLOSED.
//
// Instance model (probed 2026-09-18): every agent in the process — the main
// session and each task subagent — gets its OWN factory invocation, but the
// module itself is loaded once, so module-level state is shared. The main
// instance gates; subagent instances pass through (approval was spent at the
// spawn, the agent_id rule) except for two duties: they refuse writes to the
// gate's own files, and their `yield` call reports completion into the
// shared registry the main instance reads when gating shipping. An instance
// classifies itself as a subagent ONLY on positive evidence (session file
// under omp-task-*/ or a sidecar in the main session's artifact directory),
// so a classification failure degrades toward gating.
//
// What this hook cannot see, it does not claim to gate: hooks observe
// AgentTool calls only, so eval-prelude bridges (tab.run, computer) never
// reach it — which is why `eval` itself is denied in the main session
// outright. Subagents keep eval because their spawn was the approval.
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, realpathSync, unlinkSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const HOME = process.env.HOME ?? "";
const GATE_DIR = `${HOME}/.omp/agent/gate`;
const SCAN_BASH = `${GATE_DIR}/scan-bash.sh`;
const CHECK_PLAN = `${GATE_DIR}/check-plan.sh`;
const PLANS_ROOT = `${HOME}/.claude/plans`;
const MARKER_REL = ".omp/plan-approved";

// The unit of spawn approval: these roles never mutate, so they launch
// without the marker. Everything else — task, sonic, executor, the ported
// roles, an unknown name — is write-capable and gated.
const READ_ONLY_AGENTS: Record<string, true> = {
  scout: true,
  Explore: true,
  reviewer: true,
  verifier: true,
  "security-reviewer": true,
};

// hub operations that observe rather than act. start/restart launch arbitrary
// processes and send/stop steer them; those are armed-only, matching the
// Claude gate's "process control stays allowed when armed".
const READ_ONLY_HUB_OPS: Record<string, true> = {
  list: true,
  jobs: true,
  wait: true,
  inbox: true,
  logs: true,
  ps: true,
  describe: true,
};

// xd://lsp actions that only read code intelligence. rename, rename_file and
// applied code actions mutate the workspace and stay with the executors.
const READ_ONLY_LSP_ACTIONS: Record<string, true> = {
  diagnostics: true,
  definition: true,
  references: true,
  hover: true,
  symbols: true,
  type_definition: true,
  implementation: true,
  status: true,
  capabilities: true,
};

type Phase = "DISARMED" | "ARMED" | "EXECUTED" | "VERIFIED" | "REVIEWED";
type PipeRole = "executor" | "verifier" | "reviewer";

interface SharedState {
  phase: Phase;
  spawnRoles: Map<string, PipeRole>; // agent display name -> pipeline role
  unboundRoles: (PipeRole | null)[]; // spawn roles in task order, bound to names at tool_result
  completed: Map<string, boolean>; // display name -> refuted (insertion-ordered = completion order)
}

// Shared across factory instances via the module cache. Only the main
// instance mutates phase/spawnRoles; subagent instances append to completed.
const shared: SharedState = {
  phase: "DISARMED",
  spawnRoles: new Map(),
  unboundRoles: [],
  completed: new Map(),
};

function realpathOrSelf(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

// Writes to the gate itself are refused in EVERY instance, subagents
// included — the one place the OMP design is stricter than the Claude gate's
// blanket subagent early-allow. Resolving through the gate symlink lands on
// the aidata checkout, so editing either path is the same file; the checkout's
// omp/hooks and claude/hooks sit next to it.
const GATE_REAL = realpathOrSelf(GATE_DIR);
const AIDATA_ROOT = dirname(GATE_REAL);

// OMP_GATE_DEBUG=1 turns on the /tmp/gate-debug.log trace in debug() below.
// Read from the process env first, then the aidata repo .env — the gate runs
// in every repo, and .env is the canonical store (2026-10-06). Read once at
// module load; a missing file is just "off".
const GATE_DEBUG = (() => {
  if (process.env.OMP_GATE_DEBUG === "1") return true;
  try {
    return readFileSync(resolve(AIDATA_ROOT, ".env"), "utf8")
      .split("\n")
      .some((line) => line.trim() === "OMP_GATE_DEBUG=1");
  } catch {
    return false;
  }
})();
const PROTECTED_PREFIXES: string[] = [
  `${HOME}/.omp/agent/hooks`,
  `${HOME}/.omp/agent/config.yml`,
  `${HOME}/.claude/hooks`,
  GATE_REAL,
  resolve(AIDATA_ROOT, "omp/hooks"),
  resolve(AIDATA_ROOT, "claude/hooks"),
];

function isProtectedPath(p: string, cwd: string): boolean {
  // A path holding ".." is refused rather than resolved, the same rule the
  // Claude gate applies to memory, scratchpad and plans paths.
  if (p.includes("..")) return true;
  const abs = p.startsWith("/") ? p : resolve(cwd, p);
  return PROTECTED_PREFIXES.some((pre) => abs === pre || abs.startsWith(pre + "/"));
}

function isPlansPath(p: string, cwd: string): boolean {
  // The main session writes the plan it will later cite; that write cannot be
  // delegated, because the spawn that would delegate is what the plan
  // authorizes. Plans root is shared with the Claude gate on purpose: a plan
  // belongs to the project, not the harness.
  if (p.includes("..")) return false;
  const abs = p.startsWith("/") ? p : resolve(cwd, p);
  return abs === PLANS_ROOT || abs.startsWith(PLANS_ROOT + "/");
}

interface Deny {
  cls: string;
  reason: string;
}

// scanBash returns null for allow, a Deny otherwise. The scanner's contract:
// exit 0 allow; exit 1 = "class<TAB>reason" on stdout; anything else fails
// closed with the orchestrator class, whose remedy is never "arm the gate".
function scanBash(mode: "--orchestrator" | "--disarmed", command: string): Deny | null {
  try {
    execFileSync("bash", [SCAN_BASH, mode], {
      input: command,
      timeout: 10_000,
      stdio: ["pipe", "pipe", "ignore"],
    });
    return null;
  } catch (err) {
    const e = err as { status?: number | null; stdout?: Buffer | null };
    if (e.status === 1 && e.stdout) {
      const out = e.stdout.toString().trim();
      const tab = out.indexOf("\t");
      return tab === -1
        ? { cls: "orchestrator", reason: out }
        : { cls: out.slice(0, tab), reason: out.slice(tab + 1) };
    }
    return { cls: "orchestrator", reason: `the shared gate scanner at ${SCAN_BASH} failed; failing closed` };
  }
}

// checkPlan returns null for a valid plan, else the checker's reason.
function checkPlan(plan: string, marker: string): string | null {
  try {
    execFileSync("bash", [CHECK_PLAN, plan, marker], { timeout: 10_000, stdio: ["pipe", "pipe", "ignore"] });
    return null;
  } catch (err) {
    const e = err as { status?: number | null; stdout?: Buffer | null };
    if (e.status === 1 && e.stdout) return e.stdout.toString().trim();
    return `the shared plan checker at ${CHECK_PLAN} failed; failing closed`;
  }
}

// Shipping verbs the pipeline gates even when armed. Detected with the same
// segment splitting and word normalization the scanner uses, so a compound
// command cannot smuggle a push past on a later segment.
function shippingVerb(command: string): string | null {
  for (const seg of command.split(/\|\||&&|;|\||\$\(|<\(|\)|`|&/)) {
    const words = seg.trim().split(/\s+/).filter(Boolean);
    while (words.length > 0 && (/^(command|env|nohup|time|sudo|xargs)$/.test(words[0]) || words[0].includes("="))) {
      words.shift();
    }
    const first = (words[0] ?? "").replace(/[\\"']/g, "").split("/").pop() ?? "";
    if (first === "git") {
      let i = 1;
      while (i < words.length) {
        const w = words[i];
        if (["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"].includes(w)) {
          i += 2;
          continue;
        }
        if (w.startsWith("-")) {
          i += 1;
          continue;
        }
        break;
      }
      if (words[i] === "push") return "git push";
    }
    if (first === "gh" && words[1] === "pr" && (words[2] === "create" || words[2] === "merge")) {
      return `gh pr ${words[2]}`;
    }
  }
  return null;
}

// Replays completions in order. Executor completion sets EXECUTED from any
// later phase too — that is the regression edge, so a verifier pass can never
// cover changes an executor landed after it. Verifier credit requires the
// report to be free of REFUTED; reviewer credit requires VERIFIED. Idempotent:
// each sweep replays the full completion history from the current phase's
// predecessor state, so repeated sweeps converge.
function sweep(): void {
  if (shared.completed.size === 0) return;
  // A completion implies a spawn, which implies the gate was armed, so the
  // replay baseline is ARMED — never report DISARMED for work that happened.
  let phase: Phase = "ARMED";
  for (const [name, refuted] of shared.completed) {
    const role = shared.spawnRoles.get(name);
    if (role === "executor") phase = "EXECUTED";
    else if (role === "verifier" && phase === "EXECUTED" && !refuted) phase = "VERIFIED";
    else if (role === "reviewer" && phase === "VERIFIED") phase = "REVIEWED";
  }
  shared.phase = phase;
}

// Pipeline credit by agent type: verifier and reviewer earn their own steps;
// write-capable types (task, sonic, the executor ports, unknown names) earn
// EXECUTED; purely observational roles (scout, Explore, security-reviewer)
// earn nothing, so reconnaissance can never masquerade as execution.
function creditOf(agent: string): PipeRole | null {
  if (agent === "verifier") return "verifier";
  if (agent === "reviewer") return "reviewer";
  if (agent in READ_ONLY_AGENTS) return null;
  return "executor";
}

const PLAN_PATH_RE = /(?:~|\/[^\s"']+)\/\.claude\/plans\/[^\s/]+\/[^\s/]+\.md/;

function extractPlanPath(text: string): string | null {
  const m = text.match(PLAN_PATH_RE);
  if (!m) return null;
  const p = m[0];
  return p.startsWith("~") ? HOME + p.slice(1) : p;
}

function block(reason: string): { block: true; reason: string } {
  return { block: true, reason };
}

const ARM_HINT = `Present the plan and ask Aaron to arm the gate (mkdir -p .omp && touch .omp/plan-approved) — it disarms when the turn ends. Do not reshape the call to bypass the gate.`;

// Env-gated debug log: OMP_GATE_DEBUG=1 records lifecycle and gating
// decisions to /tmp/gate-debug.log. Off by default; never throws.
function debug(msg: string): void {
  if (!GATE_DEBUG) return;
  try {
    appendFileSync("/tmp/gate-debug.log", `${new Date().toISOString()} ${msg}\n`);
  } catch {
    // debug logging must never break the gate
  }
}

export default function (pi: HookAPI): void {
  let classified: "main" | "subagent" | null = null;
  let ownName = "";

  // Subagent only on positive evidence, in two session-file layouts: the
  // legacy $TMPDIR/omp-task-*/<Name>.jsonl (probed 2026-09-18), and the
  // current sidecar inside the main session's artifact directory,
  // ~/.omp/agent/sessions/<bucket>/<main-stem>/<Name>.jsonl (probed
  // 2026-09-25: omp-task dirs are still created but no longer hold session
  // files, which regressed every subagent to gated "main"). <main-stem> is
  // <timestamp>_<sessionId>; a directory with that name is only ever a main
  // session's artifact dir, and the main session's own file is the stem plus
  // .jsonl BESIDE it, so it never matches. Nested subagents sit one level
  // deeper under their parent and match the same way. Anything else — null
  // under --no-session, a call error — classifies as main, so a failure
  // degrades toward gating.
  const SUBAGENT_FILE_RE =
    /\/omp-task-[^/]+\/|\/sessions\/[^/]+\/\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_[^/]+\/.+\.jsonl$/;
  function classify(ctx: unknown): "main" | "subagent" {
    if (classified !== null) return classified;
    const sm = (ctx as { sessionManager?: unknown }).sessionManager;
    let file = "";
    if (sm && typeof sm === "object" && "getSessionFile" in sm) {
      const fn = (sm as { getSessionFile: unknown }).getSessionFile;
      if (typeof fn === "function") {
        try {
          const out = (fn as () => unknown).call(sm);
          if (typeof out === "string") file = out;
        } catch {
          // unreadable session file: classify as main
        }
      }
    }
    if (SUBAGENT_FILE_RE.test(file)) {
      classified = "subagent";
      ownName = basename(file, ".jsonl");
    } else {
      classified = "main";
    }
    debug(`classify who=${classified} file=${file || "(none)"}`);
    return classified;
  }

  pi.on("tool_call", (event, ctx) => {
    const who = classify(ctx);
    const input = event.input as Record<string, unknown>;
    const tool = event.toolName;

    if (who === "subagent") {
      // Duty one: self-protection, the only gate that applies inside agents.
      if ((tool === "write" || tool === "edit") && typeof input.path === "string") {
        if (isProtectedPath(input.path, ctx.cwd)) {
          return block(`GATE: writes to the gate's own files are refused in every session, subagents included: ${input.path}`);
        }
      }
      // Duty two: report completion into the shared registry. The main
      // instance reads it when gating shipping. A report containing REFUTED
      // is recorded as such and earns no verification credit.
      if (tool === "yield" && ownName !== "") {
        const data = typeof input.data === "string" ? input.data : JSON.stringify(input.data ?? "");
        shared.completed.set(ownName, /REFUTED/.test(data));
      }
      return undefined;
    }

    // ---- main instance below ----
    const marker = `${ctx.cwd}/${MARKER_REL}`;
    const armed = existsSync(marker);

    switch (tool) {
      // Reading is never gated.
      case "read":
      case "grep":
      case "glob":
      case "todo":
      case "web_search":
      case "ask":
        return undefined;

      // A general-purpose runtime cannot be scanned, so the orchestrator
      // does not get one. Execution is delegated; subagents keep eval.
      case "eval":
        return block(
          "ORCHESTRATOR ONLY: the main session does not run eval (a full Python/JS runtime defeats command scanning, and eval-prelude bridges never reach hooks). Spawn an executor for the work.",
        );

      case "write":
      case "edit": {
        const p = typeof input.path === "string" ? input.path : "";
        if (p.startsWith("xd://")) {
          const device = p.slice("xd://".length);
          if (device === "report_issue") return undefined;
          if (device === "lsp") {
            let action = "";
            let apply: unknown;
            try {
              const payload = JSON.parse(typeof input.content === "string" ? input.content : "{}") as Record<string, unknown>;
              action = typeof payload.action === "string" ? payload.action : "";
              apply = payload.apply;
            } catch {
              return block("GATE: an unparseable xd://lsp payload fails closed");
            }
            if (action in READ_ONLY_LSP_ACTIONS) return undefined;
            if (action === "code_actions" && apply !== true) return undefined;
            return block(`ORCHESTRATOR ONLY: lsp action '${action}' mutates the workspace; delegate it to an executor.`);
          }
          return block(`ORCHESTRATOR ONLY: device '${device}' can mutate state (ast_edit/resolve/debug and friends); delegate it to an executor.`);
        }
        if (isProtectedPath(p, ctx.cwd)) {
          return block(`GATE: writes to the gate's own files are refused in every session: ${p}`);
        }
        if (isPlansPath(p, ctx.cwd)) return undefined;
        return block(
          `ORCHESTRATOR ONLY: the main session does not edit files. Spawn an executor (mech-executor for a fully specified change, executor when judgment is needed) and give it the exact spec. Blocked here: ${tool} to ${p || "an unnamed path"}.`,
        );
      }

      case "bash": {
        const command = typeof input.command === "string" ? input.command : "";
        debug(`bash armed=${armed} cmd=${command.slice(0, 80)}`);
        const verdict = scanBash(armed ? "--orchestrator" : "--disarmed", command);
        if (verdict !== null) {
          if (verdict.cls === "orchestrator") {
            return block(
              `ORCHESTRATOR ONLY: the main session does not edit files or trees. Spawn an executor and give it the exact spec. Blocked here: ${verdict.reason}.`,
            );
          }
          return block(`APPROVAL GATE (disarmed): ${verdict.reason}. ${ARM_HINT}`);
        }
        if (armed) {
          const verb = shippingVerb(command);
          if (verb !== null) {
            sweep();
            if (shared.phase !== "REVIEWED") {
              return block(
                `PIPELINE: ${verb} ships to others, so it requires the full pipeline in this session: executor -> verifier -> reviewer. Current phase: ${shared.phase}. Spawn the missing role; a REFUTED verifier report earns no credit.`,
              );
            }
          }
        }
        return undefined;
      }

      case "hub": {
        const op = typeof input.op === "string" ? input.op : "";
        if (op in READ_ONLY_HUB_OPS) return undefined;
        if (armed) return undefined;
        return block(`APPROVAL GATE (disarmed): hub op '${op}' launches or steers processes, which is execution-class. ${ARM_HINT}`);
      }

      case "task": {
        const tasks = Array.isArray(input.tasks) ? input.tasks : [];
        const context = typeof input.context === "string" ? input.context : "";
        // One slot per spawned agent, in task order, so tool_result can bind
        // roles to the auto-generated display names positionally. Null slots
        // are observational roles whose completions earn no credit.
        const roles: (PipeRole | null)[] = [];
        for (const item of tasks) {
          const t = item as Record<string, unknown>;
          const agent = typeof t.agent === "string" && t.agent !== "" ? t.agent : "task";
          if (agent in READ_ONLY_AGENTS) {
            roles.push(creditOf(agent));
            continue;
          }
          if (!armed) {
            return block(
              `APPROVAL GATE (disarmed): spawning the write-capable agent '${agent}' requires an armed plan approval. ${ARM_HINT}`,
            );
          }
          const taskText = typeof t.task === "string" ? t.task : "";
          const plan = extractPlanPath(`${context}\n${taskText}`);
          if (plan === null) {
            return block(
              `NO APPROVED PLAN: the spawn task for '${agent}' names no plan file under ${PLANS_ROOT}/<project>/. Write the plan (eight sections, an Options: line under Decisions), then ask Aaron to approve it and arm the gate again.`,
            );
          }
          const planErr = checkPlan(plan, marker);
          if (planErr !== null) {
            return block(`NO APPROVED PLAN: ${planErr}. Write or fix the plan, then ask Aaron to approve it and arm the gate again.`);
          }
          roles.push(creditOf(agent));
        }
        // Record roles positionally; tool_result binds them to the spawned
        // display names, which subagent instances report completions under.
        for (const role of roles) shared.unboundRoles.push(role);
        return undefined;
      }

      default:
        // Unknown tools fail closed while disarmed, matching the read-only
        // allowlist's "anything unrecognized is denied". Armed matches the
        // Claude gate's blanket early-allow for tools it does not model.
        if (armed) return undefined;
        return block(`APPROVAL GATE (disarmed): tool '${tool}' is not on the read-only allowlist. ${ARM_HINT}`);
    }
  });

  pi.on("tool_result", (event, ctx) => {
    if (classify(ctx) !== "main") return undefined;
    if (event.toolName !== "task" || event.isError) return undefined;
    const text = event.content.map((c) => (c.type === "text" ? c.text : "")).join("\n");
    const names = [...text.matchAll(/Spawned agent `([^`]+)`/g)].map((m) => m[1]);
    for (const name of names) {
      const role = shared.unboundRoles.shift();
      if (role != null) shared.spawnRoles.set(name, role);
    }
    return undefined;
  });

  // The disarm port: approval never outlives the agent run. turn_end fires
  // per model STEP in omp (verified 2026-09-18: once per tool call), so it
  // cannot carry the disarm — agent_end is the Claude Stop-hook analog,
  // firing once when the agent loop hands control back, with
  // session_shutdown as the backstop for unclean exits. Only the main
  // instance owns the marker and the pipeline state.
  const disarm = (ctx: { cwd: string }, via: string): void => {
    if (classify(ctx) !== "main") return;
    debug(`disarm via=${via} phase=${shared.phase} completed=${shared.completed.size}`);
    shared.phase = "DISARMED";
    shared.spawnRoles.clear();
    shared.unboundRoles.length = 0;
    shared.completed.clear();
    try {
      unlinkSync(`${ctx.cwd}/${MARKER_REL}`);
    } catch {
      // absent marker is the resting state
    }
  };
  pi.on("agent_end", (_event, ctx) => disarm(ctx, "agent_end"));
  pi.on("session_shutdown", (_event, ctx) => disarm(ctx, "session_shutdown"));
}
