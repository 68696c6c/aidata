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
# push, PR, rerun, rebases) — the hybrid ruling. Running agents no longer
# depend on the main thread staying open.
#
# 2026-08-31 (Aaron): the gate is user-global by default, with a per-repo
# opt-out — a repo whose root holds .claude/no-approval-gate is exempt and the
# gate returns without deciding anything, allow or deny.
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

if [ -f "$MARKER" ]; then
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

case "$TOOL" in
  # The unit of approval is the SPAWN (Aaron, 2026-08-20): a write-capable
  # agent type needs the armed marker to launch; after that its own tool
  # calls pass the agent_id early-allow above, so a turn ending (and
  # disarming) never strands a running agent. Read-only roles spawn freely —
  # verifier is included because its in-place experiments are always
  # reverted and reviewer is read-and-run by contract. Unknown or unset types fail CLOSED to the gated side.
  Agent)
    SUBAGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty')"
    case "$SUBAGENT_TYPE" in
      scout | Explore | verifier | reviewer)
        exit 0
        ;;
    esac
    deny "spawning the write-capable agent type '${SUBAGENT_TYPE:-default}' requires an armed plan approval"
    ;;
  # Workflow stays denied: fanning out dozens of agents is a scale commitment
  # rather than a read, and it deserves an approval of its own.
  Workflow)
    deny "$TOOL is execution-class and blocked without an armed plan approval"
    ;;
  Write | Edit | NotebookEdit)
    # Memory is EXEMPT (Aaron, 2026-08-13): remembering is Claude's job, not
    # plan execution — the gate exists to force plan approval, never to add
    # barriers to memory. Everything else file-shaped stays gated.
    FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    case "$FILE_PATH" in
      "$HOME"/.claude/projects/*/memory/*)
        exit 0
        ;;
    esac
    deny "$TOOL outside the memory directory is execution-class and blocked without an armed plan approval"
    ;;
  Bash) ;;
  *)
    exit 0
    ;;
esac

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"

# Redirections and substitutions can smuggle writes through read-only tools.
# Stderr-only redirects (2>/dev/null, 2>&1) cannot write files — strip them
# before testing (Aaron, 2026-08-21: reading is never gated).
CMD_REDIR_TEST="${CMD//2>\/dev\/null/}"
CMD_REDIR_TEST="${CMD_REDIR_TEST//2>&1/}"
case "$CMD_REDIR_TEST" in
  *'>'* | *'$('* | *'<('* | *'`'*)
    deny "Bash with redirection or substitution is blocked while disarmed (read-only simple commands only)"
    ;;
esac

# Validate every simple command in the pipeline/compound: split on | ; && ||
# and require each segment's leading word(s) to be on the read-only allowlist.
NORMALIZED="$(printf '%s' "$CMD" | sed -E 's/\|\||&&|;|\|/\n/g')"

while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  [ -z "$seg" ] && continue
  # shellcheck disable=SC2086
  set -- $seg
  [ "${1:-}" = "command" ] && shift
  first="${1:-}"
  second="${2:-}"

  case "$first" in
    ls | cat | head | tail | wc | grep | rg | ugrep | file | stat | pwd | which | tree | jq | awk | sort | uniq | cut | tr | column | diff | echo | printf | date | true | lsof | ps | basename | dirname | sleep | cmp | xxd | strings | uname | df | du)
      continue
      ;;
    sed)
      case "$seg" in
        *" -i"*) deny "sed -i is blocked while disarmed (in-place edit)" ;;
      esac
      continue
      ;;
    curl)
      case "$seg" in
        *" -X GET"* | *" -X HEAD"*) : ;;
        *" -X "* | *" --request"* | *" --data"* | *" -d "* | *" -F "* | *" --form"* | *" -T "* | *" --upload-file"*)
          deny "curl with a mutating method or body is blocked while disarmed"
          ;;
      esac
      case "$seg" in
        *" -o /dev/null"*) : ;;
        *" -o "* | *" --output"*) deny "curl -o to a file is blocked while disarmed" ;;
      esac
      continue
      ;;
    find)
      case "$seg" in
        *-delete* | *-exec*) deny "find with -delete/-exec is blocked while disarmed" ;;
      esac
      continue
      ;;
    git)
      # `git -C <path> <sub>` is the same read against another checkout
      # (Aaron, 2026-08-21). Skip -C/path pairs to find the real subcommand.
      shift
      while [ "${1:-}" = "-C" ]; do shift 2 || break; done
      second="${1:-}"
      case "$second" in
        status | log | diff | show | rev-parse | blame | ls-files | shortlog | describe | check-ignore | push | reflog | ls-remote | show-ref | cat-file | merge-base | fetch)
          continue
          ;;
        branch)
          case "$seg" in
            *" -D"* | *" -d"* | *" -m"* | *" -M"* | *" -f"* | *" --force"* | *" --delete"* | *" --move"*)
              deny "git branch mutation is blocked while disarmed"
              ;;
          esac
          continue
          ;;
        *) deny "git $second is blocked while disarmed (read-only git subcommands only)" ;;
      esac
      ;;
    gh)
      case "$second ${3:-}" in
        "pr view" | "pr list" | "pr diff" | "pr checks" | "pr status" | "release list" | "release view" | "run list" | "run view" | "pr create" | "pr edit" | "run rerun" | "issue view" | "issue list")
          continue
          ;;
        "api "*)
          # GETs only: an explicit method or any field/input flag mutates.
          case "$seg" in
            *" -X "* | *" --method"* | *" -f "* | *" -F "* | *" --field"* | *" --raw-field"* | *" --input"*)
              deny "gh api with a method or fields is blocked while disarmed"
              ;;
          esac
          continue
          ;;
        *) deny "gh $second is blocked while disarmed (read-only gh subcommands only)" ;;
      esac
      ;;
    docker)
      case "$second ${3:-}" in
        "ps "* | "ps" | "images "* | "images" | "inspect "* | "compose ps" | "compose logs" | "compose images")
          continue
          ;;
        *) deny "docker $second is blocked while disarmed" ;;
      esac
      ;;
    *)
      deny "Bash command starting with $first is not on the disarmed read-only allowlist"
      ;;
  esac
done <<EOF_SEGMENTS
$NORMALIZED
EOF_SEGMENTS

exit 0
