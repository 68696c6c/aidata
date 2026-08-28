#!/usr/bin/env bash
#
# install.sh — link aidata-managed files into place and bootstrap pilotfish.
#
# Idempotent: re-running is a no-op. Never clobbers a divergent local edit —
# a regular file whose content differs from the repo copy is left alone and
# reported loudly, because silently overwriting hand-tuned doctrine is worse
# than an unfinished install.
#
# Ownership:
#   aidata-owned  — symlinked into the repo; edit either path, it is one file
#   pilotfish     — seeded by copy ONLY when absent; pilotfish's own installer
#                   owns and upgrades them thereafter

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(dirname "$REPO")"
CLAUDE_HOME="$HOME/.claude"
CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"

REVIEW_BEGIN='<!-- aidata:review-role:begin -->'
REVIEW_END='<!-- aidata:review-role:end -->'
REVIEW_HEADING='## Review role (local, not pilotfish-managed)'
PILOTFISH_BEGIN='<!-- pilotfish:begin -->'

REVIEW_BLOCK="$REPO/claude/claude-md.d/review-role.md"
PILOTFISH_BLOCK="$REPO/pilotfish/claude-md-block.md"

n_linked=0; n_seeded=0; n_skipped=0; n_warned=0

say()  { printf '  %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; n_warned=$((n_warned + 1)); }

# --- aidata-owned files: symlink, never clobber ------------------------------

link_managed() {
  local src="$1" dest="$2"

  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      n_skipped=$((n_skipped + 1)); return 0
    fi
    warn "$dest is a symlink to $(readlink "$dest"), not to $src.
   Not touching it. Remove it by hand if you want aidata to manage this path."
    return 0
  fi

  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    warn "$dest exists and is not a regular file. Skipping."
    return 0
  fi

  if [ -f "$dest" ]; then
    if cmp -s "$dest" "$src"; then
      rm "$dest"; ln -s "$src" "$dest"
      say "linked   $dest (was an identical copy)"
      n_linked=$((n_linked + 1))
    else
      warn "$dest differs from the repo copy — NOT replaced.
   diff:               diff '$dest' '$src'
   keep repo version:  rm '$dest' && ./install.sh
   keep local version: cp '$dest' '$src' && ./install.sh"
    fi
    return 0
  fi

  ln -s "$src" "$dest"
  say "linked   $dest"
  n_linked=$((n_linked + 1))
}

# --- CLAUDE.md managed block -------------------------------------------------
#
# Owns ONLY the span between the aidata markers. Anything between the pilotfish
# markers is off limits — this never reads or writes past its own delimiters.

install_review_block() {
  local tmp; tmp="$(mktemp)"

  # Fresh machine: build the file from both snapshots, pilotfish first.
  if [ ! -f "$CLAUDE_MD" ]; then
    cat "$PILOTFISH_BLOCK" > "$tmp"
    printf '\n' >> "$tmp"
    cat "$REVIEW_BLOCK" >> "$tmp"
    mv "$tmp" "$CLAUDE_MD"
    say "created  $CLAUDE_MD (pilotfish snapshot + review-role block)"
    n_seeded=$((n_seeded + 1))
    return 0
  fi

  local total begin end
  total="$(wc -l < "$CLAUDE_MD" | tr -d ' ')"
  begin="$(grep -n -F -x "$REVIEW_BEGIN" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  end="$(grep -n -F -x "$REVIEW_END" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # Already marked: replace the span in place, inclusive of both markers.
  if [ -n "$begin" ]; then
    if [ -z "$end" ] || [ "$end" -lt "$begin" ]; then
      warn "$CLAUDE_MD has an aidata begin marker with no matching end marker.
   Refusing to guess where the block stops. Fix the markers by hand."
      rm -f "$tmp"; return 0
    fi
    head -n "$((begin - 1))" "$CLAUDE_MD" > "$tmp"
    cat "$REVIEW_BLOCK" >> "$tmp"
    tail -n +"$((end + 1))" "$CLAUDE_MD" >> "$tmp"
    if cmp -s "$tmp" "$CLAUDE_MD"; then
      rm -f "$tmp"; n_skipped=$((n_skipped + 1)); return 0
    fi
    cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
    say "updated  review-role block in $CLAUDE_MD"
    n_linked=$((n_linked + 1))
    return 0
  fi

  # MIGRATION: the section predates the markers. Cut the unmarked section out
  # before appending, or the append would duplicate the heading.
  local heading next_h stop
  heading="$(grep -n -F -x "$REVIEW_HEADING" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  if [ -n "$heading" ]; then
    next_h="$(tail -n +"$((heading + 1))" "$CLAUDE_MD" | grep -n '^## ' | head -1 | cut -d: -f1 || true)"
    if [ -n "$next_h" ]; then stop="$((heading + next_h - 1))"; else stop="$total"; fi
    head -n "$((heading - 1))" "$CLAUDE_MD" > "$tmp"
    tail -n +"$((stop + 1))" "$CLAUDE_MD" >> "$tmp"
    # Trim trailing blank lines so the appended block sits exactly one clear.
    printf '%s\n' "$(cat "$tmp")" > "$tmp.trim" && mv "$tmp.trim" "$tmp"
    printf '\n' >> "$tmp"
    cat "$REVIEW_BLOCK" >> "$tmp"
    cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
    say "migrated unmarked review-role section into a marker-wrapped block"
    n_linked=$((n_linked + 1))
    return 0
  fi

  # Absent entirely: append.
  cp "$CLAUDE_MD" "$tmp"
  printf '\n' >> "$tmp"
  cat "$REVIEW_BLOCK" >> "$tmp"
  cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
  say "appended review-role block to $CLAUDE_MD"
  n_linked=$((n_linked + 1))
}

# --- pilotfish bootstrap: seed only when absent -------------------------------

seed_pilotfish_agents() {
  local src dest base
  for src in "$REPO"/pilotfish/agents/*.md; do
    base="$(basename "$src")"
    dest="$CLAUDE_HOME/agents/$base"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      n_skipped=$((n_skipped + 1)); continue
    fi
    cp "$src" "$dest"
    say "seeded   $dest — run pilotfish's installer to upgrade"
    n_seeded=$((n_seeded + 1))
  done
}

seed_pilotfish_block() {
  [ -f "$CLAUDE_MD" ] || return 0
  if grep -q -F "$PILOTFISH_BEGIN" "$CLAUDE_MD"; then
    n_skipped=$((n_skipped + 1)); return 0
  fi

  local tmp begin; tmp="$(mktemp)"
  begin="$(grep -n -F -x "$REVIEW_BEGIN" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # The snapshot goes BEFORE the review-role block, which reads as its sequel.
  if [ -n "$begin" ]; then
    head -n "$((begin - 1))" "$CLAUDE_MD" > "$tmp"
    cat "$PILOTFISH_BLOCK" >> "$tmp"
    printf '\n' >> "$tmp"
    tail -n +"$begin" "$CLAUDE_MD" >> "$tmp"
  else
    cat "$PILOTFISH_BLOCK" > "$tmp"
    printf '\n' >> "$tmp"
    cat "$CLAUDE_MD" >> "$tmp"
  fi

  cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
  say "seeded   pilotfish block into $CLAUDE_MD — run pilotfish's installer to upgrade"
  n_seeded=$((n_seeded + 1))
}

# --- run ----------------------------------------------------------------------

printf 'aidata install — repo: %s\n\n' "$REPO"

mkdir -p "$CODE/.claude" "$CLAUDE_HOME/agents" "$CLAUDE_HOME/review"

printf 'project doctrine\n'
link_managed "$REPO/CLAUDE.md"            "$CODE/CLAUDE.md"
link_managed "$REPO/settings.local.json"  "$CODE/.claude/settings.local.json"

printf '\nreview system\n'
link_managed "$REPO/claude/agents/reviewer.md" "$CLAUDE_HOME/agents/reviewer.md"
link_managed "$REPO/claude/review/global.md"   "$CLAUDE_HOME/review/global.md"
link_managed "$REPO/claude/review/go.md"       "$CLAUDE_HOME/review/go.md"
link_managed "$REPO/claude/review/review.sh"   "$CLAUDE_HOME/review/review.sh"

printf '\npilotfish bootstrap\n'
seed_pilotfish_agents
seed_pilotfish_block

printf '\nglobal CLAUDE.md\n'
install_review_block

printf '\n%s\n' '----------------------------------------'
printf 'linked/updated %d · seeded %d · skipped %d · warned %d\n' \
  "$n_linked" "$n_seeded" "$n_skipped" "$n_warned"

if [ "$n_warned" -gt 0 ]; then
  printf '\nInstall finished with warnings — see above. Nothing was overwritten.\n' >&2
  exit 1
fi
