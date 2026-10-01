#!/usr/bin/env bash
# test-agent-identity-resolve.sh — the identity map, step (c): the resolvers
# find an agent by its PROCESS (through the map), not by a window name.
#
# A private tmux server gives real pane ids; a fake /proc (AI_PROC_ROOT) holds
# the agent processes the records name. The fixture is the 2026-10-01 shape:
# the window NAMED CLE-71 is not where CLE-71 runs.
#
#   1. spool_pane_of CLE-71 -> the pane the map proves (CLE-71's process), not
#      the window that carries the name CLE-71
#   2. ai_alive_fast agrees with agent-identity.py alive, and refuses a reused
#      pid (start time), a shell carrying the id, another id
#   3. no provable process (record dead, or its pane gone from the server) ->
#      the old lookup, by registry + window name, unchanged
#   4. tmux-close-window.sh --agent CLE-71 --dry-run resolves the map's pane
#   5. desk liveness counts an agent the map proves alive even when no window
#      carries its id (the seat retired at 04:37Z)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG
P="$T_TMP/proc"; mkdir -p "$P" "$SPOOL_ROOT/agents"
export AI_PROC_ROOT="$P"
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/agent-identity.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve
t_tmux
PA="$(t_window 'CLE-71 named here' 'sleep 600')"     # carries the NAME CLE-71
PB="$(t_window 'CLE-72 lane' 'sleep 600')"           # where CLE-71 really runs

proc() {  # PID START ARGV0 ENV-ID
  mkdir -p "$P/$1"; printf '%s\0' "$3" > "$P/$1/cmdline"
  printf 'SPOOL_AGENT_ID=%s\0' "$4" > "$P/$1/environ"
  printf '%s (%s) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' "$1" "${3##*/}" "$2" > "$P/$1/stat"
  printf '%s\n' "${3##*/}" > "$P/$1/comm"
}
record() {  # ID PID START PANE [ALIVE]
  python3 - "$SPOOL_ROOT/agents/$1.json" "$1" "$2" "$3" "$4" "${5:-true}" <<'PY'
import json, sys
f, i, pid, start, pane, alive = sys.argv[1:7]
json.dump({"v": 1, "id": i, "kind": "claude", "pid": int(pid), "proc_start": start, "pane_id": pane,
           "alive": alive == "true", "session_id": "s", "title": ""}, open(f, "w"), indent=1, sort_keys=True)
PY
}
proc 101 777 /usr/bin/claude CLE-71
record CLE-71 101 777 "$PB"

# --- 1 ------------------------------------------------------------------------------
eq "1. spool_pane_of CLE-71 -> the pane its process is in (map), not the window named CLE-71" "$PB" "$(spool_pane_of CLE-71)"

# --- 2 ------------------------------------------------------------------------------
eq "2. ai_alive_fast prints the pid" 101 "$(ai_alive_fast CLE-71)"
eq "2. ... the same answer as agent-identity.py alive" "$(ai_alive CLE-71)" "$(ai_alive_fast CLE-71)"
sed -i 's/ 777 0$/ 999 0/' "$P/101/stat"
if ai_alive_fast CLE-71 >/dev/null; then nok "2. a reused pid (other start time) is not alive"; else ok "2. a reused pid (other start time) is not alive"; fi
sed -i 's/ 999 0$/ 777 0/' "$P/101/stat"
printf '/bin/bash\0' > "$P/101/cmdline"; echo bash > "$P/101/comm"
if ai_alive_fast CLE-71 >/dev/null; then nok "2. a shell carrying the id is not alive"; else ok "2. a shell carrying the id is not alive"; fi
printf '/usr/bin/claude\0' > "$P/101/cmdline"; echo claude > "$P/101/comm"
printf 'SPOOL_AGENT_ID=CLE-79\0' > "$P/101/environ"
if ai_alive_fast CLE-71 >/dev/null; then nok "2. a pid carrying another id is not alive"; else ok "2. a pid carrying another id is not alive"; fi
printf 'SPOOL_AGENT_ID=CLE-71\0' > "$P/101/environ"

# --- 3 ------------------------------------------------------------------------------
record CLE-71 101 777 "$PB" false
eq "3. record says dead -> the old lookup: the window named CLE-71" "$PA" "$(spool_pane_of CLE-71)"
record CLE-71 101 777 "%999"
eq "3. record's pane gone from the server -> the old lookup" "$PA" "$(spool_pane_of CLE-71)"
rm -f "$SPOOL_ROOT/agents/CLE-71.json"
eq "3. no record at all -> the old lookup" "$PA" "$(spool_pane_of CLE-71)"
record CLE-71 101 777 "$PB"

# --- 4 ------------------------------------------------------------------------------
out="$(bash "$T_SCRIPTS/tmux-close-window.sh" --agent CLE-71 --dry-run 2>&1)"
has "4. tmux-close-window --agent CLE-71 resolves the map's pane" "pane=$PB" "$out"
eq "4. ... and kills nothing" 2 "$(tmux -S "$SPOOL_TMUX_SOCKET" list-windows -t t -F x | grep -c . | awk '{print $1-1}')"

# --- 5 ------------------------------------------------------------------------------
proc 303 555 /usr/bin/claude CLE-73
record CLE-73 303 555 "$PB"
live="$(env PROJ_PATH="$T_REPO/csi-spl-orc" APP_PATH="$T_REPO" SPL_ORG_APP=csi-spl bash -c '
  set -uo pipefail; do_log() { :; }
  source "$PROJ_PATH/src/bash/run/spl-desk-up-all.func.sh"; spl_desk_live_agents')"
has "5. desk liveness: CLE-73 is live by its process, no window carries its id" "CLE-73" "$live"
has "5. ... and the window-name ids still count" "CLE-72" "$live"

t_done
