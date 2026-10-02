#!/usr/bin/env bash
# test.sh: run the bypass corpus (cases.tsv) against a gate and report
# expected-vs-actual verdicts.
#
# Two harnesses:
#   (default)   the Claude approval-gate hook, exercised end-to-end through its
#               real contract: Claude-format JSON on stdin, project dir as $1.
#   --direct    scan-bash.sh itself, one mode per case (unit level).
#
# Usage:
#   ./test.sh                 # end-to-end against ${GATE_HOOK:-../claude/hooks/approval-gate.sh}
#   ./test.sh --direct        # unit against ${SCAN_BASH:-./scan-bash.sh}
#
# Exit 0 when every case matches its expected verdict, 1 otherwise.
# Lines whose expected column says allow must print NOTHING to stdout in
# end-to-end mode; anything containing "deny" is a denial. That mirrors how the
# harness itself reads the hook's output.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES="${CASES:-$DIR/cases.tsv}"
GATE_HOOK="${GATE_HOOK:-$DIR/../claude/hooks/approval-gate.sh}"
SCAN_BASH="${SCAN_BASH:-$DIR/scan-bash.sh}"

DIRECT=0
[ "${1:-}" = "--direct" ] && DIRECT=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

verdict_e2e() {
  # $1 mode, $2 raw command (with \n escapes)
  local mode="$1" raw="$2" proj out
  proj="$WORK/proj"
  rm -rf "$proj"
  mkdir -p "$proj/.claude"
  [ "$mode" = "armed" ] && touch "$proj/.claude/plan-approved"
  out="$(jq -cn --arg c "$(printf '%b' "$raw")" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | bash "$GATE_HOOK" "$proj" 2>/dev/null || true)"
  if printf '%s' "$out" | grep -q '"deny"'; then
    printf 'deny'
  else
    printf 'allow'
  fi
}

verdict_direct() {
  # $1 mode, $2 raw command
  local mode="$1" raw="$2" scan_mode
  # corpus "armed" exercises the orchestrator scan (what an armed gate still
  # refuses); "disarmed" exercises the read-only allowlist.
  scan_mode="--orchestrator"
  [ "$mode" = "disarmed" ] && scan_mode="--disarmed"
  if printf '%b' "$raw" | bash "$SCAN_BASH" "$scan_mode" >/dev/null 2>&1; then
    printf 'allow'
  else
    printf 'deny'
  fi
}

while IFS=$'\t' read -r mode raw expected _rest; do
  case "$mode" in '' | \#*) continue ;; esac
  # "both" runs the case once per mode; an explicit mode runs it there only.
  modes="$mode"
  [ "$mode" = "both" ] && modes="disarmed armed"
  for m in $modes; do
    if [ "$DIRECT" -eq 1 ]; then
      actual="$(verdict_direct "$m" "$raw")"
    else
      actual="$(verdict_e2e "$m" "$raw")"
    fi
    if [ "$actual" = "$expected" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      printf 'FAIL [%s] %-46s expected=%s actual=%s\n' "$m" "$(printf '%b' "$raw" | tr '\n' '~')" "$expected" "$actual"
    fi
  done
done < "$CASES"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
