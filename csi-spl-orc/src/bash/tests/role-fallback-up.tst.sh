#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2544 retired do_spl_role_fallback_up (SPL-2532's STANDBY role
#          seats g-001, a-001, ...): a role seat that cannot act now switches
#          vendor in place (do_spl_role_failover, role-failover.tst.sh).
#   1. every ROLE_FALLBACK_CMD (up, cron, enable, disable), DRY_RUN=0 too:
#      one SKIP line naming do_spl_role_failover, exit 0, nothing started
#      (the spawn stub never runs), nothing written in <spool root>/dispatch
#   2. desk-reconcile-cron.sh no longer runs it
#  RED CONTROL: on a tree before SPL-2544 case 1 starts the 6 default ids and
#  case 2 finds the reconcile step.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
S="$T/spool"; D="$S/dispatch"; mkdir -p "$D" "$T/bin"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$D/lease.conf"
printf '#!/bin/sh\necho spawn >>"%s/spawn.log"\n' "$T" >"$T/bin/spawn"; chmod +x "$T/bin/spawn"
cat >"$T/bin/act" <<'A'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-role-fallback-up.func.sh"
do_spl_role_fallback_up
A
chmod +x "$T/bin/act"
before="$(cd "$D" && ls -A | sort | tr '\n' ' ')"
for cmd in up cron enable disable; do
  out="$(env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" ROTATE_SPAWN="$T/bin/spawn" ROLE_FALLBACK_CMD="$cmd" DRY_RUN=0 SPOOL_TEST=1 "$T/bin/act" 2>&1)"; rc=$?
  [[ $rc == 0 && "$(wc -l <<<"$out")" == 1 && "$out" == "SKIP role fallback: retired (SPL-2544)"*"do_spl_role_failover"* && ! -e "$T/spawn.log" &&
     "$(cd "$D" && ls -A | sort | tr '\n' ' ')" == "$before" ]] &&
    pass "1. ROLE_FALLBACK_CMD=$cmd DRY_RUN=0: one SKIP line pointing to do_spl_role_failover, nothing started or written" ||
    fail "1. $cmd: rc=$rc out=$out"
done
! grep -q 'do_spl_role_fallback_up' "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" &&
  pass "2. desk-reconcile-cron.sh no longer runs do_spl_role_fallback_up" || fail "2. the reconcile still runs it"
echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
