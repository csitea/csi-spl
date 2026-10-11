#!/usr/bin/env bash
# The deferred close of a mistral lane (dispatch-f0256ec8, live proof m-897
# 2026-10-10): vibe renames itself "Vibe CLI" (setproctitle), so the closer
# found no agent PID ("agent_pids=none") and killed the window ~2 s after
# /exit-clean without typing /exit, busy or not. Now:
#   1. an idle vibe gets /exit typed and leaves by itself, well before the
#      timeout; the log names its PID and the /exit. Its prompt blinks the way
#      vibe's own cursor does (`>` / `> ` + a reverse-video space): m-900 sat
#      idle to the timeout on that blink (2026-10-10 19:25Z)
#   2. a vibe mid-turn (its footer `Esc/Ctrl+C to interrupt`, a static screen
#      with an empty `>` prompt) never gets /exit: the timeout closes it
#   3. control: the closer without the "Vibe CLI" match reads no PID and
#      kills the idle vibe's window without any /exit
#   4. control: the closer that keeps trailing blanks never reads the
#      blinking prompt as stable: no /exit, only the timeout
# Every wait is a bounded poll for the state (0.1 s, a cap in seconds), never a
# fixed sleep: on a loaded CI runner (n=2 in 300 wf 10 runs, 2026-10-10) case 3
# missed a 20-count wait and case 4's control read a 2-frame blink as stable.
# Each cap stays well under the timeout its case tells apart: under load the
# no-PID close of case 3 took 7 s of its 2.3 s of sleeps (5 of 20 runs > 10 s).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SUT="$T_SCRIPTS/tmux-close-window.sh"
unset MISTRAL_TMUX_PANE
export CLOSE_LOG_DIR="$T_TMP/logs" SPOOL_BOX_TAG=tbox; mkdir -p "$CLOSE_LOG_DIR"
t_tmux
alive() { tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{pane_dead}' | grep -x "$1 0" >/dev/null; }
gone() { ! tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -x "$1" >/dev/null; }
now_ms() { local t="${EPOCHREALTIME//[!0-9]/}"; printf '%s' "$((10#$t / 1000))"; }
wait_for() {  # CAP_S WHAT CMD... : true once CMD holds (polled every 0.1 s); false, naming WHAT, at the cap
  local cap="$1" what="$2" end; shift 2
  end=$(($(now_ms) + cap * 1000))
  until "$@"; do
    (($(now_ms) < end)) || { echo "  timeout ${cap}s: $what"; return 1; }
    sleep 0.1
  done
}
wait_gone() { wait_for "$2" "pane $1 still up" gone "$1"; }  # PANE CAP_S
# The fake vibe is up: its "Vibe CLI" process runs and its screen shows MARK.
vibe_up() {  # PANE GOT-FILE MARK
  pgrep -f "^Vibe CLI .*$2" >/dev/null &&
    tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$1" 2>/dev/null | grep -F -- "$3" >/dev/null
}
# Any case red: what each closer did, its stdout and its detached log.
why() {
  local f
  for f in "$T_TMP"/o[1-4] "$CLOSE_LOG_DIR"/kill-your-self-close-*.log; do
    [ -e "$f" ] && { echo "  --- ${f##*/}"; sed 's/^/  | /' "$f"; }
  done
}

mkdir -p "$T_TMP/bin"
# fake vibe: vibe 2.26.0's input box (rules around an empty `>`), reads lines
# into $1, leaves on /exit; $2=busy holds its mid-turn footer. Idle, its
# cursor blinks on the prompt line as vibe's does: a reverse-video space, then
# none (a concealed one). The cursor cell also walks a column per frame, all
# trailing blanks, so no two frames in 15 s match for a closer that keeps
# trailing blanks: a 2-frame blink polled at its own 1 s period (a loaded
# runner) read stable to case 4's control (926c265b0).
cat >"$T_TMP/bin/vibe" <<'FAKEVIBE'
#!/usr/bin/env bash
if [ "${2:-}" = busy ]; then printf '%s\n' '⠋⠁ Generating… (29s Esc/Ctrl+C to interrupt)' '──────' '>' '──────'
else
  printf '%s\n' '  Now staying idle.' '──────'
  ( k=0; while :; do
      printf '\r>%*s\033[%sm \033[0m\033[K' "$((k % 30))" '' "$((k % 2 ? 7 : 8))"
      k=$((k + 1)); sleep 0.5
    done ) &
fi
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$1"
  [ "$line" = /exit ] && { echo VIBE-EXITED >>"$1"; kill %1 2>/dev/null; exit 0; }
done
sleep 600
FAKEVIBE
chmod +x "$T_TMP/bin/vibe"
# The pane as spawn-mistral.sh leaves it: vibe's argv reads "Vibe CLI".
cat >"$T_TMP/bin/vibe-pane" <<'FAKEPANE'
#!/bin/sh
bash -c 'exec -a "Vibe CLI" bash "$0" "$1" "$2"' "$1" "$2" "${3:-}"
sleep 600
FAKEPANE
vibe_lane() {  # ID [busy] -> pane, once the fake vibe is up (cap 10 s)
  local p mark='Now staying idle.'
  [ "${2:-}" = busy ] && mark='Esc/Ctrl+C to interrupt'
  p="$(t_window "$1@tbox" "sh $T_TMP/bin/vibe-pane $T_TMP/bin/vibe $T_TMP/got-${1#m-} ${2:-}")"
  wait_for 10 "the fake vibe of $1 never came up" vibe_up "$p" "/got-${1#m-}" "$mark" >&2
  printf '%s' "$p"
}

# 1. idle: /exit typed, vibe leaves by itself
P1="$(vibe_lane m-501)"
MISTRAL_TMUX_PANE="$P1" bash "$SUT" --agent m-501 --defer --timeout 60 >"$T_TMP/o1" 2>&1
hasnt "1. the closer finds vibe's PID" "agent_pids=none" "$(cat "$T_TMP/o1")"
check "1. the idle vibe window closes well before the 60 s timeout" wait_gone "$P1" 30
has "1. vibe got /exit typed and left by itself" "VIBE-EXITED" "$(cat "$T_TMP/got-501" 2>/dev/null)"
has "1. the log names the /exit it typed" "typing /exit" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"

# 2. mid-turn: never /exit, the timeout closes it
P2="$(vibe_lane m-502 busy)"
MISTRAL_TMUX_PANE="$P2" bash "$SUT" --agent m-502 --defer --timeout 8 >"$T_TMP/o2" 2>&1
sleep 5
check "2. a vibe mid-turn is still up 5 s after the close was scheduled" alive "$P2"
check "2. ... it is closed by the 8 s timeout" wait_gone "$P2" 20
eq "2. ... and never got /exit while busy" "" "$(cat "$T_TMP/got-502" 2>/dev/null)"

# 3. control: no "Vibe CLI" match = no PID = the window killed, no /exit
mkdir -p "$T_TMP/pre/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre/lib"
grep -v '"Vibe CLI" match' "$SUT" >"$T_TMP/pre/scripts/tmux-close-window.sh"
hasnt "3. control: the Vibe CLI match is spliced out" '"Vibe CLI" match' "$(cat "$T_TMP/pre/scripts/tmux-close-window.sh")"
P3="$(vibe_lane m-503)"
MISTRAL_TMUX_PANE="$P3" bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent m-503 --defer --timeout 60 >"$T_TMP/o3" 2>&1
has "3. control: the old closer reads no agent PID" "agent_pids=none" "$(cat "$T_TMP/o3")"
check "3. control: ... kills the window at once" wait_gone "$P3" 30
eq "3. control: ... without any /exit" "" "$(cat "$T_TMP/got-503" 2>/dev/null)"

# 4. control: trailing blanks kept = the blink never reads stable = no /exit
sed 's/ s\/\[\[:space:\]\]\*\$\/\/\x27 |$/\x27 |/' "$SUT" >"$T_TMP/pre/scripts/tmux-close-window.sh"
hasnt "4. control: the trailing-blank strip is spliced out" 's/[[:space:]]*$//' "$(grep -A4 '^rebirth_idle_screen()' "$T_TMP/pre/scripts/tmux-close-window.sh")"
P4="$(vibe_lane m-504)"
MISTRAL_TMUX_PANE="$P4" bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent m-504 --defer --timeout 12 >"$T_TMP/o4" 2>&1
hasnt "4. control: the old closer finds the PID" "agent_pids=none" "$(cat "$T_TMP/o4")"
check "4. control: ... the blinking vibe is closed only by the 12 s timeout" wait_gone "$P4" 30
eq "4. control: ... and never got /exit" "" "$(cat "$T_TMP/got-504" 2>/dev/null)"
[ "$T_FAIL" -eq 0 ] || why
t_done
