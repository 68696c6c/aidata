#!/usr/bin/env bash
#
# review.sh — run the layered review doctrine against a diff, on any
# OpenAI-compatible chat-completions backend. Vendor-agnostic: the doctrine
# lives in markdown, this script only assembles and posts it.
#
# USAGE
#   review.sh                      # staged + unstaged changes vs HEAD
#   review.sh --range <a>..<b>     # any git range, e.g. origin/main..HEAD
#   review.sh --staged             # staged changes only
#   Run it from anywhere inside the repo being reviewed.
#
# DOCTRINE ASSEMBLED (same layers, same order, as the reviewer role)
#   ~/.claude/review/global.md                 always
#   ~/.claude/review/go.md                     iff <repo-root>/go.mod exists
#   <repo-root>/.claude/review/*.md            all of them
#   <repo-root>/REVIEW.md                      only if .claude/review/ is absent
#
# ENVIRONMENT (all three required, no defaults — this is a review tool and a
# silent pass is worse than no run)
#   REVIEW_API_BASE   OpenAI-compatible base URL, including the version path
#   REVIEW_MODEL      model id
#   REVIEW_API_KEY    bearer token
#
# VENDOR EXAMPLES (base URLs verified against vendor docs 2026-08-28)
#   Moonshot / Kimi — https://platform.kimi.ai/docs/api/chat
#     REVIEW_API_BASE=https://api.moonshot.ai/v1
#     REVIEW_MODEL=kimi-k3            # model list is on the page above
#     REVIEW_API_KEY=sk-...
#
#   xAI / Grok — https://docs.x.ai/docs/api-reference
#     REVIEW_API_BASE=https://api.x.ai/v1
#     REVIEW_MODEL=grok-4.6           # [verify] example-only in the reference;
#                                     # current ids: https://docs.x.ai/docs/models
#     REVIEW_API_KEY=xai-...
#
# TRUNCATION: none, deliberately. A diff over REVIEW_MAX_DIFF_BYTES (default
# 400000) fails with instructions to narrow the range. Silently truncating a
# review would report "clean" on code nobody looked at.
#
# EXIT CODES: 0 findings printed · 1 usage/env/diff error · 2 HTTP or API error

set -euo pipefail

die() { printf 'review.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

MODE=worktree
RANGE=

while [ $# -gt 0 ]; do
  case "$1" in
    --range) [ $# -ge 2 ] || die "--range needs an argument"; MODE=range; RANGE=$2; shift 2 ;;
    --staged) MODE=staged; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"
command -v git  >/dev/null || die "git not found"

: "${REVIEW_API_BASE:?REVIEW_API_BASE is not set (see the header for vendor examples)}"
: "${REVIEW_MODEL:?REVIEW_MODEL is not set}"
: "${REVIEW_API_KEY:?REVIEW_API_KEY is not set}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"

case "$MODE" in
  range)    DIFF=$(git -C "$REPO_ROOT" diff "$RANGE") || die "git diff $RANGE failed" ;;
  staged)   DIFF=$(git -C "$REPO_ROOT" diff --cached) || die "git diff --cached failed" ;;
  worktree) DIFF=$(git -C "$REPO_ROOT" diff HEAD)     || die "git diff HEAD failed" ;;
esac

[ -n "$DIFF" ] || die "empty diff — nothing to review (mode: $MODE${RANGE:+ $RANGE})"

MAX_BYTES=${REVIEW_MAX_DIFF_BYTES:-400000}
DIFF_BYTES=$(printf '%s' "$DIFF" | wc -c | tr -d ' ')
if [ "$DIFF_BYTES" -gt "$MAX_BYTES" ]; then
  die "diff is ${DIFF_BYTES} bytes, over the ${MAX_BYTES} limit. Narrow the range (review a single commit, a sub-path, or one PR at a time) and run again. This tool never truncates a diff." 1
fi

# --- assemble doctrine -------------------------------------------------------

LAYERS=()
GLOBAL="$HOME/.claude/review/global.md"
[ -f "$GLOBAL" ] || die "missing $GLOBAL — the global doctrine layer is mandatory"
LAYERS+=("$GLOBAL")

GO_MOD=$(find "$REPO_ROOT" -maxdepth 2 -name go.mod -not -path '*/node_modules/*' -print -quit 2>/dev/null)
if [ -n "$GO_MOD" ] && [ -f "$HOME/.claude/review/go.md" ]; then
  LAYERS+=("$HOME/.claude/review/go.md")
fi

REPO_LAYER_DIR="$REPO_ROOT/.claude/review"
if [ -d "$REPO_LAYER_DIR" ]; then
  while IFS= read -r f; do LAYERS+=("$f"); done < <(find "$REPO_LAYER_DIR" -maxdepth 1 -name '*.md' | sort)
elif [ -f "$REPO_ROOT/REVIEW.md" ]; then
  LAYERS+=("$REPO_ROOT/REVIEW.md")
fi

DOCTRINE=""
for f in "${LAYERS[@]}"; do
  DOCTRINE+=$'\n\n===== DOCTRINE LAYER: '"${f/#$HOME/~}"$' =====\n\n'
  DOCTRINE+=$(cat "$f")
done

printf 'review.sh: %d doctrine layer(s), %s diff bytes, model %s\n' \
  "${#LAYERS[@]}" "$DIFF_BYTES" "$REVIEW_MODEL" >&2
for f in "${LAYERS[@]}"; do printf '  layer: %s\n' "${f/#$HOME/~}" >&2; done

SYSTEM='You are a code reviewer. You judge a diff against the doctrine layers given to you and report findings. You never propose to apply a fix yourself. Follow the doctrine exactly: run the architecture pass first, then the layer rules, then report ranked prose findings with Blockers first, numbered, each carrying file:line and either the rule violated or a concrete failure scenario. Never output JSON. Never assert behavior you have not read in the diff; mark anything inferred. State which layers you applied and what you could not cover.'

USER=$'# Review doctrine\n'"$DOCTRINE"$'\n\n===== DIFF UNDER REVIEW =====\n\n```diff\n'"$DIFF"$'\n```\n'

BODY=$(jq -n \
  --arg model "$REVIEW_MODEL" \
  --arg system "$SYSTEM" \
  --arg user "$USER" \
  '{model: $model, messages: [{role:"system", content:$system}, {role:"user", content:$user}], temperature: 0}')

# --- call --------------------------------------------------------------------

RESP_FILE=$(mktemp); trap 'rm -f "$RESP_FILE"' EXIT

HTTP=$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "${REVIEW_API_BASE%/}/chat/completions" \
  -H "Authorization: Bearer $REVIEW_API_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @- <<<"$BODY") || die "request to $REVIEW_API_BASE failed" 2

if [ "$HTTP" != "200" ]; then
  printf 'review.sh: HTTP %s from %s\n' "$HTTP" "${REVIEW_API_BASE%/}/chat/completions" >&2
  cat "$RESP_FILE" >&2
  exit 2
fi

if jq -e '.error' "$RESP_FILE" >/dev/null 2>&1; then
  printf 'review.sh: API error\n' >&2; jq '.error' "$RESP_FILE" >&2; exit 2
fi

CONTENT=$(jq -r '.choices[0].message.content // empty' "$RESP_FILE")
[ -n "$CONTENT" ] || { printf 'review.sh: empty completion — raw response follows\n' >&2; cat "$RESP_FILE" >&2; exit 2; }

printf '%s\n' "$CONTENT"
