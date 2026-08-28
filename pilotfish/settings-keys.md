# Pilotfish-managed `settings.json` keys

**Documentation only. `install.sh` never reads, writes, or merges
`~/.claude/settings.json`.**

Pilotfish's installer merges its keys into the existing `~/.claude/settings.json`
rather than replacing the file. Since that file also holds machine-local state
that has nothing to do with pilotfish — permissions, hooks, plugin enablement —
aidata stays out of it entirely. Two writers on one JSON file is how you lose an
allowlist. If a key here needs to change, run pilotfish's installer or edit the
file by hand.

## The keys

| Key | Purpose | Present on this machine (2026-08-28) |
|---|---|---|
| `model` | Primary model for the main session | yes — `claude-fable-5[1m]` |
| `fallbackModel` | Ordered fallbacks when the primary is unavailable | yes — `["opus", "sonnet"]` |
| `availableModels` | Roster offered to role agents | **no** — key absent |

`availableModels` being absent is not a fault. Roles that set `model:` in their
own frontmatter (`reviewer.md` pins `opus`) resolve it without needing a roster.

## Other keys in the live file

`~/.claude/settings.json` also carries `hooks`, `permissions`, `enabledPlugins`,
`effortLevel`, `skipAutoPermissionPrompt`, and `autoMode`. These are **not**
pilotfish's and are **not** aidata's — key names are listed here only so a
future reader knows the file is shared and does not assume it is safe to
overwrite wholesale. Their values are deliberately not reproduced in this repo.
