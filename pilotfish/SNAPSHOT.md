# Pilotfish snapshot

Upstream: <https://github.com/Nanako0129/pilotfish>

**Snapshot date:** 2026-08-28
**Installed version:** `v1.1.2` — recorded from the `<!-- pilotfish v1.1.2 -->`
marker on line 2 of the managed `~/.claude/CLAUDE.md` block, captured verbatim
in `claude-md-block.md`.

## Bootstrap contract

> `install.sh` seeds these files ONLY when absent; pilotfish's own installer
> owns and upgrades them; run it per its runbook to update.

This directory is a **bootstrap snapshot, not a managed copy.** Its only job is
to get a brand-new machine to a working orchestration setup before pilotfish's
installer has ever been run there. Once a file exists at the live path, aidata
never touches it again — no relinking, no overwriting, no diffing. That means:

- Editing a file here does **not** propagate to a machine that already has it.
  To upgrade, run pilotfish's installer; it is the owner.
- These are plain `cp` copies, not symlinks. Symlinking would make pilotfish's
  installer write back into this git repo, which would silently turn aidata
  into a fork of upstream.
- If upstream and this snapshot drift, upstream wins. Refresh the snapshot by
  re-copying from `~/.claude/` after running their installer.

## Roles

Aaron runs **6 of the 8 upstream roles.** Installed, and snapshotted in
`agents/`:

| Role | File |
|---|---|
| `executor` | `agents/executor.md` |
| `Explore` | `agents/Explore.md` |
| `mech-executor` | `agents/mech-executor.md` |
| `scout` | `agents/scout.md` |
| `security-executor` | `agents/security-executor.md` |
| `verifier` | `agents/verifier.md` |

Not installed, and deliberately not snapshotted:

- `plan-verifier`
- `security-reviewer`

`security-reviewer` is intentionally absent: its niche is covered locally by the
aidata-owned `reviewer` role, which carries the layered doctrine. Note that
`reviewer.md` lives in `claude/agents/`, **not here** — it is aidata-owned and
symlinked, not seeded.

## Contents

| File | What it is |
|---|---|
| `agents/*.md` | The six installed role definitions, copied verbatim from `~/.claude/agents/` |
| `claude-md-block.md` | The `<!-- pilotfish:begin -->` … `<!-- pilotfish:end -->` span of `~/.claude/CLAUDE.md`, inclusive and verbatim |
| `settings-keys.md` | Which `settings.json` keys pilotfish manages — documentation only, never scripted |
