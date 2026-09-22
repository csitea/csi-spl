#!/usr/bin/env bash
# spool-strip-resize-proof.sh — why the notice pane is a RIGHT strip and not a
# BOTTOM bar, measured rather than argued.
#
# The owner's report (2026-09-22): "whenever this agent connects to the
# spool-hub the terminal gets kind of distorted at the end". Seating an agent
# splits a notice pane into its window, and until 2026-09-22 that split was
# `-v`, which takes the height away from a LIVE, already-painted CLI.
#
# This script draws a numbered screen on the ALTERNATE screen buffer - the one
# every full-screen CLI paints on; measured on this box, every live agent pane
# reports `#{alternate_on}` = 1 - and then splits it both ways, on a PRIVATE
# tmux server of its own. It touches no real window and no real agent.
#
# What it prints, per case: the pane size, whether the first drawn row is still
# the first row on screen, and whether the last one is still last. The claim
# under test is not "a split resizes the pane" (both do) but "a split MOVES
# what is already drawn" - because a CLI that repaints only its own live frame
# is anchored to a row, and a row that moved is the corruption.
#
#   spool-strip-resize-proof.sh [--cols 48] [--rows 8] [--keep]
#
# Exit 0 when the measurement came out the way the code assumes (height moves
# rows, width does not), 1 when it did not - so this is a gate as well as a
# demonstration, and a tmux that stops behaving this way fails it loudly.
set -uo pipefail

COLS=48 ROWS=8 KEEP=0 W=189 H=51
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cols) COLS="${2:?}"; shift 2 ;;
    --rows) ROWS="${2:?}"; shift 2 ;;
    --width) W="${2:?}"; shift 2 ;;
    --height) H="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '24p' "$0" | sed 's/^# *//'; exit 2 ;;
    *) echo "spool-strip-resize-proof: unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v tmux >/dev/null || { echo "spool-strip-resize-proof: tmux is not installed" >&2; exit 2; }

T="$(mktemp -d)"
SOCK="$T/tmux.sock"
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null; [ "$KEEP" = 1 ] || rm -rf "$T"; }
trap cleanup EXIT

# The subject: a full-screen painter that does NOT redraw on SIGWINCH, which is
# the worst case a partially-redrawing CLI degrades towards. It numbers every
# row so a shift of even one line is visible in the capture.
cat >"$T/painter.sh" <<'EOF'
#!/usr/bin/env bash
set -u
esc=$'\033'
rows="$(tput lines 2>/dev/null)"; [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
printf '%s[?1049h%s[H%s[2J' "$esc" "$esc" "$esc"
for ((i = 1; i < rows; i++)); do printf 'ROW-%03d\n' "$i"; done
printf 'ROW-END'
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
EOF
chmod +x "$T/painter.sh"

fails=0
say() { printf '%s\n' "$*"; }

# case DIRECTION SIZE LABEL: prints the measurement and puts "no" or
# "YES (...)" in MOVED. Not a command substitution: the report goes to stdout
# for the reader, so a caller that captured it would swallow the whole thing
# and then compare the report against "no", which always differs.
MOVED=""
case_split() {  # -v|-h SIZE LABEL
  local dir="$1" size="$2" label="$3" before after geom first last moved
  tmux -S "$SOCK" kill-server 2>/dev/null; sleep 0.2
  tmux -S "$SOCK" -f /dev/null new-session -d -s p -x "$W" -y "$H" -n w "$T/painter.sh" || return 1
  sleep 1
  before="$(tmux -S "$SOCK" capture-pane -p -t w.0 | sed -n '1p')"
  tmux -S "$SOCK" split-window -d "$dir" -l "$size" -t w.0 'sleep 600' 2>/dev/null
  sleep 1
  geom="$(tmux -S "$SOCK" display-message -p -t w.0 '#{pane_width}x#{pane_height}')"
  after="$(tmux -S "$SOCK" capture-pane -p -t w.0)"
  first="$(printf '%s\n' "$after" | sed -n '1p')"
  last="$(printf '%s\n' "$after" | grep -c 'ROW-END')"
  if [ "$first" = "$before" ]; then moved=no; else moved="YES ($before -> $first)"; fi
  say "  ${label}"
  say "    agent pane      : ${W}x${H} -> ${geom}"
  say "    first drawn row : ${moved}"
  say "    last drawn row  : $([ "$last" = 1 ] && echo 'still on screen' || echo 'GONE')"
  MOVED="$moved"
}

say "spool-strip-resize-proof: tmux $(tmux -V | awk '{print $2}'), a private server, window ${W}x${H}"
say ""
say "the OLD shape - a bottom bar, split -v -l ${ROWS}:"
case_split -v "$ROWS" "split-window -d -v -l ${ROWS}"; v="$MOVED"
say ""
say "the NEW shape - a right strip, split -h -l ${COLS}:"
case_split -h "$COLS" "split-window -d -h -l ${COLS}"; h="$MOVED"
say ""

if [ "$v" = no ]; then
  say "UNEXPECTED: the bottom bar did NOT move the drawn rows on this tmux."
  say "  The reason the strip is on the right no longer holds here - re-measure"
  say "  before trusting the comment in spool-poke-queue.inc.sh."
  fails=$((fails + 1))
else
  say "as assumed: a bottom bar MOVES what is already drawn."
fi
if [ "$h" = no ]; then
  say "as assumed: a right strip leaves every drawn row where it was."
else
  say "UNEXPECTED: the right strip moved the drawn rows too - the width knob"
  say "  would then be rotating the bug rather than removing it."
  fails=$((fails + 1))
fi
say ""
say "what a width change DOES cost: the line tails past the new width are cut,"
say "because tmux does not reflow the alternate screen. A CLI repaints those on"
say "its next frame; a row that moved is not repairable that way, which is the"
say "whole difference."
[ "$fails" -eq 0 ]
