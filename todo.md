# aidata — todo

Findings from the verification pass after the 2026-08-31 install re-run
(`98da9f4`, PR #2 — bell hooks + user-global approval gate). Ranked: item 1 is a
live gate bypass, item 5 is the problem that has stalled three sessions, the
rest is hardening and carried-over plan work.

Verified from a balistiko-rooted session. Nothing below has been fixed — only
found.

---

## 1. BLOCKER — `deny()` fails OPEN on model-controlled input

> **FIXED on `feat/subagent-authorization`** (fix(gate) commit): `deny()` now
> builds its JSON with `jq`; the `\ls` / `\mkdir` / hostile-subagent_type
> probes below all produce parseable denies and are part of the branch's
> hermetic tests.

`claude/hooks/approval-gate.sh`. `deny()` documents its own contract:

> `$1` must stay JSON-safe: no double quotes or backslashes.

Two call sites interpolate untrusted input straight into the `printf` format
string, breaking it:

- `deny "Bash command starting with $first is not on the disarmed read-only allowlist"`
  — `$first` is the first word of *any* Bash command Claude writes.
- `deny "spawning the write-capable agent type '${SUBAGENT_TYPE:-default}' requires an armed plan approval"`
  — `subagent_type` comes from tool input.

`%s` does not process escapes in its *argument*, so a backslash passes through
verbatim into the JSON string. `\l` is not a valid JSON escape — RFC 8259
permits only `\" \\ \/ \b \f \n \r \t \uXXXX` — so the hook's stdout fails to
parse, and Claude Code **allows the tool call**.

### Evidence — same `*)` deny branch, only JSON-safety differs

| Probe | Expected | Actual |
|---|---|---|
| `printenv CLAUDE_CONFIG_DIR` | deny | denied |
| `\ls /Users/aaronhill/Code/aidata` | deny | **allowed** |
| `\mkdir <scratchpad>/gate-probe` | deny | **allowed — directory created** |

A single leading backslash defeats the entire disarmed allowlist, mutating
commands included. This directly contradicts the file header:

> Fail-closed on the write side: while disarmed, Bash is limited to a
> read-only allowlist of simple commands, and anything unrecognized is denied.

### Fix

Build the JSON with `jq` rather than `printf`. `jq` is already a hard
dependency — `install.sh` exits 1 without it, and the gate already shells out
to it for every `agent_id` / `tool_name` parse — so this costs nothing.

```bash
deny() {
  jq -cn --arg r "APPROVAL GATE (disarmed): $1. Present the plan and ask Aaron to arm the gate with: ! touch .claude/plan-approved — it disarms when the turn ends. Do not reshape the call to bypass the gate." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
```

With that in place the "no double quotes or backslashes" caveat can come out of
the comment, since it stops being a caveat.

### Regression test worth having

The probe table above is the test. Whatever form `pilotfish/check.sh` takes
(item 7), it should assert that a JSON-unsafe first word still produces a
parseable deny — that is the bug that got through, and it got through because
nothing exercised the deny path's *output*, only its logic.

---

## 2. Allowlisted commands that can write or exec

The disarmed allowlist is described as read-only. Three entries are not:

- **`awk` is unconditional.** `awk 'BEGIN{system("…")}'` executes arbitrary
  commands with no `>`, `$(`, `<(` or backtick to trip the redirection check.
  Also `print > "file"` — caught by the `>` check, but `system()` is the hole.
- **`sed` is checked only for `-i`.** `sed 'w /path'` writes a file on both BSD
  and GNU sed with no shell redirection at all.
- **`find` blocks `-delete`/`-exec`** but not `-execdir`, `-fprint`, `-fprintf`
  or `-fls`.

Not probed end-to-end: the `awk system()` attempt was stopped by Claude Code's
auto-mode classifier, a separate layer, so the gate's own gap was never
reached. That second layer is doing real work — but it is not this gate, and
the gate should not lean on it.

Options, in preference order:

1. Constrain each to argument shapes that cannot write (hard for `awk`).
2. Drop `awk` from the allowlist; `jq`, `grep`, `cut` and `sed` cover nearly
   every read-only use it currently serves.
3. Accept and document it, and stop calling the allowlist read-only.

Related framing bug: the `Agent` branch's comment says *"Read-only roles spawn
freely"*, but `verifier` and `reviewer` both carry `Bash`, and a spawned agent's
Bash is **completely ungated** via the `agent_id` early-allow — no allowlist, no
redirection check. The free list is "roles trusted not to leave lasting
changes", not "read-only roles". Say what it means, or the next person adding a
role will reason from a false premise.

---

## 3. `push` / `pr create` / `pr edit` / `run rerun` are in the DISARMED allowlist

The header describes shipping ops as what an *armed* gate buys:

> While armed, the main session may also perform its own mutating work in that
> turn (shipping ops: push, PR, rerun, rebases) — the hybrid ruling.

But `push` and `fetch` sit in the disarmed `git` allowlist, and `pr create`,
`pr edit` and `run rerun` sit in the disarmed `gh` allowlist. So while
disarmed, Claude can push commits and open or edit PRs — outward-facing
mutations, available on the path meant to permit only reads.

**Open end-to-end, not theoretical.**
`pentagram/balistiko/.claude/settings.local.json` pre-approves
`Bash(git push *)`, `Bash(git commit -m ' *)`, `Bash(git add *)` and
`Bash(git checkout *)`. Permission allow-rules suppress the prompt; the gate's
disarmed allowlist admits `push`. A push from a disarmed session is therefore
neither gated nor prompted — no layer stops it.

This reads like the hybrid ruling leaking into the wrong list. Decide whether
these belong to armed-only (move them out) or are a deliberate exception
(document why, and drop them from the "read-only" framing).

---

## 4. `git branch <name>` is not caught

The `branch` guard pattern-matches flags only — `-D`, `-d`, `-m`, `-M`, `-f`,
`--force`, `--delete`, `--move`. Bare `git branch newthing` creates a branch
and falls through to `continue`. Either add the "one non-flag argument" case or
move `branch` off the allowlist entirely and let `rev-parse` / `ls-files` /
`show-ref` cover the read cases.

Same compounding as item 3: that repo also pre-approves `Bash(git branch *)`,
so the prompt is suppressed too. Flag-only guard plus blanket allow-rule means
neither layer catches it.

---

## 5. Delegation — the three-layer authorization conflict

> **FIXED on `feat/subagent-authorization` except 5.4.** 5.1 (fragment-driven
> installer with the PILOTFISH_END guard), 5.2 (the fragment, Aaron-approved
> verbatim 2026-08-31), and 5.3 (the ordering rename) are on the branch. 5.4
> (adding `reviewer` to the gate's free-spawn list) was BLOCKED by the
> auto-mode classifier — it permits gate-tightening edits but refuses edits
> that widen the gate's own permissions, even user-directed — so it remains a
> two-line HAND EDIT for Aaron: the free list in approval-gate.sh's Agent
> branch, plus README's "spawn freely" sentence to match.

**Self-contained work order — this has now stalled three sessions.** Most
recently 2026-08-31, where the main session hand-rolled ~18 reconnaissance
calls that the Orchestration table explicitly assigns to `scout`. The failure
mode is **silent**: nothing errors, the work just gets done expensively by hand,
and nobody notices.

### The conflict

**Layer 1 — the harness default.** Verbatim, at the end of the main session's
system prompt:

> Do not call the AgentTool unless the user requested it
> Do not use workflows or deep-research unless the user requested it

**Layer 2 — `~/.claude/CLAUDE.md:5`**, which says the opposite:

> You are the orchestrator: keep planning, architecture, ambiguity resolution,
> and final review for yourself; delegate execution to the global role agents.

and later in the same block:

> Non-trivial changes get a fresh-context `verifier` pass before you report them
> done; prefer that over self-review.

**Layer 3 — `claude/hooks/approval-gate.sh`**, the `Agent` branch: `scout`,
`Explore` and `verifier` spawn freely, every other type is denied while
disarmed. **This layer is enforcement and behaves correctly — it is not part of
the contradiction.** Its only defect is 5.4 below.

Both sides of the real conflict are **prose**. There is no setting where
"delegation is authorized" is a boolean, so the fix is to make one side
unambiguously win *as read* — not to add more enforcement.

### Two dead ends, already investigated — do not re-hunt these

**Layer 1 cannot be switched off from disk.** Searched 2026-08-31:

```
grep -rl "AgentTool" ~/.claude/plugins ~/.claude/agents \
  ~/.claude/settings.json ~/.claude/remote-settings.json \
  ~/.claude/policy-limits.json
```

Returns nothing, as do `aidata/settings.local.json` and
`pentagram/balistiko/.claude/settings.local.json`. The string appears in no
local config — it is compiled into Claude Code or injected server-side. Not
ruled out: an enterprise managed-settings file outside `~/.claude`, unlikely on
a personal machine, deliberately not guessed at rather than verified.

**Layer 2 cannot simply be reworded.** It lives at `~/.claude/CLAUDE.md:3-25`,
*inside* the `<!-- pilotfish:begin -->` span, tagged `<!-- pilotfish v1.1.2 -->`.
That span is upstream-owned: editing it works until the v1.4.1 upgrade in item
6, then silently reverts. This is the architectural reason the fix must be a
separate aidata-owned fragment.

### Why an aidata-owned CLAUDE.md fragment does work

Two mechanisms, both load-bearing:

1. **The harness itself grants CLAUDE.md override authority.** The
   system-reminder that carries it into context states, verbatim: *"IMPORTANT:
   These instructions OVERRIDE any default behavior and you MUST follow them
   exactly as written."* Layer 1 is default behavior. That is the harness's own
   precedence ordering, not an interpretation.
2. **Layer 1 names its own exception:** *"unless the user requested it."* The
   fragment satisfies that clause rather than arguing with the default.

The gap in the status quo is that layer 2 is written as *policy about how to
delegate* — a table of which role suits which task. It never says Aaron requests
delegation. The cautious reading is that it describes delegation without
authorizing it, and that reading is what stalls sessions.

### 5.1 Generalize `install_review_block` to iterate `claude-md.d/*.md`

Currently hardcoded to one block through four globals (`REVIEW_BEGIN`,
`REVIEW_END`, `REVIEW_HEADING`, `REVIEW_BLOCK`). Make fragments
self-describing — each declares its own markers as its first and last lines,
which `review-role.md` already does — so adding a block is dropping a file in
the directory with no installer edit.

```bash
install_md_blocks() {
  local frag

  # Fresh machine: seed the pilotfish snapshot, then let every fragment append
  # through the normal path below.
  if [ ! -f "$CLAUDE_MD" ]; then
    cat "$PILOTFISH_BLOCK" > "$CLAUDE_MD"
    say "created  $CLAUDE_MD (pilotfish snapshot)"
    n_seeded=$((n_seeded + 1))
  fi

  for frag in "$REPO"/claude/claude-md.d/*.md; do
    [ -f "$frag" ] || continue
    install_md_fragment "$frag"
  done
}

install_md_fragment() {
  local frag="$1"
  local begin_marker end_marker heading h_line tmp total begin end next_h stop
  local pf_begin pf_end

  begin_marker="$(head -1 "$frag")"
  end_marker="$(tail -1 "$frag")"
  case "$begin_marker" in '<!-- aidata:'*':begin -->') : ;;
    *) warn "$frag does not begin with an aidata marker — skipping."; return 0 ;;
  esac
  case "$end_marker" in '<!-- aidata:'*':end -->') : ;;
    *) warn "$frag does not end with an aidata marker — skipping."; return 0 ;;
  esac

  tmp="$(mktemp)"
  total="$(wc -l < "$CLAUDE_MD" | tr -d ' ')"
  begin="$(grep -n -F -x "$begin_marker" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  end="$(grep -n -F -x "$end_marker" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # Already marked: replace the span in place, inclusive of both markers.
  if [ -n "$begin" ]; then
    if [ -z "$end" ] || [ "$end" -lt "$begin" ]; then
      warn "$CLAUDE_MD has $begin_marker with no matching end marker.
   Refusing to guess where the block stops. Fix the markers by hand."
      rm -f "$tmp"; return 0
    fi
    head -n "$((begin - 1))" "$CLAUDE_MD" > "$tmp"
    cat "$frag" >> "$tmp"
    tail -n +"$((end + 1))" "$CLAUDE_MD" >> "$tmp"
    if cmp -s "$tmp" "$CLAUDE_MD"; then
      rm -f "$tmp"; n_skipped=$((n_skipped + 1)); return 0
    fi
    cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
    say "updated  $(basename "$frag" .md) block in $CLAUDE_MD"
    n_linked=$((n_linked + 1)); return 0
  fi

  # MIGRATION: section predates the markers. Its heading is the fragment's
  # first '## ' line.
  heading="$(grep -m1 '^## ' "$frag" || true)"
  h_line=''
  [ -n "$heading" ] && h_line="$(grep -n -F -x "$heading" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # Never migrate a heading living inside the pilotfish span — upstream-owned.
  pf_begin="$(grep -n -F -x "$PILOTFISH_BEGIN" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  pf_end="$(grep -n -F -x "$PILOTFISH_END" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  if [ -n "$h_line" ] && [ -n "$pf_begin" ] && [ -n "$pf_end" ] \
     && [ "$h_line" -ge "$pf_begin" ] && [ "$h_line" -le "$pf_end" ]; then
    h_line=''
  fi

  if [ -n "$h_line" ]; then
    next_h="$(tail -n +"$((h_line + 1))" "$CLAUDE_MD" | grep -n '^## ' | head -1 | cut -d: -f1 || true)"
    if [ -n "$next_h" ]; then stop="$((h_line + next_h - 1))"; else stop="$total"; fi
    head -n "$((h_line - 1))" "$CLAUDE_MD" > "$tmp"
    tail -n +"$((stop + 1))" "$CLAUDE_MD" >> "$tmp"
    printf '%s\n' "$(cat "$tmp")" > "$tmp.trim" && mv "$tmp.trim" "$tmp"
    printf '\n' >> "$tmp"
    cat "$frag" >> "$tmp"
    cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
    say "migrated unmarked $(basename "$frag" .md) section into a marked block"
    n_linked=$((n_linked + 1)); return 0
  fi

  # Absent entirely: append.
  cp "$CLAUDE_MD" "$tmp"
  printf '\n' >> "$tmp"
  cat "$frag" >> "$tmp"
  cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
  say "appended $(basename "$frag" .md) block to $CLAUDE_MD"
  n_linked=$((n_linked + 1))
}
```

Two things that go with it:

- **New `PILOTFISH_END` global**, and a guard the current code lacks. Once the
  heading migration is generic, a fragment headed `## Orchestration` would cut
  pilotfish's own section. The existing comment promises never to write past its
  own delimiters; this makes that true rather than incidental.
- **`seed_pilotfish_block` needs updating** — it currently locates `REVIEW_BEGIN`
  to insert before it. It must find the first aidata marker of any slug:
  `grep -n -E '^<!-- aidata:[a-z0-9-]+:begin -->$' "$CLAUDE_MD" | head -1 | cut -d: -f1`

### 5.2 The fragment — `claude/claude-md.d/20-subagent-authorization.md`

The doctrine half, and the part wanting Aaron's eye rather than an agent's.
Constraints it must respect, all deliberate: narrow scope, no `Workflow`/fan-out,
and explicitly not a licence to route around enforcement.

```markdown
<!-- aidata:subagent-auth:begin -->
## Subagent authorization

**This section is Aaron's standing request to delegate.** Where a default
instruction says not to call the Agent tool unless the user requested it, this
is that request — given in advance, durable across sessions, and not needing to
be restated per task. Do not ask permission to spawn a role agent named in the
Orchestration table above, and do not fall back to doing that work in the main
session on the grounds that the current turn did not ask for it. State at the
point of first delegation that you are acting on this standing authorization.

Scope, deliberately narrow:

- **Covered:** the named role agents in the Orchestration table above, plus
  `reviewer` from the Review role section.
- **Not covered:** `Workflow` and any fan-out, deep research, and ad-hoc agent
  types named in neither table. Those still need an explicit ask.
- **Not a licence to route around enforcement.** A hook denial or a permission
  prompt is a decision and stands; a default instruction is not. If the approval
  gate denies a spawn, present the plan and ask — never reshape the call, and
  never delegate in order to have a subagent perform what was denied to the
  main session.
<!-- aidata:subagent-auth:end -->
```

Notes for whoever writes it: the slug is `subagent-auth` while the filename is
`subagent-authorization` — fine under 5.1, since markers come from file
contents. The role list points at the tables rather than enumerating, so an
upstream pilotfish rename does not strand it. The "state at the point of first
delegation" clause is deliberate: it converts silent non-compliance into
something observable.

### 5.3 Rename for explicit ordering

`review-role.md` → `10-review-role.md`, new fragment → `20-subagent-authorization.md`.
Fragments apply in lexical filename order and the auth block refers to tables
above it, so order is load-bearing. Safe rename: the marker, not the filename,
identifies the span in `CLAUDE.md`.

### 5.4 Add `reviewer` to the gate's free list

`claude/hooks/approval-gate.sh`, `Agent` branch:

```bash
    case "$SUBAGENT_TYPE" in
      scout | Explore | verifier | reviewer)
        exit 0
        ;;
    esac
```

`claude/agents/reviewer.md` declares `tools: Read, Glob, Grep, Bash` — no
`Write`, no `Edit` — and its own description says *"Read-and-run only; it never
fixes what it finds."* Today it is denied as a *"write-capable agent type"*,
which is false. PR #1 shipped the reviewer; PR #2 shipped a gate that does not
know it exists.

The consequence is backwards: **a diff cannot be reviewed without first arming a
plan approval**, when review is the read-only step that should inform approval.
Same argument the gate's own comment already makes for `verifier`, just not
applied to aidata's own agent. See also the framing note in item 2.

### 5.5 Done-criteria

- [ ] `./install.sh` run twice from a clean tree: first run reports the new
      fragment appended, second run is a **no-op** — `skipped` counters up,
      `CLAUDE.md` byte-identical (`cmp` it against a copy taken between runs).
- [ ] `~/.claude/CLAUDE.md` ends up with three spans in order — pilotfish,
      review-role, subagent-auth — with markers intact and non-overlapping, and
      the pilotfish span byte-identical to `pilotfish/claude-md-block.md`.
- [ ] A fragment with a malformed or missing marker produces a `warn` and a
      non-zero exit, and does not modify `CLAUDE.md`.
- [ ] Spawning `reviewer` from a disarmed session succeeds.
- [ ] Spawning `executor` from a disarmed session is still denied.

### 5.6 Traps

- **Run the session from `~/Code/aidata`.** `install.sh` cannot be executed from
  a gated session in another repo — arming permits Claude's own writes, not
  arbitrary script execution, and the script is not on the disarmed allowlist.
- **Item 1 is unfixed.** Until `deny()` is fixed, the disarmed allowlist is
  advisory: a leading backslash bypasses it. Do not use that to get work done.
- **This fix is prose, not enforcement.** It should hold, but it is not
  guaranteed. The 5.2 self-announcement clause is the only detector.

---

## 6. Relocation plan — carried over, still not started

From the 2026-08-31 plan. The install re-run did not touch any of it.

- [ ] **Refresh the pilotfish snapshot from the upstream tag**, not by
      re-copying from `~/.claude` after an install. That live-state derivation
      is the root cause of `pilotfish/settings-keys.md` documenting
      "Present on this machine (2026-08-28)" state that was never true here.
- [ ] **Answer the open question first: legacy runbook or the v1.4.x Plugin
      beta?** Plugin was the recommendation — agents ship inside the plugin and
      it never edits `settings.json`, which deletes both the
      `pilotfish/agents/` seed-and-freeze problem and the settings-keys gap.
      Cost is beta status.
- [ ] **Upgrade pilotfish past v1.1.2 BEFORE setting `CLAUDE_CONFIG_DIR`.**
      Ordering constraint, and getting it wrong fails *silently* — the vendored
      v1.1.2 hardcodes `~/.claude/` in 22 places, so every write lands in the
      old root while Claude Code reads the new one. Fixed upstream in v1.3.6
      (2026-07-31); current is v1.4.1 (2026-08-27). **v1.3.6's changelog prose
      never mentions the fix** — it is visible only in git history / PR #37, so
      pin by tag and read history.
- [ ] **Then** `export CLAUDE_CONFIG_DIR=~/Code/.claude-home` in the shell
      profile — outside any repo, so `.claude.json`'s OAuth tokens are never one
      `git add -A` from a commit. It cannot be set from project-level
      `.claude/settings.json` `env`. Change `install.sh`'s `CLAUDE_HOME` to
      `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
- [ ] **The subagent-authorization block: now specified in full as item 5.**
      Note the dependency — it cannot be installed until 5.1 lands, because the
      current installer only knows about `review-role.md`.

## 7. `pilotfish/check.sh` — expected-vs-actual reporter

Also carried over, and this pass is the argument for it. Everything in the
"verified good" table below was checked by hand across ~15 tool calls. It
should report: which live agent files are symlinks / copies / absent, snapshot
version vs the live `<!-- pilotfish vX -->` marker, whether pilotfish has ever
been installed here, documented settings keys vs present, and the resolved
config root. `~/Code/CLAUDE.md` requires "scripts over prose documentation",
and this script would have caught three drift findings that prose missed.

Add the item-1 deny-path assertion to it.

---

## Verified good on 2026-08-31 — do not redo

| Check | Result |
|---|---|
| 8 aidata symlinks (`CLAUDE.md`, `settings.local.json`, `reviewer.md`, 3× review, 2× hooks) | all present, all resolving into `~/Code/aidata` |
| `settings.json` merge | `effortLevel: xhigh` and `skipAutoPermissionPrompt: true` survived; 4 hook entries added; the `hascmd` guard makes re-runs no-ops |
| `~/.claude/CLAUDE.md` | markers intact and non-overlapping — pilotfish 1–25, aidata 27–42; block matches `review-role.md` byte-for-byte |
| pilotfish snapshot | untouched at v1.1.2; 6/6 agents live as copies; no new seeds, correctly — the snapshot still carries only those 6 |
| `jq`, `afplay` | `/opt/homebrew/bin/jq`, `/usr/bin/afplay` |
| hook scripts | `0755` |
| gate live in balistiko | active and disarmed (no `.claude/no-approval-gate`), confirmed by real denials |

The `Aug 31 10:50` mtime on `claude/` was just the new `hooks/` subdirectory;
`review-role.md` itself is unchanged since Aug 29, so the installer's skip of
the CLAUDE.md block was correct rather than a missed update.

## Note for whoever picks this up

Writes to `~/Code/aidata/**` and `~/.claude/**` may be denied from a session
rooted in another project — the approval gate blocks `Write` outside the memory
directory whenever `.claude/plan-approved` is absent. Arming it is sufficient;
the auto-mode classifier does **not** block these writes (tested 2026-08-31).
Executing `install.sh` is a separate matter and does need an aidata-rooted
session. **Prefer running that session from `~/Code/aidata`.**
