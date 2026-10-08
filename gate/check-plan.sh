#!/usr/bin/env bash
# check-plan.sh: does this plan file carry the approved shape? Extracted from
# claude/hooks/approval-gate.sh on 2026-09-08/18 logic; shared by both
# harnesses. The CALLER extracts the plan path from wherever the harness puts
# it (Claude spawn prompt, OMP task text) and passes it here — path-in,
# verdict-out.
#
# Usage: check-plan.sh <plan-path> <marker-path>
#
# Verdict contract (same shape as scan-bash.sh): exit 0 = valid plan. exit 1 =
# invalid, one reason line on stdout holding exactly the text that was the
# deny_plan() argument in approval-gate.sh; the caller wraps it. exit 2 =
# usage error; callers treat anything but 0/1 as fail-closed.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: check-plan.sh <plan-path> <marker-path>\n' >&2
  exit 2
fi

plan="$1"
marker="$2"

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

verdict() {
  printf '%s\n' "$1"
  exit 1
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

# A project segment of ".." points the citation out of the plans root
# altogether, so it is refused rather than resolved.
case "$plan" in
  *..*) verdict "the plan path '$plan' holds '..', which is refused rather than resolved" ;;
esac

if [ ! -f "$plan" ]; then
  verdict "the plan file '$plan' named in the prompt is not an existing regular file"
fi

for heading in "${PLAN_HEADINGS[@]}"; do
  if ! grep -qE "^## $heading[[:space:]]*\$" "$plan"; then
    verdict "'$plan' has no '## $heading' heading"
  fi
done

for heading in "${PLAN_HEADINGS[@]}"; do
  body="$(plan_section "$plan" "$heading")"
  nws="$(printf '%s' "$body" | tr -d '[:space:]' | wc -c)"
  nws="${nws//[[:space:]]/}"
  if [ "$nws" -lt 40 ]; then
    verdict "the '$heading' section of '$plan' holds $nws non-whitespace characters, under the 40 required"
  fi
done

# A here-string, not a pipe: with pipefail a producer killed by SIGPIPE when
# grep -q exits early would set the pipeline's status and invert this test.
body="$(plan_section "$plan" "Decisions")"
if ! grep -qiE '^[[:space:]]*([-*]|[0-9]+\.)?[[:space:]]*Options:' <<<"$body"; then
  verdict "the 'Decisions' section of '$plan' has no 'Options:' line, so no alternatives were written down"
fi

# Freshness: approval covers the bytes Aaron read. A plan edited after the
# marker was touched has not been approved in its current form.
marker_mtime="$(file_mtime "$marker")"
plan_mtime="$(file_mtime "$plan")"
if [ -z "$marker_mtime" ] || [ -z "$plan_mtime" ]; then
  verdict "the modification time of '$plan' or of the approval marker could not be read"
fi
if [ "$marker_mtime" -lt "$plan_mtime" ]; then
  verdict "plan modified after arming: '$plan' is newer than the approval marker; arm again"
fi

exit 0
