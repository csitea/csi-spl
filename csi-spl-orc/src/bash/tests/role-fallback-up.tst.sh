#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2532, do_spl_role_fallback_up: keep the fallback role seats
#          (LEASE_ORCH_FALLBACK, LEASE_DISPATCH_FALLBACK) live as STANDBY, so
#          the SPL-2521 vendor fallback has a live seat to hand a role to (on
#          2026-10-19 no box ran one). A sandbox: a fake /proc
#          (LEASE_PROC_ROOT), panes read through LEASE_PANE_CMD (the stub
#          pattern of fleet-lease-vendor-failover.tst.sh), tmux, spawn-window,
#          kill and the identity map are stubs (ROTATE_TMUX, ROTATE_SPAWN,
#          ROTATE_KILL, ROTATE_AI). The action runs under ./run's set -E + ERR trap.
#   1. dry run: one PLAN per missing id (ROLE_FALLBACK_IDS=g-001,g-002 -> 2;
#      no narrowing -> the 6 default ids), nothing spawned or written
#   2. no seat -> DRY_RUN=0 starts 1 per missing id (grok, SPAWN_REUSE_ID=1,
#      a STANDBY seed), STARTED logged
#   3. seats live -> starts 0, OK
#   4. a live seat on grok's quota screen (402: "You hit your weekly limit")
#      -> REFUSED by the lease's own able test, starts 0, nothing killed
#   5. a started seat stopped on that screen -> closed (TERM + window killed),
#      backed off: the next run starts nothing (BACKOFF); past the backoff it
#      tries again; a clean start that the lease's able test refuses
#      ROLE_FALLBACK_SETTLE s later is closed and backed off the same way
#   6. LEASE_*_FALLBACK=none -> 0 started; no LEASE_FLEET -> SKIP
#   7. cron: no role-fallback.conf -> nothing; enable writes it; then starts
#   8. the run lock held -> SKIP, nothing started
#   9. never writes a lease file: lease, lease.orch, lease.conf unchanged
#  10. desk-reconcile-cron.sh runs it (ROLE_FALLBACK_CMD=cron DRY_RUN=0) and
#      logs only its STARTED / REFUSED lines; its failure does not fail the
#      reconcile; DESK_ROLE_FALLBACK=0 and the lease pause skip it
#  RED CONTROL: on a tree without the action (master before SPL-2532) every
#  case fails (the action file is missing; case 10: no such step).
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
QUOTA=$'grok\n\n You hit your weekly limit\n\n ❯ Buy more credits\n   Try Again\n\n ↑/↓ navigate · y copy'

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
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>";
# spawn.screen.<ID>: the new pane shows that screen (a dialog)
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; pid=$(( 3000 + 10#$n )); pane="%3$n"
echo "spawn $1 $2 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-}" >>"$T/spawn.log"
cp "$4" "$T/seed.$id"
printf '%s\t%s\n' "$pane" "$pid" >>"$T/tmux/panes"
[ -f "$T/spawn.screen.$id" ] && { cp "$T/spawn.screen.$id" "$T/tmux/screen.$pane"; cp "$T/spawn.screen.$id" "$T/pane/$pid"; }
[ -f "$T/spawn.lease-pane.$id" ] && cp "$T/spawn.lease-pane.$id" "$T/pane/$pid"
"$T/bin/proc" "$pid" "$id" "$1"
echo "$id $pane"
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
esac
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
source "$PROJ_PATH/src/bash/run/spl-role-fallback-up.func.sh"
do_spl_role_fallback_up || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPL_STATE_DIR="$T/state" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/pane" LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_ACTIVITY_CMD="$T/bin/tr" \
  ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_KILL="$T/bin/kill" ROTATE_AI="$T/bin/ai" ROTATE_AS_AGENT_DIRECT=1 \
  ROTATE_POLL=1 ROTATE_START_WAIT=3 ROTATE_START_CHECK_WAIT=0 ROTATE_NEW_EXIT_WAIT=1 START_CHECK_POLL=0

world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/pane/"* "$T/"*.log "$T/seed."* "$T/spawn.screen."* "$T/spawn.lease-pane."* "$T/ai."* "${D:?}"/* "${S:?}"/[acg]-0*
  echo "$CONF" >"$D/lease.conf"
  echo "c-002@sat 1760000000" >"$D/lease"; echo "c-001@sat 1760000000" >"$D/lease.orch"
  "$T/bin/proc" 101 c-001; "$T/bin/proc" 102 c-002; "$T/bin/proc" 103 c-003
  : >"$T/tmux/panes"
}
act() { env "$@" "$T/bin/act"; }
spawns() { cat "$T/spawn.log" 2>/dev/null | grep -c '^spawn '; }
leasesum() { cat "$D/lease" "$D/lease.orch" "$D/lease.conf" | md5sum; }
# shellcheck disable=SC2054 # one env assignment, its commas are the value
G2=(ROLE_FALLBACK_IDS=g-001,g-002)

# --- 1. dry run -----------------------------------------------------------------------
world; L0="$(leasesum)"
act "${G2[@]}" >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(grep -c ' PLAN g-00[12] no live seat: would start grok' "$T/o")" == 2 && "$(spawns)" == 0 &&
   ! -e "$D/role-fallback.log" && ! -e "$D/role-fallback" ]] &&
  pass "1. dry run: 2 PLAN lines (g-001, g-002), nothing spawned or written" || fail "1. dry: rc=$rc spawns=$(spawns) $(cat "$T/o")"
act >"$T/o" 2>&1
[[ "$(grep -c ' PLAN ' "$T/o")" == 6 ]] && grep -q ' PLAN a-003 .*would start agy a-003@box-desk as dispatch STANDBY' "$T/o" &&
  pass "1. dry run, no narrowing: the lease's 6 default fallback ids (g-001 a-001 g-002 g-003 a-002 a-003)" || fail "1. defaults: $(cat "$T/o")"

# --- 2. no seat -> 1 start per missing id --------------------------------------------------
world
act DRY_RUN=0 "${G2[@]}" >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 2 ]] && grep -q '^spawn grok g-001 SPAWN_REUSE_ID=1$' "$T/spawn.log" && grep -q '^spawn grok g-002 SPAWN_REUSE_ID=1$' "$T/spawn.log" &&
  pass "2. no seat: one grok start per missing id (g-001, g-002), SPAWN_REUSE_ID=1" || fail "2. rc=$rc $(cat "$T/spawn.log" 2>&1) $(cat "$T/o")"
grep -q 'STANDBY fallback seat of the orch role' "$T/seed.g-001" && grep -q 'STANDBY fallback seat of the dispatch role' "$T/seed.g-002" &&
  grep -q 'you are now ACTIVE' "$T/seed.g-001" && pass "2. the seeds say STANDBY, act only when the lease names it" || fail "2. seed: $(cat "$T/seed.g-001" 2>&1)"
[[ "$(grep -c ' STARTED g-00[12] grok pid 300[12]' "$D/role-fallback.log" 2>/dev/null)" == 2 ]] &&
  pass "2. STARTED logged once per seat" || fail "2. log: $(cat "$D/role-fallback.log" 2>&1)"

# --- 3. seats live -> starts 0 -------------------------------------------------------------
: >"$T/spawn.log"
act DRY_RUN=0 "${G2[@]}" >"$T/o" 2>&1
[[ "$(spawns)" == 0 && "$(grep -c ' OK g-00[12] live and able' "$T/o")" == 2 ]] &&
  pass "3. seats live: starts 0, OK" || fail "3. spawns=$(spawns) $(cat "$T/o")"
[[ "$(grep -c ' STARTED \| OK ' "$D/role-fallback.log")" == 4 ]] && act DRY_RUN=0 "${G2[@]}" >/dev/null 2>&1 &&
  [[ "$(wc -l <"$D/role-fallback.log")" == 4 ]] && pass "3. an unchanged verdict is not logged again" || fail "3. log repeats: $(cat "$D/role-fallback.log")"

# --- 4. a live seat on the quota screen -> REFUSED, starts 0, not killed ------------------------
world; "$T/bin/proc" 210 g-001 grok; printf '%s\n' "$QUOTA" >"$T/pane/210"
act DRY_RUN=0 ROLE_FALLBACK_IDS=g-001 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 0 && -d "$T/proc/210" && ! -e "$T/kill.log" ]] &&
  grep -q ' REFUSED g-001 live but cannot act: stalled pid=210: You hit your weekly limit' "$T/o" &&
  pass "4. a live seat on grok's quota screen: REFUSED by the lease's able test, starts 0, not killed" || fail "4. rc=$rc spawns=$(spawns) $(cat "$T/o")"

# --- 5. a started seat stops on the quota screen -> closed, backed off ------------------------
world; printf '%s\n' "$QUOTA" >"$T/spawn.screen.g-002"
act DRY_RUN=0 ROLE_FALLBACK_IDS=g-002 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 1 && ! -d "$T/proc/3002" ]] && grep -q '^kill -TERM 3002' "$T/kill.log" && grep -q '^kill-window %3002' "$T/tmux/log" &&
  grep -q " REFUSED g-002 started and closed: .*'grok weekly limit' dialog" "$T/o" && [[ -s "$D/role-fallback/refused.g-002" ]] &&
  pass "5. a seat started on the quota dialog: closed (TERM, window killed), REFUSED, backed off" || fail "5. rc=$rc spawns=$(spawns) $(cat "$T/kill.log" "$T/o" 2>&1)"
: >"$T/spawn.log"
act DRY_RUN=0 ROLE_FALLBACK_IDS=g-002 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && grep -q ' BACKOFF g-002 refused 0 min ago' "$T/o" &&
  pass "5. the next run starts nothing (BACKOFF)" || fail "5. backoff: spawns=$(spawns) $(cat "$T/o")"
rm -f "$T/spawn.screen.g-002" "$T/tmux/screen.%3002" "$T/pane/3002"
act DRY_RUN=0 ROLE_FALLBACK_IDS=g-002 ROLE_FALLBACK_BACKOFF=0 >"$T/o" 2>&1
[[ "$(spawns)" == 1 && ! -e "$D/role-fallback/refused.g-002" ]] && grep -q ' STARTED g-002' "$T/o" &&
  pass "5. past the backoff it starts again (and clears the refusal)" || fail "5. retry: $(cat "$T/o")"

# a clean start that the lease's able test then refuses (a login picker the
# start check did not see): closed after ROLE_FALLBACK_SETTLE, backed off
world; printf 'Select login method:\n\n ❯ 1. Account\n' >"$T/spawn.lease-pane.g-001"
act DRY_RUN=0 ROLE_FALLBACK_IDS=g-001 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(spawns)" == 1 && ! -d "$T/proc/3001" ]] && grep -q '^kill -TERM 3001' "$T/kill.log" &&
  grep -q ' REFUSED g-001 started and closed: not able 30s after the start: stalled pid=3001: Select login method' "$T/o" && [[ -s "$D/role-fallback/refused.g-001" ]] &&
  pass "5. a clean start the lease's able test refuses: closed, REFUSED, backed off" || fail "5. able after start: rc=$rc $(cat "$T/kill.log" "$T/o" 2>&1)"

# --- 6. none, no fleet --------------------------------------------------------------------
world
act DRY_RUN=0 LEASE_ORCH_FALLBACK=none LEASE_DISPATCH_FALLBACK=none >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && grep -q 'SKIP role fallback: no fallback id to keep' "$T/o" &&
  pass "6. LEASE_*_FALLBACK=none: 0 started" || fail "6. none: $(cat "$T/o")"
printf 'LEASE_ORCH_FALLBACK=none\nLEASE_DISPATCH_FALLBACK=none\n' >>"$D/lease.conf"
act DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && grep -q 'no fallback id to keep' "$T/o" && pass "6. none in lease.conf: 0 started" || fail "6. none conf: $(cat "$T/o")"
world; grep -v LEASE_FLEET "$D/lease.conf" >"$D/c" && mv "$D/c" "$D/lease.conf"
act DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && grep -q 'SKIP role fallback: no LEASE_FLEET' "$T/o" && pass "6. no LEASE_FLEET: SKIP" || fail "6. fleet: $(cat "$T/o")"

# --- 7. cron opt-in -------------------------------------------------------------------------
world
act ROLE_FALLBACK_CMD=cron DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 0 ]] && grep -q 'SKIP role fallback: not enabled' "$T/o" && pass "7. cron with no role-fallback.conf: nothing" || fail "7. cron off: $(cat "$T/o")"
act ROLE_FALLBACK_CMD=enable "${G2[@]}" >"$T/o" 2>&1
[[ ! -e "$D/role-fallback.conf" ]] && grep -q '^PLAN .*ROLE_FALLBACK=1 ROLE_FALLBACK_IDS=g-001,g-002' "$T/o" && pass "7. enable dry run writes nothing" || fail "7. enable dry: $(cat "$T/o")"
act ROLE_FALLBACK_CMD=enable DRY_RUN=0 "${G2[@]}" >"$T/o" 2>&1
act ROLE_FALLBACK_CMD=cron DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 2 ]] && grep -qx 'ROLE_FALLBACK_IDS=g-001,g-002' "$D/role-fallback.conf" &&
  pass "7. enabled: the cron step starts the conf's ids (g-001, g-002)" || fail "7. cron on: spawns=$(spawns) $(cat "$T/o")"
act ROLE_FALLBACK_CMD=disable DRY_RUN=0 >/dev/null 2>&1; rm -rf "$T/proc/300"*
act ROLE_FALLBACK_CMD=cron DRY_RUN=0 >"$T/o" 2>&1
[[ "$(spawns)" == 2 ]] && grep -q 'not enabled' "$T/o" && pass "7. disable: the cron step starts nothing" || fail "7. disable: $(cat "$T/o")"

# --- 8. the run lock ------------------------------------------------------------------------
world
( flock 9; command sleep 3 ) 9>>"$D/role-fallback.lock" & command sleep 0.5
act DRY_RUN=0 "${G2[@]}" >"$T/o" 2>&1; wait
[[ "$(spawns)" == 0 ]] && grep -q 'SKIP role fallback: another run holds' "$T/o" && pass "8. lock held: SKIP, nothing started" || fail "8. lock: $(cat "$T/o")"

# --- 9. no lease file written -------------------------------------------------------------------
world; act DRY_RUN=0 >/dev/null 2>&1
[[ "$(leasesum)" == "$L0" && "$(spawns)" == 6 ]] && pass "9. 6 seats started, lease / lease.orch / lease.conf byte-identical" ||
  fail "9. lease changed or spawns=$(spawns)"

# --- 10. the desk reconcile cron step ------------------------------------------------------------
O="$T/co/$(basename "$PROJ_ROOT")"
mkdir -p "$O/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$O/src/bash/scripts/"
printf '#!/bin/sh\necho "run $* CMD=${ROLE_FALLBACK_CMD:-} DRY_RUN=${DRY_RUN:-}" >>"%s/runs"\n[ "$2" = do_spl_role_fallback_up ] || exit 0\necho "OK g-001 noise"\necho "2026-10-19T08:00:00Z sat STARTED g-002 grok pid 7 pane %%%%7, dispatch STANDBY"\nexit "${FB_RC:-0}"\n' "$T" >"$O/run"
chmod +x "$O/run"
cron() {
  : >"$T/runs"
  env SPOOL_ROOT="$S" DESK_CRON_TOOLS=true DESK_TRUNK_CHECK=0 DESK_LEASE=0 DESK_SETTINGS_CHECK=0 DESK_WELCOME=0 DESK_RESPONDER=0 \
    DESK_ALL_TENANTS=0 DESK_OTHER_BOXES=0 DESK_DISPATCH=0 "$@" bash "$O/src/bash/scripts/desk-reconcile-cron.sh" >"$T/o" 2>&1
}
world; cron; rc=$?
[[ $rc == 0 ]] && grep -q '^run -a do_spl_role_fallback_up CMD=cron DRY_RUN=0$' "$T/runs" && grep -q 'INFO .* STARTED g-002 grok' "$T/o" &&
  ! grep -q noise "$T/o" && grep -q 'INFO do_spl_role_fallback_up exit 0' "$T/o" &&
  pass "10. the reconcile tick runs ROLE_FALLBACK_CMD=cron DRY_RUN=0 and logs only its STARTED/REFUSED lines" || fail "10. rc=$rc $(cat "$T/runs" "$T/o")"
cron FB_RC=1; rc=$?
[[ $rc == 0 ]] && grep -q 'INFO do_spl_role_fallback_up exit 1' "$T/o" && pass "10. its failure does not fail the reconcile" || fail "10. rc=$rc $(cat "$T/o")"
cron DESK_ROLE_FALLBACK=0
! grep -q do_spl_role_fallback_up "$T/runs" && pass "10. DESK_ROLE_FALLBACK=0 skips it" || fail "10. off: $(cat "$T/runs")"
echo "pause" >"$D/lease.pause"; cron; rm -f "$D/lease.pause"
! grep -q do_spl_role_fallback_up "$T/runs" && pass "10. the lease pause cuts it" || fail "10. pause: $(cat "$T/runs")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
