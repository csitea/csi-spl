#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2544, do_spl_role_failover: a role seat that cannot act switches
#          to the next vendor IN PLACE (owner HUM-10 t1 b3e90079, msg dfe76b16:
#          "the order is claude -> grok -> agy"); no second standby process.
#          A sandbox: a fake /proc (LEASE_PROC_ROOT), panes read through
#          LEASE_PANE_CMD, tmux, spawn-window, kill, ./run (lane-mix, the
#          handoff's sources) and the identity map are stubs; the seat switch
#          is the REAL role-seat-switch.sh. The action runs under ./run's
#          set -E + ERR trap.
#   1. dry run: PLAN c-001 -> g-001, nothing moved, lease.conf unchanged
#   2. stall -> switch to grok: one dir g-001 (the inbox moved with it),
#      every other letter links to it, grok started in the seat
#      (SPAWN_REUSE_ID=1), lease.conf LEASE_ORCH=g-001, the old claude ended
#      and its window closed, seat.001 recorded, c-002's prompt untouched
#   3. the 10-19 overwrite, RED CONTROL: a start on g-001 while g-001 links to
#      ANOTHER seat (c-002) writes c-002's lifetime/prompt.txt; the switch
#      refuses that start (not a dir of its own), nothing written
#   4. grok out (lane-mix: no sign-in) -> agy (a-001); agy's wait not run yet
#      (ROLE_FAILOVER_SILENT 250 <= 300) -> nothing
#   5. grok unable after its start -> closed, the dirs back to c-001,
#      lease.conf untouched, grok backed off, then agy in the same run
#   6. a seat already on grok that cannot act -> agy; the record keeps the
#      claude id it goes back to
#   7. SKIP: the seat able; the rotation lock held; a rotation in flight
#   8. concurrent rotation: while a switch runs, do_spl_orch_rotate finds
#      rotate.orch.lock held (GATE SKIP locked)
#   9. the handback: the rotation's successor of a failover seat stays grok
#      while claude cannot act, is claude (g-001 -> c-001) once it can; the
#      record goes when the seat is claude again; a standby box hands it back
#  10. dispatch: c-002 -> g-002 (LEASE_MASTER), the dispatcher brief in the
#      seed, c-003 untouched
#  11. SPL-2609, proof of work: the switch sends the new seat a probe task
#      (its inbox) carrying the ACK command; the fake seat runs that REAL
#      command (ROLE_FAILOVER_CMD=ack, spl_rotate_ack_send) as its new pid.
#      RED CONTROL: a seat that starts and sits at an idle prompt but never
#      acks (NO_ACK=g) is NOT able: closed, dirs back, lease.conf untouched,
#      grok backed off (before SPL-2609 it took the seat). A seat that acks
#      is able; the ack from another pid is refused.
#  12. SPL-2865 (b), 2026-10-22 09:54Z on the standby box: the silent holder
#      was another box's seat, the lease launched the switch on a fresh wd
#      HIT, and the seat was able again by the time the guards had run
#      (rotate.log "cannot act (able )"). The seat is checked again right
#      before the switch: able = SKIP, nothing moved or started.
#  13. SPL-2865 (c): a failed switch puts back what it wrote: the links it
#      made for the seat's other letters (g-001 -> c-001) go, and the seat's
#      lifetime/prompt.txt is the one it had before (not the grok seed).
#  14. SPL-2943, the 2026-10-22 10:23..11:01Z picture: claude, grok and agy
#      cannot act; a SECOND claude login (its own config folder,
#      CLAUDE2_CONFIG_DIR) can. RED CONTROL: before SPL-2943 nothing took the
#      seat ("no vendor is left"). Now the seat restarts IN PLACE as claude
#      (same id c-001, no dir switch) with CLAUDE_CONFIG_DIR = that folder;
#      no login in the folder = dormant, nothing started. The handback: the
#      rotation keeps the second login while claude is out, the main login
#      (no CLAUDE_CONFIG_DIR) once claude can act; the record goes then.
#  RED CONTROL: on a tree before SPL-2544 every case fails (no such action);
#  12 and 13 fail on a tree before SPL-2865; 14 before SPL-2943.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$T/pane" "$D"
TCK="$(getconf CLK_TCK)"; UP=100000
echo "$UP.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
CONF=$'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\nLEASE_FLEET=main\nLEASE_ENV=prd\nLEASE_TENANT=t1'
LOGIN=$'Select login method:\n\n ❯ 1. Claude account\n   2. Console account'

# proc <pid> <id> [comm]: a fake agent process carrying SPOOL_AGENT_ID=<id>
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo "${3:-claude}" >"$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$d/environ"
echo "$1 (${3:-claude}) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - 7200) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
# tmux: panes in $T/tmux/panes as "<pane>\t<pid>"; a screen in screen.<pane>
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; cmd="$1"; shift; tgt=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -F) shift 2 ;; *) shift ;; esac; done
echo "$cmd $tgt" >>"$T/tmux/log"
case "$cmd" in
  list-panes) awk -F'\t' '{print $2" "$1}' "$P" 2>/dev/null ;;
  capture-pane) cat "$T/tmux/screen.$tgt" 2>/dev/null || printf '────\n❯ \n────\n' ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" >"$P.new"; mv "$P.new" "$P" ;;
  display-message) echo "0 " ;;
  *) : ;;
esac
EOF
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"; as
# spawn-core: the seed into <spool>/<ID>/lifetime/prompt.txt (a link is
# followed, as on the box) and a registry.tsv row.
# spawn.screen.<ID> / spawn.lease-pane.<ID>: the new pane shows that screen.
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; case "$1" in grok) b=3000 ;; agy) b=4000 ;; *) b=5000 ;; esac
pid=$(( b + 10#$n )); pane="%$pid"
echo "spawn $1 $2 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-}" >>"$T/spawn.log"
[ -f "$T/spawn.sleep" ] && command sleep "$(cat "$T/spawn.sleep")"
cp "$4" "$T/seed.$id"
mkdir -p "$SPOOL_ROOT/$id/lifetime"; cp "$4" "$SPOOL_ROOT/$id/lifetime/prompt.txt"
printf '%s\t%s\t%s\t%s\t%s\t-\n' "$id" "$1" "$pane" "$3" "$(date -u +%Y%m%dT%H%M%SZ)" >>"$SPOOL_ROOT/registry.tsv"
printf '%s\t%s\n' "$pane" "$pid" >>"$T/tmux/panes"
[ -f "$T/spawn.screen.$1" ] && { cp "$T/spawn.screen.$1" "$T/tmux/screen.$pane"; cp "$T/spawn.screen.$1" "$T/pane/$pid"; }
[ -f "$T/spawn.lease-pane.$1" ] && cp "$T/spawn.lease-pane.$1" "$T/pane/$pid"
"$T/bin/proc" "$pid" "$id" "$1"
[ -n "${SPAWN_CLAUDE_CONFIG_DIR:-}" ] && { printf 'CLAUDE_CONFIG_DIR=%s\0' "$SPAWN_CLAUDE_CONFIG_DIR" >>"$T/proc/$pid/environ"; echo "cfg $id $SPAWN_CLAUDE_CONFIG_DIR" >>"$T/spawn.log"; }
echo "$id $pane"
EOF
# claude auth status: logged in only under a CLAUDE_CONFIG_DIR holding "login"
cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/login" ]; then echo '{"loggedIn": true}'; else echo '{"loggedIn": false}'; fi
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"; rm -rf "$T/proc/$2"
EOF
cat >"$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "$3" >"$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
  retire) echo "retire $2" >>"$T/ai.log" ;;
esac
EOF
# ./run: lane-mix answers per LANE_MIX_SPLIT_KIND (GROK_OUT=1: grok skipped),
# every other action prints nothing. HEAL=<pid>: a lane-mix call clears that
# pid's pane (the seat can act again while the guards run)
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "run $*" >>"$T/run.log"
[ "$2" = do_spl_lane_mix ] || exit 0
[ -n "${HEAL:-}" ] && rm -f "$T/pane/$HEAL"
case "$LANE_MIX_SPLIT_KIND" in
  *grok=100*) if [ "${GROK_OUT:-0}" = 1 ]; then echo "grok 100 skip (no sign-in); share to claude"; echo "pick=claude"; else echo "pick=grok"; fi ;;
  *agy=100*) if [ "${AGY_OUT:-0}" = 1 ]; then echo "agy 100 skip (no agy cli); share to claude"; echo "pick=claude"; else echo "pick=agy"; fi ;;
esac
EOF
# spool-send.sh: the sender's outbox copy, as the real one writes it; a
# probe task (ACK-COMMAND in the body) to a seat whose vendor letter is not
# in NO_ACK is acked by that seat: the REAL ack command, run as its new pid
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
echo "send $*" >>"$T/send.log"
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;; --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
if [ -d "$SPOOL_ROOT/$from" ]; then
  mkdir -p "$SPOOL_ROOT/$from/outbox"
  jq -n --arg f "$from" --arg t "$to" --arg k "$kind" --arg ta "$task" '{msg_id: "m", from: $f, to: $t, kind: $k, task_id: $ta}' >"$SPOOL_ROOT/$from/outbox/$(date +%s%N).json"
fi
case "$kind $body" in task*ACK-COMMAND:*) ;; *) exit 0 ;; esac
case " ${NO_ACK:-} " in *" ${to%%-*} "*) echo "seat $to never acks" >>"$T/ack.log"; exit 0 ;; esac
role="$(sed -nE 's/.*ROLE_FAILOVER_ROLE=([a-z]+).*/\1/p' <<<"$body")"; rid="$(sed -nE 's/.*ROTATE_ID=([^ ]+).*/\1/p' <<<"$body")"
npid="$(sed -n 's/^ROTATE_NEW_PID=//p' "$SPOOL_ROOT/dispatch/role-failover/rotate.failover-$role.ctx")"
env ROLE_FAILOVER_CMD=ack ROLE_FAILOVER_ROLE="$role" ROTATE_ID="$rid" ROTATE_CALLER_PID="${ACK_PID:-$npid}" "$T/bin/act" >>"$T/ack.log" 2>&1
echo "ack rc=$?" >>"$T/ack.log"
EOF
# the lease's pane read (LEASE_PANE_CMD <pid>): $T/pane/<pid>, else an idle prompt
printf '#!/bin/sh\ncat "$T/pane/$1" 2>/dev/null || printf "❯ \\n"\n' >"$T/bin/pane"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/tr"
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
sleep() { :; }
do_log() { echo "$*"; }
do_require_bin() { return 0; }
source "$PROJ_PATH/src/bash/run/spl-role-failover.func.sh"
source "$PROJ_PATH/src/bash/run/spl-orch-rotate.func.sh"
"${ACT_FN:-do_spl_role_failover}" || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPL_STATE_DIR="$T/state" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/pane" LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_ACTIVITY_CMD="$T/bin/tr" \
  ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_KILL="$T/bin/kill" ROTATE_AI="$T/bin/ai" ROTATE_RUN="$T/bin/run" ROTATE_SEND="$T/bin/send" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_LEASE_KINDS="claude grok agy" ROTATE_SWITCH_DESK_ENVS="" DESK_STATE_ROOT="$T/desks" ROTATE_CLAUDE_BIN=/bin/true \
  ROTATE_POLL=1 ROTATE_START_WAIT=3 ROTATE_START_CHECK_WAIT=0 ROTATE_NEW_EXIT_WAIT=1 ROTATE_TERM_WAIT=1 ROLE_FAILOVER_EXIT_WAIT=1 START_CHECK_POLL=0 \
  ROLE_FAILOVER_ACK_WAIT=2 \
  LANE_MIX_WD_DIR="$T/wd"

# the box: three claude role seats, each its own real dir; c-001 on a login picker
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/pane/"* "$T/"*.log "$T/seed."* "$T/spawn."* "$T/ai."* "$T/wd" "${D:?}"/* "${S:?}"/[acgmq]-0* "$S/registry."*
  echo "$CONF" >"$D/lease.conf"
  echo "c-002@box-desk $(date +%s)" >"$D/lease"; echo "c-001@box-desk $(date +%s)" >"$D/lease.orch"
  local id
  for id in c-001 c-002 c-003; do mkdir -p "$S/$id/inbox" "$S/$id/outbox" "$S/$id/lifetime"; echo "SEED $id" >"$S/$id/lifetime/prompt.txt"; done
  echo '{"msg_id":"m1"}' >"$S/c-001/inbox/m1.json"
  "$T/bin/proc" 101 c-001; "$T/bin/proc" 102 c-002; "$T/bin/proc" 103 c-003
  printf '%%101\t101\n%%102\t102\n%%103\t103\n' >"$T/tmux/panes"
  printf '%s\n' "$LOGIN" >"$T/pane/101"
}
act() { env "$@" "$T/bin/act"; }
spawns() { [[ -f "$T/spawn.log" ]] || { echo 0; return 0; }; grep -c '^spawn ' "$T/spawn.log" || true; }
lnk() { readlink "$S/$1" 2>/dev/null || echo "-"; }
real() { [[ -d "$S/$1" && ! -L "$S/$1" ]]; }
key() { sed -n "s/^$1=//p" "$D/lease.conf"; }

# --- 1. dry run ------------------------------------------------------------------------
world; C0="$(md5sum <"$D/lease.conf")"
act ROLE_FAILOVER_ROLE=orch >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 0 && "$(md5sum <"$D/lease.conf")" == "$C0" ]] && real c-001 && [[ ! -e "$S/g-001" ]] &&
  grep -q ' SWITCH PLAN c-001 (claude) cannot act (stalled pid=101: Select login method.*c-001 -> g-001 in place' "$T/o" &&
  pass "1. dry run: PLAN c-001 -> g-001, nothing moved or started, lease.conf unchanged" || fail "1. rc=$rc spawns=$(spawns) $(cat "$T/o")"

# --- 2. stall -> grok in place ------------------------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 1 ]] && grep -q '^spawn grok g-001 SPAWN_REUSE_ID=1$' "$T/spawn.log" &&
  pass "2. grok started IN the seat as g-001 (SPAWN_REUSE_ID=1), one process" || fail "2. rc=$rc $(cat "$T/spawn.log" 2>&1) $(cat "$T/o")"
real g-001 && [[ "$(lnk c-001)" == g-001 && "$(lnk a-001)" == g-001 && "$(lnk m-001)" == g-001 && -f "$S/g-001/inbox/m1.json" && -f "$S/c-001/inbox/m1.json" ]] &&
  pass "2. one real dir g-001 (the unread inbox moved with it); c-001, a-001, m-001 link to it" || fail "2. dirs: c=$(lnk c-001) a=$(lnk a-001) $(ls -la "$S")"
[[ "$(key LEASE_ORCH)" == g-001 && "$(key LEASE_MASTER)" == c-002 ]] && ls "$D"/lease.conf.bak-* >/dev/null 2>&1 &&
  pass "2. lease.conf LEASE_ORCH=g-001 (a backup first), the other keys kept" || fail "2. conf: $(cat "$D/lease.conf")"
grep -q '^kill -TERM 101' "$T/kill.log" && [[ ! -d "$T/proc/101" ]] && grep -q '^kill-window %101' "$T/tmux/log" && pass "2. the old claude session ended (TERM after /exit) and its window closed" || fail "2. old: $(cat "$T/kill.log" "$T/tmux/log" 2>&1)"
grep -q '^c-001 g-001 grok [0-9T]*Z-failover-orch [0-9]*$' "$D/role-failover/seat.001" && grep -q -- '-failover-orch OK g-001 (grok, pid 3001' "$D/role-failover.log" &&
  pass "2. the switch is recorded (role-failover/seat.001) and logged" || fail "2. record: $(cat "$D/role-failover/seat.001" "$D/role-failover.log" 2>&1)"
[[ "$(cat "$S/c-002/lifetime/prompt.txt")" == "SEED c-002" && "$(cat "$S/c-003/lifetime/prompt.txt")" == "SEED c-003" ]] &&
  grep -q '^## Vendor failover .*-failover-orch (SPL-2544)' "$S/g-001/lifetime/prompt.txt" && grep -q '^You are g-001@box-desk, the orch seat' "$S/g-001/lifetime/prompt.txt" &&
  pass "2. the seed went to the seat's own prompt; c-002's and c-003's prompts untouched" || fail "2. prompts: $(head -3 "$S/c-002/lifetime/prompt.txt" "$S/g-001/lifetime/prompt.txt")"
grep -q -- '--to g-001 --kind result .*VENDOR FAILOVER' "$T/send.log" && pass "2. the seat's new id gets the switch note" || fail "2. note: $(cat "$T/send.log" 2>&1)"

# --- 3. the 10-19 overwrite: a start on an id that links to another seat ------------------
world; rm -rf "$S/g-001"; ln -s c-002 "$S/g-001"
echo "STANDBY SEED" >"$T/standby.seed"
SPOOL_ROOT="$S" "$T/bin/spawn" grok g-001 "$T" "$T/standby.seed" x >/dev/null 2>&1
[[ "$(cat "$S/c-002/lifetime/prompt.txt")" == "STANDBY SEED" ]] &&
  pass "3. RED CONTROL: a plain start on g-001 -> c-002 overwrites c-002's lifetime/prompt.txt (the 10-19 09:5xZ overwrite)" ||
  fail "3. control did not overwrite: $(cat "$S/c-002/lifetime/prompt.txt")"
world; rm -rf "$S/g-001"; ln -s c-002 "$S/g-001"; : >"$T/spawn.log"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 ROTATE_SEAT_SWITCH=true >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 0 && "$(cat "$S/c-002/lifetime/prompt.txt")" == "SEED c-002" && "$(key LEASE_ORCH)" == c-001 ]] &&
  grep -q "SWITCH FAIL after the switch $S/g-001 is not a dir of its own" "$T/o" &&
  pass "3. the switch refuses that start: nothing spawned, c-002's prompt untouched, lease.conf unchanged" || fail "3. rc=$rc spawns=$(spawns) $(cat "$T/o")"

# --- 4. grok out -> agy; agy's wait --------------------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 GROK_OUT=1 ROLE_FAILOVER_SILENT=250 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 0 ]] && real c-001 && grep -q 'SWITCH SKIP grok cannot take seat c-001: no sign-in' "$T/o" &&
  grep -q 'SWITCH SKIP agy not yet: the holder is silent 250s, agy takes a seat past 300s' "$T/o" &&
  pass "4. grok out, silent 250 s: agy's wait (300 s) has not run, nothing switched" || fail "4. wait: rc=$rc $(cat "$T/o")"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 GROK_OUT=1 ROLE_FAILOVER_SILENT=310 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 1 && "$(key LEASE_ORCH)" == a-001 && "$(lnk c-001)" == a-001 && "$(lnk g-001)" == a-001 ]] && real a-001 &&
  grep -q '^spawn agy a-001 SPAWN_REUSE_ID=1$' "$T/spawn.log" &&
  pass "4. grok out (lane-mix: no sign-in), silent 310 s: agy a-001 runs the seat" || fail "4. agy: rc=$rc $(cat "$T/o")"

# --- 5. grok unable after its start -> back, then agy -------------------------------------
world; printf '%s\n' "$LOGIN" >"$T/spawn.lease-pane.grok"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
grep -q '^spawn grok g-001' "$T/spawn.log" && grep -q '^kill -TERM 3001' "$T/kill.log" && [[ ! -d "$T/proc/3001" ]] &&
  grep -q 'SWITCH FAIL grok g-001 (pid 3001) not able 30s after the start: stalled pid=3001: Select login method.*seat switch back g-001 -> c-001; links removed: a-001 g-001 m-001 q-001; prompt.txt put back; lease.conf untouched' "$T/o" &&
  [[ -s "$D/role-failover/refused.001.grok" ]] &&
  pass "5. grok started but unable: closed, the dirs switched back, lease.conf untouched, grok backed off" || fail "5. back: rc=$rc $(cat "$T/kill.log" "$T/o" 2>&1)"
[[ $rc == 0 && "$(key LEASE_ORCH)" == a-001 && "$(spawns)" == 2 ]] && real a-001 && [[ "$(lnk c-001)" == a-001 ]] && grep -q '^spawn agy a-001' "$T/spawn.log" &&
  pass "5. grok unable -> agy in the same run: a-001 runs the seat" || fail "5. agy: rc=$rc conf=$(key LEASE_ORCH) $(cat "$T/spawn.log")"
rm -f "$T/spawn.lease-pane.grok"; world; mkdir -p "$D/role-failover"; echo "$(date +%s) earlier fail" >"$D/role-failover/refused.001.grok"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 AGY_OUT=1 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && real c-001 && grep -q 'SWITCH SKIP grok backed off for seat c-001' "$T/o" && grep -q 'SWITCH SKIP agy cannot take seat c-001: no agy cli' "$T/o" &&
  pass "5. a backed-off grok and an agy with no CLI: nothing switched" || fail "5. backoff: $(cat "$T/o")"

# --- 6. a seat already on grok that cannot act -> agy ---------------------------------------
world; act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >/dev/null 2>&1
[[ "$(key LEASE_ORCH)" == g-001 ]] || fail "6. setup: $(cat "$D/lease.conf")"
printf '%s\n' "$LOGIN" >"$T/pane/3001"; : >"$T/spawn.log"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(key LEASE_ORCH)" == a-001 && "$(lnk c-001)" == a-001 && "$(lnk g-001)" == a-001 ]] && real a-001 && [[ ! -d "$T/proc/3001" ]] &&
  grep -q '^c-001 a-001 agy ' "$D/role-failover/seat.001" &&
  pass "6. grok seat g-001 unable -> agy a-001 in place; the record still names c-001 to go back to" || fail "6. rc=$rc $(cat "$D/role-failover/seat.001" "$T/o" 2>&1)"

# --- 7. SKIPs -------------------------------------------------------------------------------
world; rm -f "$T/pane/101"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && real c-001 && grep -q 'SWITCH SKIP c-001 can act again' "$T/o" && pass "7. the seat able again: SKIP" || fail "7. able: $(cat "$T/o")"
world
( flock 9; command sleep 3 ) 9>>"$D/rotate.orch.lock" & command sleep 0.5
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; wait
[[ "$(spawns)" == 0 ]] && real c-001 && grep -q 'SWITCH SKIP an hourly rotation holds rotate.orch.lock' "$T/o" &&
  pass "7. the rotation lock held: SKIP, nothing switched" || fail "7. lock: $(cat "$T/o")"
world; printf 'ROTATE_RID=20261019T1005Z-orch\nROTATE_PHASE=ACK\n' >"$D/rotate.orch.ctx"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && grep -q 'SWITCH SKIP rotation 20261019T1005Z-orch is in flight at ACK' "$T/o" &&
  pass "7. a rotation in flight: SKIP (it resumes first)" || fail "7. ctx: $(cat "$T/o")"
act ROLE_FAILOVER_ROLE=nope >"$T/o" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q 'FATAL ROLE_FAILOVER_ROLE must be orch or dispatch' "$T/o" && pass "7. a bad role: FATAL" || fail "7. role: rc=$rc"

# --- 8. concurrent rotation ----------------------------------------------------------------------
world; echo 3 >"$T/spawn.sleep"
( act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o8" 2>&1 ) & bg=$!
command sleep 1.5
act ACT_FN=do_spl_orch_rotate DRY_RUN=0 ROTATE_FORCE=1 >"$T/o" 2>&1
wait "$bg"; rm -f "$T/spawn.sleep"
grep -q ' GATE SKIP locked' "$T/o" && grep -q ' SWITCH OK g-001' "$T/o8" &&
  pass "8. while the switch runs, the hourly orch rotation finds rotate.orch.lock held (GATE SKIP locked); the switch completes" ||
  fail "8. $(cat "$T/o" "$T/o8")"

# --- 9. the handback ----------------------------------------------------------------------------
vend() { env bash -c '
  sleep() { :; }; do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-orch-rotate.func.sh"
  spl_rotate_conf >/dev/null; spl_orch_rotate_vendor; echo "KIND=$ROTATE_KIND NEXT=$(spl_rotate_vendor_id "$LEASE_ORCH") WHY=$ROTATE_VENDOR_WHY"'; }
world; act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >/dev/null 2>&1
mkdir -p "$T/wd/ctx1/c-005"; echo "HIT S2 kind=auth Please run /login" >"$T/wd/ctx1/c-005/out.s2"
out="$(vend 2>&1)"
[[ "$out" == *"KIND=grok NEXT= WHY=failover seat g-001: claude still cannot act (c-005 S2 kind=auth"* ]] &&
  pass "9. claude still out (a claude seat's newest verdict S2 kind=auth): the rotation's successor stays grok, same id" || fail "9. stays: $out"
echo "OK" >"$T/wd/ctx1/c-005/out.s2"
out="$(vend 2>&1)"
[[ "$out" == *"KIND=claude NEXT=c-001 WHY=failover seat g-001 (switched from c-001): claude can act again: the handback"* ]] &&
  pass "9. claude able again: the rotation's successor is claude, g-001 -> c-001 (the handback)" || fail "9. handback: $out"
# a standby box: the orch lease held elsewhere, the failover seat still goes back
echo "c-001@pc $(date +%s)" >"$D/lease.orch"; printf 'LEASE_FLEET=main\n' >>"$D/lease.conf"
act ACT_FN=do_spl_orch_rotate ROTATE_FORCE=1 >"$T/o" 2>&1
grep -q 'GATE OK standby (orch lease: c-001@pc), but g-001 is a failover seat and claude can act again: handing it back' "$T/o" &&
  pass "9. a standby box hands its failover seat back too (orch rotation gate)" || fail "9. standby gate: $(head -5 "$T/o")"
bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/role-seat-switch.sh" --apply g-001 c-001 >/dev/null 2>&1
printf 's/^LEASE_ORCH=g-001$/LEASE_ORCH=c-001/\n' | sed -i -f - "$D/lease.conf"
out="$(vend 2>&1)"
[[ "$out" == *"KIND=claude NEXT= "* && ! -e "$D/role-failover/seat.001" ]] && real c-001 &&
  pass "9. the seat is c-001 again: its failover record is gone, the rule before it applies" || fail "9. cleared: $out $(ls "$D/role-failover")"

# --- 10. dispatch ---------------------------------------------------------------------------------
world; printf '%s\n' "$LOGIN" >"$T/pane/102"; printf '%s\n' "$LOGIN" >"$T/pane/103"
mkdir -p "$D/briefs"; echo "# Dispatcher brief for c-002 (master)" >"$D/briefs/brief-dispatcher-c-002.md"
act ROLE_FAILOVER_ROLE=dispatch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(key LEASE_MASTER)" == g-002 && "$(key LEASE_FAILOVER)" == c-003 && "$(key LEASE_ORCH)" == c-001 && "$(lnk c-002)" == g-002 ]] && real g-002 && real c-003 && real c-001 &&
  grep -q '^# Dispatcher brief for g-002 (master)' "$S/g-002/lifetime/prompt.txt" && [[ "$(cat "$S/c-003/lifetime/prompt.txt")" == "SEED c-003" ]] &&
  pass "10. dispatch: the master seat c-002 -> g-002 (LEASE_MASTER), the dispatcher brief in its seed; c-001 and c-003 untouched" ||
  fail "10. rc=$rc $(cat "$D/lease.conf") $(cat "$T/o")"

# --- 11. SPL-2609: able = the probe acked, not a prompt ------------------------------------------
# RED CONTROL: grok starts, its pane an idle prompt (the lease's test passes), never acks
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 AGY_OUT=1 NO_ACK=g >"$T/o" 2>&1; rc=$?
grep -q '^spawn grok g-001 SPAWN_REUSE_ID=1$' "$T/spawn.log" && grep -q -- '--to g-001 --kind task .*PROBE [0-9T]*Z-failover-g-001: .*ACK-COMMAND: .*ROLE_FAILOVER_CMD=ack ROLE_FAILOVER_ROLE=orch ROTATE_ID=[0-9T]*Z-failover-g-001 ' "$T/send.log" &&
  pass "11. the switch sends the new seat g-001 a probe task carrying the ACK command" || fail "11. probe: $(cat "$T/send.log" 2>&1)"
[[ $rc == 0 && "$(key LEASE_ORCH)" == c-001 ]] && real c-001 && [[ "$(lnk g-001)" == - && ! -d "$T/proc/3001" && -s "$D/role-failover/refused.001.grok" ]] &&
  grep -q 'SWITCH FAIL grok g-001 (pid 3001) not able: no ack of the probe [0-9T]*Z-failover-g-001 within 2s (up, but it did no work).*seat switch back g-001 -> c-001; links removed: a-001 g-001 m-001 q-001; prompt.txt put back; lease.conf untouched' "$T/o" &&
  grep -q 'no ack of the probe' "$D/able.g-001" &&
  pass "11. RED CONTROL: a grok seat at an idle prompt that never acks is NOT able: closed, dirs back to c-001, lease.conf untouched, grok backed off" ||
  fail "11. no-ack: rc=$rc conf=$(key LEASE_ORCH) c-001=$(lnk c-001) $(cat "$T/o")"
# the seat acks: able, by the real ack sender
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 AGY_OUT=1 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(key LEASE_ORCH)" == g-001 ]] && grep -q 'ACK OK sent by pid 3001' "$T/ack.log" &&
  jq -e 'select(.kind == "result" and .from == "g-001" and (.task_id | test("^failover-orch-rotate-[0-9T]+Z-failover-g-001$")))' "$S/g-001/outbox/"*.json >/dev/null 2>&1 &&
  grep -q 'SWITCH OK g-001 acked the probe [0-9T]*Z-failover-g-001' "$T/o" &&
  pass "11. a seat that runs the probe's ack (its result in g-001/outbox) is able: lease.conf LEASE_ORCH=g-001" ||
  fail "11. ack: rc=$rc conf=$(key LEASE_ORCH) $(cat "$T/ack.log" 2>&1) $(cat "$T/o")"
rid="$(grep -oE 'ROTATE_ID=[0-9T]+Z-failover-g-001' "$T/send.log" | sed -n 1p | cut -d= -f2)"
act ROLE_FAILOVER_CMD=ack ROLE_FAILOVER_ROLE=orch ROTATE_ID="$rid" ROTATE_CALLER_PID=999 DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 3 ]] && grep -q "ACK FAIL refused: caller pid '999' is not the new session 3001" "$T/o" &&
  pass "11. the same ack from another pid is refused (exit 3)" || fail "11. wrong pid: rc=$rc $(cat "$T/o")"

# --- 12. SPL-2865 (b): the seat able again by the time the guards ran ----------------------
world; echo "c-001@sat $(date +%s)" >"$D/lease.orch"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 HEAL=101 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 0 && "$(key LEASE_ORCH)" == c-001 ]] && real c-001 && [[ ! -e "$S/g-001" && "$(cat "$S/c-001/lifetime/prompt.txt")" == "SEED c-001" ]] &&
  grep -q 'SWITCH SKIP c-001 can act again' "$T/o" && ! grep -q 'SWITCH WAIT c-001' "$T/o" &&
  pass "12. the holder silent on another box, this box's seat able again before the switch: SKIP, nothing moved or started" ||
  fail "12. rc=$rc spawns=$(spawns) g-001=$(lnk g-001) $(cat "$T/o")"

# --- 13. SPL-2865 (c): a failed switch leaves no link and no seed behind ---------------------
world; printf '%s\n' "$LOGIN" >"$T/spawn.lease-pane.grok"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 AGY_OUT=1 >"$T/o" 2>&1; rc=$?
rm -f "$T/spawn.lease-pane.grok"
grep -q '^spawn grok g-001' "$T/spawn.log" && grep -q 'SWITCH FAIL grok g-001 .*seat switch back g-001 -> c-001' "$T/o" ||
  fail "13. setup: the grok start did not fail: $(cat "$T/o")"
[[ $rc == 0 && "$(key LEASE_ORCH)" == c-001 ]] && real c-001 && [[ ! -e "$S/g-001" && ! -L "$S/g-001" && ! -L "$S/a-001" && ! -L "$S/m-001" && ! -L "$S/q-001" ]] &&
  pass "13. the failed switch removed the links it made (g-001, a-001, m-001, q-001 -> c-001)" ||
  fail "13. links: g=$(lnk g-001) a=$(lnk a-001) m=$(lnk m-001) $(ls -la "$S")"
[[ "$(cat "$S/c-001/lifetime/prompt.txt")" == "SEED c-001" && -f "$S/c-001/inbox/m1.json" ]] &&
  pass "13. the seat's lifetime/prompt.txt is its own seed again, the inbox kept" ||
  fail "13. prompt: $(head -3 "$S/c-001/lifetime/prompt.txt")"

# --- 14. SPL-2943: the second claude login ------------------------------------------------
C2="$T/claude2"
world; rm -rf "$C2"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 GROK_OUT=1 AGY_OUT=1 ROTATE_CLAUDE_BIN="$T/bin/claude" CLAUDE2_CONFIG_DIR="$C2" >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 0 && "$(key LEASE_ORCH)" == c-001 ]] && real c-001 && grep -q 'SWITCH SKIP claude2 cannot take seat c-001: no second login: the folder CLAUDE2_CONFIG_DIR does not exist (dormant)' "$T/o" &&
  pass "14. no second login yet: claude2 is dormant, nothing started" || fail "14. dormant: rc=$rc $(cat "$T/o")"
world; mkdir -p "$C2"; : >"$C2/login"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 GROK_OUT=1 AGY_OUT=1 ROTATE_CLAUDE_BIN="$T/bin/claude" CLAUDE2_CONFIG_DIR="$C2" >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 1 && "$(key LEASE_ORCH)" == c-001 ]] && real c-001 && [[ ! -e "$S/g-001" && ! -e "$S/a-001" ]] &&
  grep -q '^spawn claude c-001 SPAWN_REUSE_ID=1$' "$T/spawn.log" && grep -qx "cfg c-001 $C2" "$T/spawn.log" &&
  pass "14. RED CONTROL: claude, grok and agy out, the second login able: c-001 restarts in place as claude with CLAUDE_CONFIG_DIR=<second folder> (was: no vendor left)" ||
  fail "14. claude2: rc=$rc spawns=$(spawns) $(cat "$T/spawn.log" 2>&1) $(cat "$T/o")"
grep -q '^c-001 c-001 claude2 ' "$D/role-failover/seat.001" && [[ ! -d "$T/proc/101" && -f "$S/c-001/inbox/m1.json" ]] &&
  pass "14. the old session ended, the inbox kept, the record names claude2" || fail "14. record: $(cat "$D/role-failover/seat.001" 2>&1) $(grep -E "SWITCH (FAIL|OK|WAIT)" "$T/o" | cut -c1-300)"
mkdir -p "$T/wd/ctx1/c-005"; echo "HIT S2 kind=limit resets 9pm" >"$T/wd/ctx1/c-005/out.s2"
out="$(env ROTATE_CLAUDE_BIN="$T/bin/claude" CLAUDE2_CONFIG_DIR="$C2" bash -c 'sleep() { :; }; do_log() { :; }
  source "$PROJ_PATH/src/bash/run/spl-orch-rotate.func.sh"; spl_rotate_conf >/dev/null
  spl_rotate_failover_vendor c-001; echo "KIND=$ROTATE_KIND CFG=$ROTATE_CLAUDE_CONFIG_DIR"' 2>&1)"
[[ "$out" == *"KIND=claude CFG=$C2"* ]] && pass "14. the main login still out: the rotation keeps the seat on the second login" || fail "14. stays: $out"
echo "OK" >"$T/wd/ctx1/c-005/out.s2"
out="$(env ROTATE_CLAUDE_BIN="$T/bin/claude" CLAUDE2_CONFIG_DIR="$C2" bash -c 'sleep() { :; }; do_log() { :; }
  source "$PROJ_PATH/src/bash/run/spl-orch-rotate.func.sh"; spl_rotate_conf >/dev/null
  spl_rotate_failover_vendor c-001; echo "KIND=$ROTATE_KIND CFG=$ROTATE_CLAUDE_CONFIG_DIR"' 2>&1)"
[[ "$out" == *"KIND=claude CFG= "* || "$out" == *"KIND=claude CFG=" ]] && pass "14. the main login back: the handback starts claude with no CLAUDE_CONFIG_DIR" || fail "14. handback: $out"
"$T/bin/proc" 5001 c-001
out="$(bash -c 'do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-orch-rotate.func.sh"; spl_rotate_conf >/dev/null
  spl_rotate_failover_seat c-001 && echo KEPT || echo GONE' 2>&1)"
[[ "$out" == *GONE* && ! -e "$D/role-failover/seat.001" ]] && pass "14. the seat on the main login again: the claude2 record is gone" || fail "14. record: $out"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
