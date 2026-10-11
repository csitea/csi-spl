#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_probe_member_seat over a scratch state dir, a fake invite and
#          a fake sign-in script. No hub, no proxy, no spool binary.
#   1. prd (and any env but dev) is refused before anything happens
#   2. dry run: says what it would do, writes nothing, invites nobody
#   3. DRY_RUN=0: one invite, then the sign-in; human-email + pw-human written
#      where do_spl_workspace_delivery_probe reads them, dir 0700
#   4. a re-run does not invite again
#   5. a state dir seated for another email is refused
#   6. a failed sign-in is FAIL (exit 1)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ST="$T/state"; mkdir -p "$ST"

# the fake sign-in: writes pw-human like native_login; fails while $T/seatfail exists
cat >"$T/seat.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$SEAT_FAIL" ] && { echo '{"status": 403, "human_id": "", "error": "not_allowed"}'; exit 1; }
echo "$M3_TENANT $M3_HUMAN_EMAIL $M3_AUTH_URL" >>"$SEAT_LOG"
( umask 077; echo secret >"$M3_STATE/pw-human" )
echo '{"status": 200, "human_id": "HUM-42"}'
EOF
chmod +x "$T/seat.sh"

seat() {
  env PROJ_PATH="$PROJ_ROOT" SPL_STATE_DIR="$ST" PROBE_SEAT_CMD="$T/seat.sh" SEAT_LOG="$T/seats" \
    SEAT_FAIL="$T/seatfail" INVITE_LOG="$T/invites" PROBE_BOX=sat ENV=dev TENANT_ID=t1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_spl_cloud_cnf() { return 0; }
    spl_host_spool() { return 0; }
    spl_cnf_api_fqdn() { printf -v "$1" %s hub.example.com; }
    spl_m3_invite() { echo "$1 $2 $3" >>"$INVITE_LOG"; }
    source "$PROJ_PATH/src/bash/run/spl-probe-member-seat.func.sh"
    do_spl_probe_member_seat'
}
n() { [[ -f "$1" ]] && wc -l <"$1" || echo 0; }

seat ENV=prd DRY_RUN=0 >"$T/o" 2>&1 && fail "1. prd accepted" ||
  { [[ ! -e "$ST/m3-e2e" && "$(n "$T/invites")" == 0 ]] && pass "1. prd is refused, nothing touched" || fail "1. prd: $(cat "$T/o")"; }
seat TENANT_ID='T1;x' >/dev/null 2>&1 && fail "1. a bad slug accepted" || pass "1. TENANT_ID must be a slug"

seat >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$ST/m3-e2e" && "$(n "$T/invites")" == 0 ]] && grep -q 'invite delivery-probe-sat@example.com to t1 as member' "$T/o" &&
  pass "2. dry run: the plan, nothing written or invited" || fail "2. dry: rc=$rc $(cat "$T/o")"

seat DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$T/invites")" == "t1 delivery-probe-sat@example.com member" ]] &&
  [[ "$(cat "$ST/m3-e2e/t1/human-email")" == delivery-probe-sat@example.com && -s "$ST/m3-e2e/t1/pw-human" ]] &&
  [[ "$(stat -c %a "$ST/m3-e2e/t1")" == 700 ]] && grep -q '"human_id": "HUM-42"' "$T/o" &&
  grep -q '^t1 delivery-probe-sat@example.com https://hub.example.com$' "$T/seats" &&
  pass "3. invited once, signed in, the login is where the probe reads it" || fail "3. seat: rc=$rc $(cat "$T/o")"

seat DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(n "$T/invites")" == 1 && "$(n "$T/seats")" == 2 ]] && pass "4. a re-run does not invite again" || fail "4. rerun: invites=$(n "$T/invites")"

seat DRY_RUN=0 PROBE_MEMBER_EMAIL=other@example.com >"$T/o" 2>&1 && fail "5. another email accepted" ||
  { grep -q 'names another member' "$T/o" && pass "5. a dir seated for another email is refused" || fail "5. other: $(cat "$T/o")"; }

touch "$T/seatfail"
seat DRY_RUN=0 >"$T/o" 2>&1 && fail "6. a failed sign-in passed" ||
  { grep -q '^FAIL delivery-probe-sat@example.com could not sign in' "$T/o" && pass "6. a failed sign-in is FAIL" || fail "6. fail: $(cat "$T/o")"; }

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
