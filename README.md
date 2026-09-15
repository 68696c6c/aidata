# aidata

Portable manager for Aaron's coding-agent setup: Claude Code with pilotfish,
and omp. Clone it on a new machine, run `./install.sh`, and the doctrine, the
review system, and a working set of orchestration roles are in place.

Hand-rolled shell and symlinks. No Dotbot, no framework, no dependencies beyond
`bash`, `git`, coreutils, and `jq` (the hooks parse their input with it, and the
`settings.json` merge is jq-based; `install.sh` refuses to run without it).

## What it manages

| Repo file | Live path | Mechanism |
|---|---|---|
| `CLAUDE.md` | `~/Code/CLAUDE.md` | link |
| `settings.local.json` | `~/Code/.claude/settings.local.json` | link |
| `claude/agents/reviewer.md` | `~/.claude/agents/reviewer.md` | link |
| `claude/review/global.md` | `~/.claude/review/global.md` | link |
| `claude/review/go.md` | `~/.claude/review/go.md` | link |
| `claude/review/review.sh` | `~/.claude/review/review.sh` | link |
| `claude/hooks/approval-gate.sh` | `~/.claude/hooks/approval-gate.sh` | link |
| `claude/hooks/disarm-gate.sh` | `~/.claude/hooks/disarm-gate.sh` | link |
| `claude/claude-md.d/*.md` (each) | `~/.claude/CLAUDE.md` | block |
| (four hook entries) | `~/.claude/settings.json` | merge |
| `pilotfish/agents/*.md` (6) | `~/.claude/agents/*.md` | seed |
| `pilotfish/claude-md-block.md` | `~/.claude/CLAUDE.md` | seed |
| `omp/agents/reviewer.md` | `~/.omp/agent/agents/reviewer.md` | link |
| `omp/agents/verifier.md` | `~/.omp/agent/agents/verifier.md` | link |

Four mechanisms, four different ownership rules:

- **link** — symlink into the repo. The repo owns it. Edit either path; it is
  one file on disk.
- **block** — a marker-delimited span inside a file aidata does not otherwise
  own. Every `claude/claude-md.d/*.md` file is a self-describing fragment: its
  first and last lines are its own `<!-- aidata:<slug>:begin/end -->` markers,
  fragments apply in lexical filename order (hence the number prefixes), and
  `install.sh` rewrites only what lies between each fragment's markers — never
  inside the pilotfish span, which is guarded explicitly. Adding a block is
  dropping a file in the directory; no installer edit.
- **merge** — an addition to a file aidata does not own. Each hook entry is
  added only when no hook anywhere in `settings.json` already carries its exact
  command string, so nothing existing is ever modified or removed and a re-run
  changes nothing. A `settings.json` that does not parse is reported and left
  untouched.
- **seed** — copied in **only when absent**. See
  [`pilotfish/SNAPSHOT.md`](pilotfish/SNAPSHOT.md); pilotfish's own installer
  owns these files and upgrades them, aidata only bootstraps a bare machine.

`install.sh` **never clobbers a divergent local edit.** A live file that differs
from the repo copy is left exactly as it is, reported loudly with a diff command
and both resolutions, and the run exits non-zero. Re-running after a clean
install is a no-op.

## New machine

```sh
git clone git@github.com:68696c6c/aidata.git ~/Code/aidata
cd ~/Code/aidata && ./install.sh
```

Then, if you want orchestration roles newer than the snapshot, run **pilotfish's
own installer** per its runbook — it owns those files from that point on.
Upstream: <https://github.com/Nanako0129/pilotfish>. The snapshot is `v1.1.2`,
captured 2026-08-28.

`install.sh` is safe to re-run at any time, and is how you pick up doctrine
changes after a `git pull` (it rewrites the managed `CLAUDE.md` block; the
symlinked files need nothing).

## Hooks

`install.sh` merges four hook entries into `~/.claude/settings.json` — two for
the bell, two for the approval gate. Both are user-global: they apply in every
repo on the machine, and nothing per-project needs wiring.

**Bell.** A `Stop` hook plays `Glass.aiff` when a turn ends and a `Notification`
hook plays `Ping.aiff` when Claude wants attention, both `async` so they never
hold a turn. macOS only — they shell out to `afplay`, and fail silently
(`|| true`) anywhere it is missing.

**Approval gate.** Tools that *change* things are denied in the main session
unless the current repo is armed. Reading is never gated.

```sh
touch .claude/plan-approved      # arm, from the repo root — lasts ONE turn
```

The `Stop` hook (`disarm-gate.sh`) removes the marker when the turn ends, so an
approval never outlives the turn it was given for. While disarmed, `Write` /
`Edit` / `NotebookEdit` are denied outside `~/.claude/projects/*/memory/*`,
`Workflow` is denied, spawning a write-capable agent type is denied (`scout`,
`Explore`, `verifier`, and `reviewer` — the roles trusted not to leave lasting
changes — spawn freely), and `Bash` is limited to a read-only
allowlist of simple commands — anything unrecognized is denied. Subagents' own
tool calls are ungated: the approval is spent at the spawn, so a running agent
never depends on the main thread staying open.

**Per-repo opt-out.** A repo that should not be gated says so in its own root:

```sh
touch .claude/no-approval-gate   # this repo is exempt, permanently
```

Both scripts return immediately for such a repo, deciding nothing — and
`disarm-gate.sh` will not remove a marker there either.

The project root reaches the scripts as `$1`, wired as `${CLAUDE_PROJECT_DIR}`
in the hook's `args` (the exec form: each element is passed as one argument with
no shell quoting), which is what lets one user-global script gate whichever repo
the session started in.

## Editing doctrine

The linked files are symlinks, so editing `~/.claude/review/go.md` and editing
`claude/review/go.md` are the same edit to the same inode. Work wherever is
convenient, then commit from the repo:

```sh
cd ~/Code/aidata && git add claude/review/go.md && git commit
```

The one file that is *not* a symlink is `~/.claude/CLAUDE.md`. To change the
review-role section, edit **`claude/claude-md.d/10-review-role.md`** in the repo and
re-run `./install.sh` — editing the live file directly works until the next
install, which overwrites the block. Keep the markers as the first and last
lines.

## Second harness: omp

[omp](https://omp.sh) (oh-my-pi, `omp`, source at
<https://github.com/can1357/oh-my-pi>) is the second coding-agent harness this
repo sets up. It runs Kimi K3 through Fireworks and drives the projects Aaron
chooses to drive with it; the Claude Code + pilotfish setup keeps driving the
rest and is untouched by any of this. The harness is chosen per project by
running `omp` instead of `claude` in that repo. Nothing in the repo marks it,
and nothing under `~/.claude/` changes when omp is installed or removed.

What the two harnesses share is the doctrine, and only in the reviewers. Both
a Claude `reviewer` and an omp `reviewer` load the same
`~/.claude/review/global.md`, the same language layer (`go.md`), and the same
`<repo-root>/.claude/review/*.md`. Those paths are aidata symlinks and stay
readable whether or not Claude Code is running. The two `verifier` roles share
one body and contract (pilotfish's text) and load no review layer by design:
a verifier refutes a claim rather than grading a diff against doctrine.

What aidata manages here is exactly three symlinks: `omp/agents/reviewer.md`
and `omp/agents/verifier.md` into `~/.omp/agent/agents/`, because omp discovers
user-level task agents from `~/.omp/agent/agents/*.md` and deliberately ignores
`.claude/agents` (the frontmatter schema differs), and
`omp/extensions/bell.ts` into `~/.omp/agent/extensions/`, because omp
discovers user-level extensions from `~/.omp/agent/extensions/`. The link
block is skipped, not warned about, on a machine where `~/.omp/agent` does not
exist yet: install omp, run it once, then re-run `./install.sh`.

omp ships bundled agents named `reviewer`, `scout`, `security-reviewer`,
`sonic`, and `task` (`omp agents unpack` writes them), and a non-bundled agent
with the same name overrides the bundled one. The linked `reviewer.md`
therefore shadows omp's bundled `reviewer` on purpose, so the doctrine
reviewer replaces omp's own, which spawns `scout` and returns a structured
schema; `verifier` has no bundled counterpart to shadow. `omp agents unpack`
writes into the same directory: without `--force` it leaves the two agent
symlinks alone. `omp agents unpack --force` writes through the symlink and
overwrites the repo-tracked `omp/agents/reviewer.md` with omp's bundled reviewer
(measured on omp 18.1.21); the link survives, so `./install.sh` sees a
correct link and reports nothing. The guard is git: `git -C ~/Code/aidata
status` shows the file modified and `git -C ~/Code/aidata restore
omp/agents/reviewer.md` puts the doctrine reviewer back. Do not run `unpack
--force` on a machine where these links exist.

What aidata does not manage: `~/.omp/agent/config.yml` and
`~/.omp/agent/models.yml`, because omp writes them at runtime and a file with
two writers loses one of them, and the Fireworks credential, which this repo
never stores, reads, or moves. `FIREWORKS_API_KEY` is the environment variable
omp's built-in `fireworks` provider reads; set it in your shell profile the way
you set the other provider keys.

`omp/extensions/bell.ts` gives an omp session the same audible cue Claude Code
has: Glass on `session_stop`, which fires once when a main-agent turn settles
and never for task agents, and Ping on `tool_approval_requested`. It is the omp
counterpart of the Claude Code `Stop` and `Notification` hooks `install.sh`
merges into `~/.claude/settings.json`, and the two sound paths are a hand copy
of the two `afplay` commands there, so they can drift. Each of the two sound
paths appears exactly once in each of the two files; this check must print
exactly these four lines:

```sh
cd ~/Code/aidata
grep -o '/System/Library/Sounds/[A-Za-z]*\.aiff' install.sh omp/extensions/bell.ts | sort | uniq -c
```

```
   1 install.sh:/System/Library/Sounds/Glass.aiff
   1 install.sh:/System/Library/Sounds/Ping.aiff
   1 omp/extensions/bell.ts:/System/Library/Sounds/Glass.aiff
   1 omp/extensions/bell.ts:/System/Library/Sounds/Ping.aiff
```

Known gap: an omp session has no approval gate. The gate and the plan-file
rule are Claude Code hooks (`claude/hooks/approval-gate.sh`); omp extension
modules are TypeScript files under `~/.omp/agent/extensions/`, this repo's
first being `omp/extensions/bell.ts`, and a `tool_call` blocker would go under
`~/.omp/agent/hooks/pre/`. Porting them is a separate job that has not been
done.

The omp role files carry a hand copy of each Claude role's body, so they can
drift. These two commands must each show exactly one hunk, the one line the
provenance comment in each file explains. The anchors are the line ending the
provenance comment and the frontmatter fence, so frontmatter growth on either
side leaves the check exact:

```sh
cd ~/Code/aidata
diff <(sed '1,/-->$/d' omp/agents/reviewer.md) <(sed '1,/-->$/d' claude/agents/reviewer.md)
diff <(sed '1,/-->$/d' omp/agents/verifier.md) <(sed -n '/^---$/,/^---$/!p' pilotfish/agents/verifier.md)
```

## Cross-vendor review

`review.sh` runs the same layered doctrine as the `reviewer` role against any
OpenAI-compatible endpoint — a second opinion from a different vendor, not a
replacement for the gate. All three variables are required, deliberately with no
defaults: a review tool that silently passes is worse than no review tool.

```sh
export REVIEW_API_BASE=https://api.moonshot.ai/v1   # includes the version path
export REVIEW_MODEL=kimi-k3
export REVIEW_API_KEY=sk-...

# or the same model through Fireworks, the vendor the omp harness runs on:
export REVIEW_API_BASE=https://api.fireworks.ai/inference/v1
export REVIEW_MODEL=accounts/fireworks/models/kimi-k3
export REVIEW_API_KEY="$FIREWORKS_API_KEY"

review.sh                        # staged + unstaged vs HEAD
review.sh --staged               # staged only
review.sh --range origin/main..HEAD
review.sh --help                 # vendor examples and exit codes
```

Run it from anywhere inside the repo under review. It assembles
`~/.claude/review/global.md`, the language layer (`go.md` when the repo has a
`go.mod`), and the repo's own `.claude/review/*.md`.

Vendor inversion in an omp project: there Kimi K3 is the model doing the
primary work, so a Kimi review is no longer a second vendor's opinion. Use the
Claude `reviewer` role, or `review.sh` pointed at Moonshot or xAI, for the
second opinion in those repos.
