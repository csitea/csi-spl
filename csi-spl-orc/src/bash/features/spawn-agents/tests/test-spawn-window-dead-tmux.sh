#!/usr/bin/env bash
# spawn-window.sh when the tmux server dies MID-SPAWN (robustness review gap 3,
# SPL-2353): at `new-window` (after the id is claimed), and right after the
# window is created, before the launcher has seeded the agent. Safe outcome:
# no orphan window, no lost id (a failed spawn releases its claim; a started
# one stays held until the reaper retires it), no double-assigned id.
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
cat >"$T_TMP/bin/tmux" <<EOS
#!/usr/bin/env bash
case " \$* " in *" new-window "*) ;; *) exec "$REAL_TMUX" "\$@" ;; esac
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
read -r ID PANE <<<"$(printf '%s\n' "$out" | grep -E '^c-[0-9]{3} %' | tail -1)"
eq "the spawn reports the window it made" 0 "$rc"
check "...an id and a pane" test -n "${ID:-}" -a -n "${PANE:-}"
eq "no orphan window: the server and its windows are gone" "" "$(wins)"
check "the id stays held by its spool dir (not lost, not free)" test -d "$R/${ID:-none}/inbox"
t_tmux
nxt="$(bash "$NAI" --kind claude --no-reserve)"
if [ -n "$nxt" ] && [ "$nxt" != "${ID:-}" ]; then ok "the allocator never hands ${ID:-} out again ($nxt)"; else nok "the allocator handed out '${ID:-}' twice ($nxt)"; fi
# The reaper takes the dead claim: no window, dead past SPOOL_ID_REAP_H (its
# own clock: hourly ticks; a longer gap starts the clock again).
out=""; for h in 12 13 14 15 16 17 18; do out+="$(SPOOL_NOW="2026-10-02T${h}:00:00Z" bash "$T_SCRIPTS/agent-id-reap.sh" --apply 2>&1)"; done
has "the reaper retires the dead claim 6 h later" "REAP ${ID:-none}: dead 6 h" "$out"
check "...into .retired/, quarantined" test ! -e "$R/${ID:-none}" -a -n "$(awk -F'\t' -v i="${ID:-none}" '$1 == i' "$R/registry.retired.tsv" 2>/dev/null)"
nxt="$(SPOOL_NOW=2026-10-02T18:00:00Z bash "$NAI" --kind claude --no-reserve)"
if [ -n "$nxt" ] && [ "$nxt" != "${ID:-}" ]; then ok "inside the quarantine ${ID:-} is still not handed out ($nxt)"; else nok "'${ID:-}' handed out inside its quarantine ($nxt)"; fi

t_done
