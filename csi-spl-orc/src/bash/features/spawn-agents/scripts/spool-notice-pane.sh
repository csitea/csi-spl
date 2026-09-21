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

# How tall this pane is. A repaint that prints MORE lines than the pane holds
# scrolls, and since the newest record is printed FIRST it is the one that
# scrolls away - the exact opposite of what this pane is for. Measured on the
# live orchestrator pane 2026-09-21: 39 records into 8 rows showed the OLDEST.
pane_rows() {
  local r=""
  # tmux is the authority on its own pane. `tput lines` needs a terminfo entry
  # for $TERM, which inside tmux is a tmux-* name that is often not installed;
  # it then reports its 24-line default, 24 lines go into an 8-row pane, and
  # the newest record - printed first - scrolls straight off the top. That is
  # the whole bug, wearing a different hat.
  if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
    r="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_height}' 2>/dev/null)"
  fi
  [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 2 ] || r="$(tput lines 2>/dev/null)"
  [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 2 ] || r="${LINES:-24}"
  [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 2 ] || r=24
  printf '%s' "$r"
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
  local fit budget i head body
  fit="$(pane_rows)"
  # One row short of the pane: each printed line ends in a newline, so filling
  # every row scrolls the pane by one - and the line that leaves is the FIRST,
  # which is the newest record's header. Measured 2026-09-21: the pane opened
  # on the newest BODY, its header one row above the top.
  budget=$(( fit - 1 )); (( budget < 1 )) && budget=1
  if [ "${#rows[@]}" -eq 0 ]; then
    out=("${FAINT}(no messages yet - a DM to this agent appears here, newest first)${OFF}")
  else
    for (( i = ${#rows[@]} - 1; i >= 0; i-- )); do
      head="${rows[i]%%$'\t'*}"
      body="${rows[i]#*$'\t'}"
      [ "$body" = "${rows[i]}" ] && body=""
      out+=("${BLUE}${head}${OFF}")
      [ -n "$body" ] && out+=("${DIM}${body}${OFF}")
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
