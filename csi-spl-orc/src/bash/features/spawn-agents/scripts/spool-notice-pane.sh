#!/usr/bin/env bash
# spool-notice-pane.sh — the newest notice on TOP, in an agent's notice pane.
#
# specs/028-spool-terminal-delivery. The pane spool_poke_show splits into an
# agent's window runs this; it is not a `tail`. A terminal appends, and the
# owner's rule for every listing is newest-first (013/CLE-3425), so the pane is
# REPAINTED on each new notice with the newest record at the top.
#
#   spool-notice-pane.sh --log <file> [--max 50]
#
# The wake-up is `tail -F` on the log: it blocks in the kernel until a line is
# written, so this costs nothing while nothing arrives. Bursts are coalesced -
# several notices in the same instant repaint once.
#
# The log is one record per line, TAB-separated: <head>\t<body>. Bodies are
# already squeezed to one line by spool_notify_clean, so a line IS a record.
# Only the last --max records are kept in the file, and only as many as the
# pane is TALL are painted - printing more would scroll the newest record,
# which is printed first, straight off the top.
#
# Since 2026-09-22 the pane is a narrow RIGHT-HAND strip, not a full-width
# bottom bar, so every record is WORD-WRAPPED to the pane's width here rather
# than left to the terminal. Two reasons, and neither is cosmetic:
#
#   1. a terminal wrap costs rows the budget below did not count, so a record
#      that looked like 2 rows lands as 5 and pushes the newest record - which
#      is printed FIRST - off the top. That is the same bug pane_rows exists to
#      stop, arriving through the width instead of the height.
#   2. a wrap at the pane edge breaks mid-word and leaves no indent, so a
#      48-column strip reads as a wall. A wrapped continuation is indented by
#      two, which is what makes it read as a chat column.
set -uo pipefail

LOG="" MAX=50
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log) [ "$#" -ge 2 ] || { echo "usage: spool-notice-pane.sh --log <file> [--max N]" >&2; exit 2; }; LOG="$2"; shift 2 ;;
    --max) [ "$#" -ge 2 ] || exit 2; MAX="$2"; shift 2 ;;
    -h|--help) echo "usage: spool-notice-pane.sh --log <file> [--max N]" >&2; exit 2 ;;
    *) echo "spool-notice-pane: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$LOG" ] || { echo "spool-notice-pane: --log is required" >&2; exit 2; }
[[ "$MAX" =~ ^[0-9]+$ ]] && [ "$MAX" -gt 0 ] || MAX=50
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: >>"$LOG" || { echo "spool-notice-pane: cannot write $LOG" >&2; exit 73; }

esc=$'\033'
tab=$'\t'

# A repaint pushes the previous screenful into the pane's SCROLLBACK, so after
# a few messages `capture-pane -S -200` shows the same notice several times and
# the newest sits in the middle of a history nobody asked for - which reads
# exactly like a duplicate delivery. Measured on the live orchestrator pane
# 2026-09-21: one notice at scrollback lines 78 AND 115 of a 200-line capture,
# from ONE delivery.
#
# So the scrollback is dropped after each paint. The pane then holds exactly
# what is on screen, and a capture cannot lie about how many times a message
# arrived. The alternate screen would also do it, but `capture-pane` needs -a
# to read that, and every existing measurement here - the probe's, the
# orchestrator's - captures without it; a surface that needs a special flag to
# observe is a surface people will mis-measure.
drop_scrollback() {
  [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ] || return 0
  tmux clear-history -t "$TMUX_PANE" 2>/dev/null || true
}

colour() { [ -z "${NO_COLOR:-}" ] && [ "${SPOOL_SHOW_COLOUR:-1}" = 1 ]; }
if colour; then
  BLUE="${esc}[1;38;5;39m"; DIM="${esc}[38;5;110m"; FAINT="${esc}[38;5;66m"; OFF="${esc}[0m"
else
  BLUE="" DIM="" FAINT="" OFF=""
fi

# How tall AND how wide this pane is, into PANE_ROWS / PANE_COLS. A repaint
# that prints MORE lines than the pane holds scrolls, and since the newest
# record is printed FIRST it is the one that scrolls away - the exact opposite
# of what this pane is for. Measured on the live orchestrator pane 2026-09-21:
# 39 records into 8 rows showed the OLDEST.
#
# One tmux round trip for both numbers: this runs on every repaint.
PANE_ROWS=24 PANE_COLS=80
pane_geom() {
  local g="" r="" c=""
  # tmux is the authority on its own pane. `tput lines` needs a terminfo entry
  # for $TERM, which inside tmux is a tmux-* name that is often not installed;
  # it then reports its 24-line default, 24 lines go into an 8-row pane, and
  # the newest record - printed first - scrolls straight off the top. That is
  # the whole bug, wearing a different hat.
  if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
    g="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_height} #{pane_width}' 2>/dev/null)"
    r="${g%% *}"; c="${g##* }"
  fi
  [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 2 ] || r="$(tput lines 2>/dev/null)"
  [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 2 ] || r="${LINES:-24}"
  [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 2 ] || r=24
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 8 ] || c="$(tput cols 2>/dev/null)"
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 8 ] || c="${COLUMNS:-80}"
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 8 ] || c=80
  PANE_ROWS="$r"; PANE_COLS="$c"
}

# WRAPPED: TEXT broken into lines of at most WIDTH columns, every line after
# the first indented by INDENT. A word too long to fit a line of its own is
# hard-split rather than handed to the terminal, because the terminal's own
# wrap is the row the budget did not count.
#
# Pure parameter expansion: this runs once per printed record on every repaint,
# and a `fold` here is a process per record.
WRAPPED=()
wrap_text() {  # TEXT WIDTH INDENT
  local text="$1" width="$2" indent="$3" line="" word budget cont pad i
  local -  # restores the shell options set below on return
  set -f   # a body may hold * or ? and this is an unquoted expansion
  WRAPPED=()
  [[ "$width" =~ ^[0-9]+$ ]] && [ "$width" -ge 8 ] || width=8
  [[ "$indent" =~ ^[0-9]+$ ]] && [ "$indent" -le $(( width - 4 )) ] || indent=0
  cont=$(( width - indent ))
  budget=$width
  for word in $text; do
    while [ "${#word}" -gt "$budget" ]; do
      if [ -n "$line" ]; then WRAPPED+=("$line"); line=""; budget=$cont; continue; fi
      WRAPPED+=("${word:0:$budget}"); word="${word:$budget}"; budget=$cont
    done
    if [ -z "$line" ]; then line="$word"
    elif [ $(( ${#line} + 1 + ${#word} )) -le "$budget" ]; then line="$line $word"
    else WRAPPED+=("$line"); line="$word"; budget=$cont
    fi
  done
  [ -n "$line" ] && WRAPPED+=("$line")
  printf -v pad '%*s' "$indent" ''
  for (( i = 1; i < ${#WRAPPED[@]}; i++ )); do WRAPPED[i]="${pad}${WRAPPED[i]}"; done
}

# A head with its uuids shortened to eight characters, for DISPLAY only.
#
# In a 48-column strip a full head is three rows, two of them routing metadata
# a human does not read: "task 57e6f191-582e-45b1-a08e-389c0b034803 msg
# ca8bb6f3-5f68-49fc-aea2-857021dbf44b". Two messages then fill sixteen rows of
# a pane the owner asked to read as a CHAT. Eight characters is what git, the
# hub's own logs and every id in this repo's reports use, and it is enough to
# match an id against a log line.
#
# The LOG keeps the full ids - this is the renderer, and the record is the
# record. The poke line the agent acts on is untouched, so nothing that needs
# a whole uuid ever sees a shortened one.
shorten_ids() {  # HEAD
  printf '%s' "$1" | sed -E 's/\b([0-9a-fA-F]{8})-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/\1/g'
}

render() {
  local -a rows=() out=()
  # A record is <head>TAB<body> and carries no control characters: this
  # renderer writes the colour, the log never does. Anything else was written
  # by an OLDER or FOREIGN writer - a second checkout of this feature pointed
  # at the same spool root, which happened on this box 2026-09-21 - and is
  # skipped rather than painted. Painting it produced body-above-header
  # nonsense, because an older writer put one record on three lines.
  while IFS= read -r line; do
    case "$line" in
      *"$esc"*) continue ;;
      *"$tab"*) rows+=("$line") ;;
    esac
  done < <(tail -n "$MAX" "$LOG" 2>/dev/null)
  local budget i j head body
  pane_geom
  # One row short of the pane: each printed line ends in a newline, so filling
  # every row scrolls the pane by one - and the line that leaves is the FIRST,
  # which is the newest record's header. Measured 2026-09-21: the pane opened
  # on the newest BODY, its header one row above the top.
  budget=$(( PANE_ROWS - 1 )); (( budget < 1 )) && budget=1
  if [ "${#rows[@]}" -eq 0 ]; then
    wrap_text "(no messages yet - a DM to this agent appears here, newest first)" "$PANE_COLS" 2
    for (( j = 0; j < ${#WRAPPED[@]}; j++ )); do out+=("${FAINT}${WRAPPED[j]}${OFF}"); done
  else
    for (( i = ${#rows[@]} - 1; i >= 0; i-- )); do
      head="${rows[i]%%$'\t'*}"
      body="${rows[i]#*$'\t'}"
      [ "$body" = "${rows[i]}" ] && body=""
      wrap_text "$(shorten_ids "$head")" "$PANE_COLS" 2
      for (( j = 0; j < ${#WRAPPED[@]}; j++ )); do out+=("${BLUE}${WRAPPED[j]}${OFF}"); done
      if [ -n "$body" ]; then
        wrap_text "$body" "$PANE_COLS" 2
        for (( j = 0; j < ${#WRAPPED[@]}; j++ )); do out+=("${DIM}${WRAPPED[j]}${OFF}"); done
      fi
      out+=("")
      # Stop building as soon as the pane is full: the rest would scroll the
      # newest record off the top anyway.
      [ "${#out[@]}" -ge "$budget" ] && break
    done
  fi
  # Home + erase, then only what fits: a repaint is the only way to put the
  # newest record on top, and it must not overflow the pane.
  printf '%s[H%s[2J' "$esc" "$esc"
  for (( i = 0; i < ${#out[@]} && i < budget; i++ )); do
    printf '%s\n' "${out[i]}"
  done
  drop_scrollback
}

# Keep the file at the bound too, so a pane that runs for days stays cheap.
trim() {
  local n
  n="$(wc -l <"$LOG" 2>/dev/null)" || return 0
  [ "${n:-0}" -gt $(( MAX * 2 )) ] || return 0
  local tmp="$LOG.trim.$$"
  tail -n "$MAX" "$LOG" >"$tmp" 2>/dev/null && mv "$tmp" "$LOG" 2>/dev/null || rm -f "$tmp"
}

# A resize changes what fits, so repaint on SIGWINCH too.
trap 'render' WINCH

render
# tail -F blocks until a line is written: event-driven, no polling loop.
#
# From the BEGINNING, not `-n 0`. The notice that creates this pane is written
# a moment AFTER the split returns, so a tail that starts at EOF can position
# itself past it and the pane then sits on "(no messages yet)" until the
# SECOND message arrives - measured 2026-09-21, and it is the first message
# that matters most. What the wake-up carries is irrelevant: render re-reads
# the log, so replaying the existing lines at startup costs a few repaints and
# removes the race.
tail -n +1 -F "$LOG" 2>/dev/null | while IFS= read -r _; do
  # Coalesce a burst: drain whatever else is already queued, then repaint once.
  while IFS= read -r -t 0.05 _; do :; done
  trim
  render
done
