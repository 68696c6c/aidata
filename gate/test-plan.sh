#!/usr/bin/env bash
# test-plan.sh: exercise check-plan.sh against fixture plans. Every shape rule
# gets one failing fixture and the valid fixture proves the happy path.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_PLAN="${CHECK_PLAN:-$DIR/check-plan.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MARKER="$WORK/plan-approved"
touch "$MARKER"

BODY='This section body holds well over forty non-whitespace characters of real content.'

# Emits a plan with every section valid except the overrides named in $1:
#   skip:<Heading>      omit the heading entirely
#   short:<Heading>     heading present, body too short
#   nooptions           Decisions body without an Options: line
make_plan() {
  local out="$1" variant="${2:-}"
  local h
  for h in "Goal" "Out of scope" "Design fit" "Decisions" "New surface" "Steps" "Verification" "Fallback"; do
    case "$variant" in
      "skip:$h") continue ;;
    esac
    printf '## %s\n' "$h" >>"$out"
    case "$variant" in
      "short:$h") printf 'too short\n' >>"$out" ;;
      *)
        if [ "$h" = "Decisions" ] && [ "$variant" != "nooptions" ]; then
          printf -- '- Options: do A, do B; chose A because it is boring and correct.\n' >>"$out"
        fi
        printf '%s\n' "$BODY" >>"$out"
        ;;
    esac
  done
}

pass=0
fail=0

expect() {
  # $1 label, $2 expected (allow|deny), $3 plan path arg, $4 marker path arg
  local label="$1" expected="$2" plan="$3" marker="$4" rc=0
  bash "$CHECK_PLAN" "$plan" "$marker" >/dev/null 2>&1 || rc=$?
  local actual=allow
  [ "$rc" -ne 0 ] && actual=deny
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: expected=%s actual=%s (rc=%d)\n' "$label" "$expected" "$actual" "$rc"
  fi
}

valid="$WORK/valid.md"; : >"$valid"; make_plan "$valid"
sleep 1.1 # plan must be OLDER than the marker for the freshness test below to mean anything
touch "$MARKER"
expect "valid plan" allow "$valid" "$MARKER"

missing_heading="$WORK/missing-heading.md"; : >"$missing_heading"; make_plan "$missing_heading" "skip:Fallback"
touch "$MARKER"
expect "missing heading" deny "$missing_heading" "$MARKER"

short_section="$WORK/short.md"; : >"$short_section"; make_plan "$short_section" "short:Steps"
touch "$MARKER"
expect "short section" deny "$short_section" "$MARKER"

no_options="$WORK/no-options.md"; : >"$no_options"; make_plan "$no_options" "nooptions"
touch "$MARKER"
expect "no Options line" deny "$no_options" "$MARKER"

expect "plan absent" deny "$WORK/does-not-exist.md" "$MARKER"
expect "traversal refused" deny "$WORK/../etc/plan.md" "$MARKER"
expect "marker absent" deny "$valid" "$WORK/no-marker"

stale="$WORK/stale.md"; : >"$stale"; make_plan "$stale"
touch "$MARKER"
sleep 1.1
touch "$stale" # plan edited AFTER arming
expect "plan newer than marker" deny "$stale" "$MARKER"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
