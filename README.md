# aidata

Portable manager for Aaron's Claude setup. Clone it on a new machine, run
`./install.sh`, and the doctrine, the review system, and a working set of
orchestration roles are in place.

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
| `claude/claude-md.d/review-role.md` | `~/.claude/CLAUDE.md` | block |
| (four hook entries) | `~/.claude/settings.json` | merge |
| `pilotfish/agents/*.md` (6) | `~/.claude/agents/*.md` | seed |
| `pilotfish/claude-md-block.md` | `~/.claude/CLAUDE.md` | seed |

Four mechanisms, four different ownership rules:

- **link** — symlink into the repo. The repo owns it. Edit either path; it is
  one file on disk.
- **block** — a marker-delimited span inside a file aidata does not otherwise
  own. `install.sh` rewrites only what is between
  `<!-- aidata:review-role:begin -->` and `<!-- aidata:review-role:end -->`, and
  never reads or writes inside the pilotfish markers.
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
`Explore`, and `verifier` spawn freely), and `Bash` is limited to a read-only
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
review-role section, edit **`claude/claude-md.d/review-role.md`** in the repo and
re-run `./install.sh` — editing the live file directly works until the next
install, which overwrites the block. Keep the markers as the first and last
lines.

## Cross-vendor review

`review.sh` runs the same layered doctrine as the `reviewer` role against any
OpenAI-compatible endpoint — a second opinion from a different vendor, not a
replacement for the gate. All three variables are required, deliberately with no
defaults: a review tool that silently passes is worse than no review tool.

```sh
export REVIEW_API_BASE=https://api.moonshot.ai/v1   # includes the version path
export REVIEW_MODEL=kimi-k3
export REVIEW_API_KEY=sk-...

review.sh                        # staged + unstaged vs HEAD
review.sh --staged               # staged only
review.sh --range origin/main..HEAD
review.sh --help                 # vendor examples and exit codes
```

Run it from anywhere inside the repo under review. It assembles
`~/.claude/review/global.md`, the language layer (`go.md` when the repo has a
`go.mod`), and the repo's own `.claude/review/*.md`.
