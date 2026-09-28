#!/usr/bin/env bash
# test-tmux-close-window.sh — the agent-teardown helper (specs/048, ported).
# The bug it pins: an unresolvable owner used to fall back to the ACTIVE pane,
# so a teardown closed the window the human was looking at. A private tmux
# server, fake agent windows; the live server is never touched.
#
#   1. no ownership source at all -> exit 3, the active window survives
#   2. --agent resolves the window by its (tagged) name; --dry-run kills nothing
#   3. --agent closes exactly that window, a sibling survives
#   4. a registry pane whose window names ANOTHER id -> exit 4, nothing closed
#   5. --defer on a pane with no agent CLI closes it after the grace, and logs
#      the target to CLOSE_LOG_DIR
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SUT="$T_SCRIPTS/tmux-close-window.sh"
unset TMUX TMUX_PANE CLE_TMUX_PANE GRK_TMUX_PANE AGY_TMUX_PANE QWN_TMUX_PANE MCP_BOT_AGENT_ID \
      CLE_TMUX_SOCK GRK_TMUX_SOCK AGY_TMUX_SOCK QWN_TMUX_SOCK
export CLOSE_LOG_DIR="$T_TMP/logs" SPOOL_BOX_TAG=tbox; mkdir -p "$CLOSE_LOG_DIR"
t_tmux
alive() { tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -qx "$1"; }

VICTIM="$(t_window 'tbox: CLE-09 someone else' 'sleep 600')"
tmux -S "$SPOOL_TMUX_SOCKET" select-window -t "$VICTIM"

# --- 1. no source -------------------------------------------------------------
bash "$SUT" >"$T_TMP/o" 2>&1; eq "1. no ownership source is refused (3)" 3 "$?"
check "1. the ACTIVE window survives" alive "$VICTIM"

# --- 2. --agent + --dry-run -----------------------------------------------------
P7="$(t_window 'tbox: CLE-07 wip' 'sleep 600')"
out="$(bash "$SUT" --agent cle-7 --dry-run 2>&1)"; eq "2. --agent --dry-run exits 0" 0 "$?"
has "2. it resolves the tagged window of CLE-07" "CLE-07" "$out"
check "2. --dry-run kills nothing" alive "$P7"

# --- 3. --agent closes that window only ------------------------------------------
bash "$SUT" --agent CLE-07 >"$T_TMP/o" 2>&1; eq "3. --agent CLE-07 exits 0" 0 "$?"
check "3. CLE-07's window is gone" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P7'"
check "3. the sibling survives" alive "$VICTIM"

# --- 4. registry mismatch -----------------------------------------------------------
printf 'GRK-05\tgrok\t%s\t/x\t20260101T000000Z\n' "$VICTIM" >"$SPOOL_ROOT/registry.tsv"
bash "$SUT" --agent GRK-05 >"$T_TMP/o" 2>&1; rc=$?
[ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; eq "4. a pane whose window names another id is refused" 0 "$?"
check "4. ... and nothing was closed" alive "$VICTIM"

# --- 5. --defer --------------------------------------------------------------------------
P8="$(t_window 'tbox: QWN-08 done' 'sleep 600')"
bash "$SUT" --agent QWN-08 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "5. --defer returns 0 at once" 0 "$?"
has "5. it names the scheduled target" "scheduled defer-close" "$(cat "$T_TMP/o")"
for _ in $(seq 1 20); do alive "$P8" || break; sleep 0.5; done
check "5. the deferred close lands" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P8'"
has "5. the log records the target" "closing window" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log 2>/dev/null)"
check "5. the victim survives the whole run" alive "$VICTIM"
t_done
