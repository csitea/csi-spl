#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-1713. On 2026-10-13 a box's lease.conf was cut to its three
#          LEASE_MASTER / FAILOVER / ORCH lines (20:05Z, no backup), then
#          removed (20:07Z); the next LEASE_CMD=ensure left fleet mode.
#   1. spl_lease_conf_write keeps every key the new text does not name, sets
#      the ones it names in place, appends new ones, leaves a byte-identical
#      .bak-<UTC>-<tag>, keeps the file mode; an unchanged text writes no
#      backup; an empty text or a non KEY=value line is refused, file intact
#   2. spl_lease_conf_flip: KEY=OLD -> NEW with a backup; already NEW = no-op;
#      neither = refused, nothing written
#   3. do_spl_dispatch_setup step 2 keeps a key it does not know
#      (LEASE_HOLDDOWN, LEASE_INTERMITTENT) and leaves a backup
#   4. every lease.conf rewrite in the orc code goes through the one writer:
#      no `> lease.conf`, `sed -i`, `mv` or `cat >` onto it anywhere else
#   5. LEASE_CMD=ensure on a lease.conf that lost LEASE_FLEET while its newest
#      backup has it: refused, the fleet loop is NOT stopped and nothing
#      starts; CONTROL: with no such backup, ensure leaves fleet mode as before
#   6. spool_env_resolve refuses the live root (exit 96) from a hand-typed
#      shell that loaded spool-env.inc.sh from a lane worktree (the
#      2026-10-13 shape) and from a shell with the test lib loaded; CONTROLS:
#      SPOOL_LIVE_OK=1, a main checkout, a script file, a sandbox root pass.
#      The "live" root here is a mktemp dir (SPOOL_LIVE_ROOT).
#  Fixtures only in a mktemp root: never the live /var/spool-hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
LIB="$PROJ_ROOT/lib/bash/funcs/spl-lease-conf.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac

D="$T/spool/dispatch"; C="$D/lease.conf"
FULL=(LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH=c-001 LEASE_FLEET=main 'LEASE_PRIORITY=pc,sat'
  'LEASE_PRIORITY_ORCH=pc,sat' 'LEASE_PRIORITY_DISPATCH=pc,sat' LEASE_ENV=prd LEASE_TENANT=t1 ASKS_OWNER=HUM-10)
seed() { rm -rf "$T/spool"; mkdir -p "$D"; printf '%s\n' "${FULL[@]}" "$@" >"$C"; chmod 640 "$C"; }
baks() { find "$D" -name 'lease.conf.bak-*' | wc -l; }
key() { sed -n "s/^$1=//p" "$C"; }
lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

# --- 1. the writer ------------------------------------------------------------
if [[ -f "$LIB" ]]; then
  seed; cp "$C" "$T/orig"
  printf 'LEASE_MASTER=c-009\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\nLEASE_NEW=x\n' | lib spl_lease_conf_write "$C" t1 >"$T/o" 2>&1; rc=$?
  b="$(find "$D" -name 'lease.conf.bak-*-t1')"
  [[ $rc == 0 && "$(key LEASE_MASTER)" == c-009 && "$(head -1 "$C")" == LEASE_MASTER=c-009 && "$(key LEASE_NEW)" == x &&
     "$(tail -1 "$C")" == LEASE_NEW=x && "$(grep -c . "$C")" == 11 && "$(baks)" == 1 && -n "$b" ]] && cmp -s "$b" "$T/orig" &&
     diff <(grep -v '^LEASE_MASTER=\|^LEASE_NEW=' "$C") <(grep -v '^LEASE_MASTER=' "$T/orig") >/dev/null &&
     [[ "$(stat -c %a "$C")" == 640 ]] && grep -q "^BACKUP $b\$" "$T/o" &&
    pass "1. a three-key text keeps the other 8 keys, sets/appends its own, byte-identical backup, mode kept" ||
    fail "1. rc=$rc baks=$(baks): $(cat "$T/o"; cat "$C")"
  printf 'LEASE_MASTER=c-009\n' | lib spl_lease_conf_write "$C" t1 >"$T/o" 2>&1
  [[ "$(baks)" == 1 && ! -s "$T/o" ]] && pass "1. an unchanged text writes nothing, no new backup" || fail "1. unchanged: baks=$(baks) $(cat "$T/o")"
  cp "$C" "$T/before"
  printf '' | lib spl_lease_conf_write "$C" t1 >"$T/o" 2>&1 && fail "1. an empty text was accepted" ||
    { cmp -s "$C" "$T/before" && pass "1. an empty text is refused, the file intact" || fail "1. an empty text changed the file"; }
  printf 'LEASE_MASTER=c-001\nrm -rf /\n' | lib spl_lease_conf_write "$C" t1 >"$T/o" 2>&1 && fail "1. a non KEY=value line was accepted" ||
    { cmp -s "$C" "$T/before" && [[ "$(baks)" == 1 ]] && pass "1. a non KEY=value line is refused, nothing written" || fail "1. a bad line changed the file"; }
else
  fail "1. no $LIB (the one lease.conf writer)"
fi

# --- 2. flip ------------------------------------------------------------------
seed
lib spl_lease_conf_flip "$C" rid LEASE_ORCH c-001 g-001 >/dev/null 2>&1 && [[ "$(key LEASE_ORCH)" == g-001 && "$(grep -c . "$C")" == 10 && "$(baks)" == 1 ]] &&
  pass "2. flip KEY=OLD -> NEW keeps the rest, one backup" || fail "2. flip: baks=$(baks) $(cat "$C")"
lib spl_lease_conf_flip "$C" rid LEASE_ORCH c-001 g-001 >/dev/null 2>&1 && [[ "$(baks)" == 1 ]] &&
  pass "2. flip to the value it already has: no-op" || fail "2. idempotent flip: baks=$(baks)"
cp "$C" "$T/before"
lib spl_lease_conf_flip "$C" rid LEASE_ORCH c-077 c-078 >/dev/null 2>&1 && fail "2. a flip from a value the file lacks was accepted" ||
  { cmp -s "$C" "$T/before" && pass "2. a flip from a value the file lacks is refused, nothing written" || fail "2. refused flip changed the file"; }

# --- 3. dispatch-setup step 2 -------------------------------------------------
seed LEASE_HOLDDOWN=7 LEASE_INTERMITTENT=sat
cp "$C" "$T/orig"
env PROJ_PATH="$PROJ_ROOT" LEASE_CONF="$C" bash -c '
  do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-dispatch-setup.func.sh"
  DISPATCH_MASTER=c-009 DISPATCH_FAILOVER=c-003 DISPATCH_ORCH=c-001 DISPATCH_STEPS=2 SPL_DISPATCH_DRY=0
  ENV=prd DISPATCH_POSTS_DIR=/nonexistent
  spl_dispatch_setup_shared' >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(key LEASE_MASTER)" == c-009 && "$(key LEASE_HOLDDOWN)" == 7 && "$(key LEASE_INTERMITTENT)" == sat &&
   "$(key LEASE_FLEET)" == main && "$(key ASKS_OWNER)" == HUM-10 && "$(baks)" == 1 ]] &&
  pass "3. setup step 2 keeps LEASE_HOLDDOWN / LEASE_INTERMITTENT and leaves a backup" ||
  fail "3. rc=$rc baks=$(baks): $(cat "$T/o"; diff "$T/orig" "$C")"

# --- 4. one writer ------------------------------------------------------------
hits="$(cd "$PROJ_ROOT" && grep -rnE --include='*.sh' \
  '((^|[^0-9&])>|sed -i|mv (-f )?|tee (-a )?)[^|;&]*"?(\$\{?(LEASE_CONF|conf)\}?|[^" ]*/lease\.conf)"?[[:space:]]*($|\||;|&|\)|2>)' \
  src/bash/run src/bash/scripts lib/bash/funcs src/bash/features/*/scripts src/bash/features/*/lib 2>/dev/null |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|lib/bash/funcs/spl-lease-conf\.func\.sh:')"
[[ -z "$hits" ]] && pass "4. no lease.conf write outside spl_lease_conf_write" || fail "4. a lease.conf writer bypasses spl_lease_conf_write:
$hits"
# the scan can find one: a planted writer shows up
mkdir -p "$T/p/src/bash/run"; printf 'x() {\n  printf "%%s\\n" "$t" > "$LEASE_CONF"\n}\n' >"$T/p/src/bash/run/plant.func.sh"
grep -qE '((^|[^0-9&])>|sed -i|mv (-f )?|tee (-a )?)[^|;&]*"?(\$\{?(LEASE_CONF|conf)\}?|[^" ]*/lease\.conf)"?[[:space:]]*($|\||;|&|\)|2>)' "$T/p/src/bash/run/plant.func.sh" &&
  pass "4. CONTROL: the scan finds a planted '> \"\$LEASE_CONF\"'" || fail "4. CONTROL: the scan misses a planted writer"

# --- 5. ensure keeps the fleet loop on a conf that lost LEASE_FLEET ------------
ensure() {  # leaves the calls in $T/calls; $1 = lease.conf lines (no LEASE_FLEET)
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" CALLS="$T/calls" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init || exit 1
    spl_lease_ids() { spl_lease_conf; }
    spl_lease_trunk_check() { :; }
    spl_lease_code_ver() { echo v1; }
    spl_lease_running() { [[ "$1" == fleet ]]; }
    spl_lease_stop_one() { echo "stop $1" >>"$CALLS"; }
    spl_lease_detach() { echo "start" >>"$CALLS"; }
    spl_lease_ensure' >"$T/o" 2>&1
}
seed; cp "$C" "$C.bak-20261013T1751Z-master"; touch -d '1 hour ago' "$C.bak-20261013T1751Z-master"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$C"
ensure; rc=$?
[[ $rc != 0 && ! -s "$T/calls" ]] && grep -q 'lost LEASE_FLEET' "$T/o" && grep -q 'ensure REFUSED' "$D/lease.log" &&
  pass "5. a conf that lost LEASE_FLEET (newest backup has it): ensure refuses, the fleet loop runs on" ||
  fail "5. rc=$rc calls=[$(tr '\n' ' ' <"$T/calls")]: $(cat "$T/o")"
rm -f "$C".bak-*
ensure; rc=$?
[[ $rc == 0 ]] && grep -qx 'stop fleet' "$T/calls" &&
  pass "5. CONTROL: no backup with LEASE_FLEET: ensure leaves fleet mode as before" ||
  fail "5. CONTROL rc=$rc calls=[$(tr '\n' ' ' <"$T/calls")]: $(cat "$T/o")"

# --- 6. the live-root guard ---------------------------------------------------
ENVLIB="$PROJ_ROOT/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
LIVE="$T/live"; mkdir -p "$LIVE" "$T/csi-spl-wt/x-001/lib" "$T/csi-spl/lib" "$T/sbx"
cp "$ENVLIB" "$T/csi-spl-wt/x-001/lib/"; cp "$ENVLIB" "$T/csi-spl/lib/"
WTL="$T/csi-spl-wt/x-001/lib/spool-env.inc.sh"; MAINL="$T/csi-spl/lib/spool-env.inc.sh"
# resolve <lib> <root> [pre-code]: a hand-typed `bash -c` shell, as on 2026-10-13
resolve() {
  (cd "$T" && env -u SPOOL_TEST -u SPOOL_LIVE_OK SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$2" SPOOL_ENV_NO_BINS=1 \
    SPOOL_BOX_ENV=/nonexistent ${EXTRA:-} bash -c "${3:-} . '$1'; spool_env_resolve; echo REACHED") >"$T/o6" 2>&1
}
resolve "$WTL" "$LIVE"; rc=$?
[[ $rc == 96 ]] && ! grep -q REACHED "$T/o6" && grep -q 'REFUSED.*lane worktree' "$T/o6" &&
  pass "6. a bash -c shell with the lib from a lane worktree: the live root is refused (96)" || fail "6. worktree shell rc=$rc: $(cat "$T/o6")"
resolve "$MAINL" "$LIVE" 't_sandbox() { :; };'; rc=$?
[[ $rc == 96 ]] && ! grep -q REACHED "$T/o6" && grep -q 'REFUSED.*test lib' "$T/o6" &&
  pass "6. the test lib loaded (t_sandbox): the live root is refused" || fail "6. test lib rc=$rc: $(cat "$T/o6")"
EXTRA=SPOOL_LIVE_OK=1 resolve "$WTL" "$LIVE"; rc=$?
[[ $rc == 0 ]] && grep -q REACHED "$T/o6" && pass "6. CONTROL: SPOOL_LIVE_OK=1 passes" || fail "6. CONTROL live ok rc=$rc: $(cat "$T/o6")"
resolve "$MAINL" "$LIVE"; rc=$?
[[ $rc == 0 ]] && grep -q REACHED "$T/o6" && pass "6. CONTROL: the lib from a main checkout passes" || fail "6. CONTROL main rc=$rc: $(cat "$T/o6")"
resolve "$WTL" "$T/sbx"; rc=$?
[[ $rc == 0 ]] && grep -q REACHED "$T/o6" && pass "6. CONTROL: a sandbox root passes" || fail "6. CONTROL sandbox rc=$rc: $(cat "$T/o6")"
printf '. "%s"; spool_env_resolve; echo REACHED\n' "$WTL" >"$T/csi-spl-wt/x-001/s.sh"
(cd "$T" && env -u SPOOL_TEST -u SPOOL_LIVE_OK SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$LIVE" SPOOL_ENV_NO_BINS=1 SPOOL_BOX_ENV=/nonexistent \
  bash "$T/csi-spl-wt/x-001/s.sh") >"$T/o6" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q REACHED "$T/o6" && pass "6. CONTROL: a script file in a worktree passes" || fail "6. CONTROL script rc=$rc: $(cat "$T/o6")"

echo "---"
[[ $fails == 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
