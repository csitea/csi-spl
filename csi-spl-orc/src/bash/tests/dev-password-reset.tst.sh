#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dev_password_reset over a scratch dir and a fake reset
#          script. No hub.
#   1. prd is refused; bad input is refused
#   2. dry run: says what it would do, the file unchanged
#   3. a file the first probe seat still owns (probe-invited beside it) is
#      refused, the file unchanged
#   4. DRY_RUN=0: the reset script gets the email, tenant, hub and file; OK
#   5. a failed reset is FAIL (exit 1) and leaves the file as it was
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
D="$T/m3-e2e/t1"; mkdir -p "$D"; F="$D/pw-human"
echo replaced >"$F"

cat >"$T/reset.sh" <<'EOF'
#!/usr/bin/env bash
echo "$RESET_EMAIL $RESET_TENANT $RESET_API $RESET_PW_FILE" >>"$RESET_LOG"
[ -e "$RESET_FAIL" ] && { echo '{"step": "reset", "status": 401}'; exit 1; }
echo new-secret >"$RESET_PW_FILE"
echo '{"step": "login", "status": 200}'
EOF
chmod +x "$T/reset.sh"

reset() {
  env PROJ_PATH="$PROJ_ROOT" RESET_CMD="$T/reset.sh" RESET_LOG="$T/log" RESET_FAIL="$T/fail" \
    ENV=dev TENANT_ID=t1 RESET_EMAIL=m3-e2e-human@example.com RESET_PW_FILE="$F" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_spl_cloud_cnf() { return 0; }
    spl_cnf_api_fqdn() { printf -v "$1" %s hub.example.com; }
    source "$PROJ_PATH/src/bash/run/spl-dev-password-reset.func.sh"
    do_spl_dev_password_reset'
}

reset ENV=prd DRY_RUN=0 >/dev/null 2>&1 && fail "1. prd accepted" || pass "1. prd is refused"
reset RESET_EMAIL='x;y' >/dev/null 2>&1 && fail "1. a bad email accepted" || pass "1. RESET_EMAIL must be an email"
reset RESET_PW_FILE=pw-human >/dev/null 2>&1 && fail "1. a relative file accepted" || pass "1. RESET_PW_FILE must be absolute"

reset >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$F")" == replaced && ! -e "$T/log" ]] && grep -q "would: reset the password of m3-e2e-human@example.com" "$T/o" &&
  pass "2. dry run: the plan, the file unchanged" || fail "2. dry: rc=$rc $(cat "$T/o")"

touch "$D/probe-invited"
reset DRY_RUN=0 >"$T/o" 2>&1 && fail "3. an unmigrated probe dir accepted" ||
  { [[ "$(cat "$F")" == replaced && ! -e "$T/log" ]] && grep -q 'do_spl_probe_member_seat first' "$T/o" &&
    pass "3. a dir the first probe seat still owns is refused" || fail "3. marker: $(cat "$T/o")"; }
rm -f "$D/probe-invited"

reset DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$F")" == new-secret ]] && grep -qxF "m3-e2e-human@example.com t1 https://hub.example.com $F" "$T/log" &&
  grep -q '^OK m3-e2e-human@example.com has a new password' "$T/o" &&
  pass "4. reset, signed in, kept in the file" || fail "4. reset: rc=$rc $(cat "$T/o")"

echo kept >"$F"; touch "$T/fail"
reset DRY_RUN=0 >"$T/o" 2>&1 && fail "5. a failed reset passed" ||
  { [[ "$(cat "$F")" == kept ]] && grep -q '^FAIL m3-e2e-human@example.com was not reset' "$T/o" &&
    pass "5. a failed reset is FAIL, the file as it was" || fail "5. fail: $(cat "$T/o")"; }

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
