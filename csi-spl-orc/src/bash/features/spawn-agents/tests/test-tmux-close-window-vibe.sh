#!/usr/bin/env bash
# The deferred close of a mistral lane (dispatch-f0256ec8, live proof m-897
# 2026-10-10): vibe renames itself "Vibe CLI" (setproctitle), so the closer
# found no agent PID ("agent_pids=none") and killed the window ~2 s after
# /exit-clean without typing /exit, busy or not. Now:
#   1. an idle vibe gets /exit typed and leaves by itself, well before the
#      timeout; the log names its PID and the /exit
#   2. a vibe mid-turn (its footer `Esc/Ctrl+C to interrupt`, a static screen
#      with an empty `>` prompt) never gets /exit: the timeout closes it
#   3. control: the closer without the "Vibe CLI" match reads no PID and
#      kills the idle vibe's window without any /exit
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SUT="$T_SCRIPTS/tmux-close-window.sh"
unset MISTRAL_TMUX_PANE
export CLOSE_LOG_DIR="$T_TMP/logs" SPOOL_BOX_TAG=tbox; mkdir -p "$CLOSE_LOG_DIR"
t_tmux
alive() { tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{pane_dead}' | grep -x "$1 0" >/dev/null; }
gone() { ! tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -x "$1" >/dev/null; }
wait_gone() { for _ in $(seq 1 "$2"); do gone "$1" && return 0; sleep 0.5; done; return 1; }

mkdir -p "$T_TMP/bin"
# fake vibe: vibe 2.26.0's input box (rules around an empty `>`), reads lines
# into $1, leaves on /exit; $2=busy holds its mid-turn footer
cat >"$T_TMP/bin/vibe" <<'FAKEVIBE'
#!/usr/bin/env bash
if [ "${2:-}" = busy ]; then printf '%s\n' '⠋⠁ Generating… (29s Esc/Ctrl+C to interrupt)' '──────' '>' '──────'
else printf '%s\n' '  Now staying idle.' '──────' '>' '──────'; fi
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$1"
  [ "$line" = /exit ] && { echo VIBE-EXITED >>"$1"; exit 0; }
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
vibe_lane() {  # ID [busy] -> pane
  local p
  p="$(t_window "$1@tbox" "sh $T_TMP/bin/vibe-pane $T_TMP/bin/vibe $T_TMP/got-${1#m-} ${2:-}")"
  sleep 1
  printf '%s' "$p"
}

# 1. idle: /exit typed, vibe leaves by itself
P1="$(vibe_lane m-501)"
MISTRAL_TMUX_PANE="$P1" bash "$SUT" --agent m-501 --defer --timeout 60 >"$T_TMP/o1" 2>&1
hasnt "1. the closer finds vibe's PID" "agent_pids=none" "$(cat "$T_TMP/o1")"
check "1. the idle vibe window closes well before the 60 s timeout" wait_gone "$P1" 40
has "1. vibe got /exit typed and left by itself" "VIBE-EXITED" "$(cat "$T_TMP/got-501" 2>/dev/null)"
has "1. the log names the /exit it typed" "typing /exit" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"

# 2. mid-turn: never /exit, the timeout closes it
P2="$(vibe_lane m-502 busy)"
MISTRAL_TMUX_PANE="$P2" bash "$SUT" --agent m-502 --defer --timeout 8 >"$T_TMP/o2" 2>&1
sleep 5
check "2. a vibe mid-turn is still up 5 s after the close was scheduled" alive "$P2"
check "2. ... it is closed by the 8 s timeout" wait_gone "$P2" 30
eq "2. ... and never got /exit while busy" "" "$(cat "$T_TMP/got-502" 2>/dev/null)"

# 3. control: no "Vibe CLI" match = no PID = the window killed, no /exit
mkdir -p "$T_TMP/pre/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/pre/lib"
grep -v '"Vibe CLI" match' "$SUT" >"$T_TMP/pre/scripts/tmux-close-window.sh"
hasnt "3. control: the Vibe CLI match is spliced out" '"Vibe CLI" match' "$(cat "$T_TMP/pre/scripts/tmux-close-window.sh")"
P3="$(vibe_lane m-503)"
MISTRAL_TMUX_PANE="$P3" bash "$T_TMP/pre/scripts/tmux-close-window.sh" --agent m-503 --defer --timeout 60 >"$T_TMP/o3" 2>&1
has "3. control: the old closer reads no agent PID" "agent_pids=none" "$(cat "$T_TMP/o3")"
check "3. control: ... kills the window at once" wait_gone "$P3" 20
eq "3. control: ... without any /exit" "" "$(cat "$T_TMP/got-503" 2>/dev/null)"
t_done
