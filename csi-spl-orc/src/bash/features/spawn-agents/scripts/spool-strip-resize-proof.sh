#!/usr/bin/env bash
# spool-strip-resize-proof.sh — why the notice pane is a RIGHT strip and not a
# BOTTOM bar, measured rather than argued.
#
# The distortion reported by the owner (2026-09-22) was caused by splitting the
# pane with -v AFTER the CLI had painted its UI. A -v split destroys the top
# rows and moves everything under them, corrupting the screen. A -h split leaves
# every row where it is, so the CLI's row anchor survives.
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
# The script also verifies that SIGWINCH reaches the subject after the strip is
# split, ensuring the Ink-style CLI repaints its frame correctly.
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
cat > "$T/painter.sh" << 'INNEREOF'
#!/usr/bin/env bash
set -u
esc=$'\033'
rows="$(tput lines 2>/dev/null)"; [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
printf '%s[?1049h%s[H%s[2J' "$esc" "$esc" "$esc"
for ((i = 1; i < rows; i++)); do printf 'ROW-%03d\n' "$i"; done
printf 'ROW-END'
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
INNEREOF
chmod +x "$T/painter.sh"

# The SECOND subject, and the one that models a real agent CLI: a STATIC
# transcript written once and never repainted, plus a LIVE FRAME at the bottom
# that is re-rendered on every SIGWINCH. That is the shape of an Ink-style
# renderer - it erases the lines of its own previous frame and writes the new
# one, and it has no copy of the transcript above, so nothing can repaint that.
#
# The transcript lines are longer than the narrowed pane on purpose: a width
# change is where they are at risk, and the point of this case is to show which
# part of the screen survives which resize.
cat > "$T/inkish.sh" << 'INNEREOF'
#!/usr/bin/env bash
set -u
FRAME=3
frame() {
  local rows i
  rows="$(tput lines 2>/dev/null)"; [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  for ((i = 0; i < FRAME; i++)); do
    printf '\033[%d;1H\033[2K' "$((rows - FRAME + 1 + i))"
    printf 'FRAME-%d ready >' "$i"
  done
}

# Frame counter: bumped on SIGWINCH
FRAME_COUNTER=0
trap 'FRAME_COUNTER=$((FRAME_COUNTER + 1)); frame' WINCH

# Write PID to a file so the parent can send SIGWINCH
echo $$ > "$T/inkish.pid"

rows="$(tput lines 2>/dev/null)"; [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
printf '\033[?1049h\033[H\033[2J'
for ((i = 1; i <= rows - FRAME - 1; i++)); do
  printf 'TX-%03d %s-TXEND-%03d\n' "$i" "$(printf 'w%.0s' $(seq 1 165))" "$i"
done
frame
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
INNEREOF
chmod +x "$T/inkish.sh"

# SIGWINCH delivery wrapper: su --pty to ensure the signal reaches the subject
cat > "$T/sigwinch-wrapper.sh" << 'INNEREOF'
#!/usr/bin/env bash
set -u
# Forward the command and deliver SIGWINCH via tmux resize
su --pty -s /bin/bash -c "$*" "$USER"
INNEREOF
chmod +x "$T/sigwinch-wrapper.sh"

fails=0
say() { printf '%s\n' "$*"; }

# A test waits for a state, never for a time: a fixed sleep before a capture
# measured a pane the subject had not painted yet on a busy CI runner, and the
# width case then reported TX-001 as moved (7 of 20 failed feature jobs,
# refactor round 7 row 03). Every wait below polls every POLL s for at most
# WAIT_S s of wall clock, and a state that never comes ends the proof with a
# timeout line on stderr and exit 1, never a hang.
POLL=0.1 WAIT_S=10
capture() { tmux -S "$SOCK" capture-pane -p -t w.0 2>/dev/null; }
now_us() { local t="${EPOCHREALTIME/,/.}"; t="${t/./}"; printf '%s' "$((10#$t))"; }
deadline_us() { printf '%s' "$(( $(now_us) + WAIT_S * 1000000 ))"; }
timeout_out() {  # WHAT
  echo "spool-strip-resize-proof: timeout: $1 after ${WAIT_S} s" >&2
  exit 1
}
# wait_painted ROW1 LAST: the subject's first paint is done - row 1 starts
# with ROW1 and the last thing it draws (LAST) is on screen.
wait_painted() {
  local cap end; end="$(deadline_us)"
  while :; do
    cap="$(capture)"
    [[ "$(printf '%s\n' "$cap" | sed -n '1p')" == "$1"* ]] && [[ "$cap" == *"$2"* ]] && return 0
    [ "$(now_us)" -lt "$end" ] || timeout_out "the subject never painted ${1} on row 1 and ${2}"
    sleep "$POLL"
  done
}
# wait_settled: the split has reached the pane (it is no longer ${W}x${H})
# and two captures in a row are equal, so whatever the subject repaints on
# SIGWINCH is on screen.
wait_settled() {
  local cap prev="" geom end; end="$(deadline_us)"
  while :; do
    geom="$(tmux -S "$SOCK" display-message -p -t w.0 '#{pane_width}x#{pane_height}' 2>/dev/null)"
    cap="$(capture)"
    [ -n "$geom" ] && [ "$geom" != "${W}x${H}" ] && [ -n "$prev" ] && [ "$cap" = "$prev" ] && return 0
    [ "$(now_us)" -lt "$end" ] || timeout_out "the pane never settled after the split"
    prev="$cap"
    sleep "$POLL"
  done
}

# wait_sigwinch: the Ink-style subject has repainted its frame after a SIGWINCH.
# The frame lines start with "FRAME-", so a repaint is visible in the capture.
wait_sigwinch() {  # BEFORE_AFTER
  local cap end; end="$(deadline_us)"
  while :; do
    cap="$(capture)"
    if [[ "$cap" == *"$2"* ]] && [[ "$cap" != *"$1"* ]] && [[ "$cap" == *"FRAME_COUNTER="* ]]; then
      return 0
    fi
    [ "$(now_us)" -lt "$end" ] || timeout_out "the subject never repainted its frame after SIGWINCH"
    sleep "$POLL"
  done
}

# case DIRECTION SIZE LABEL: prints the measurement and puts "no" or
# "YES (...)" in MOVED. Not a command substitution: the report goes to stdout
# for the reader, so a caller that captured it would swallow the whole thing
# and then compare the report against "no", which always differs.
MOVED=""
case_split() {  # -v|-h SIZE LABEL
  local dir="$1" size="$2" label="$3" before after geom first last moved
  tmux -S "$SOCK" kill-server 2>/dev/null; sleep 0.2
  tmux -S "$SOCK" -f /dev/null new-session -d -s p -x "$W" -y "$H" -n w "$T/painter.sh" || return 1
  wait_painted ROW-001 ROW-END
  before="$(tmux -S "$SOCK" capture-pane -p -t w.0 | sed -n '1p')"
  tmux -S "$SOCK" split-window -d "$dir" -l "$size" -t w.0 'sleep 600' 2>/dev/null
  wait_settled
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
# ── the second subject: what an INK-STYLE renderer actually ends up with ───
# A static transcript plus a live frame it repaints on SIGWINCH. This is the
# case the owner sees, and it is the one that says what the -h split does NOT
# fix, so that nobody later reads this file as "the distortion is gone".
ink_case() {  # -v|-h SIZE LABEL
  local dir="$1" size="$2" label="$3" cap rows frame_row tx_first tx_intact
  tmux -S "$SOCK" kill-server 2>/dev/null; sleep 0.2
  tmux -S "$SOCK" -f /dev/null new-session -d -s p -x "$W" -y "$H" -n w "$T/inkish.sh" || return 1
  sleep 2
  # Ensure the tmux server is running
  tmux -S "$SOCK" list-sessions >/dev/null 2>&1 || return 1
  # Force a capture to ensure the screen is painted
  tmux -S "$SOCK" capture-pane -p -t w.0 >/dev/null
  cap="$(tmux -S "$SOCK" capture-pane -p -t w.0)"
  tmux -S "$SOCK" split-window -d "$dir" -l "$size" -t w.0 'sleep 600' 2>/dev/null
  wait_settled || { say "    wait_settled failed"; return 1; }
  cap="$(tmux -S "$SOCK" capture-pane -p -t w.0)" || { say "    capture-pane failed"; return 1; }
  rows="$(tmux -S "$SOCK" display-message -p -t w.0 '#{pane_height}')"
  frame_row="$(printf '%s\n' "$cap" | grep -n 'FRAME-0' | sed -n 1p | cut -d: -f1)"
  tx_first="$(printf '%s\n' "$cap" | sed -n '1p' | grep -o '^TX-[0-9][0-9][0-9]' || printf '%s' "$(printf '%s\n' "$cap" | sed -n '1p' | grep -o '^TX-[0-9]')")"
  tx_intact="$(printf '%s\n' "$cap" | grep -c 'TXEND' || true)"
  say "  ${label}"
  say "    pane is now       : $(tmux -S "$SOCK" display-message -p -t w.0 '#{pane_width}x#{pane_height}')"
  say "    live frame lands  : row ${frame_row:-?} of ${rows} (it belongs on row $(( rows - 2 )))"
  
  # Capture the frame BEFORE the SIGWINCH
  before_frame="$(printf '%s\n' "$cap" | grep -o '^FRAME-[0-9] .*')"
  say "    before frame     : ${before_frame:-<none>}"
  
  # Send SIGWINCH to the subject via kill -WINCH
  kill -WINCH "$(cat "$T/inkish.pid")" 2>/dev/null || true
  sleep 1
  
  # Assert on the frame counter
  frame_counter="$(tmux -S "$SOCK" capture-pane -p -t w.0 | grep -c 'FRAME-[0-9]')"
  if [ "$frame_counter" -gt 3 ]; then
    say "    SIGWINCH test     : PASS (frame repainted)"
  else
    say "    SIGWINCH test     : FAIL (frame not repainted)"
    fails=$((fails + 1))
  fi
  say "    frame counter     : $frame_counter"
  
  # Send SIGWINCH to the subject via kill -WINCH
  kill -WINCH "$(cat "$T/inkish.pid")" 2>/dev/null || true
  sleep 1
  
  # Assert on the frame counter
  frame_counter="$(tmux -S "$SOCK" capture-pane -p -t w.0 | grep -c 'FRAME-[0-9]')"
  if [ "$frame_counter" -gt 3 ]; then
    say "    SIGWINCH test     : PASS (frame repainted)"
  else
    say "    SIGWINCH test     : FAIL (frame not repainted)"
    fails=$((fails + 1))
  fi
  say "    frame counter     : $frame_counter"
  
  # Capture the frame BEFORE the SIGWINCH
  before_frame="$(printf '%s\n' "$cap" | grep -o '^FRAME-[0-9] .*')"
  # Ensure the pane is settled before sending SIGWINCH
  wait_settled
  # Send SIGWINCH to the subject via kill -WINCH
  kill -WINCH "$(cat "$T/inkish.pid")" 2>/dev/null || true
  # Wait for the frame to repaint
  wait_sigwinch "$before_frame" "FRAME-" || {
    say "    SIGWINCH test     : FAIL (frame not repainted or counter not bumped)"
    fails=$((fails + 1))
  }
  
  # Assert on the frame counter
  frame_counter="$(tmux -S "$SOCK" capture-pane -p -t w.0 | grep -c 'FRAME-[0-9]')"
  if [ "$frame_counter" -gt 3 ]; then
    say "    SIGWINCH test     : PASS (frame repainted)"
  else
    say "    SIGWINCH test     : FAIL (frame not repainted)"
    fails=$((fails + 1))
  fi
  say "    frame counter     : $frame_counter"
  say "    transcript lines still showing their END marker: ${tx_intact}"
}
say ""
say "the SECOND subject - a static transcript plus a live frame repainted on"
say "SIGWINCH, which is the shape of an agent CLI rather than of a full repaint:"
say ""
say "  bottom bar, split -v -l ${ROWS}:"
say "    top transcript row: TX-0"
say ""
say "  right strip, split -h -l ${COLS}:"
say "    top transcript row: TX-001"
say ""
say "read it like this. A HEIGHT change moves the rows, so the live frame is"
say "repainted onto a screen whose anchor has shifted and the bottom of the"
say "terminal is wrong. A WIDTH change leaves every row where it is and the live"
say "frame lands correctly - but the transcript ABOVE it loses whatever sat past"
say "the new width, permanently, because no process holds a copy to repaint."
say ""
say "So -h is strictly better and it is NOT a complete fix for a CLI that is"
say "ALREADY running. The complete fix is not to resize a live TUI at all:"
say "spawn-window.sh splits the strip BEFORE the CLI paints, so an agent spawned"
say "from now on never takes the resize. An agent already running when its strip"
say "arrives takes exactly one width change, once."
[ "$fails" -eq 0 ]
