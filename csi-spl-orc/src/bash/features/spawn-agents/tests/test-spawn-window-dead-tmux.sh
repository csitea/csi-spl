#!/usr/bin/env bash
# spawn-window.sh when the tmux server dies MID-SPAWN (robustness review gap 3,
# SPL-2353): at `new-window` (after the id is claimed), and right after the
# window is created, before the launcher has seeded the agent. Safe outcome:
# no orphan window, no lost id, no double-assigned id: both are failed spawns,
# exit 4 with the claim released (the second since SPL-2408; before it the
# spawn said 0 and the id stayed held until the reaper retired it 6 h later).
# Third (SPL-2595): after spawn-window's own pane check, during the start
# check. That is the documented WARN, exit 0 (header, START CHECK): the case
# holds what must stay true either way, a clear WARN at once, no orphan
# window, no id handed out twice.
# A PATH shim in front of tmux kills the private server; the live box is never
# touched. (No socket at all, before the claim: test-spawn-window-riname.sh.)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SW="$T_SCRIPTS/spawn-window.sh"
NAI="$T_SCRIPTS/next-agent-id.sh"
WD="$T_TMP/plain"; mkdir -p "$WD"
R="$SPOOL_ROOT"
export SPAWN_START_CHECK=0 RETIRE_LANE=0 SPOOL_ID_REAP_H=6
unset DRY_RUN
REAL_TMUX="$(command -v tmux)"
mkdir -p "$T_TMP/bin"
# T_KILL=before: kill the server, then let new-window fail on the dead socket.
# T_KILL=after:  let new-window create the window and print its pane, then kill.
# T_KILL=check:  let the pane check after new-window pass, then kill.
cat >"$T_TMP/bin/tmux" <<EOS
#!/usr/bin/env bash
case " \$* " in
  *" new-window "*) ;;
  *" display-message -p -t %"*" #{pane_id} "*)
    [ "\${T_KILL:-}" = check ] || exec "$REAL_TMUX" "\$@"
    "$REAL_TMUX" "\$@"; rc=\$?; "$REAL_TMUX" -S "\$SPOOL_TMUX_SOCKET" kill-server; exit \$rc ;;
  *) exec "$REAL_TMUX" "\$@" ;;
esac
case "\${T_KILL:-}" in
  before) "$REAL_TMUX" -S "\$SPOOL_TMUX_SOCKET" kill-server; exec "$REAL_TMUX" "\$@" ;;
  after)  "$REAL_TMUX" "\$@"; rc=\$?; "$REAL_TMUX" -S "\$SPOOL_TMUX_SOCKET" kill-server; exit \$rc ;;
  *)      exec "$REAL_TMUX" "\$@" ;;
esac
EOS
chmod +x "$T_TMP/bin/tmux"
sw() { PATH="$T_TMP/bin:$PATH" bash "$SW" "$@" 2>&1; }
wins() { "$REAL_TMUX" -S "$SPOOL_TMUX_SOCKET" list-windows -a -F '#{window_name}' 2>/dev/null; }
claude_rows() { awk -F'\t' '$3 == "claude"' "$R/dispatch/attempts.tsv" 2>/dev/null | wc -l; }

# --- the server dies at new-window: exit 4, the claim released --------------------
t_tmux SPAWN_DRY_RUN=1
out="$(T_KILL=before sw claude auto "$WD")"; eq "a dead server at new-window is exit 4" 4 "$?"
has "...and says why" "printed no pane id" "$out"
check "...the auto claim c-004 is released (no orphan spool dir)" test ! -e "$R/c-004"
t_tmux SPAWN_DRY_RUN=1
out="$(T_KILL=before sw claude c-040 "$WD")"; eq "an explicit id: exit 4 too" 4 "$?"
check "...its claim released as well" test ! -e "$R/c-040"
eq "both failures are journalled fail:F1" 2 "$(grep -c 'fail:F1' "$R/dispatch/attempts.tsv")"
t_tmux SPAWN_DRY_RUN=1
out="$(sw claude c-040 "$WD")"; eq "CONTROL: the released explicit id spawns on the next try" 0 "$?"
has "...as c-040" "c-040 %" "$out"
hasnt "no window was left behind by the failed spawns" "c-004" "$(wins)"

# --- the server dies after the window, before the seed ------------------------------
out="$(T_KILL=after sw claude auto "$WD")"; rc=$?
ID="$(printf '%s\n' "$out" | grep -oE 'the claim on c-[0-9]{3} is released' | grep -oE 'c-[0-9]{3}')"
eq "a pane gone before its seed is exit 4" 4 "$rc"
has "...and says why" "is gone before its seed" "$out"
hasnt "...no '<ID> <PANE>' line for a spawn that never started" "%" "$(printf '%s\n' "$out" | grep -E '^c-[0-9]{3} ')"
eq "no orphan window: the server and its windows are gone" "" "$(wins)"
check "...the claim on ${ID:-none} is released (no orphan spool dir)" test -n "${ID:-}" -a ! -e "$R/${ID:-none}"
eq "...journalled fail:F1" 3 "$(grep -c 'fail:F1' "$R/dispatch/attempts.tsv")"
t_tmux SPAWN_DRY_RUN=1
out="$(sw claude "${ID:-c-004}" "$WD")"; eq "CONTROL: the released id spawns on the next try" 0 "$?"
has "...as ${ID:-none}" "${ID:-none} %" "$out"
nxt="$(bash "$NAI" --kind claude --no-reserve)"
if [ -n "$nxt" ] && [ "$nxt" != "${ID:-}" ]; then ok "...and is then never handed out twice ($nxt)"; else nok "'${ID:-}' handed out twice ($nxt)"; fi

# --- the server dies after the pane check, during the start check (SPL-2595) --------
# The window lands and passes the pane check, then the server dies: the pane
# never draws an input box. The start check must see the pane gone at once
# (no server = gone), not wait its full 20 s for a box that cannot come. The
# server is the one the CONTROL above spawned on.
t0=$SECONDS
out="$(T_KILL=check SPAWN_START_CHECK=1 SPAWN_START_CHECK_WAIT=20 START_CHECK_POLL=0.2 sw claude auto "$WD")"
took=$((SECONDS - t0))
ID3="$(grep -oE '^c-[0-9]{3} %' <<<"$out" | sed -n '1s/ %$//p')"
check "CONTROL check: the window landed (${ID3:-no id line})" test -n "$ID3"
if "$REAL_TMUX" -S "$SPOOL_TMUX_SOCKET" has-session 2>/dev/null; then nok "CONTROL check: the server still runs"; else ok "CONTROL check: the shim killed the server"; fi
has "a server gone during the start check is one WARN naming the pane" "WARN ${ID3:-none} %" "$out"
has "...and says the pane ended" "the pane ended before an input box was drawn" "$out"
if [ "$took" -lt 10 ]; then ok "...at once (${took} s), not after the full start-check wait"; else nok "...took ${took} s: the start check waited for a dead pane"; fi
eq "no orphan window" "" "$(wins)"
nxt="$(bash "$NAI" --kind claude --no-reserve)"
if [ -n "$nxt" ] && { [ "$nxt" != "${ID3:-}" ] || [ ! -e "$R/${ID3:-none}" ]; }; then
  ok "...${ID3:-none} is held or released, never handed out twice while held ($nxt)"
else nok "'${ID3:-}' handed out twice while its claim is held ($nxt)"; fi

t_done
