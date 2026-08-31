# aidata — todo

Findings from the verification pass after the 2026-08-31 install re-run
(`98da9f4`, PR #2 — bell hooks + user-global approval gate). Ranked: item 1 is a
live gate bypass, item 5 is the problem that has stalled three sessions, the
rest is hardening and carried-over plan work.

Verified from a balistiko-rooted session.

**Status 2026-08-31 (later session).** Items 1, 5 and 8 are fixed, merged
(`2911d67`, PR #3) and verified live. Item 10 is new. Items 2, 3, 4, 6, 7 and 9
remain open, untouched.

---

## 1. BLOCKER — `deny()` fails OPEN on model-controlled input

> **FIXED — merged `2911d67` (PR #3), commit `39cf068`, installed and verified.**
> `deny()` builds its JSON with `jq`, live at `claude/hooks/approval-gate.sh:66`.
> Confirmed 2026-08-31: a backslash-bearing denial came back as valid JSON where
> it previously failed open. The `\ls` / `\mkdir` / hostile-subagent_type probes
> are part of the branch's hermetic tests.
>
> **Not re-probed on 2026-08-31 (later session).** The backslash probe was
> attempted and denied *by the redirection rule first* — the probe command
> carried a `>`. Removing the `>` to get past a denial is the reshaping the gate
> forbids, so it was not retried. Keep the probe table as a `check.sh`
> assertion (item 7); an interactive session cannot cleanly exercise it.

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

> **FIXED — merged `2911d67` (PR #3), installed, and now BEHAVIOURALLY VERIFIED.**
> 5.1 (fragment-driven installer with the PILOTFISH_END guard, `b88ea0e`), 5.2
> (the fragment, Aaron-approved verbatim), 5.3 (the ordering rename — both files
> live in `claude/claude-md.d/` as `10-review-role.md` and
> `20-subagent-authorization.md`), and 5.4 (`ffc51d5`, live at
> `approval-gate.sh:81`). 5.4 was authored by Aaron — the auto-mode classifier
> permits gate-TIGHTENING edits but refuses ones that widen the gate's own
> permissions, even user-directed — and applied as his patch; README's spawn
> list matches.
>
> **The fix works.** 2026-08-31, later session, first session to load the block
> from a cold start: the `aidata:subagent-auth` span was present in context at
> `~/.claude/CLAUDE.md:44-66`, and the session delegated `scout` and `reviewer`
> unprompted while announcing it was acting on the standing authorization — the
> 5.2 self-announcement clause firing exactly as designed. Three sessions of
> silent non-delegation, closed.

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

- [x] `./install.sh` run twice from a clean tree — **verified 2026-08-31.**
      Run 1: `1 updated / 17 skipped / 0 warned`. Run 2: `0 / 18 / 0`.
      `CLAUDE.md` byte-identical across runs. `settings.json` untouched, with
      `effortLevel` and `skipAutoPermissionPrompt` intact.
- [x] Three spans in order — **verified 2026-08-31.** pilotfish 1–25,
      `aidata:review-role` 27–42, `aidata:subagent-auth` 44–66; markers intact
      and non-overlapping; pilotfish span byte-identical to
      `pilotfish/claude-md-block.md`.
- [ ] A fragment with a malformed or missing marker produces a `warn` and a
      non-zero exit, and does not modify `CLAUDE.md`.
      **Still untested, deliberately.** It needs a fragment with a knowingly
      bad marker committed to `claude/claude-md.d/`, and a failed attempt can
      leave debris that breaks later installs. Belongs in a hermetic test with
      a temp `CLAUDE_HOME`, not in a live session. See also item 9, which is the
      same class of hazard.
- [x] Spawning `reviewer` from a disarmed session succeeds — **verified
      2026-08-31**, spawned freely from a balistiko-rooted disarmed session.
- [x] Spawning `executor` from a disarmed session is still denied — **verified
      2026-08-31.** Denial arrived well-formed and fully parseable
      (`spawning the write-capable agent type 'executor' requires an armed plan
      approval`), which is also a live no-regression check on the item-1
      `deny()` rewrite.

### 5.6 Traps

- **Prefer running the session from `~/Code/aidata`** for install work — but
  the reason previously given here was **wrong and is retracted.** Arming is
  *not* "Claude's own writes but not arbitrary script execution": the marker
  check at `approval-gate.sh:55` short-circuits with `exit 0` **before** tool
  dispatch and before the Bash allowlist, so an armed gate permits any command,
  `./install.sh` included. Arming is a full bypass for the whole turn, and the
  Stop hook disarms it at turn end. Run installs from the aidata root because
  that is where relative paths and `git` state are right, not because the gate
  forbids it elsewhere.
- **Item 1 is FIXED** (`39cf068`). The disarmed allowlist is no longer advisory:
  a leading backslash now produces a parseable deny instead of failing open.
- **This fix is prose, not enforcement.** It should hold, but it is not
  guaranteed. The 5.2 self-announcement clause is the only detector — and on
  2026-08-31 it fired correctly on the first cold-start session. Keep the clause;
  it is the only reason non-compliance would ever be noticed.

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

**Third finding now points here.** Item 10 needs a fixture table of
command-string → allow/deny for the splitter, and item 11 needs the same shape
for the flag guards. Together with the item-1 deny-path probe that is three
separate asks for the same missing thing: **a way to assert the gate's decisions
without a live session.** The item-1 probe in particular *cannot* be run
interactively — attempting it on 2026-08-31 tripped the redirection rule first,
and stripping the `>` to get past a denial is the reshaping the gate forbids.
This is no longer a nice-to-have reporter; it is the only place these assertions
can live.

---

## 8. `head -n 0` aborts the install when a managed marker is on line 1

> **FIXED — merged `2911d67` (PR #3), commit `87477c8`.** `head_upto N FILE`
> emits nothing for N<=0 and routes the three `head -n "$((…-1))"` sites through
> it — live at `install.sh:44,48` with call sites at 144, 176 and 225.

Found by the verifier pass on the subagent-auth branch. `head -n "$((begin-1))"`
becomes `head -n 0` when the marker is on line 1; BSD/macOS `head` errors on
that, and under `set -euo pipefail` the whole install aborts silently — no
`warn`, no summary, the `global CLAUDE.md` phase never runs. Pre-existing on
`main` (4 of 5 line-1 layouts already aborted). Neither real machine is exposed
(both have `<!-- pilotfish:begin -->` on line 1), but it broke the documented
"delete the pilotfish span and re-run to re-seed" recovery.

## 9. Fragment marker hygiene — self-inflicted-only, not yet guarded

Also from the verifier pass. None is reachable by a shipped fragment; all need a
hand-authored bad file. Left as hardening for `check.sh` (item 7) or a future
installer pass:

- **Slug mismatch not validated.** A fragment beginning `aidata:x:begin` and
  ending `aidata:y:end` passes both shape checks and installs silently.
- **End-marker slug collision jams the second run.** A fragment whose end marker
  duplicates an earlier fragment's slug makes run 2 warn "begin marker with no
  matching end marker" (grep finds the earlier end first).
- **Duplicate slug across two fragments is last-wins with churning counters.**
  The file converges, but every run reports `linked/updated` for the collision
  and nothing names it.

---

## 10. Quote-blind command splitter denies legitimate reads

Found 2026-08-31 (later session). `claude/hooks/approval-gate.sh:125`:

```bash
NORMALIZED="$(printf '%s' "$CMD" | sed -E 's/\|\||&&|;|\|/\n/g')"
```

The splitter is quote-blind, so it splits on `|` **inside a quoted string**.
`grep -n "a\|b" file` becomes three fragments; the second (`b" file`) has no
allowlisted leading word and the whole command is denied. Alternation grep — and
anything else carrying a literal `|`, `;` or `&&` inside quotes — is unusable
while disarmed.

**This is not a regression, and it is not new.** Every such denial previously
contained a backslash, produced unparseable JSON, and **failed open**, so the
command ran anyway and nobody noticed. Fixing `deny()` (item 1) made the gate
fail closed, which is correct — it just made a pre-existing blind spot visible.
Fixing item 1 was still right; this is the bill for it.

### REJECTED fix — strip quoted spans before splitting

**Do not apply this. A review pass on 2026-08-31 found it fails OPEN three
ways**, each verified by patching a scratchpad copy of the hook and running both
versions against real hook JSON with an unarmed, non-exempt project dir.

```bash
# REJECTED — fails open, see below
STRIPPED="$(printf '%s' "$CMD" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
```

**R1 — balanced quotes are the hole, not unbalanced ones.** The two sed passes
run independently, so the single-quote pass has no notion of double-quote
context: an apostrophe inside one double-quoted argument pairs with an
apostrophe in a *later* one, and everything between them is deleted — real
separators and real commands included.

```
CMD:      grep "it's" a; rm -rf /tmp/z; grep "won't" b
STRIPPED: grep  b            ← the rm is gone
CURRENT:  DENY               PATCHED: ALLOW  (rm -rf /tmp/z executes)
```

`it's` / `don't` / `won't` in a grep pattern is precisely the traffic this fix
exists to unblock. The proposal's claimed invariant — "an unbalanced quote leaves
content in place and fails closed" — is true (verified) but is the wrong
invariant.

**R2 — `$seg` feeds fourteen downstream flag guards, and stripping weakens all
of them.** Deleting quoted spans can only *remove* matches, so every guard from
:142 to :194 gets weaker. Verified flips:

```
find . "-delete"          CURRENT: DENY   PATCHED: ALLOW
find . "-exec" rm {} \;   CURRENT: DENY   PATCHED: ALLOW
```

The architectural miss: the existing sibling pattern `CMD_REDIR_TEST`
(`approval-gate.sh:115-121`) deliberately confines its normalized copy to a
**single** `case` test, leaving every other test on raw `$CMD`. The proposal
widens that normalization to the whole loop.

**R3 — it does change which word is first, in the allow direction.**

```
"/tmp/evil-"cat file      CURRENT: DENY   PATCHED: ALLOW  (bash runs /tmp/evil-cat)
'/tmp/evil-'grep x f      CURRENT: DENY   PATCHED: ALLOW  (bash runs /tmp/evil-grep)
```

Root defect behind all three: **content deletion is not quote removal.** Bash's
word after quote removal is `/tmp/evil-cat`; the proposal's word after content
deletion is `cat`, which is allowlisted at :137. The gate would validate a
different string than the one bash executes.

### The approach that does work — mask, don't delete

- **Mask-and-slice closes R2 and R3.** Replace each quoted span with same-length
  filler (or just record its offsets), compute the split points from the masked
  string, then slice the **original `$CMD`** at those offsets. `$seg` then still
  carries real text for the flag guards and the real first word for the
  allowlist, while the split itself is quote-aware.
- **R1 is not fixable with two sed passes at all.** It needs a single
  left-to-right scan tracking quote state (in-single / in-double / bare) that
  recognizes separators only in the bare state — roughly 20 lines of `while` over
  `${CMD:i:1}`. For a gate whose stated posture is fail-closed, that is
  proportionate; two `s///g` passes are not.
- **`bash -n` is not an option** — it syntax-checks only and emits no tokens or
  separator offsets. No stdlib-level bash facility for this was found; treat
  "use bash's own parser" as unavailable rather than rejected.
- **Compute the normalization once and feed both halves of the gate.** Today the
  redirect check (:118) reads raw `$CMD` while the split would read stripped
  text, so `grep "a>b" f` is denied and `grep "a|b" f` allowed — the same class of
  quoted metacharacter, two opposite answers in one hook. Fixing only the split
  guarantees this bug gets refiled against `>` later.

### Non-negotiable before any of this lands

**Build the fixture table first.** This hook has **no tests**:
`find ~/Code/aidata -name '*approval*'` returns only the script itself. The
three fail-open flips above fell out of nine hand-built cases in about ten
minutes; one fixture table would have caught them, and item 1 is the standing
proof that a plausible-looking gate change can fail open with nothing to notice.
The reviewer explicitly does **not** consider its own finding set exhaustive and
expects a fuzzer to find more.

Cases already known to behave correctly, worth keeping as regression anchors:
escaped quotes (`\"`) and unbalanced quotes both over-deny (fail closed);
`$'...'` ANSI-C quoting strips correctly; `$(…)` and backticks are unreachable,
already denied upstream at :118.

### Workaround until fixed

### Workaround until fixed

Use separate `grep` invocations rather than `\|` alternation while disarmed.

---

## 11. Quote-naive flag guards are ALREADY open — verified live

Found by the same 2026-08-31 review pass. **Independent of item 10's fix; these
are holes in the file as it stands today.** Every guard between
`approval-gate.sh:141` and `:201` tests for a literal space before the flag
(`*" -i"*`), and a quote breaks the substring match. Verified ALLOW against the
**current** hook, unarmed:

```
git branch "-D" foo         → ALLOW   (bash runs: git branch -D foo)
sed "-i" s/a/b/ f           → ALLOW   (bash runs: sed -i …)
curl "-X" POST http://h     → ALLOW   (bash runs: curl -X POST …)
```

Same root cause as item 10 — quote-naive substring matching against text that
bash will quote-remove before executing. The guards check a string the shell
never sees.

**This compounds with items 3 and 4.** `pentagram/balistiko/.claude/settings.local.json`
pre-approves `Bash(git branch *)`, so the permission prompt is suppressed *and*
the gate's guard misses: neither layer catches `git branch "-D" main`.

Fix these in the **same pass** as item 10 — a quote-aware normalization that
yields the real post-quote-removal argument text serves both, and fixing the
splitter alone would leave these while adding item 10's R2 on top of them.

Full list of guards sharing the defect, all reading `$seg`: `:142` (`sed -i`),
`:148-151` (`curl -X` / `--data` / `-F` / `-T`), `:154-155` (`curl -o`), `:161`
(`find -delete` / `-exec`), `:177` (`git branch -D/-d/-m/-M/-f`), `:194`
(`gh api -X` / `--field` / `--input`).

### Measured friction, 2026-08-31

Five distinct false-positive denials in one session, all on plainly read-only
commands, all from the redirect/substitution pre-check at `approval-gate.sh:118`
matching a metacharacter **inside a quoted string**:

| Command shape | Denied because |
|---|---|
| `awk 'NR>=36 && NR<=42 {...}' file` | `>` in a comparison operator |
| `grep -n "func Lookup\|func Units" *.go` | `\|` split the command; fragment two began `func` |
| `grep -n '```go' README.md` | backtick read as command substitution |
| `gh pr list --jq '"... -> ..."'` | `>` inside a jq format string |
| `gh run view --jq '.name + " -> " + .conclusion'` | same |

None of these writes anything. Each cost a retry and a reformulation, and the
grep case cost a wrong turn — the denial names the *second fragment's* first
word, so it reads as a nonsense complaint about a word the user never typed.

This is the same root cause as item 10 (quote-blind handling) reaching the
*over-deny* side rather than the fail-open side, and it is the half that is felt
every session. Whatever fix lands should be measured against this table.

**Doctrine gap noted in passing:** there is no shell layer in
`~/.claude/review/` — only `global.md` and `go.md`. Every review of these hooks
therefore runs on global doctrine alone. Given that aidata is now three findings
deep in quote/escaping bugs in shell, a `~/.claude/review/shell.md` covering
quote-removal-vs-substring-matching and fail-closed posture would pay for
itself.

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
