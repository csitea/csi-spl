#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the GC agent of a box (do_spl_gc, spl-gc.func.sh; owner HUM-10,
#          t1 91a36ace), in a sandbox: tmux is a stub keeping windows in a
#          file, the spool send and the restart are stubs. Nothing real is
#          touched. The action runs under ./run's `set -E` + ERR trap.
#   1. the slot's vendor comes from cnf/gc/gc.conf: :00 claude, :30 grok,
#      :47 grok; a cnf that swaps them swaps the vendor (not hard-coded)
#   2. COUNTING: two starts in one slot = 1 GC window, the second SKIPs;
#      CONTROL: the window gone, the next start opens a 2nd one (the count
#      can see two)
#   3. a GC older than GC_MAX_AGE is ended before the next start
#   4. gc-cron.sh: a minute that is no slot runs nothing; the manifest row
#   5. the owner's 3-minute cap: begin, poke at +100 s delivered, poke at
#      +200 s refused (CAP, exit 4); no begin = refused
#   6. restart: never poked = refused; poked in this pass = refused; poked on
#      an earlier pass, no progress = do_spl_agent_restart CAUSE=gc; moved
#      since the poke = no restart
#   7. a role seat and a human hold are refused
#   8. close-ask: one note to the orchestrator, a second in 24 h refused
#   9. done: one summary line to c-001 and the GC window closed
#  10. scan: this box's agents only, an ACCEPTED lane hinted done
#  11. gc-session.sh: which CLIs exist is probed as the agent user (bare
#      *_BIN names count); grok missing on the box = the cnf fallback (claude),
#      bypass flags, the fixed prompt file
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # rc, old, gp and out are read inside the check strings (eval)
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin"
export T S D

# 2026-10-13T21:00:00Z, a :00 slot
H0=1792098000

reset() {
  rm -rf "$S" "$T"/*.log "$T/tmux"
  mkdir -p "$D" "$T/tmux" "$T/bin"
  : >"$T/tmux/windows"
  printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
  printf 'LEASE_ORCH=c-001\nLEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_FLEET=main\nLEASE_ENV=prd\nLEASE_TENANT=t1\n' >"$D/lease.conf"
  echo 900 >"$T/tmux/next"
}

# lane <id> [box]: an agent window and its spool dirs, heartbeat progress at H0
lane() {
  local id="$1" box="${2:-box-a}" n
  n="$(cat "$T/tmux/next")"; echo $(( n + 1 )) >"$T/tmux/next"
  mkdir -p "$S/$id/inbox" "$S/$id/outbox" "$S/$id/archive" "$S/$id/lifetime"
  printf '# Lane brief: the %s task\n' "$id" >"$S/$id/lifetime/brief.md"
  echo "SPL-9$n" >"$S/$id/lifetime/issue"
  progress "$id" "$H0"
  printf '%%%s\t%s@%s some title\n' "$n" "$id" "$box" >>"$T/tmux/windows"
}
progress() { jq -n --arg p "$(date -u -d "@$2" +%FT%TZ)" '{state: "idle", progress_ts: $p, tool: null, api_error: null}' >"$S/$1/heartbeat.json"; }

# tmux: windows "<pane>\t<name>"; new-window appends, kill-window drops
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
W="$T/tmux/windows"; echo "$*" >>"$T/tmux/log"
cmd="$1"; shift
tgt="" name=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -n) name="$2"; shift 2 ;; -F) shift 2 ;; -a|-d|-p|-P) shift ;; -S) shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  list-sessions) echo '1 $0' ;;
  list-panes) cat "$W" ;;
  new-window) n="$(cat "$T/tmux/next")"; echo $(( n + 1 )) >"$T/tmux/next"
    printf '%%%s\t%s\n' "$n" "$name" >>"$W"; echo "%$n" ;;
  kill-window) grep -v "^$tgt	" "$W" >"$W.n"; mv "$W.n" "$W" ;;
  capture-pane) printf 'some output\n❯ \n' ;;
esac
EOF
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/send.log"
EOF
cat >"$T/bin/restart" <<'EOF'
#!/usr/bin/env bash
echo "restart ID=$ID CAUSE=$CAUSE DRY_RUN=$DRY_RUN EV=$WD_EVIDENCE" >>"$T/restart.log"
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO) rc=$?"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-gc.func.sh"
do_spl_gc || exit $?
EOF
chmod +x "$T/bin/"*

export PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 LEASE_MACHINE=box-a \
  ROTATE_TMUX="$T/bin/tmux" GC_SEND="$T/bin/send" GC_RESTART_CMD="$T/bin/restart" GC_CLOSE_DELAY=0
unset SPOOL_AGENT_ID SPOOL_BOX_TAG MCP_BOT_AGENT_ID TMUX TMUX_PANE GC_VENDOR GC_CONF GC_RUN_ID
# gc <cmd> <now> [VAR=value ...]: one action run, its output in $T/out, its exit in rc
gc() { local c="$1" t="$2"; shift 2; rc=0; env GC_CMD="$c" GC_NOW="$t" DRY_RUN="${DRY:-0}" "$@" "$T/bin/act" >"$T/out" 2>&1 || rc=$?; cat "$T/out" >>"$T/all.out"; }
n() { if [ -f "$1" ]; then grep -c -- "${2:-.}" "$1" || true; else echo 0; fi; }
gcwin() { n "$T/tmux/windows" "gc@box-a"; }

# --- 1. the slot's vendor ------------------------------------------------------------
reset
DRY=1 gc start "$H0"; check "1. :00 = claude (cnf slot 00)" 'grep -q "vendor=claude" "$T/out"'
DRY=1 gc start $(( H0 + 1800 )); check "1. :30 = grok (cnf slot 30)" 'grep -q "vendor=grok" "$T/out"'
DRY=1 gc start $(( H0 + 2820 )); check "1. :47 = the :30 slot's grok" 'grep -q "vendor=grok" "$T/out"'
printf 'slot 00 grok\nslot 30 claude\nfallback claude\n' >"$T/swap.conf"
DRY=1 gc start "$H0" GC_CONF="$T/swap.conf"; check "1. a cnf that swaps the slots swaps the vendor" 'grep -q "vendor=grok" "$T/out"'
check "1. a dry start opens nothing" '[ "$(gcwin)" = 0 ]'

# --- 2. counting test + control -----------------------------------------------------
reset; lane c-911
gc start "$H0"; r1=$rc
gc start $(( H0 + 60 )); r2=$rc
check "2. COUNT: two starts in one slot = 1 GC window (rc $r1 $r2)" '[ "$(gcwin)" = 1 ] && [ "$(n "$T/tmux/log" new-window)" = 1 ]'
check "2. the second start SKIPs: the first is alive" 'grep -q "SKIP .* is alive" "$T/out" && grep -q "SKIP" "$D/gc/gc.log"'
gc start $(( H0 + 1440 ))
check "2. a start 24 min later, the GC still alive (< GC_MAX_AGE) = still 1" '[ "$(n "$T/tmux/log" new-window)" = 1 ]'
grep -v "gc@box-a" "$T/tmux/windows" >"$T/w" && mv "$T/w" "$T/tmux/windows"
gc start $(( H0 + 1500 ))
check "2. CONTROL: the GC window gone, the next start opens a 2nd (the count sees 2)" '[ "$(n "$T/tmux/log" new-window)" = 2 ] && [ "$(gcwin)" = 1 ]'

# --- 3. a stale GC --------------------------------------------------------------------
reset; lane c-911
gc start "$H0"; old="$(awk '{print $2}' "$D/gc/run")"
gc start $(( H0 + 1500 ))
check "3. a GC older than GC_MAX_AGE is ended, a new one starts" 'grep -q "kill-window -t $old" "$T/tmux/log" && [ "$(n "$T/tmux/log" new-window)" = 2 ] && [ "$(gcwin)" = 1 ]'
check "3. logged END-STALE" 'grep -q "END-STALE" "$D/gc/gc.log"'

# --- 4. the cron script ---------------------------------------------------------------
rc=0; GC_CRON_MINUTE=17 bash "$PROJ_ROOT/src/bash/scripts/gc-cron.sh" >"$T/cron.out" 2>&1 || rc=$?
check "4. gc-cron.sh: minute 17 is no slot = exit 0, nothing run" '[ "$rc" = 0 ] && [ ! -s "$T/cron.out" ]'
check "4. gc-cron.sh is executable" '[ -x "$PROJ_ROOT/src/bash/scripts/gc-cron.sh" ]'
check "4. the manifest row gc runs gc-cron.sh every minute" 'grep -qE "^gc +\| \* \* \* \* \* +\| src/bash/scripts/gc-cron.sh +\| gc/cron.log" "$PROJ_ROOT/cnf/box-crons/box-crons.manifest"'

# --- 5. the 3-minute cap ---------------------------------------------------------------
reset; lane c-911; lane c-912
gc start "$H0"
gc poke $(( H0 + 10 )) AGENT_ID=c-911 GC_HINT="x"
check "5. poke without begin = refused (exit 4)" '[ "$rc" = 4 ] && grep -q "begin it first" "$T/out"'
gc begin $(( H0 + 10 )) AGENT_ID=c-911
check "5. begin prints the issue and the cap" '[ "$rc" = 0 ] && grep -q "issue: SPL-9" "$T/out" && grep -q "BEGIN c-911: 180s" "$T/out"'
gc poke $(( H0 + 110 )) AGENT_ID=c-911 GC_HINT="run do_check_pre_push_lint, the gate is red on shellcheck"
check "5. poke at +100 s = one note on task gc-c-911" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--to c-911 --kind note --task gc-c-911")" = 1 ]'
gc poke $(( H0 + 110 )) AGENT_ID=c-911 GC_HINT="again"
check "5. a 2nd poke in the same pass = refused" '[ "$rc" = 4 ] && [ "$(n "$T/send.log")" = 1 ]'
gc begin $(( H0 + 120 )) AGENT_ID=c-912
gc close-ask $(( H0 + 320 )) AGENT_ID=c-912 GC_WHY="x"
check "5. +200 s on one agent = CAP, refused (exit 4), nothing sent" '[ "$rc" = 4 ] && grep -q "CAP 200s > 180s" "$T/out" && [ "$(n "$T/send.log")" = 1 ]'
gc begin $(( H0 + 330 )) AGENT_ID=c-911
check "5. the agent before is logged with its time, OVER the cap" 'grep -q "END c-912 210s OVER" "$D/gc/gc.log"'
gc poke $(( H0 + 330 )) AGENT_ID=c-912 GC_HINT="x"
check "5. an action on another agent than the one begun = refused" '[ "$rc" = 4 ] && grep -q "the agent begun is c-911" "$T/out"'

# --- 6. restart ----------------------------------------------------------------------
reset; lane c-911; lane c-913
gc start "$H0"
gc begin $(( H0 + 5 )) AGENT_ID=c-911
gc restart $(( H0 + 6 )) AGENT_ID=c-911
check "6. never poked = refused" '[ "$rc" = 4 ] && grep -q "never poked" "$T/out" && [ ! -s "$T/restart.log" ]'
gc poke $(( H0 + 7 )) AGENT_ID=c-911 GC_HINT="h"
gc restart $(( H0 + 8 )) AGENT_ID=c-911
check "6. poked in this pass = refused" '[ "$rc" = 4 ] && grep -q "restart on a later pass" "$T/out" && [ ! -s "$T/restart.log" ]'
grep -v "gc@box-a" "$T/tmux/windows" >"$T/w" && mv "$T/w" "$T/tmux/windows"
gc start $(( H0 + 1800 ))
gc begin $(( H0 + 1805 )) AGENT_ID=c-911
gc restart $(( H0 + 1806 )) AGENT_ID=c-911
sleep 0.3
check "6. poked on an earlier pass, no progress = do_spl_agent_restart CAUSE=gc" '[ "$rc" = 0 ] && grep -q "restart ID=c-911 CAUSE=gc DRY_RUN=0 EV=gc .*no heartbeat progress" "$T/restart.log"'
check "6. the restart path knows the cause gc" 'grep -qE "^ARS_CAUSES=\".* gc\"" "$PROJ_ROOT/src/bash/run/spl-agent-restart.func.sh"'
gc begin $(( H0 + 1810 )) AGENT_ID=c-913
gc poke $(( H0 + 1811 )) AGENT_ID=c-913 GC_HINT="h"
progress c-913 $(( H0 + 2000 ))
gc begin $(( H0 + 3100 )) AGENT_ID=c-913
gc restart $(( H0 + 3101 )) AGENT_ID=c-913
check "6. moved since the poke = no restart (exit 3)" '[ "$rc" = 3 ] && grep -q "MOVED c-913" "$T/out" && [ "$(n "$T/restart.log")" = 1 ]'

# --- 7. role seat, human hold ----------------------------------------------------------
reset; lane c-001; lane c-914
gc start "$H0"
gc begin $(( H0 + 1 )) AGENT_ID=c-001
gc poke $(( H0 + 2 )) AGENT_ID=c-001 GC_HINT="h"
check "7. a role seat is never poked" '[ "$rc" = 4 ] && grep -q "a role seat" "$T/out" && [ "$(n "$T/send.log")" = 0 ]'
echo $(( H0 + 3600 )) >"$S/c-914/.human-hold"
gc begin $(( H0 + 3 )) AGENT_ID=c-914
gc poke $(( H0 + 4 )) AGENT_ID=c-914 GC_HINT="h"
check "7. a human hold is refused" '[ "$rc" = 4 ] && grep -q "human hold" "$T/out" && [ "$(n "$T/send.log")" = 0 ]'

# --- 8. close-ask ----------------------------------------------------------------------
reset; lane c-915
gc start "$H0"
gc begin $(( H0 + 1 )) AGENT_ID=c-915
gc close-ask $(( H0 + 2 )) AGENT_ID=c-915 GC_WHY="ACCEPTED by c-001 at 20:00Z, idle since"
check "8. close-ask = one note to the orchestrator" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--to orchestrator --kind note --task gc-c-915")" = 1 ]'
gc begin $(( H0 + 1800 )) AGENT_ID=c-915
gc close-ask $(( H0 + 1801 )) AGENT_ID=c-915 GC_WHY="again"
check "8. a 2nd close-ask within 24 h = refused" '[ "$rc" = 4 ] && [ "$(n "$T/send.log")" = 1 ]'

# --- 9. done ---------------------------------------------------------------------------
reset; lane c-916
gc start "$H0"; gp="$(awk '{print $2}' "$D/gc/run")"
gc "done" $(( H0 + 300 )) GC_SUMMARY="1 agents: 1 working"
check "9. done = one summary line to c-001 on task gc-box-a" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--to c-001 --kind note --task gc-box-a")" = 1 ] && grep -q "DONE .*1 agents: 1 working" "$D/gc/gc.log"'
check "9. done closes the GC window" 'grep -q "kill-window -t $gp" "$T/tmux/log" && [ "$(gcwin)" = 0 ]'

# --- 10. scan --------------------------------------------------------------------------
reset; lane c-917; lane c-918; lane c-919 box-b
printf '{"v":1,"from":"c-001","to":"c-918","kind":"result","body":"ACCEPTED - thanks"}\n' >"$S/c-918/archive/m1.json"
gc scan $(( H0 + 60 ))
check "10. scan lists this box's agents only" '[ "$rc" = 0 ] && grep -q "^== c-917 " "$T/out" && grep -q "^== c-918 " "$T/out" && ! grep -q "c-919" "$T/out" && grep -q "agents=2" "$T/out"'
check "10. an ACCEPTED lane is hinted done" 'grep -q "^== c-918 .*hint=accepted" "$T/out" && grep -q "^== c-917 .*hint=working" "$T/out"'
gc scan $(( H0 + 1000 ))
check "10. silent past GC_SILENT_AGE is hinted silent" 'grep -q "^== c-917 .*hint=silent" "$T/out"'

# --- 11. the session command -----------------------------------------------------------
printf '#!/bin/sh\n' >"$T/bin/claude"; chmod +x "$T/bin/claude"
out="$(SPOOL_VENDOR_CLIS_CMD="echo claude" CLAUDE_BIN="$T/bin/claude" GROK_BIN="$T/none/grok" GC_SESSION_PRINT=1 bash "$PROJ_ROOT/src/bash/features/gc/gc-session.sh" grok claude 20261013T2100Z-gc-box-a "$T" 2>&1)"
check "11. grok missing = the cnf fallback claude, bypass flags" 'grep -q "no grok CLI on this box" <<<"$out" && grep -q "$T/bin/claude.* --dangerously-skip-permissions" <<<"$out"'
out2="$(SPOOL_VENDOR_CLIS_CMD="echo claude,grok" CLAUDE_BIN=claude GROK_BIN=grok GC_SESSION_PRINT=1 bash "$PROJ_ROOT/src/bash/features/gc/gc-session.sh" claude grok 20261013T2200Z-gc-box-a "$T" 2>&1)"
check "11. a bare-name CLAUDE_BIN on the agent PATH starts claude (sat 22:00Z)" '! grep -q "no claude CLI" <<<"$out2" && grep -q "'"'"'claude'"'"' --name" <<<"$out2"'
out3="$(SPOOL_VENDOR_CLIS_CMD="echo mistral" CLAUDE_BIN=claude GROK_BIN=grok GC_SESSION_PRINT=1 timeout 1 bash "$PROJ_ROOT/src/bash/features/gc/gc-session.sh" claude grok 20261013T2200Z-gc-box-a "$T" 2>&1)"
check "11. neither CLI on the agent PATH = no GC this slot" 'grep -q "no grok CLI either" <<<"$out3"'
check "11. the session reads the fixed prompt file" 'grep -q "features/gc/gc-prompt.md" <<<"$out" && [ -s "$PROJ_ROOT/src/bash/features/gc/gc-prompt.md" ]'
check "11. no ERR trap fired in any run" '! grep -q ERRTRAP "$T/all.out"'

echo "---"
if [ "$fails" -eq 0 ]; then echo "gc-agent: all checks passed"; exit 0; fi
echo "gc-agent: $fails check(s) failed"; exit 1
