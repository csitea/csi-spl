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
#   6. T-EXITCLEAN-RETIRING (spec 060 FR-016): --agent CLE-001 --defer from a
#      retiring window closes THAT window, never the new CLE-001 (control: from
#      outside it resolves to the new one); from another window it is refused
#   7. spec 061 ids (c-097 / g-113 / a-091 / q-004) resolve EXACTLY: lower-case
#      kind, 3 digits, never re-padded, in both the <ID>@<box> and the tagged
#      "<tag>: <ID>" window shape, never a look-alike ("C-97"). Control: the
#      pre-c0ec0735 norm_id (10#n, %02d) turns c-097 into C-97 and misses it
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

# --- 6. T-EXITCLEAN-RETIRING (spec 060 FR-016) ------------------------------------------
NEWP="$(t_window 'CLE-001@tbox' 'sleep 600')"
OLDP="$(t_window 'CLE-001-0405Z-retiring' 'sleep 600')"
out="$(bash "$SUT" --agent CLE-001 --dry-run 2>&1)"
has "6. control: --agent CLE-001 from outside resolves to the NEW window" "$NEWP" "$out"
out="$(CLE_TMUX_PANE="$OLDP" bash "$SUT" --agent CLE-001 --dry-run 2>&1)"
has "6. from the retiring pane it resolves to the retiring window" "$OLDP" "$out"
hasnt "6. ... not the new one" "$NEWP" "$out"
CLE_TMUX_PANE="$OLDP" bash "$SUT" --agent CLE-001 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "6. --defer from the retiring pane returns 0" 0 "$?"
for _ in $(seq 1 20); do alive "$OLDP" || break; sleep 0.5; done
check "6. the retiring window is closed" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$OLDP'"
check "6. the NEW window survives" alive "$NEWP"
CLE_TMUX_PANE="$VICTIM" bash "$SUT" --agent CLE-001 --defer --timeout 10 >"$T_TMP/o" 2>&1; eq "6. --defer from another window's pane is refused (4)" 4 "$?"
check "6. ... and the new window survives" alive "$NEWP"
# --- 7. spec 061 ids resolve exactly (/exit-clean left c-097's window open) ---------------
NC="$(t_window 'c-097@tbox' 'sleep 600')"
NG="$(t_window 'tbox: g-113 wip' 'sleep 600')"
NA="$(t_window 'a-091@tbox' 'sleep 600')"
NQ="$(t_window 'tbox: q-004' 'sleep 600')"
DECOY="$(t_window 'C-97@tbox' 'sleep 600')"
for pair in "c-097:$NC" "G-113:$NG" "a-091:$NA" "q-004:$NQ"; do
  id="${pair%%:*}"; pane="${pair#*:}"
  out="$(bash "$SUT" --agent "$id" --dry-run 2>&1)"; eq "7. --agent $id --dry-run exits 0" 0 "$?"
  has "7. --agent $id resolves its own pane" "pane=$pane " "$out"
  has "7. ... as ${id,,}: lower case, never re-padded" "via --agent ${id,,}" "$out"
done
hasnt "7. c-097 never resolves the look-alike C-97" "$DECOY" "$(bash "$SUT" --agent c-097 --dry-run 2>&1)"
# Control: the same script with the pre-c0ec0735 norm_id spliced in (beside
# a lib/ link, which it loads relative to itself).
mkdir -p "$T_TMP/old/scripts"; ln -s "$(cd "$(dirname "$SUT")/../lib" && pwd)" "$T_TMP/old/lib"
cat >"$T_TMP/old-norm.sh" <<'OLDNORM'
norm_id() {
  local t p n
  t="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  if printf '%s' "$t" | grep -qE '^[A-Z]+-?[0-9]+$'; then
    p="$(printf '%s' "$t" | grep -oE '^[A-Z]+')"
    n="$(printf '%s' "$t" | grep -oE '[0-9]+$')"
    printf '%s-%02d' "$p" "$((10#$n))"
    return 0
  fi
  return 1
}
OLDNORM
awk -v f="$T_TMP/old-norm.sh" '/^norm_id\(\) \{/ { while ((getline l < f) > 0) print l; skip = 1; next }
  skip { if (/^}/) skip = 0; next } { print }' "$SUT" >"$T_TMP/old/scripts/tmux-close-window.sh"
out="$(bash "$T_TMP/old/scripts/tmux-close-window.sh" --agent c-097 --dry-run 2>&1)"
has "7. control: the old norm_id turns c-097 into C-97" "'C-97'" "$out"
hasnt "7. control: ... and misses c-097's window" "pane=$NC " "$out"
bash "$SUT" --agent c-097 >"$T_TMP/o" 2>&1; eq "7. --agent c-097 closes its window (exit 0)" 0 "$?"
check "7. c-097's window is gone" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$NC'"
check "7. the look-alike C-97 window survives" alive "$DECOY"
t_done
