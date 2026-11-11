#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the GC agent of a box (do_spl_gc, spl-gc.func.sh; owner HUM-10,
#          t1 91a36ace), in a sandbox: tmux is a stub keeping windows in a
#          file, the spool send and the restart are stubs. Nothing real is
#          touched. The action runs under `set -E` + an ERR trap: a lint on strays, ./run clears its own.
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
#  13. agy (SPL-2443): heartbeat progress unknown (`-`). Moved since the poke
#      (pane changed, a post) = no restart; truly frozen = today's restart;
#      an id with two panes is judged in the one its live harness (env
#      SPOOL_AGENT_ID) runs in, never the kept old pane at bash
#  14. the start check (b04-02): the :30 grok pane stopped on grok's weekly
#      limit menu = that window ended, claude started in a new one and written
#      to the run file, a FALLBACK line naming the dialog; the fallback on a
#      dialog too = FAIL, no third start; no input box in the wait = kept.
#      The stub screen draws no input box, so the suite waits
#      GC_START_CHECK_S=0 s (one look) unless a case says otherwise
#  17. the instance agent kinds (SPL-5241, owner HUM-10 t1 476aff8f: grok off):
#      the :30 grok slot with grok off = claude, one FALLBACK line naming the
#      setting; paused = claude; a failed read (hub error, junk, no fleet) =
#      claude, never grok (also a junk agent_kinds_paused, and no hub client:
#      the real spl_lane_init with no LEASE_ENV); a dry run says it and logs nothing; CONTROL: grok
#      on (qwen off) = grok as today; COUNT: the :00 claude slot reads nothing
#      The hub is a stub (LANE_HUB_CMD): kinds off [] unless a case says otherwise
#  18. one id, two boxes, and seats idle by design (SPL-5317): AGENT_ID
#      c-507@sat on box-a's GC, which has its own c-507 = refused, the log
#      names both seats, nothing sent; a GC_HINT with a bare id, or about
#      c-507@sat while poking c-507 here = refused; CONTROL: all qualified to
#      this box = delivered, the body naming c-507@box-a. An owner pane seat
#      (c-004's brief line) = hinted idle by design, poke / restart /
#      close-ask refused; a standing seat (heading, "Standing seat: stay up",
#      lifetime/standing, "# Brief: the standing ... seat") = no close-ask;
#      CONTROL: a plain lane, and lanes whose title or heading only names a
#      standing seat, are closed. A box tag != its machine: <id>@<machine> is
#      this box for begin and poke
#  15. close-ask with a landed claim (SPL-3270), in a throwaway repo: a sha
#      on origin/master = sent; a sha on a side branch only = refused, nothing
#      sent; an 8-hex msg id that is no commit = sent; no sha = sent
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
  rm -rf "$S" "$T"/*.log "$T/tmux" "$T/kinds.json" "$T/kinds.rc"
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
# lease <holder> <epoch> / lease_orch <holder> <epoch>: the fleet lease mirrors
lease() { printf '%s %s\n' "$1" "$2" >"$D/lease"; }
lease_orch() { printf '%s %s\n' "$1" "$2" >"$D/lease.orch"; }
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
  capture-pane) if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'some output\n❯ \n'; fi ;;
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
# the action under set -E and an ERR trap
# SPL-5154, as dispatch-rotate.tst.sh: the ERR trap records a stray failing
# command (one ERRTRAP line on stderr) and the run goes on; the action runs as
# a plain command, because in a `||` list bash suppresses ERR for the whole
# call. ROTATE_TEST_STRAY=<fn>: <fn> starts with a failing command (red control).
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap '[[ $BASH_COMMAND == return* ]] || echo "ERRTRAP: $BASH_COMMAND (line $LINENO)" >&2' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-gc.func.sh"
if [[ -n "${ROTATE_TEST_STRAY:-}" ]]; then
  eval "stray_$(declare -f "$ROTATE_TEST_STRAY")"
  eval "$ROTATE_TEST_STRAY() { command false; stray_$ROTATE_TEST_STRAY \"\$@\"; }"
fi
do_spl_gc
EOF
# the hub (LANE_HUB_CMD): `fleet-load get` prints $T/kinds.json, exit $T/kinds.rc
cat >"$T/bin/hub" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >>"$T/hub.log"
cat "$T/kinds.json" 2>/dev/null || echo '{"agent_kinds_off":[],"agent_kinds_paused":{}}'
exit "$(cat "$T/kinds.rc" 2>/dev/null || echo 0)"
EOF2
chmod +x "$T/bin/"*

export GC_PROC_ROOT="$T/proc" SPOOL_OWNER_HOP=0 PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 LEASE_MACHINE=box-a \
  ROTATE_TMUX="$T/bin/tmux" GC_SEND="$T/bin/send" GC_RESTART_CMD="$T/bin/restart" GC_CLOSE_DELAY=0 \
  LANE_HUB_CMD="$T/bin/hub" GC_START_CHECK_S=0 START_CHECK_POLL=0.1
unset LANE_FLEET LANE_ENV LANE_TENANT LANE_MODE SPOOL_AGENT_ID SPOOL_BOX_TAG MCP_BOT_AGENT_ID TMUX TMUX_PANE GC_VENDOR GC_CONF GC_RUN_ID
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

# SPL-5154, the red control of this file's ERRTRAP asserts: a stray planted at
# the start of the action leaves an ERRTRAP line, where the old
# `|| exit $?` stub left none
reset; DRY_RUN=1 GC_CMD=start GC_NOW="$H0" ROTATE_TEST_STRAY=do_spl_gc "$T/bin/act" >"$T/out" 2>&1 || true
check "1. control: a planted stray failing command shows as ERRTRAP" 'grep -q "^ERRTRAP: command false" "$T/out"'

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
lease c-002@sat $(( H0 - 30 )); lease_orch c-001@box-c $(( H0 - 20 ))
gc close-ask $(( H0 + 2 )) AGENT_ID=c-915 GC_WHY="ACCEPTED by c-001 at 20:00Z, idle since"
check "8. close-ask = one note to the dispatch lease holder" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--to c-002@sat --kind note --task gc-c-915 --body GC")" = 1 ]'
check "8. close-ask = one cc to the orch lease holder" '[ "$(n "$T/send.log" "--to c-001@box-c --kind note --task gc-c-915 --body cc (sent to the dispatch lease holder c-002@sat)")" = 1 ] && [ "$(n "$T/send.log")" = 2 ]'
gc begin $(( H0 + 1800 )) AGENT_ID=c-915
gc close-ask $(( H0 + 1801 )) AGENT_ID=c-915 GC_WHY="again"
check "8. a 2nd close-ask within 24 h = refused" '[ "$rc" = 4 ] && [ "$(n "$T/send.log")" = 2 ]'
reset; lane c-915
gc start "$H0"; gc begin $(( H0 + 1 )) AGENT_ID=c-915
lease c-002@sat $(( H0 - 600 )); lease_orch c-001@box-c $(( H0 - 20 ))
gc close-ask $(( H0 + 2 )) AGENT_ID=c-915 GC_WHY="idle"
check "8. close-ask, stale dispatch lease = one note to the orch holder, no cc twice" '[ "$rc" = 0 ] && [ "$(n "$T/send.log")" = 1 ] && [ "$(n "$T/send.log" "--to c-001@box-c --kind note --task gc-c-915 .*sent to the orch lease holder c-001@box-c")" = 1 ]'

# --- 9. done ---------------------------------------------------------------------------
reset; lane c-916
gc start "$H0"; gp="$(awk '{print $2}' "$D/gc/run")"
gc "done" $(( H0 + 300 )) GC_SUMMARY="1 agents: 1 working"
check "9. done, no dispatch lease = one summary to the orch seat c-001@box-a, saying so" '[ "$rc" = 0 ] && [ "$(n "$T/send.log")" = 1 ] && [ "$(n "$T/send.log" "--to c-001@box-a --kind note --task gc-box-a .*1 agents: 1 working -- no dispatch lease: sent to the orch lease holder c-001@box-a")" = 1 ] && grep -q "DONE .* to c-001@box-a: 1 agents: 1 working" "$D/gc/gc.log" && grep -q "REPORT-TO no dispatch lease" "$D/gc/gc.log"'
check "9. done closes the GC window" 'grep -q "kill-window -t $gp" "$T/tmux/log" && [ "$(gcwin)" = 0 ]'

# --- 10. scan --------------------------------------------------------------------------
reset; lane c-917; lane c-918; lane c-919 box-b
printf '{"v":1,"from":"c-001","to":"c-918","kind":"result","body":"ACCEPTED - thanks"}\n' >"$S/c-918/archive/m1.json"
gc scan $(( H0 + 60 ))
check "10. scan lists this box's agents only" '[ "$rc" = 0 ] && grep -q "^== c-917@box-a " "$T/out" && grep -q "^== c-918@box-a " "$T/out" && ! grep -q "c-919" "$T/out" && grep -q "agents=2" "$T/out"'
check "10. an ACCEPTED lane is hinted done" 'grep -q "^== c-918@box-a .*hint=accepted" "$T/out" && grep -q "^== c-917@box-a .*hint=working" "$T/out"'
gc scan $(( H0 + 1000 ))
check "10. silent past GC_SILENT_AGE is hinted silent" 'grep -q "^== c-917@box-a .*hint=silent" "$T/out"'

# --- 11. the report goes to the dispatch lease holder, read at send time --------------
# (owner HUM-10, form 84d604dd: the 10-13 night every sat summary went to a fixed
# c-001 on a limit dialog). summary <now>: one done run, a fresh send.log.
summary() { rm -f "$T/send.log"; gc "done" "$1" GC_SUMMARY="2 agents: 2 working" "${@:2}"; }
reset; lane c-916; gc start "$H0"
lease c-002@box-a $(( H0 - 30 ))
summary $(( H0 + 10 ))
check "11. holder on this box = sent there, qualified, nothing to c-001" '[ "$rc" = 0 ] && [ "$(n "$T/send.log")" = 1 ] && [ "$(n "$T/send.log" "--to c-002@box-a --kind note --task gc-box-a")" = 1 ] && ! grep -q -- "-- " "$T/send.log"'
lease c-002@sat $(( H0 - 30 ))
summary $(( H0 + 10 )); s_new="$(cat "$T/send.log")"
check "11. holder c-002@sat on the other box = the qualified id" '[ "$(n "$T/send.log" "--to c-002@sat --kind note --task gc-box-a")" = 1 ] && [ "$(n "$T/send.log")" = 1 ]'
lease c-003 $(( H0 - 30 ))
summary $(( H0 + 10 ))
check "11. a bare-id lease (no fleet) = this box qualifies it" '[ "$(n "$T/send.log" "--to c-003@box-a --kind note")" = 1 ]'
lease c-002@sat $(( H0 - 400 )); lease_orch c-001@sat $(( H0 - 20 ))
summary $(( H0 + 10 ))
check "11. stale lease (410 s > 180 s) = the orch lease holder, said in the line" '[ "$(n "$T/send.log")" = 1 ] && [ "$(n "$T/send.log" "--to c-001@sat --kind note --task gc-box-a .* -- dispatch lease c-002@sat 410s old > 180s: sent to the orch lease holder c-001@sat")" = 1 ]'
check "11. the fallback is logged" 'grep -q "REPORT-TO dispatch lease c-002@sat 410s old > 180s: sent to the orch lease holder c-001@sat" "$D/gc/gc.log"'
lease_orch c-001@sat $(( H0 - 900 ))
summary $(( H0 + 10 ))
check "11. stale lease and stale lease.orch = lease.conf LEASE_ORCH at this box" '[ "$(n "$T/send.log" "--to c-001@box-a --kind note .*orch lease holder c-001@box-a")" = 1 ]'
lease none@unreachable $(( H0 - 5 ))
summary $(( H0 + 10 ))
check "11. none@unreachable = no holder: the fallback" '[ "$(n "$T/send.log" "--to c-001@box-a .*dispatch lease none@unreachable")" = 1 ]'
lease c-002@sat $(( H0 - 30 ))
summary $(( H0 + 10 )) GC_REPORT_TO=c-009
check "11. GC_REPORT_TO set = that id, no fallback text" '[ "$(n "$T/send.log" "--to c-009 --kind note")" = 1 ] && [ "$(n "$T/send.log")" = 1 ]'
# CONTROL: the old fixed addressee (role seat 001, GC_REPORT_TO=c-001) fails the
# holder check above on the same lease
summary $(( H0 + 10 )) GC_REPORT_TO=c-001
check "11. CONTROL: a fixed c-001 does not reach the holder c-002@sat (the new run did)" '[ "$(n "$T/send.log" "--to c-002@sat")" = 0 ] && grep -q -- "--to c-002@sat" <<<"$s_new"'
# read at SEND time: the holder moves between two sends of one pass
reset; lane c-915; gc start "$H0"; gc begin $(( H0 + 1 )) AGENT_ID=c-915
lease c-002@sat $(( H0 - 30 )); lease_orch c-002@sat $(( H0 - 30 ))
gc close-ask $(( H0 + 2 )) AGENT_ID=c-915 GC_WHY="idle"
lease c-003@box-c $(( H0 + 100 ))
gc "done" $(( H0 + 120 )) GC_SUMMARY="1 agents: 1 close asked"
check "11. holder = orch holder: no cc; the holder moved: done follows it" '[ "$(n "$T/send.log")" = 2 ] && [ "$(n "$T/send.log" "--to c-002@sat --kind note --task gc-c-915")" = 1 ] && [ "$(n "$T/send.log" "--to c-003@box-c --kind note --task gc-box-a")" = 1 ]'

# --- 12. the session command -----------------------------------------------------------
printf '#!/bin/sh\n' >"$T/bin/claude"; chmod +x "$T/bin/claude"
out="$(SPOOL_VENDOR_CLIS_CMD="echo claude" CLAUDE_BIN="$T/bin/claude" GROK_BIN="$T/none/grok" GC_SESSION_PRINT=1 bash "$PROJ_ROOT/src/bash/features/gc/gc-session.sh" grok claude 20261013T2100Z-gc-box-a "$T" 2>&1)"
check "12. grok missing = the cnf fallback claude, bypass flags" 'grep -q "no grok CLI on this box" <<<"$out" && grep -q "$T/bin/claude.* --dangerously-skip-permissions" <<<"$out"'
out2="$(SPOOL_VENDOR_CLIS_CMD="echo claude,grok" CLAUDE_BIN=claude GROK_BIN=grok GC_SESSION_PRINT=1 bash "$PROJ_ROOT/src/bash/features/gc/gc-session.sh" claude grok 20261013T2200Z-gc-box-a "$T" 2>&1)"
check "12. a bare-name CLAUDE_BIN on the agent PATH starts claude (sat 22:00Z)" '! grep -q "no claude CLI" <<<"$out2" && grep -q "'"'"'claude'"'"' --name" <<<"$out2"'
out3="$(SPOOL_VENDOR_CLIS_CMD="echo mistral" CLAUDE_BIN=claude GROK_BIN=grok GC_SESSION_PRINT=1 timeout 1 bash "$PROJ_ROOT/src/bash/features/gc/gc-session.sh" claude grok 20261013T2200Z-gc-box-a "$T" 2>&1)"
check "12. neither CLI on the agent PATH = no GC this slot" 'grep -q "no grok CLI either" <<<"$out3"'
check "12. the session reads the fixed prompt file" 'grep -q "features/gc/gc-prompt.md" <<<"$out" && [ -s "$PROJ_ROOT/src/bash/features/gc/gc-prompt.md" ]'
check "12. no ERR trap fired in any run" '! grep -q ERRTRAP "$T/all.out"'

# --- 13. agy: progress unknown, and the live pane ---------------------------------------
noprog() { jq -n '{state: "idle", progress_ts: null, tool: null, api_error: null}' >"$S/$1/heartbeat.json"; }
pane_of() { awk -F'\t' -v i="$1" 'index($2, i "@") == 1 {p = $1} END {print p}' "$T/tmux/windows"; }
# pass2 <id>...: poke each on pass 1, a new pass 30 min later; then restart <id> at +3100
pass2() {
  local id
  gc start "$H0"
  for id in "$@"; do gc begin $(( H0 + 5 )) AGENT_ID="$id"; gc poke $(( H0 + 6 )) AGENT_ID="$id" GC_HINT="h"; done
  grep -v "gc@box-a" "$T/tmux/windows" >"$T/w" && mv "$T/w" "$T/tmux/windows"
  gc start $(( H0 + 1800 ))
}
rs() { rm -f "$T/restart.log"; gc begin $(( H0 + 3100 )) AGENT_ID="$1"; gc restart $(( H0 + 3101 )) AGENT_ID="$1"; sleep 0.3; }
reset; lane a-921; lane a-922; lane a-923; noprog a-921; noprog a-922; noprog a-923
pass2 a-921 a-922 a-923
check "13. the poke recorded progress - and the pane's screen" 'grep -qE "^[0-9]+ - .* %[0-9]+:[0-9a-f]{12}$" "$D/gc/a-921.poked"'
printf 'agy: reading the brief\n> \n' >"$T/tmux/screen.$(pane_of a-921)"
rs a-921
check "13. agy, progress -, the pane changed since the poke = MOVED, no restart (exit 3)" '[ "$rc" = 3 ] && grep -q "MOVED a-921: progress unknown (-), the pane changed" "$T/out" && [ ! -s "$T/restart.log" ]'
echo '{}' >"$S/a-923/outbox/m1.json"; touch -d "@$(( H0 + 600 ))" "$S/a-923/outbox/m1.json"
rs a-923
check "13. agy, progress -, a post since the poke = MOVED, no restart" '[ "$rc" = 3 ] && grep -q "MOVED a-923: .*outbox/m1.json is newer" "$T/out" && [ ! -s "$T/restart.log" ]'
rs a-922
check "13. agy truly frozen (pane, spool unchanged) = restart CAUSE=gc, saying progress unknown" '[ "$rc" = 0 ] && grep -q "restart ID=a-922 CAUSE=gc DRY_RUN=0 EV=gc .*progress unknown (-); pane %[0-9]*:[0-9a-f]* and spool unchanged since" "$T/restart.log"'
# the stale pane: a-925's kept old pane %801 (bash, the retire banner) listed
# first, the live agy in %802 under a shell
reset
mkdir -p "$S/a-925/inbox" "$S/a-925/outbox" "$S/a-925/archive" "$S/a-925/lifetime" "$T/proc"
rm -rf "$T/proc/"*
for r in "7001 (bash) S 1" "7002 (bash) S 1" "7003 (node) S 7002" "7004 (bash) S 1"; do mkdir -p "$T/proc/${r%% *}"; echo "$r 0 0" >"$T/proc/${r%% *}/stat"; done
printf 'SPOOL_AGENT_ID=a-925\0' >"$T/proc/7003/environ"; printf 'HOME=/x\0' >"$T/proc/7001/environ" ; printf 'HOME=/x\0' >"$T/proc/7002/environ"
printf '%%801\ta-925@box-a ! -2057Z-retiring\t7001\n%%802\ta-925@box-a sdlc round review\t7002\n' >>"$T/tmux/windows"
printf 'Kept after the close\n$ \n' >"$T/tmux/screen.%801"; printf 'agy: working on round 7\n> \n' >"$T/tmux/screen.%802"
noprog a-925
gc scan $(( H0 + 60 ))
check "13. two panes for one id: scan judges the live harness pane %802, once" 'grep -q "^== a-925@box-a pane=%802 " "$T/out" && grep -q "working on round 7" "$T/out" && ! grep -q "Kept after the close" "$T/out" && grep -q "agents=1" "$T/out"'
gc begin $(( H0 + 61 )) AGENT_ID=a-925
check "13. begin captures the live pane, not the kept one" 'grep -q "working on round 7" "$T/out" && ! grep -q "Kept after the close" "$T/out"'
rm -f "$T/proc/7003/environ"
gc scan $(( H0 + 62 ))
check "13. no live harness proven = the first pane (today's pick)" 'grep -q "^== a-925@box-a pane=%801 " "$T/out"'
check "13. no ERR trap fired" '! grep -q ERRTRAP "$T/all.out"'

# --- 14. the start check: a vendor stopped on a limit dialog ---------------------------
limit_screen() { printf '  ┃  You hit your weekly limit.\n  ┃  1 (○) Buy more credits\n  ┃  2 (○) Try Again\n' >"$T/tmux/screen.$1"; }
reset; limit_screen %900
gc start $(( H0 + 1800 ))
check "14. grok on its weekly limit (%900) = that window ended, claude in a new one, claude in the run file" '[ "$rc" = 0 ] && grep -q "kill-window -t %900" "$T/tmux/log" && [ "$(gcwin)" = 1 ] && [ "$(n "$T/tmux/log" new-window)" = 2 ] && [ "$(awk "{print \$2, \$3}" "$D/gc/run")" = "%901 claude" ]'
check "14. one FALLBACK line names the dialog, START names claude" '[ "$(n "$D/gc/gc.log" "FALLBACK 20261015T2130Z-gc-box-a grok -> claude: grok weekly limit")" = 1 ] && grep -q "START 20261015T2130Z-gc-box-a claude %901" "$D/gc/gc.log"'
check "14. the fallback session is started as claude" 'grep -q "new-window .*gc-session.sh'"'"' '"'"'claude'"'"' '"'"'claude'"'"'" "$T/tmux/log"'
reset; limit_screen %900; printf 'Usage limit reached · resets 4pm\n' >"$T/tmux/screen.%901"
gc start $(( H0 + 1800 ))
check "14. the fallback on a dialog too = FAIL, both windows ended, no third start (exit 1)" '[ "$rc" = 1 ] && [ "$(n "$T/tmux/log" new-window)" = 2 ] && [ "$(gcwin)" = 0 ] && grep -q "FAIL 20261015T2130Z-gc-box-a: the fallback claude stopped on usage limit" "$D/gc/gc.log" && [ ! -s "$D/gc/run" ]'
reset
s0=$SECONDS; gc start $(( H0 + 1800 )) GC_START_CHECK_S=1
check "14. no input box within the wait = the window kept, as today (one start, grok)" '[ "$rc" = 0 ] && [ "$(n "$T/tmux/log" new-window)" = 1 ] && [ "$(awk "{print \$3}" "$D/gc/run")" = grok ] && ! grep -q FALLBACK "$D/gc/gc.log" && (( SECONDS - s0 < 5 ))'
# --- 15. close-ask: a landed claim is checked (SPL-3270) ---------------------------------
R="$T/repo"; rm -rf "$R" "$T/origin.git"
gq() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }
git init -q --bare "$T/origin.git" && git init -q -b master "$R"
gq remote add origin "$T/origin.git"; gq commit --allow-empty -m on-master; gq push -q origin master
gq switch -q -c side; gq commit --allow-empty -m side-only; gq push -q origin side; gq switch -q master
on="$(git -C "$R" rev-parse --short=9 master)"; side="$(git -C "$R" rev-parse --short=9 side)"
close15() {
  reset; lane c-917; gc start "$H0"; gc begin $(( H0 + 1 )) AGENT_ID=c-917
  lease c-002@sat $(( H0 - 30 )); lease_orch c-002@sat $(( H0 - 20 ))
  gc close-ask $(( H0 + 2 )) AGENT_ID=c-917 GC_REPO="$R" GC_WHY="$1"
}
close15 "PASS on $on, $on is on master"
check "15. a sha on origin/master = sent" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--task gc-c-917")" = 1 ]'
close15 "PASS on $side, $side is on master"
check "15. a sha on a side branch only = refused, nothing sent" '[ "$rc" = 4 ] && [ "$(n "$T/send.log")" = 0 ] && grep -q "REFUSED close-ask c-917: GC_WHY says $side landed, but it is not on origin/master" "$D/gc/gc.log"'
close15 "landed, see msg e211ca41"
check "15. an 8-hex msg id that is no commit = sent" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--task gc-c-917")" = 1 ]'
close15 "landed, ACCEPTED by c-001 at 20:00Z"
check "15. a landed claim with no sha = sent" '[ "$rc" = 0 ] && [ "$(n "$T/send.log" "--task gc-c-917")" = 1 ]'

# --- 16. the prompt row's dim suggestion is not typed input (SPL-3371) -------------------
# capture-pane -e wraps Claude Code's grey suggestion in ESC[2m..ESC[0m; on 10-25 the
# GC read c-157's ghost "/exit-clean" as typed and asked for a close.
reset; lane c-918; p16="$(pane_of c-918)"
printf 'working on it\n\e[39m❯\xc2\xa0\e[2m/exit-clean \e[0m\n' >"$T/tmux/screen.$p16"
gc begin $(( H0 + 1 )) AGENT_ID=c-918
check "16. begin: a dim suggestion on the prompt row is dropped, the row and the text above stay" 'grep -q "^❯" "$T/out" && grep -q "working on it" "$T/out" && ! grep -q "exit-clean" "$T/out" && ! grep -q $'"'"'\e'"'"' "$T/out"'
gc scan $(( H0 + 2 ))
check "16. scan: the same pane prints no /exit-clean" 'grep -q "^   | ❯" "$T/out" && ! grep -q "exit-clean" "$T/out"'
printf 'working on it\n\e[39m❯\xc2\xa0\e[38;5;231m/exit-clean \e[39m\n' >"$T/tmux/screen.$p16"
gc begin $(( H0 + 3 )) AGENT_ID=c-918
check "16. CONTROL: the same text typed (not dim) is kept, its colour codes stripped" 'grep -q "^❯.*/exit-clean $" "$T/out" && ! grep -q $'"'"'\e'"'"' "$T/out"'

# --- 17. the instance agent kinds (SPL-5241) ---------------------------------------------
kinds() { printf '%s\n' "$1" >"$T/kinds.json"; }
started() { [ "$rc" = 0 ] && [ "$(n "$T/tmux/log" new-window)" = 1 ] && [ "$(awk '{print $3}' "$D/gc/run")" = "$1" ]; }
reset; kinds '{"agent_kinds_off":["grok","qwen"],"agent_kinds_paused":{}}'
gc start $(( H0 + 1800 ))
check "17. grok off: the :30 slot starts claude, one window, claude in the run file" 'started claude && grep -q "new-window .*gc-session.sh'"'"' '"'"'claude'"'"' '"'"'claude'"'"'" "$T/tmux/log"'
check "17. grok off: one FALLBACK line names the setting, START names claude, no grok START" '[ "$(n "$D/gc/gc.log" "FALLBACK 20261015T2130Z-gc-box-a grok -> claude: grok off in the prd instance settings")" = 1 ] && grep -q "START 20261015T2130Z-gc-box-a claude" "$D/gc/gc.log" && ! grep -q "START .* grok" "$D/gc/gc.log"'
check "17. the read is the hub fleet-load get" '[ "$(n "$T/hub.log" "^fleet-load get$")" = 1 ]'
reset; kinds '{"agent_kinds_off":[],"agent_kinds_paused":{"grok":{"until":"2026-11-20T00:00:00Z","reason":"usage limit","box":"sat"}}}'
gc start $(( H0 + 1800 ))
check "17. grok paused = claude" 'started claude && grep -q "FALLBACK .* grok -> claude: grok paused in the prd instance settings until 2026-11-20T00:00:00Z" "$D/gc/gc.log"'
reset; echo 1 >"$T/kinds.rc"; kinds 'Error: hub unreachable'
gc start $(( H0 + 1800 ))
check "17. a failed hub read = claude, never grok" 'started claude && grep -q "FALLBACK .* grok -> claude: the agent kinds setting was not read (the hub did not answer it: Error: hub unreachable)" "$D/gc/gc.log"'
reset; kinds '{"fleet":"main"}'
gc start $(( H0 + 1800 ))
check "17. an answer with no agent_kinds_off = claude" 'started claude && grep -q "FALLBACK .* grok -> claude: the agent kinds setting was not read" "$D/gc/gc.log"'
reset; kinds '{"agent_kinds_off":[],"agent_kinds_paused":["grok"]}'
gc start $(( H0 + 1800 ))
check "17. a junk agent_kinds_paused (an array) = claude, never grok (R7 W1)" 'started claude && grep -q "FALLBACK .* grok -> claude: the agent kinds setting was not read" "$D/gc/gc.log"'
reset; kinds '{"agent_kinds_off":[],"agent_kinds_paused":{"grok":"junk"}}'
gc start $(( H0 + 1800 ))
check "17. a paused entry jq cannot read = claude, never grok" 'started claude && grep -q "FALLBACK .* grok -> claude: the agent kinds setting was not read (jq: " "$D/gc/gc.log"'
reset; sed -i '/^LEASE_ENV=/d' "$D/lease.conf"
gc start $(( H0 + 1800 )) LANE_HUB_CMD=
check "17. no hub client (no LEASE_ENV, the real init) = claude, the hub not called (R7 W2)" 'started claude && grep -q "FALLBACK .* grok -> claude: the agent kinds setting was not read (no hub client: .*LANE_ENV" "$D/gc/gc.log" && [ "$(n "$T/hub.log")" = 0 ]'
reset; sed -i '/^LEASE_FLEET=/d' "$D/lease.conf"
gc start $(( H0 + 1800 ))
check "17. no fleet in lease.conf = claude, the hub not called" 'started claude && grep -q "FALLBACK .* grok -> claude: .*no fleet" "$D/gc/gc.log" && [ "$(n "$T/hub.log")" = 0 ]'
reset; kinds '{"agent_kinds_off":["grok"],"agent_kinds_paused":{}}'
DRY=1 gc start $(( H0 + 1800 ))
check "17. a dry start says FALLBACK and plans claude, logs nothing, opens nothing" 'grep -q "^FALLBACK .* grok -> claude: grok off" "$T/out" && grep -q "vendor=claude" "$T/out" && [ ! -s "$D/gc/gc.log" ] && [ "$(gcwin)" = 0 ]'
reset; kinds '{"agent_kinds_off":["qwen"],"agent_kinds_paused":{"agy":{"until":"2026-11-20T00:00:00Z","reason":"x","box":"sat"}}}'
gc start $(( H0 + 1800 ))
check "17. CONTROL: grok on (qwen off, agy paused) = grok as today, no FALLBACK" 'started grok && ! grep -q FALLBACK "$D/gc/gc.log" && [ "$(n "$T/hub.log")" = 1 ]'
reset; kinds '{"agent_kinds_off":["grok"],"agent_kinds_paused":{}}'
gc start "$H0"
check "17. COUNT: the :00 claude slot (the fallback) reads nothing from the hub" 'started claude && [ "$(n "$T/hub.log")" = 0 ] && ! grep -q FALLBACK "$D/gc/gc.log"'

# --- 18. one id on two boxes; seats idle by design (SPL-5317) ------------------------
# 11-11 (c-001 notes 28c3ecec, ec624c33, b55741ab, n=1 each): one box's GC
# poked its own c-507 about a FAIL relayed to c-507@sat, told the owner's
# pane seat c-004 it looked stuck, and asked to close the standing c-981.
sent() { n "$T/send.log" "${1:-.}"; }
reset; lane c-507; gc start "$H0"
gc begin $(( H0 + 1 )) AGENT_ID=c-507@sat
check "18. begin c-507@sat on box-a (its own c-507 lives here) = refused (exit 4)" '[ "$rc" = 4 ] && grep -q "REFUSED begin c-507@sat: a seat of box sat, not of this box box-a (c-507@box-a here is a different seat, not touched)" "$D/gc/gc.log"'
gc poke $(( H0 + 2 )) AGENT_ID=c-507@sat GC_HINT="a-336@box-b waits on your fix"
check "18. poke c-507@sat on box-a = refused, nothing sent to the local c-507" '[ "$rc" = 4 ] && [ "$(sent)" = 0 ] && [ ! -f "$D/gc/c-507.poked" ]'
gc begin $(( H0 + 3 )) AGENT_ID=c-507
gc poke $(( H0 + 4 )) AGENT_ID=c-507 GC_HINT="a-336 waits on your fix for the agy FAIL"
check "18. a GC_HINT naming a bare id (a-336) = refused, nothing sent" '[ "$rc" = 4 ] && [ "$(sent)" = 0 ] && grep -q "GC_HINT names a-336 with no box" "$T/out"'
gc poke $(( H0 + 5 )) AGENT_ID=c-507 GC_HINT="a-336@box-b waits on c-507@sat for the agy FAIL"
check "18. a GC_HINT about c-507@sat while poking c-507 here = refused, both named" '[ "$rc" = 4 ] && [ "$(sent)" = 0 ] && grep -q "REFUSED poke c-507@box-a: GC_HINT is about c-507@sat, a seat of another box" "$D/gc/gc.log"'
gc poke $(( H0 + 6 )) AGENT_ID=c-507@box-a GC_HINT="a-336@box-a waits on your fix (c-507@box-a)"
check "18. CONTROL: all qualified to this box = one note, the body and the log name c-507@box-a" '[ "$rc" = 0 ] && [ "$(sent "--to c-507 --kind note --task gc-c-507 --body GC (box-a, .*) to c-507@box-a: you look stuck")" = 1 ] && grep -q "POKE c-507@box-a: " "$D/gc/gc.log"'
# the owner pane seat: c-004's brief line, verbatim
reset; lane c-004; lane c-920; gc start "$H0"
printf '# Seat brief: a channel topic - the owner'"'"'s investigation seat\n\n## Rules\n- Do not post in the topic unless the owner tells you to in your pane.\n' >"$S/c-004/lifetime/brief.md"
gc scan $(( H0 + 1000 ))
check "18. scan: the pane seat silent 1000 s is idle by design, not silent; a plain lane is silent" 'grep -q "^== c-004@box-a .*hint=idle by design: an owner pane seat, not stuck, scan only (Do not post in the topic unless the owner tells you to in your pane)" "$T/out" && grep -q "^== c-920@box-a .*hint=silent" "$T/out"'
gc begin $(( H0 + 1001 )) AGENT_ID=c-004
gc poke $(( H0 + 1002 )) AGENT_ID=c-004 GC_HINT="post your 3 open questions to the topic as a blocker"; r1=$rc
gc restart $(( H0 + 1003 )) AGENT_ID=c-004; r2=$rc
gc close-ask $(( H0 + 1004 )) AGENT_ID=c-004 GC_WHY="idle"; r3=$rc
check "18. the pane seat: poke, restart, close-ask refused (exit 4 x3), nothing sent" '[ "$r1$r2$r3" = 444 ] && [ "$(sent)" = 0 ] && [ "$(n "$D/gc/gc.log" "REFUSED .* c-004@box-a: an owner pane seat, idle by design")" = 3 ]'
gc begin $(( H0 + 1005 )) AGENT_ID=c-920
gc poke $(( H0 + 1006 )) AGENT_ID=c-920 GC_HINT="the gate is red: run do_check_pre_push_lint"
check "18. CONTROL: the plain silent lane next to it is poked" '[ "$rc" = 0 ] && [ "$(sent "--to c-920 ")" = 1 ]'
# standing seats: c-981's heading, a "Standing seat: stay up" line, lifetime/standing
standing18() {  # <id> <brief text> [file]: ACCEPTED, begin, close-ask
  lane "$1"; printf '%b' "$2" >"$S/$1/lifetime/brief.md"; [ -z "${3:-}" ] || : >"$S/$1/lifetime/standing"
  printf '{"v":1,"from":"c-001","to":"%s","kind":"result","body":"ACCEPTED - thanks"}\n' "$1" >"$S/$1/archive/m1.json"
  gc begin $(( H0 + 2000 )) AGENT_ID="$1"; gc close-ask $(( H0 + 2001 )) AGENT_ID="$1" GC_WHY="ACCEPTED by c-001@box-a, idle since"
}
reset; gc start "$H0"; lease c-002@sat $(( H0 + 1970 )); lease_orch c-002@sat $(( H0 + 1970 ))
standing18 c-981 '# Seat brief: a wf-12 topic 0956269e - rebase the wf-12 branch, then stay as the topic seat (standing seat, claude, runs ON box-b)\n'; r1=$rc
standing18 c-982 '# Lane brief: reviewer\n\nReport per answered post. Standing seat: stay up; exit only on ACCEPTED.\n'; r2=$rc
standing18 c-983 '# Lane brief: the c-983 task\n' file; r3=$rc
check "18. a standing seat (heading / stay-up line / lifetime/standing) with ACCEPTED = no close-ask (exit 4 x3), nothing sent" '[ "$r1$r2$r3" = 444 ] && [ "$(sent)" = 0 ] && [ "$(n "$D/gc/gc.log" "REFUSED close-ask c-98[123]@box-a: a standing seat is never done")" = 3 ]'
gc scan $(( H0 + 2002 ))
check "18. scan: the standing seat with ACCEPTED is hinted never done, not accepted" 'grep -q "^== c-981@box-a .*hint=standing seat, never done" "$T/out" && ! grep -q "^== c-981@box-a .*hint=accepted" "$T/out"'
standing18 c-984 '# Lane brief: row 3, review by the round standing reviewer c-285@sat\n'
check "18. CONTROL: a plain lane with ACCEPTED (its brief names another standing reviewer) = close-ask sent" '[ "$rc" = 0 ] && [ "$(sent "--task gc-c-984")" = 1 ]'
standing18 c-985 '# Lane brief: a GC bug\n\nIts brief makes c-981 a STANDING seat ("Standing seat: stay up"). A standing seat is never done.\n'
check "18. CONTROL: a lane whose brief quotes another seat's \"Standing seat: stay up\" = close-ask sent" '[ "$rc" = 0 ] && [ "$(sent "--task gc-c-985")" = 1 ]'
# N1 (R7 c-781 f2578445): a title or heading that only NAMES a standing seat
# is a lane. Verbatim from 3 lane briefs (the reviewer of this fix among them).
standing18 c-986 '# Lane brief: bug - the watchdog S1 restarts an idle standing seat whose plan line is a monitor wait (one small task, claude)\n'; r1=$rc
standing18 c-987 '# Lane brief: SPL-5317 R7 code review of a1f1e8706 (the GC never pokes a same-id seat of another box, nor an owner pane seat; no close-ask for a standing seat)\n'; r2=$rc
standing18 c-988 '# Lane brief: a CI caps test races the hub log\n\n## The red (diagnosed by the standing CI seat c-296@box-b, msg c6175e5e)\n'; r3=$rc
check "18. CONTROL: lanes whose title or a heading only names a standing seat = close-ask sent (x3)" '[ "$r1$r2$r3" = 000 ] && [ "$(sent "--task gc-c-98[678]")" = 3 ]'
standing18 c-989 '# Brief: the standing CI-refactor seat - one measured CI change per round (claude, complex_coding, CI only)\n'
check "18. a \"# Brief: the standing ... seat\" title = no close-ask (exit 4)" '[ "$rc" = 4 ] && [ "$(sent "--task gc-c-989")" = 0 ]'
# N3: the box tag (SPOOL_BOX_TAG) differs from the machine (ROTATE_BOX); a
# qualified <id>@<machine> is this box for begin and poke, the body names the tag.
reset; lane c-507; gc start "$H0" SPOOL_BOX_TAG=tag-a
gc begin $(( H0 + 1 )) SPOOL_BOX_TAG=tag-a AGENT_ID=c-507@box-a
check "18. tag != machine: begin c-507@box-a (the machine) = begun (exit 0)" '[ "$rc" = 0 ] && grep -q "^BEGIN c-507:" "$T/out"'
gc poke $(( H0 + 2 )) SPOOL_BOX_TAG=tag-a AGENT_ID=c-507@box-a GC_HINT="a-336@box-a waits on c-507@tag-a"
check "18. tag != machine: poke c-507@box-a, GC_HINT naming the tag and the machine = one note to c-507@tag-a" '[ "$rc" = 0 ] && [ "$(sent "--to c-507 --kind note --task gc-c-507 --body GC (tag-a, .*) to c-507@tag-a: you look stuck")" = 1 ]'
gc poke $(( H0 + 3 )) SPOOL_BOX_TAG=tag-a AGENT_ID=c-507@box-b GC_HINT="x"
check "18. tag != machine: poke c-507@box-b = refused (exit 4), no second note" '[ "$rc" = 4 ] && [ "$(sent)" = 1 ]'
check "18. no ERR trap fired" '! grep -q ERRTRAP "$T/all.out"'

check "14. no ERR trap fired" '! grep -q ERRTRAP "$T/all.out"'

echo "---"
if [ "$fails" -eq 0 ]; then echo "gc-agent: all checks passed"; exit 0; fi
echo "gc-agent: $fails check(s) failed"; exit 1
