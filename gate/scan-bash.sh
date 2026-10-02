#!/usr/bin/env bash
# scan-bash.sh: is this shell command a write? Shared scanner, extracted
# verbatim from claude/hooks/approval-gate.sh on 2026-09-18 (the comments
# below are the history of bypasses found live; preserve them with the code).
# Single source for both harnesses: approval-gate.sh pipes Bash commands here,
# and the OMP write-gate hook (omp/hooks/write-gate.ts) execs it per bash call.
#
# Usage: scan-bash.sh --orchestrator | --disarmed     command on stdin
#
#   --orchestrator   refuses constructs a planning session must never run even
#                    when the gate is armed: interpreters, file-writing
#                    commands, in-place sed, mutating git, movers with paths
#                    outside scratch (/tmp), redirects outside scratch.
#   --disarmed       the read-only allowlist for a disarmed gate: every simple
#                    command in the compound must be a known read.
#
# Verdict contract: exit 0 = allow (stdout silent). exit 1 = deny, one
# tab-separated line on stdout: CLASS<TAB>REASON, where CLASS is
# "orchestrator" (refused in every gate state) or "disarmed" (refused only
# while the gate is disarmed). The CALLER wraps REASON in its own
# harness-specific framing, so REASON is exactly the text that was the
# deny*() argument in approval-gate.sh. exit 2 = usage error; callers treat
# anything but 0/1 as fail-closed.
set -euo pipefail
set -f # no pathname expansion while word-splitting command segments

MODE="${1:-}"
case "$MODE" in
  --orchestrator | --disarmed) ;;
  *)
    printf 'usage: scan-bash.sh --orchestrator|--disarmed (command on stdin)\n' >&2
    exit 2
    ;;
esac

CMD="$(cat)"

deny_with() {
  printf '%s\t%s\n' "$1" "$2"
  exit 1
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
    deny_with orchestrator "a redirection writing to '${target:-an unreadable target}'"
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
    deny_with orchestrator "$name with the path '$tok' outside scratch space"
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
        deny_with orchestrator "the interpreter '$first', which can write files in any form"
        ;;
      tee | truncate | dd | install | rsync | patch)
        deny_with orchestrator "the file-writing command '$first'"
        ;;
      sed)
        case "$seg" in
          *" -i"* | *" --in-place"*) deny_with orchestrator "sed in-place editing" ;;
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
          *-delete* | *-exec*) deny_with orchestrator "find with -delete or -exec" ;;
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
            deny_with orchestrator "git $sub, which changes a working tree or git history"
            ;;
          branch)
            case "$seg" in
              *" -D"* | *" -d"* | *" -m"* | *" -M"* | *" -f"* | *" --force"* | *" --delete"* | *" --move"*)
                deny_with orchestrator "git branch mutation"
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

# Stderr-only redirects (2>/dev/null, 2>&1) cannot write files, so strip them
# once here (Aaron, 2026-08-21: reading is never gated). Both the orchestrator
# scan and the disarmed redirection test read the stripped copy.
CMD_REDIR_TEST="${CMD//2>\/dev\/null/}"
CMD_REDIR_TEST="${CMD_REDIR_TEST//2>&1/}"

if [ "$MODE" = "--orchestrator" ]; then
  orchestrator_bash_scan "$CMD_REDIR_TEST"
  exit 0
fi

# --disarmed: read-only allowlist ------------------------------------------
# The disarmed state composes BOTH scans, matching how approval-gate.sh always
# ran the orchestrator scan ahead of the marker test: a single call answers
# "is this command allowed in this gate state", so no caller can forget the
# composition. Orchestrator-class reasons are reported with their own class so
# the caller frames them with the right remedy.
orchestrator_bash_scan "$CMD_REDIR_TEST"

# Redirections and substitutions can smuggle writes through read-only tools.
case "$CMD_REDIR_TEST" in
  *'>'* | *'$('* | *'<('* | *'`'*)
    deny_with disarmed "Bash with redirection or substitution is blocked while disarmed (read-only simple commands only)"
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
        *" -i"*) deny_with disarmed "sed -i is blocked while disarmed (in-place edit)" ;;
      esac
      continue
      ;;
    curl)
      case "$seg" in
        *" -X GET"* | *" -X HEAD"*) : ;;
        *" -X "* | *" --request"* | *" --data"* | *" -d "* | *" -F "* | *" --form"* | *" -T "* | *" --upload-file"*)
          deny_with disarmed "curl with a mutating method or body is blocked while disarmed"
          ;;
      esac
      case "$seg" in
        *" -o /dev/null"*) : ;;
        *" -o "* | *" --output"*) deny_with disarmed "curl -o to a file is blocked while disarmed" ;;
      esac
      continue
      ;;
    find)
      case "$seg" in
        *-delete* | *-exec*) deny_with disarmed "find with -delete/-exec is blocked while disarmed" ;;
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
              deny_with disarmed "git branch mutation is blocked while disarmed"
              ;;
          esac
          continue
          ;;
        *) deny_with disarmed "git $second is blocked while disarmed (read-only git subcommands only)" ;;
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
              deny_with disarmed "gh api with a method or fields is blocked while disarmed"
              ;;
          esac
          continue
          ;;
        *) deny_with disarmed "gh $second is blocked while disarmed (read-only gh subcommands only)" ;;
      esac
      ;;
    docker)
      case "$second ${3:-}" in
        "ps "* | "ps" | "images "* | "images" | "inspect "* | "compose ps" | "compose logs" | "compose images")
          continue
          ;;
        *) deny_with disarmed "docker $second is blocked while disarmed" ;;
      esac
      ;;
    *)
      deny_with disarmed "Bash command starting with $first is not on the disarmed read-only allowlist"
      ;;
  esac
done <<EOF_SEGMENTS
$NORMALIZED
EOF_SEGMENTS

exit 0
