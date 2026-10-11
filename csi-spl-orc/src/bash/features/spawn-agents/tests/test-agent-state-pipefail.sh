#!/usr/bin/env bash
# test-agent-state-pipefail.sh — classify_screen reads a busy screen as busy
# under a caller's `set -o pipefail`, every time. Its old `printf | grep -q`
# shape lost a MATCH when grep -q exited first and printf died of SIGPIPE:
# tmux-close-window.sh (set -uo pipefail) then read busy as idle and typed
# /exit into a lane mid-turn (c-783, tree 27a9a5c1d: 10 of 3000 under load).
#
# Gating: 300 reads (~10 s) of a 220 KB screen, 'esc to interrupt' at the
# top. At that size the old shape loses the match on EVERY read, load or
# not (old lib: 0 of 300 read busy on a quiet box, 0 of 3000 under 8
# burners). Long run:
#   AGENT_STATE_PIPEFAIL_N=3000       reads (~2 min idle box)
#   AGENT_STATE_PIPEFAIL_LOAD=<1..8>  nice burners during the loop
#   AGENT_STATE_LIB=<path>            classify with another copy of the lib
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
# shellcheck source=../lib/agent-state.inc.sh
. "${AGENT_STATE_LIB:-$T_FEAT/lib/agent-state.inc.sh}"

n="${AGENT_STATE_PIPEFAIL_N:-300}"
load="${AGENT_STATE_PIPEFAIL_LOAD:-0}"
[ "$load" -le 8 ] || load=8

# ~200 KB: the live footer first, then 4000 lines of tool output.
scr="$(printf '%s\n' '✶ Running… (12s · esc to interrupt)'
  for i in $(seq 1 4000); do printf 'line %04d of a long tool result, padded to fifty bytes\n' "$i"; done)"
check "screen is over the pipe buffer (${#scr} bytes)" [ "${#scr}" -gt 131072 ]
eq "pipefail is on" on "$(set -o | awk '$1 == "pipefail" {print $2}')"

burners=()
stop_burners() { local p; for p in "${burners[@]}"; do kill "$p" 2>/dev/null; done; }
trap stop_burners EXIT
for _ in $(seq 1 "$load"); do
  timeout 300 nice -n 19 bash -c 'while :; do :; done' &
  burners+=("$!")
done

busy=0; other=0
for _ in $(seq 1 "$n"); do
  if [ "$(classify_screen "$scr")" = busy ]; then busy=$((busy + 1)); else other=$((other + 1)); fi
done
stop_burners
echo "   busy $busy of $n, not busy $other (load $load burners)"
eq "busy screen reads busy $n of $n under pipefail" "$n" "$busy"

t_done
