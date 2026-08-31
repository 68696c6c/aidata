#!/usr/bin/env bash
# Disarms the approval gate (Aaron, 2026-08-13) by removing the
# .claude/plan-approved marker, so an approval never outlives the turn it was
# given for. Wired to the Stop hook.
#
# Canonical copy lives in aidata (claude/hooks/disarm-gate.sh) and is symlinked
# to ~/.claude/hooks/disarm-gate.sh by its install.sh. The wiring is
# USER-GLOBAL (~/.claude/settings.json), not per-project: the project root
# arrives as $1 via the hook's exec-form args (${CLAUDE_PROJECT_DIR}).
#
# 2026-08-31 (Aaron): the gate is user-global by default, with a per-repo
# opt-out — a repo whose root holds .claude/no-approval-gate is exempt. An
# opted-out repo is left completely alone, marker included: this script never
# removes a file in a repo that has opted out of the gate.
#
# It skips subagent completions, which is the whole reason this is a script
# rather than an inline `rm -f`. The hooks docs say a configured Stop hook is
# converted to SubagentStop inside a subagent; if that holds, every finishing
# subagent would disarm the gate MID-TURN and block the rest of the work Aaron
# had just approved, and the failure would look like the gate randomly
# forgetting an approval. agent_id is the field the docs name for telling the
# two apart — present only inside a subagent call.
#
# MEASURED 2026-08-13: this build does NOT fire that event. Two real subagent
# completions, with this script instrumented to log every invocation, produced
# no SubagentStop — only the main-thread Stop at turn end. So the guard below
# is insurance against documented behavior we have not observed, not a fix for
# a reproduced bug. It is three lines and costs nothing; keep it. If a future
# version starts firing SubagentStop, this is already correct.
set -euo pipefail

PROJECT_DIR="${1:-$PWD}"
MARKER="$PROJECT_DIR/.claude/plan-approved"

INPUT="$(cat)"

# The opt-out is checked only after stdin is drained: exiting first would close
# the pipe mid-write and could surface a spurious hook error in exactly the
# repos that asked not to be gated. It removes nothing on the way out.
if [ -f "$PROJECT_DIR/.claude/no-approval-gate" ]; then
  exit 0
fi

AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')"
if [ -n "$AGENT_ID" ]; then
  exit 0
fi

rm -f "$MARKER"
