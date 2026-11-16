#!/usr/bin/env bash
# rotate-weekly-first.tst.sh - the role rotations check the weekly % before a
# successor (SPL-5697, spec 175 task 5.8)
#
# A session spawned at 17:49 hit "You've hit your weekly limit" at 18:11: the
# rotation had started a claude seat with the box at 99..100 %. Now the
# dispatch (spl_disp_vendor) and orch (spl_orch_rotate_vendor) vendor picks
# end in spl_rotate_weekly_first: a claude or grok successor at or over its
# weekly mark (spl_box_quota_max) goes to the other one when it can act and is
# under its own mark. The reading is faked through LANE_QUOTA_CMD, the
# vendor guards (spl_rotate_grok_why, spl_rotate_claude_out) are stubs.
#   1. dispatch: claude 99 %, grok able at 10 % -> grok, the reason named
#   2. claude 89 % (under 90) -> claude, the reason unchanged
#   3. claude 99 %, grok cannot act -> claude stays, both reasons named
#   4. claude 99 %, grok 96 % over its own mark 95 -> claude stays
#   5. no reading -> claude
#   6. ROTATE_ROLE_VENDOR=grok, grok 97 % over 95, claude able at 20 % -> claude
#   7. ROTATE_ROLE_VENDOR=grok, grok 97 %, claude cannot act -> grok stays
#   8. ROTATE_ROLE_VENDOR=agy (dispatch) at any reading -> agy, no check
#   9. ROTATE_GROK_STANDBY=0, claude 99 % -> claude
#  10. a claude successor on the second login (ROTATE_CLAUDE_CONFIG_DIR) -> claude
#  11. orch: claude 99 %, grok able -> grok
#
# Run: bash csi-spl-orc/src/bash/tests/rotate-weekly-first.tst.sh </dev/null
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SPOOL_ROOT="$T/spool" SPOOL_TEST=1
mkdir -p "$SPOOL_ROOT" "$T/lease"
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$HERE/../run/spl-rotate-lib.func.sh"
# shellcheck source=/dev/null
source "$HERE/../run/spl-dispatch-rotate.func.sh"
# shellcheck source=/dev/null
source "$HERE/../run/spl-orch-rotate.func.sh"

export LEASE_DIR="$T/lease" LEASE_ORCH=c-901 ROTATE_ORCH_SPLIT=0
export ROTATE_QUOTA_CNF="$T/none.yaml" BOX_QUOTA_WEEKLY_MAX_PCT=90 BOX_QUOTA_WEEKLY_MAX_PCT_GROK=95
unset ROTATE_ROLE_VENDOR ROTATE_GROK_STANDBY ROTATE_CLAUDE_CONFIG_DIR SPL_CNF
GROK_WHY="" CLAUDE_OUT=""
spl_rotate_grok_why() { echo "$GROK_WHY"; }
spl_rotate_claude_out() { echo "$CLAUDE_OUT"; }

# pick FN READING: run FN (spl_disp_vendor c-902 | spl_orch_rotate_vendor) on
# the weekly READING, print "<kind>|<why>"
pick() {
  local fn="$1"
  shift
  ( export LANE_QUOTA_CMD="echo $1"
    ROTATE_KIND="" ROTATE_VENDOR_WHY=""
    if [[ "$fn" == disp ]]; then spl_disp_vendor c-902; else spl_orch_rotate_vendor; fi
    echo "$ROTATE_KIND|$ROTATE_VENDOR_WHY" )
}
# expect NAME GOT WANT_KIND WANT_WHY_SUBSTRING
expect() {
  local kind="${2%%|*}" why="${2#*|}"
  if [[ "$kind" == "$3" && "$why" == *"$4"* ]]; then pass "$1 -> $kind ($why)"
  else fail "$1: want $3 with '$4', got $kind ($why)"; fi
}

expect "1. dispatch, claude 99%, grok able" "$(pick disp claude:99,grok:10)" grok "dispatch seats: claude; but claude weekly 99% >= 90%: grok"
expect "2. claude 89%, under the mark" "$(pick disp claude:89,grok:10)" claude "dispatch seats: claude"
[[ "$(pick disp claude:89,grok:10)" == "claude|dispatch seats: claude" ]] &&
  pass "2. the reason is unchanged under the mark" || fail "2. reason: $(pick disp claude:89,grok:10)"
GROK_WHY="no grok cli"
expect "3. claude 99%, grok cannot act" "$(pick disp claude:99,grok:10)" claude "claude weekly 99% >= 90%, but grok cannot take it (no grok cli): claude stays"
GROK_WHY=""
expect "4. claude 99%, grok 96% over its own 95" "$(pick disp claude:99,grok:96)" claude "but grok cannot take it (grok weekly 96% >= 95%): claude stays"
expect "5. no reading" "$(pick disp '')" claude "dispatch seats: claude"
export ROTATE_ROLE_VENDOR=grok ROTATE_LEASE_KINDS="claude grok"
expect "6. ROTATE_ROLE_VENDOR=grok, grok 97%, claude able at 20%" "$(pick disp claude:20,grok:97)" claude "ROTATE_ROLE_VENDOR=grok: grok; but grok weekly 97% >= 95%: claude"
CLAUDE_OUT="c-005 S2 kind=limit 3m ago: x"
expect "7. ROTATE_ROLE_VENDOR=grok, grok 97%, claude cannot act" "$(pick disp claude:20,grok:97)" grok "but claude cannot take it (c-005 S2 kind=limit 3m ago: x): grok stays"
CLAUDE_OUT=""
export ROTATE_ROLE_VENDOR=agy
spl_rotate_agy_why() { :; }
expect "8. ROTATE_ROLE_VENDOR=agy at 100%" "$(pick disp claude:100,grok:100,agy:100)" agy "ROTATE_ROLE_VENDOR=agy: agy"
unset ROTATE_ROLE_VENDOR
expect "9. ROTATE_GROK_STANDBY=0, claude 99%" "$(ROTATE_GROK_STANDBY=0 pick disp claude:99,grok:10)" claude "dispatch seats: claude"
[[ "$(ROTATE_GROK_STANDBY=0 pick disp claude:99,grok:10)" != *grok* ]] &&
  pass "9. no switch named" || fail "9. $(ROTATE_GROK_STANDBY=0 pick disp claude:99,grok:10)"
# shellcheck disable=SC2034 # read by spl_rotate_weekly_first
spl_rotate_failover_vendor() { ROTATE_KIND=claude ROTATE_CLAUDE_CONFIG_DIR="$T/.claude-2" ROTATE_VENDOR_WHY="failover seat c-902: claude2 stays"; }
expect "10. the second login keeps claude" "$(pick disp claude:99,grok:10)" claude "failover seat c-902: claude2 stays"
unset -f spl_rotate_failover_vendor
spl_rotate_failover_vendor() { return 1; }
expect "11. orch, claude 99%, grok able" "$(pick orch claude:99,grok:10)" grok "ROTATE_ORCH_SPLIT=0: claude; but claude weekly 99% >= 90%: grok"

echo "---"
if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
