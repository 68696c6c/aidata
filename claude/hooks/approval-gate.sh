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
# file under $HOME/.claude/plans/<project>/, where <project> is the basename of
# the project root, and the gate reads that file. It requires all eight
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
# The gate enforces plan approval before CHANGES and nothing else — reading
# is never gated (Aaron, 2026-08-13). Fail-closed on the write side: while
# disarmed, Bash is limited to a read-only allowlist of simple commands, and
# anything unrecognized is denied — the fix is to ask Aaron to arm the gate,
# never to reshape a command to slip past it.
set -euo pipefail
set -f # no pathname expansion while word-splitting command segments

PROJECT_DIR="${1:-$PWD}"
MARKER="$PROJECT_DIR/.claude/plan-approved"

# The plan file a write-capable spawn must cite lives under the project's own
# directory inside the user-global plans root, so one rule serves every repo.
PROJECT_NAME="$(basename "$PROJECT_DIR")"
PLANS_ROOT="$HOME/.claude/plans"
PLAN_DIR="$PLANS_ROOT/$PROJECT_NAME"
PLAN_TEMPLATE="$PLANS_ROOT/TEMPLATE.md"

# The required sections, in the order the template lists them. A plan missing
# any of these is refused before its bodies are measured, so the denial names
# the missing heading rather than an empty section.
PLAN_HEADINGS=(
  "Goal"
  "Out of scope"
  "Design fit"
  "Decisions"
  "New surface"
  "Steps"
  "Verification"
  "Fallback"
)

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
  # Same jq construction and the same fail-open reasoning as deny(): $1 quotes
  # a path and a heading read out of a model-written prompt and file. The
  # message class differs on purpose (Aaron, 2026-09-08) because neither
  # arming nor delegation is the remedy here. The remedy is a plan file with
  # the required shape, approved before the spawn.
  jq -cn --arg r "NO APPROVED PLAN: $1. A write-capable spawn requires a plan file under $PLAN_DIR/ carrying all eight sections (Goal, Out of scope, Design fit, Decisions, New surface, Steps, Verification, Fallback), 40+ non-whitespace characters in each, and an 'Options:' line under Decisions. Template: $PLAN_TEMPLATE. Write or fix the plan, then ask Aaron to approve it and arm the gate again." \
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

# Redirect targets and the path arguments of cp/mv/rm-style commands may point
# anywhere in /tmp, which is scratch by construction and subsumes the
# scratchpad prefixes above. /private/tmp is the same directory as /tmp on
# macOS (/tmp is a symlink to it), so both spellings carry the same
# permission. Everything else, a relative path included, is outside.
is_bash_write_path() {
  case "$1" in
    *..*) return 1 ;;
    /tmp/* | /private/tmp/*) return 0 ;;
  esac
  return 1
}

# A redirection writes a file unless its target is scratch space or /dev/null.
# Descriptor moves (2>&1, >&2, 1>&2) move a fd and write nothing. A target
# that cannot be resolved to an allowed prefix fails CLOSED, including a
# target hidden inside quotes, which the disarmed allowlist below already
# refuses for the same reason.
check_redirects() {
  local tok target
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    case "$tok" in
      *'>'*) ;;
      *) continue ;;
    esac
    case "$tok" in
      '>&'[0-9] | [0-9]'>&'[0-9] | '&>&'[0-9]) continue ;;
    esac
    target="${tok#[0-9]}"
    target="${target#&}"
    target="${target#>}"
    target="${target#>}"
    target="${target#|}"
    if [ -z "$target" ]; then
      target="${1:-}"
      [ "$#" -gt 0 ] && shift
    fi
    case "$target" in
      /dev/null) continue ;;
    esac
    if is_bash_write_path "$target"; then
      continue
    fi
    deny_orchestrator "a redirection writing to '${target:-an unreadable target}'"
  done
}

# Every path argument of a file-moving command has to land in scratch space.
# An argument starting with - is a flag; anything else is treated as a path,
# so a relative path is outside by definition. A mode or owner argument (the
# 755 of chmod) reads as a relative path here and is refused with it; that is
# the fail-closed side of the same rule.
check_path_args() {
  local name tok prev
  name="$1"
  shift
  prev=""
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    case "$prev" in
      *'>')
        # consumed as the target of a redirection, already checked above
        prev="$tok"
        continue
        ;;
    esac
    prev="$tok"
    case "$tok" in
      -* | *'>'*) continue ;;
    esac
    if is_bash_write_path "$tok"; then
      continue
    fi
    deny_orchestrator "$name with the path '$tok' outside scratch space"
  done
}

# `\rm`, "rm" and /bin/rm all run rm, so the command word is normalized before
# it is compared. A deny list that skips normalization is walked past by a
# quoting trick, which is the bypass class found live on 2026-08-31 when
# '\mkdir x' sailed through the allowlist. Sets NORM rather than echoing,
# because a command substitution would run in a subshell and a denial there
# could not exit the hook.
NORM=""
normalize_word() {
  NORM="${1//\\/}"
  NORM="${NORM//\"/}"
  NORM="${NORM//\'/}"
  NORM="${NORM##*/}"
}

# Constructs the orchestrator may never run, checked in the same shape the
# disarmed allowlist below uses: split the compound on | ; && || and read the
# leading word(s) of each simple command. Newlines already separate segments,
# so a heredoc body is examined as its own segment. Substitution boundaries
# ($( , <( , backtick and the closing paren) split too: `echo $(rm -rf x)`
# runs rm, so rm has to be read as the leading word of a segment of its own.
orchestrator_bash_scan() {
  local normalized seg first sub
  normalized="$(printf '%s' "$1" | sed -E 's/\|\||&&|;|\||\$\(|<\(|\)|`/\n/g')"

  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [ -z "$seg" ] && continue
    # shellcheck disable=SC2086
    check_redirects $seg

    # shellcheck disable=SC2086
    set -- $seg
    # A leading command/env/nohup/time/sudo/xargs word or a VAR=value
    # assignment only prefixes the real command word; step over them to reach
    # it, so `xargs rm <path>` is read as rm.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        command | env | nohup | time | sudo | xargs | *=*) shift ;;
        *) break ;;
      esac
    done
    normalize_word "${1:-}"
    first="$NORM"

    case "$first" in
      python | python[0-9]* | perl | ruby | node | nodejs | bun | deno | php)
        # Any form writes files: a script file, -c, -e, a - stdin script or a
        # heredoc. The interpreter itself is the construct being refused.
        deny_orchestrator "the interpreter '$first', which can write files in any form"
        ;;
      tee | truncate | dd | install | rsync | patch)
        deny_orchestrator "the file-writing command '$first'"
        ;;
      sed)
        case "$seg" in
          *" -i"* | *" --in-place"*) deny_orchestrator "sed in-place editing" ;;
        esac
        ;;
      cp | mv | rm | mkdir | touch | ln | chmod | chown | rmdir)
        shift
        check_path_args "$first" "$@"
        ;;
      find)
        # Same rule the disarmed allowlist below already applies to find, for
        # the same reason: -delete and -exec turn a search into a write.
        case "$seg" in
          *-delete* | *-exec*) deny_orchestrator "find with -delete or -exec" ;;
        esac
        ;;
      git)
        # Skip the global options to find the real subcommand, keeping the
        # ones that take a value in a separate word paired with it.
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -C | -c | --git-dir | --work-tree | --namespace | --exec-path | --config-env)
              shift 2 || break
              ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        normalize_word "${1:-}"
        sub="$NORM"
        case "$sub" in
          add | commit | cherry-pick | rebase | merge | apply | am | revert | reset | restore | checkout | switch | stash | worktree | pull | tag | rm | mv | clean | init | clone | notes | filter-branch | replace | update-ref | symbolic-ref)
            deny_orchestrator "git $sub, which changes a working tree or git history"
            ;;
          branch)
            case "$seg" in
              *" -D"* | *" -d"* | *" -m"* | *" -M"* | *" -f"* | *" --force"* | *" --delete"* | *" --move"*)
                deny_orchestrator "git branch mutation"
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done <<EOF_SEGMENTS
$normalized
EOF_SEGMENTS
}

# ---------------------------------------------------------------------------
# Orchestrator-only enforcement (Aaron, 2026-09-08), ahead of the armed
# early-allow so the marker cannot lift it. Everything not refused here is
# left to the marker and, while disarmed, to the read-only allowlist below:
# git push, git fetch, gh, docker, make, op, aws, curl and process control
# stay allowed when armed, because shipping is the orchestrator's job.
#
# Build tools (pnpm, npm, go, make) stay allowed too, on the grounds that they
# write only inside node_modules, dist and build caches of a worktree an
# executor owns. That is a judgment call about blast radius rather than a
# guarantee, and Aaron may tighten it later; a tightening belongs in the scan
# below, next to the interpreters.
# ---------------------------------------------------------------------------
case "$TOOL" in
  Write | Edit | NotebookEdit)
    # Memory is EXEMPT (Aaron, 2026-08-13): remembering is Claude's job, not
    # plan execution. The session scratchpad is exempt on the same reasoning,
    # since notes and working files there are not the codebase. Every other
    # file, armed or not, belongs to an executor.
    FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    case "$FILE_PATH" in
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
    # Stderr-only redirects (2>/dev/null, 2>&1) cannot write files, so strip
    # them once here (Aaron, 2026-08-21: reading is never gated). Both the
    # orchestrator scan and the disarmed redirection test read the stripped
    # copy.
    CMD_REDIR_TEST="${CMD//2>\/dev\/null/}"
    CMD_REDIR_TEST="${CMD_REDIR_TEST//2>&1/}"
    orchestrator_bash_scan "$CMD_REDIR_TEST"
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

# Escapes the ERE metacharacters of a literal path segment before it is
# spliced into the plan-path pattern. A project directory named with a dot or
# a plus would otherwise match more than itself.
re_escape() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

# BSD stat and GNU stat spell the modification time differently, so try the
# macOS form first and fall back to the GNU one. Prints nothing if neither
# works, which the caller treats as a failure. -L follows a symlink to its
# target: BSD stat reports the link's own mtime otherwise, which would let a
# plan symlinked before arming have its target rewritten after it and still
# read as fresh.
file_mtime() {
  stat -L -f %m "$1" 2>/dev/null || stat -L -c %Y "$1" 2>/dev/null || true
}

# Prints the body of one `## ` section: every line after the heading up to the
# next `## ` heading or EOF. Sections may appear in any order, so the walk
# tracks which heading it is inside rather than counting.
plan_section() {
  awk -v want="$2" '
    /^## / {
      name = substr($0, 4)
      sub(/[[:space:]]+$/, "", name)
      inside = (name == want)
      next
    }
    inside { print }
  ' "$1"
}

# The plan-file rule (Aaron, 2026-09-08). Called only for a write-capable
# Agent spawn from the main session with the marker already in place, so the
# arming message still comes first while disarmed and the marker check stays
# the outer gate. Every failure exits through deny_plan naming the one check
# that failed; falling off the end means the plan is valid.
check_plan_file() {
  local prompt plan_re plan heading body nws marker_mtime plan_mtime newest

  prompt="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // empty')"

  # The prompt must carry the path, so the plan the executor is told to build
  # from is the same file the gate validated. Newest-by-mtime is used only for
  # the denial hint below. The filename segment excludes / and whitespace,
  # which keeps the match inside the project's plans directory and lets
  # trailing punctuation in prose fall outside it.
  plan_re="($(re_escape "$HOME")|~)/\\.claude/plans/$(re_escape "$PROJECT_NAME")/[^[:space:]/]+\\.md"
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

  if [ ! -f "$plan" ]; then
    deny_plan "the plan file '$plan' named in the prompt is not an existing regular file"
  fi

  for heading in "${PLAN_HEADINGS[@]}"; do
    if ! grep -qE "^## $heading[[:space:]]*\$" "$plan"; then
      deny_plan "'$plan' has no '## $heading' heading"
    fi
  done

  for heading in "${PLAN_HEADINGS[@]}"; do
    body="$(plan_section "$plan" "$heading")"
    nws="$(printf '%s' "$body" | tr -d '[:space:]' | wc -c)"
    nws="${nws//[[:space:]]/}"
    if [ "$nws" -lt 40 ]; then
      deny_plan "the '$heading' section of '$plan' holds $nws non-whitespace characters, under the 40 required"
    fi
  done

  # A here-string, not a pipe: with pipefail a producer killed by SIGPIPE when
  # grep -q exits early would set the pipeline's status and invert this test.
  body="$(plan_section "$plan" "Decisions")"
  if ! grep -qiE '^[[:space:]]*([-*]|[0-9]+\.)?[[:space:]]*Options:' <<<"$body"; then
    deny_plan "the 'Decisions' section of '$plan' has no 'Options:' line, so no alternatives were written down"
  fi

  # Freshness: approval covers the bytes Aaron read. A plan edited after the
  # marker was touched has not been approved in its current form.
  marker_mtime="$(file_mtime "$MARKER")"
  plan_mtime="$(file_mtime "$plan")"
  if [ -z "$marker_mtime" ] || [ -z "$plan_mtime" ]; then
    deny_plan "the modification time of '$plan' or of the approval marker could not be read"
  fi
  if [ "$marker_mtime" -lt "$plan_mtime" ]; then
    deny_plan "plan modified after arming: '$plan' is newer than the approval marker; arm again"
  fi
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

# Redirections and substitutions can smuggle writes through read-only tools.
# CMD and its stderr-stripped copy were read in the orchestrator branch above.
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
