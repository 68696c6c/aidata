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

# jq is not optional: the user-settings merge below is jq-based, and the
# approval-gate hooks parse their stdin with jq at every tool call.
if ! command -v jq >/dev/null 2>&1; then
  printf '!! jq is not installed. It is required by the hook scripts and by the\n' >&2
  printf '   settings.json merge. Install it (brew install jq) and re-run.\n' >&2
  exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(dirname "$REPO")"
CLAUDE_HOME="$HOME/.claude"
CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
SETTINGS="$CLAUDE_HOME/settings.json"

PILOTFISH_BEGIN='<!-- pilotfish:begin -->'
PILOTFISH_END='<!-- pilotfish:end -->'

# Any fragment's begin marker, first line of each claude-md.d/*.md file.
AIDATA_MARKER_RE='^<!-- aidata:[a-z0-9-]+:begin -->$'

PILOTFISH_BLOCK="$REPO/pilotfish/claude-md-block.md"

n_linked=0; n_seeded=0; n_skipped=0; n_warned=0

say()  { printf '  %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; n_warned=$((n_warned + 1)); }

# head_upto N FILE — the first N lines, and NOTHING for N<=0. BSD/macOS `head`
# errors on `-n 0` ("illegal line count"), which under `set -e` aborts the whole
# install; that case is real whenever a managed marker sits on line 1 (e.g. a
# CLAUDE.md hand-reduced to just an aidata block, then re-seeded).
head_upto() {
  [ "$1" -le 0 ] && return 0
  head -n "$1" "$2"
}

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

# --- CLAUDE.md managed blocks --------------------------------------------------
#
# Every claude/claude-md.d/*.md file is a self-describing fragment: its first
# line is its own '<!-- aidata:<slug>:begin -->' marker and its last line the
# matching end marker, and fragments apply in lexical filename order (which is
# why the files carry number prefixes — later blocks may refer to earlier
# ones). Each install owns ONLY the span between its fragment's markers.
# Anything between the pilotfish markers is off limits — the guard below makes
# that a checked property rather than an accident of heading names.

install_md_blocks() {
  local frag

  # Fresh machine: seed the pilotfish snapshot, then let every fragment append
  # through the normal path below.
  if [ ! -f "$CLAUDE_MD" ]; then
    cat "$PILOTFISH_BLOCK" > "$CLAUDE_MD"
    say "created  $CLAUDE_MD (pilotfish snapshot)"
    n_seeded=$((n_seeded + 1))
  fi

  for frag in "$REPO"/claude/claude-md.d/*.md; do
    [ -f "$frag" ] || continue
    install_md_fragment "$frag"
  done
}

install_md_fragment() {
  local frag="$1"
  local begin_marker end_marker heading h_line tmp total begin end next_h stop
  local pf_begin pf_end

  begin_marker="$(head -1 "$frag")"
  end_marker="$(tail -1 "$frag")"
  case "$begin_marker" in '<!-- aidata:'*':begin -->') : ;;
    *) warn "$frag does not begin with an aidata marker — skipping."; return 0 ;;
  esac
  case "$end_marker" in '<!-- aidata:'*':end -->') : ;;
    *) warn "$frag does not end with an aidata marker — skipping."; return 0 ;;
  esac

  tmp="$(mktemp)"
  total="$(wc -l < "$CLAUDE_MD" | tr -d ' ')"
  begin="$(grep -n -F -x "$begin_marker" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  end="$(grep -n -F -x "$end_marker" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # Already marked: replace the span in place, inclusive of both markers.
  if [ -n "$begin" ]; then
    if [ -z "$end" ] || [ "$end" -lt "$begin" ]; then
      warn "$CLAUDE_MD has $begin_marker with no matching end marker.
   Refusing to guess where the block stops. Fix the markers by hand."
      rm -f "$tmp"; return 0
    fi
    head_upto "$((begin - 1))" "$CLAUDE_MD" > "$tmp"
    cat "$frag" >> "$tmp"
    tail -n +"$((end + 1))" "$CLAUDE_MD" >> "$tmp"
    if cmp -s "$tmp" "$CLAUDE_MD"; then
      rm -f "$tmp"; n_skipped=$((n_skipped + 1)); return 0
    fi
    cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
    say "updated  $(basename "$frag" .md) block in $CLAUDE_MD"
    n_linked=$((n_linked + 1))
    return 0
  fi

  # MIGRATION: the section predates the markers. Its heading is the fragment's
  # first '## ' line; cut the unmarked section out before appending, or the
  # append would duplicate it.
  heading="$(grep -m1 '^## ' "$frag" || true)"
  h_line=''
  [ -n "$heading" ] && h_line="$(grep -n -F -x "$heading" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # Never migrate a heading living inside the pilotfish span — upstream-owned.
  # Without this, a fragment headed like one of pilotfish's own sections would
  # cut upstream's text out of the file.
  pf_begin="$(grep -n -F -x "$PILOTFISH_BEGIN" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  pf_end="$(grep -n -F -x "$PILOTFISH_END" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"
  if [ -n "$h_line" ] && [ -n "$pf_begin" ] && [ -n "$pf_end" ] \
     && [ "$h_line" -ge "$pf_begin" ] && [ "$h_line" -le "$pf_end" ]; then
    h_line=''
  fi

  if [ -n "$h_line" ]; then
    next_h="$(tail -n +"$((h_line + 1))" "$CLAUDE_MD" | grep -n '^## ' | head -1 | cut -d: -f1 || true)"
    if [ -n "$next_h" ]; then stop="$((h_line + next_h - 1))"; else stop="$total"; fi
    head_upto "$((h_line - 1))" "$CLAUDE_MD" > "$tmp"
    tail -n +"$((stop + 1))" "$CLAUDE_MD" >> "$tmp"
    # Trim trailing blank lines so the appended block sits exactly one clear.
    printf '%s\n' "$(cat "$tmp")" > "$tmp.trim" && mv "$tmp.trim" "$tmp"
    printf '\n' >> "$tmp"
    cat "$frag" >> "$tmp"
    cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
    say "migrated unmarked $(basename "$frag" .md) section into a marked block"
    n_linked=$((n_linked + 1))
    return 0
  fi

  # Absent entirely: append.
  cp "$CLAUDE_MD" "$tmp"
  printf '\n' >> "$tmp"
  cat "$frag" >> "$tmp"
  cat "$tmp" > "$CLAUDE_MD"; rm -f "$tmp"
  say "appended $(basename "$frag" .md) block to $CLAUDE_MD"
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
  begin="$(grep -n -E "$AIDATA_MARKER_RE" "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)"

  # The snapshot goes BEFORE the first aidata block, whichever fragment that
  # is — the aidata blocks read as its sequel.
  if [ -n "$begin" ]; then
    head_upto "$((begin - 1))" "$CLAUDE_MD" > "$tmp"
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

# --- user settings hooks: surgical jq merge ------------------------------------
#
# Owns nothing in settings.json. It ADDS four hook entries and never modifies or
# removes anything already there: an entry is added only when no hook anywhere
# in the file already carries its exact command string, which is what makes a
# re-run a no-op.
#
# The two gate entries use the hooks EXEC form: because "args" is present the
# command is executed directly and each args element is passed as one argument
# with no shell quoting, so ${CLAUDE_PROJECT_DIR} — the project root where the
# session started — reaches the script as $1 whatever the path contains.

install_user_hooks() {
  local bell_stop bell_notify gate_pre gate_stop specs base tmp

  bell_stop='afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true'
  bell_notify='afplay /System/Library/Sounds/Ping.aiff 2>/dev/null || true'
  gate_pre="$CLAUDE_HOME/hooks/approval-gate.sh"
  gate_stop="$CLAUDE_HOME/hooks/disarm-gate.sh"

  specs="$(jq -n \
    --arg bell_stop "$bell_stop" \
    --arg bell_notify "$bell_notify" \
    --arg gate_pre "$gate_pre" \
    --arg gate_stop "$gate_stop" \
    '[
      { event: "Stop", cmd: $bell_stop, entry: {
          hooks: [ { type: "command", command: $bell_stop, async: true } ] } },
      { event: "Notification", cmd: $bell_notify, entry: {
          hooks: [ { type: "command", command: $bell_notify, async: true } ] } },
      { event: "PreToolUse", cmd: $gate_pre, entry: {
          matcher: "Agent|Workflow|Write|Edit|NotebookEdit|Bash",
          hooks: [ { type: "command", command: $gate_pre,
                     args: ["${CLAUDE_PROJECT_DIR}"], timeout: 15,
                     statusMessage: "approval gate" } ] } },
      { event: "Stop", cmd: $gate_stop, entry: {
          hooks: [ { type: "command", command: $gate_stop,
                     args: ["${CLAUDE_PROJECT_DIR}"] } ] } }
    ]')"

  if [ -e "$SETTINGS" ] && [ ! -f "$SETTINGS" ]; then
    warn "$SETTINGS exists and is not a regular file. Skipping the hooks merge."
    return 0
  fi

  if [ -f "$SETTINGS" ]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
      warn "$SETTINGS is not valid JSON — NOT touched. Fix it by hand and re-run.
   check: jq . '$SETTINGS'"
      return 0
    fi
    base="$SETTINGS"
  else
    base='/dev/null'
  fi

  tmp="$(mktemp "$SETTINGS.aidata.XXXXXX")"

  if ! jq --indent 2 -n --argjson specs "$specs" --slurpfile doc "$base" '
    def hascmd($c): [ .. | objects | select(.command? == $c) ] | length > 0;
    ($doc[0] // {})
    | reduce $specs[] as $s (.;
        if hascmd($s.cmd) then .
        else .hooks[$s.event] = ((.hooks[$s.event] // []) + [$s.entry])
        end)
  ' > "$tmp" 2>/dev/null || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "the hooks merge for $SETTINGS did not produce valid JSON — file untouched."
    return 0
  fi

  if [ -f "$SETTINGS" ] && cmp -s "$tmp" "$SETTINGS"; then
    rm -f "$tmp"; n_skipped=$((n_skipped + 1)); return 0
  fi

  # mktemp makes the file 0600; carry the live file's mode across so the merge
  # does not quietly retighten a config the user reads with other tools.
  local existed='no' mode
  if [ -f "$SETTINGS" ]; then
    existed='yes'
    mode="$(stat -f '%OLp' "$SETTINGS" 2>/dev/null || echo 644)"
  else
    mode=644
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$SETTINGS"
  if [ "$existed" = 'yes' ]; then
    say "merged   bell + approval-gate hooks into $SETTINGS"
    n_linked=$((n_linked + 1))
  else
    say "created  $SETTINGS (bell + approval-gate hooks)"
    n_seeded=$((n_seeded + 1))
  fi
}

# --- run ----------------------------------------------------------------------

printf 'aidata install — repo: %s\n\n' "$REPO"

mkdir -p "$CODE/.claude" "$CLAUDE_HOME/agents" "$CLAUDE_HOME/review" "$CLAUDE_HOME/hooks"

printf 'project doctrine\n'
link_managed "$REPO/CLAUDE.md"            "$CODE/CLAUDE.md"
link_managed "$REPO/settings.local.json"  "$CODE/.claude/settings.local.json"

printf '\nreview system\n'
link_managed "$REPO/claude/agents/reviewer.md" "$CLAUDE_HOME/agents/reviewer.md"
link_managed "$REPO/claude/review/global.md"   "$CLAUDE_HOME/review/global.md"
link_managed "$REPO/claude/review/go.md"       "$CLAUDE_HOME/review/go.md"
link_managed "$REPO/claude/review/review.sh"   "$CLAUDE_HOME/review/review.sh"

printf '\nhooks\n'
link_managed "$REPO/claude/hooks/approval-gate.sh" "$CLAUDE_HOME/hooks/approval-gate.sh"
link_managed "$REPO/claude/hooks/disarm-gate.sh"   "$CLAUDE_HOME/hooks/disarm-gate.sh"
install_user_hooks

printf '\npilotfish bootstrap\n'
seed_pilotfish_agents
seed_pilotfish_block

printf '\nglobal CLAUDE.md\n'
install_md_blocks

printf '\n%s\n' '----------------------------------------'
printf 'linked/updated %d · seeded %d · skipped %d · warned %d\n' \
  "$n_linked" "$n_seeded" "$n_skipped" "$n_warned"

if [ "$n_warned" -gt 0 ]; then
  printf '\nInstall finished with warnings — see above. Nothing was overwritten.\n' >&2
  exit 1
fi
