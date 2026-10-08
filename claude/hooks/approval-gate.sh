#!/usr/bin/env bash
# Approval gate (Aaron, 2026-08-12; spawn-gate model 2026-08-20): tools that
# CHANGE things are DENIED in the MAIN session unless .claude/plan-approved
# exists. Aaron arms the gate after approving a plan (`touch
# .claude/plan-approved`); disarm-gate.sh, wired to the Stop hook, removes the
# marker when the turn ends, so approval never outlives the turn.
#
# Canonical copy lives in aidata (claude/hooks/approval-gate.sh) and is
# symlinked to ~/.claude/hooks/approval-gate.sh by its install.sh. The wiring
# is USER-GLOBAL (~/.claude/settings.json), not per-project: the project root
# arrives as $1 via the hook's exec-form args (${CLAUDE_PROJECT_DIR}).
#
# 2026-08-20 (Aaron): the unit of approval is the SPAWN. Subagent tool calls
# are ungated (agent_id early-allow below); launching a write-capable agent
# type requires the armed marker (Agent branch below). While armed, the main
# session may also perform its own mutating work in that turn (shipping ops:
# push, PR, rerun, rebases) — the hybrid ruling, SUPERSEDED on 2026-09-08 by
# the orchestrator-only ruling below; it is kept here as history, not as
# current behavior. Running agents no longer depend on the main thread
# staying open.
#
# 2026-08-31 (Aaron): the gate is user-global by default, with a per-repo
# opt-out — a repo whose root holds .claude/no-approval-gate is exempt and the
# gate returns without deciding anything, allow or deny.
#
# 2026-09-08 (Aaron): the main session is the ORCHESTRATOR ONLY. It never
# edits a file and it never changes a git working tree or git history, armed
# or not. This supersedes the hybrid clause above. Arming still authorizes
# exactly two things: spawning write-capable agents, and shipping or
# orchestration operations that touch no tree (git push, git fetch, gh,
# docker, docker compose, make, op, aws, curl, process control). Editing is
# delegated: the main session spawns an executor and hands it the spec. The
# orchestrator-only checks therefore run BEFORE the armed early-allow, so the
# marker cannot lift them, and they carry their own denial message because
# arming is not the remedy for them.
#
# 2026-09-08 (Aaron), the PLAN FILE rule: an armed marker alone no longer
# authorizes a write-capable Agent spawn. The spawn prompt has to name a plan
# file under $HOME/.claude/plans/<project>/, one directory per project (see the
# follow-up below), and the gate reads that file. It requires all eight
# sections as `## ` headings (Goal, Out of scope, Design fit, Decisions, New
# surface, Steps, Verification, Fallback), at least 40 non-whitespace
# characters of body in each, at least one `Options:` line inside Decisions,
# and a marker at least as new as the plan, so editing a plan after approval
# re-requires approval. The reason: a plan that was approved and was detailed
# still hid a design decision inside its prose, because prose can run long
# without ever naming a choice or its alternatives. A fixed shape forces the
# alternatives into a place a reviewer reads before arming. The rule is global
# and project-agnostic: every repo the gate covers resolves its own plans
# directory from its own root. Because the main session has to write the plan
# it will later cite, $HOME/.claude/plans/ joins the memory directory and the
# session scratchpad as an allowed write location. Template:
# $HOME/.claude/plans/TEMPLATE.md.
#
# 2026-09-08 (Aaron), plan-rule follow-ups from the first hours under it,
# three fixes. First, the template no longer tells an author to write "None."
# under New surface: the 40-character floor applies to every section, so that
# section now asks for one sentence saying that nothing with an audience is
# added and why. Second, a memory path holding ".." is refused instead of
# resolved, the way the scratchpad and plans paths already were; the memory
# pattern's * spans slashes, so a traversal through it reached any file on
# disk. Third, a spawn prompt may name a plan under any
# $HOME/.claude/plans/<name>/ directory and not only the session project's
# own, because a plan lives with the project the change belongs to, which is
# often not the project the orchestrating session runs in. The shape,
# freshness and ".." checks are identical wherever the plan lives, and those
# are what protect approval; the directory name is a filing convention. A
# denial that finds no plan path in the prompt still names the session
# project's directory as the default place to put one.
#
# 2026-09-18 (Aaron): the SCANNING and PLAN-SHAPE logic moved out of this
# file into ../../gate/scan-bash.sh and ../../gate/check-plan.sh, so the OMP
# write-gate hook (aidata/omp/hooks/write-gate.ts) can share one
# implementation instead of drifting against a port. What remains here is
# Claude plumbing: stdin JSON, the opt-out, the agent_id early-allow, the
# Write/Edit path rules, the spawn gate, and the deny-message framing. The
# extraction is behavior-preserving — gate/cases.tsv is the characterization
# corpus recorded against this file BEFORE the move, and gate/test.sh must
# stay green against it. The scripts are located relative to this file's real
# path (it is a symlink into the aidata checkout), with ~/.claude/hooks/gate/
# as fallback; a missing or failing script fails CLOSED.
#
# The gate enforces plan approval before CHANGES and nothing else — reading
# is never gated (Aaron, 2026-08-13). Fail-closed on the write side: while
# disarmed, Bash is limited to a read-only allowlist of simple commands, and
# anything unrecognized is denied — the fix is to ask Aaron to arm the gate,
# never to reshape a command to slip past it.
set -euo pipefail
set -f # no pathname expansion while word-splitting command segments

PROJECT_DIR="${1:-$PWD}"
MARKER="$PROJECT_DIR/.claude/plan-approved"

# Plans live in per-project directories inside the user-global plans root. The
# session project's own directory is the default a denial points at, and a
# spawn may cite a plan under any project directory there, since the change
# often belongs to another repo (the 2026-09-08 follow-up above).
PROJECT_NAME="$(basename "$PROJECT_DIR")"
PLANS_ROOT="$HOME/.claude/plans"
PLAN_DIR="$PLANS_ROOT/$PROJECT_NAME"
PLAN_TEMPLATE="$PLANS_ROOT/TEMPLATE.md"

# The shared gate scripts live at aidata/gate/; this file is symlinked from
# ~/.claude/hooks/, so resolve through the symlink to find them. link_managed
# uses absolute targets, so a single readlink suffices. The fallback path is
# where install.sh links the scripts for harnesses that cannot resolve the
# checkout (and where a plain copy of this file, not a symlink, still finds
# them).
SELF="${BASH_SOURCE[0]}"
if [ -L "$SELF" ]; then SELF="$(readlink "$SELF")"; fi
GATE_DIR="$(cd "$(dirname "$SELF")/../../gate" 2>/dev/null && pwd || true)"
if [ -z "$GATE_DIR" ] || [ ! -x "$GATE_DIR/scan-bash.sh" ]; then
  GATE_DIR="$HOME/.claude/hooks/gate"
fi
SCAN_BASH="$GATE_DIR/scan-bash.sh"
CHECK_PLAN="$GATE_DIR/check-plan.sh"

INPUT="$(cat)"

# The opt-out is checked only after stdin is drained: exiting first would close
# the pipe mid-write and could surface a spurious hook error in exactly the
# repos that asked not to be gated. Everything below — the allow paths and the
# deny paths alike — is skipped for an exempt repo.
if [ -f "$PROJECT_DIR/.claude/no-approval-gate" ]; then
  exit 0
fi

# Subagent tool calls are UNGATED (Aaron, 2026-08-20): the approval was spent
# at the spawn, so a running agent's writes must not depend on the main
# thread staying open or the marker surviving the turn — that dependency is
# what forced the orchestrator to hold turns open and locked Aaron out of the
# thread. agent_id is present only inside a subagent's own tool calls.
AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')"
if [ -n "$AGENT_ID" ]; then
  exit 0
fi

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"

deny() {
  # Built with jq, never printf: $1 carries model-controlled text (a command's
  # first word, a subagent_type), and hand-rolled JSON around it fails OPEN —
  # a bare backslash makes the output unparseable and the harness then ALLOWS
  # the call (found live 2026-08-31: '\mkdir x' sailed through the allowlist).
  jq -cn --arg r "APPROVAL GATE (disarmed): $1. Present the plan and ask Aaron to arm the gate with: ! touch .claude/plan-approved — it disarms when the turn ends. Do not reshape the call to bypass the gate." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

deny_orchestrator() {
  # Same jq construction and the same fail-open reasoning as deny(), with a
  # different message on purpose (Aaron, 2026-09-08): arming does not lift an
  # orchestrator-only denial, so telling the model to ask for the marker would
  # be wrong advice. The remedy is delegation.
  jq -cn --arg r "ORCHESTRATOR ONLY: the main session does not edit files. Spawn an executor (mech-executor for a fully specified change, executor when judgment is needed) and give it the exact spec. Blocked here: $1." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

deny_plan() {
  # Same jq construction and the same fail-open reasoning as deny(), with a
  # different message on purpose (Aaron, 2026-09-08) because neither
  # arming nor delegation is the remedy here. The remedy is a plan file with
  # the required shape, approved before the spawn.
  jq -cn --arg r "NO APPROVED PLAN: $1. A write-capable spawn requires a plan file under $PLAN_DIR/, or under the plans directory of the project the change belongs to, carrying all eight sections (Goal, Out of scope, Design fit, Decisions, New surface, Steps, Verification, Fallback), 40+ non-whitespace characters in each, and an 'Options:' line under Decisions. Template: $PLAN_TEMPLATE. Write or fix the plan, then ask Aaron to approve it and arm the gate again." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# The only places the main session writes for itself: its own memory directory
# (handled at the Write branch) and the per-session scratchpad. The uid segment
# is Aaron's 501 today, so claude-* keeps the rule working if the uid changes.
# A case glob spans slashes, which is what lets one * cover the project and
# session segments; that same property is why a path holding .. is refused
# outright rather than resolved.
is_scratchpad_path() {
  case "$1" in
    *..*) return 1 ;;
    /private/tmp/claude-*/*/scratchpad | /private/tmp/claude-*/*/scratchpad/*) return 0 ;;
    /tmp/claude-*/*/scratchpad | /tmp/claude-*/*/scratchpad/*) return 0 ;;
  esac
  return 1
}

# The third place the main session writes for itself (Aaron, 2026-09-08): the
# plan files a write-capable spawn has to cite. Writing the plan cannot be
# delegated, since the spawn that would do the delegating is what the plan
# authorizes. A path holding .. is refused outright rather than resolved, the
# same rule is_scratchpad_path applies and for the same reason.
is_plans_path() {
  case "$1" in
    *..*) return 1 ;;
    "$PLANS_ROOT"/*) return 0 ;;
  esac
  return 1
}

# scan_command runs the shared scanner and translates its verdict contract
# (aidata/gate/scan-bash.sh) back into this file's deny functions. $1 =
# --orchestrator | --disarmed, $2 = the raw command. exit 0 = allow. On
# denial, SCAN_CLASS is "orchestrator" or "disarmed" and SCAN_REASON is the
# core reason, exactly the text the pre-extraction code passed to deny*(). A
# scanner error is reported as class "orchestrator" so it can never be read
# as "blocked only while disarmed" — fail closed with the framing whose
# remedy is not "arm the gate".
SCAN_CLASS=""
SCAN_REASON=""
scan_command() {
  local out rc=0
  out="$(printf '%s' "$2" | bash "$SCAN_BASH" "$1" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "$rc" -ne 1 ]; then
    SCAN_CLASS="orchestrator"
    SCAN_REASON="the shared gate scanner at $SCAN_BASH exited $rc; failing closed (run aidata install.sh if it is missing)"
    return 1
  fi
  SCAN_CLASS="${out%%$'\t'*}"
  SCAN_REASON="${out#*$'\t'}"
  return 1
}

# ---------------------------------------------------------------------------
# Orchestrator-only enforcement (Aaron, 2026-09-08), ahead of the armed
# early-allow so the marker cannot lift it. The Write/Edit path rules are
# local; the Bash scan is the shared scanner's --orchestrator mode, which
# refuses interpreters, file-writing commands, in-place sed, mutating git,
# and movers or redirects outside scratch space. Everything not refused is
# left to the marker and, while disarmed, to the read-only allowlist in the
# scanner's --disarmed mode: git push, git fetch, gh, docker, make, op, aws,
# curl and process control stay allowed when armed, because shipping is the
# orchestrator's job.
#
# Build tools (pnpm, npm, go, make) stay allowed too, on the grounds that they
# write only inside node_modules, dist and build caches of a worktree an
# executor owns. That is a judgment call about blast radius rather than a
# guarantee, and Aaron may tighten it later; a tightening belongs in the
# scanner, next to the interpreters.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Write | Edit | NotebookEdit)
    # Memory is EXEMPT (Aaron, 2026-08-13): remembering is Claude's job, not
    # plan execution. The session scratchpad is exempt on the same reasoning,
    # since notes and working files there are not the codebase. Every other
    # file, armed or not, belongs to an executor.
    FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    # The * of the memory pattern spans slashes, exactly as it does in
    # is_scratchpad_path, so a memory path holding .. is refused outright here
    # too rather than resolved: the first arm claims it and the exemption
    # below never sees it (Aaron, 2026-09-08).
    case "$FILE_PATH" in
      *..*) ;;
      "$HOME"/.claude/projects/*/memory/*)
        exit 0
        ;;
    esac
    if is_scratchpad_path "$FILE_PATH"; then
      exit 0
    fi
    if is_plans_path "$FILE_PATH"; then
      exit 0
    fi
    deny_orchestrator "$TOOL to ${FILE_PATH:-an unnamed path}"
    ;;
  Bash)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    if [ ! -x "$SCAN_BASH" ]; then
      deny_orchestrator "the shared gate scanner is missing at $SCAN_BASH; run aidata install.sh to link it"
    fi
    if ! scan_command --orchestrator "$CMD"; then
      deny_orchestrator "$SCAN_REASON"
    fi
    ;;
esac

# The read-only agent roles, declared once because two branches test them now:
# the plan-file gate just below and the disarmed spawn gate further down.
# verifier is included because its in-place experiments are always reverted and
# reviewer is read-and-run by contract. An unknown or unset type is treated as
# write-capable, which fails CLOSED to the gated side.
is_read_only_agent_type() {
  case "$1" in
    scout | Explore | verifier | reviewer) return 0 ;;
  esac
  return 1
}

# Escapes the ERE metacharacters of a literal path prefix before it is
# spliced into the plan-path pattern. A home directory named with a dot or a
# plus would otherwise match more than itself.
re_escape() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

# The plan-file rule (Aaron, 2026-09-08). Called only for a write-capable
# Agent spawn from the main session with the marker already in place, so the
# arming message still comes first while disarmed and the marker check stays
# the outer gate. Path EXTRACTION from the prompt is local to this file (the
# OMP gate extracts from task text instead); the shape, freshness and ".."
# checks all live in the shared checker. Every failure exits through
# deny_plan naming the one check that failed; falling off the end means the
# plan is valid.
check_plan_file() {
  local prompt plan_re plan newest out rc

  prompt="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // empty')"

  # The prompt must carry the path, so the plan the executor is told to build
  # from is the same file the gate validated. Newest-by-mtime is used only for
  # the denial hint below. Both the project segment and the filename segment
  # exclude / and whitespace, which keeps the match exactly one directory
  # under the plans root and lets trailing punctuation in prose fall outside
  # it. The project segment is any name (the 2026-09-08 follow-up), so the
  # ".." refusal in the shared checker is what keeps the cited plan inside
  # the plans root.
  plan_re="($(re_escape "$HOME")|~)/\\.claude/plans/[^[:space:]/]+/[^[:space:]/]+\\.md"
  plan="$(printf '%s' "$prompt" | grep -oE "$plan_re" | head -n 1 || true)"

  if [ -z "$plan" ]; then
    # set -f is on for the whole hook, so the glob is expanded inside the
    # command substitution's subshell where restoring it costs nothing.
    newest="$(
      set +f
      ls -t "$PLAN_DIR"/*.md 2>/dev/null | head -n 1 || true
    )"
    deny_plan "the spawn prompt for '$SUBAGENT_TYPE' names no plan file under $PLAN_DIR/ (newest plan there: ${newest:-none found})"
  fi

  case "$plan" in
    '~'/*) plan="$HOME/${plan#\~/}" ;;
  esac

  if [ ! -x "$CHECK_PLAN" ]; then
    deny_plan "the shared plan checker is missing at $CHECK_PLAN; run aidata install.sh to link it"
  fi
  rc=0
  out="$(bash "$CHECK_PLAN" "$plan" "$MARKER" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -ne 1 ]; then
    deny_plan "the shared plan checker at $CHECK_PLAN exited $rc; failing closed"
  fi
  deny_plan "$out"
}

# ---------------------------------------------------------------------------
# Plan-file gate (Aaron, 2026-09-08), between the marker test and the armed
# early-allow: arming authorizes a write-capable spawn only when a plan file
# with the required shape backs it. Ordered after the marker on purpose, so a
# disarmed session is told to get the gate armed rather than being sent to
# rewrite a plan it has not yet had approved.
# ---------------------------------------------------------------------------
if [ "$TOOL" = "Agent" ] && [ -f "$MARKER" ]; then
  SUBAGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty')"
  if ! is_read_only_agent_type "$SUBAGENT_TYPE"; then
    SUBAGENT_TYPE="${SUBAGENT_TYPE:-default}"
    check_plan_file
  fi
fi

if [ -f "$MARKER" ]; then
  exit 0
fi

case "$TOOL" in
  # The unit of approval is the SPAWN (Aaron, 2026-08-20): a write-capable
  # agent type needs the armed marker to launch; after that its own tool
  # calls pass the agent_id early-allow above, so a turn ending (and
  # disarming) never strands a running agent. Read-only roles spawn freely,
  # per is_read_only_agent_type above.
  Agent)
    SUBAGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty')"
    if is_read_only_agent_type "$SUBAGENT_TYPE"; then
      exit 0
    fi
    deny "spawning the write-capable agent type '${SUBAGENT_TYPE:-default}' requires an armed plan approval"
    ;;
  # Workflow stays denied: fanning out dozens of agents is a scale commitment
  # rather than a read, and it deserves an approval of its own.
  Workflow)
    deny "$TOOL is execution-class and blocked without an armed plan approval"
    ;;
  # Write, Edit and NotebookEdit are already decided above: the orchestrator
  # branch allows memory and the scratchpad and refuses every other path,
  # armed or not, so there is nothing left for the marker to authorize.
  Bash) ;;
  *)
    exit 0
    ;;
esac

# Disarmed Bash: the shared scanner's --disarmed mode, which composes the
# orchestrator scan with the read-only allowlist (redirection/substitution
# pre-check included). The scanner ran --orchestrator above already, so an
# orchestrator-class reason here is unreachable; the branch is kept anyway
# because a wrong frame would tell the model to arm the gate for a denial
# arming cannot lift.
if ! scan_command --disarmed "$CMD"; then
  if [ "$SCAN_CLASS" = "orchestrator" ]; then
    deny_orchestrator "$SCAN_REASON"
  fi
  deny "$SCAN_REASON"
fi

exit 0
