#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_probe_member_seat over a scratch state dir, a fake invite and
#          a fake sign-in script. No hub, no proxy, no spool binary.
#   1. an env but dev / prd, and a prd workspace that is not a test one
#      (t1), are refused before anything happens
#   2. dry run: says what it would do, writes nothing, invites nobody
#   3. RED CONTROL (2026-10-11): the dev e2e member's m3-e2e/t1/pw-human (no
#      human-email beside it, as do_spl_m3_e2e leaves it on dev) is kept byte
#      for byte; the probe login goes to m3-e2e/t1/probe/ (dirs 0700), where
#      do_spl_workspace_delivery_probe reads it first; one invite
#   4. a re-run does not invite again
#   5. a probe dir seated for another email is refused
#   6. a failed sign-in is FAIL (exit 1)
#   7. the default address is the desk box id (SPOOL_DESK_BOX), never the
#      host name
#   8. a login the first version left in m3-e2e/<ws>/ (its probe-invited
#      marker) is moved into probe/, no second invite, the member kept
#   9. prd e2e-2 (owner HUM-10, t1 msg bc92a373): the relay mailbox's
#      plus-address, the PROBE_MEMBER_ROLE invite, the verify mail over IMAP
#      with the relay password in a 0600 file that is gone after the run
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ST="$T/state"; WS="$ST/m3-e2e/t1"; P="$WS/probe"
mkdir -p "$WS"

# the fake sign-in: writes pw-human like native_login; fails while $T/seatfail exists
cat >"$T/seat.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$SEAT_FAIL" ] && { echo '{"status": 403, "human_id": "", "error": "not_allowed"}'; exit 1; }
echo "$M3_TENANT $M3_HUMAN_EMAIL $M3_AUTH_URL $M3_STATE ${M3_IMAP_USER:-} ${M3_IMAP_HOST:-} $([ -s "${M3_IMAP_PASS_FILE:-/x}" ] && stat -c %a "$M3_IMAP_PASS_FILE")" >>"$SEAT_LOG"
( umask 077; echo "probe-secret" >"$M3_STATE/pw-human" )
echo '{"status": 200, "human_id": "HUM-42"}'
EOF
chmod +x "$T/seat.sh"

seat() {
  env PROJ_PATH="$PROJ_ROOT" SPL_STATE_DIR="$ST" PROBE_SEAT_CMD="$T/seat.sh" SEAT_LOG="$T/seats" \
    SEAT_FAIL="$T/seatfail" INVITE_LOG="$T/invites" SPOOL_DESK_BOX=sat SPOOL_TEST=1 SPL_CNF="$T/cnf.yaml" ENV=dev TENANT_ID=t1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_spl_cloud_cnf() { return 0; }
    spl_host_spool() { return 0; }
    spl_cnf_api_fqdn() { printf -v "$1" %s hub.example.com; }
    spl_m3_invite() { echo "$1 $2 $3" >>"$INVITE_LOG"; }
    spl_m3_imap_pass() { ( umask 077; echo relay-secret >"$1" ); }
    spl_m3_imap_forget() { [[ -n "${M3_IMAP_PASS_FILE:-}" ]] && rm -f "$M3_IMAP_PASS_FILE"; return 0; }
    source "$PROJ_PATH/src/bash/run/spl-probe-member-seat.func.sh"
    do_spl_probe_member_seat'
}
n() { [[ -f "$1" ]] && wc -l <"$1" || echo 0; }
printf 'env:\n  mail:\n    env:\n      SPOOL_HUB_MAIL_SMTP_HOST: smtp.example.com\n      SPOOL_HUB_MAIL_SMTP_USER: relay@example.com\n' >"$T/cnf.yaml"

# the dev e2e member's stored password, as do_spl_m3_e2e leaves it on dev
( umask 077; echo "e2e-member-secret" >"$WS/pw-human" )
e2e_sum="$(md5sum <"$WS/pw-human")"

seat ENV=prd DRY_RUN=0 >"$T/o" 2>&1 && fail "1. prd t1 accepted" ||
  { [[ ! -e "$P" && "$(n "$T/invites")" == 0 ]] && grep -q 'only in a test workspace' "$T/o" && pass "1. prd t1 (a real workspace) is refused, nothing touched" || fail "1. prd: $(cat "$T/o")"; }
seat ENV=stg DRY_RUN=0 >"$T/o" 2>&1 && fail "1. ENV=stg accepted" || pass "1. an env but dev / prd is refused"
seat PROBE_MEMBER_ROLE='x;y' >/dev/null 2>&1 && fail "1. a bad role accepted" || pass "1. PROBE_MEMBER_ROLE must be a role id"
seat TENANT_ID='T1;x' >/dev/null 2>&1 && fail "1. a bad slug accepted" || pass "1. TENANT_ID must be a slug"

seat >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$P" && "$(n "$T/invites")" == 0 ]] && grep -q "invite delivery-probe-sat@example.com to t1 as member.*$P/human-email" "$T/o" &&
  pass "2. dry run: the plan names probe/, nothing written or invited" || fail "2. dry: rc=$rc $(cat "$T/o")"

# --- 3. RED CONTROL: the e2e member's login is never touched -----------------
seat DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$WS/pw-human")" == "$e2e_sum" && ! -e "$WS/human-email" ]] &&
  pass "3. the e2e member's m3-e2e/t1/pw-human is kept byte for byte" || fail "3. e2e login replaced: rc=$rc $(cat "$WS/pw-human" "$WS/human-email" 2>&1)"
[[ $rc -eq 0 && "$(cat "$T/invites")" == "t1 delivery-probe-sat@example.com member" ]] &&
  [[ "$(cat "$P/human-email" 2>/dev/null)" == delivery-probe-sat@example.com && "$(cat "$P/pw-human" 2>/dev/null)" == probe-secret ]] &&
  [[ "$(stat -c %a "$P")" == 700 && "$(stat -c %a "$WS")" == 700 ]] && grep -q '"human_id": "HUM-42"' "$T/o" &&
  grep -q "^t1 delivery-probe-sat@example.com https://hub.example.com $P *$" "$T/seats" &&
  pass "3. invited once, signed in, the probe login is in probe/" || fail "3. seat: rc=$rc $(cat "$T/o")"

seat DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(n "$T/invites")" == 1 && "$(n "$T/seats")" == 2 ]] && pass "4. a re-run does not invite again" || fail "4. rerun: invites=$(n "$T/invites")"

seat DRY_RUN=0 PROBE_MEMBER_EMAIL=other@example.com >"$T/o" 2>&1 && fail "5. another email accepted" ||
  { grep -q 'names another member' "$T/o" && pass "5. a probe dir seated for another email is refused" || fail "5. other: $(cat "$T/o")"; }

touch "$T/seatfail"
seat DRY_RUN=0 >"$T/o" 2>&1 && fail "6. a failed sign-in passed" ||
  { grep -q '^FAIL delivery-probe-sat@example.com could not sign in' "$T/o" && pass "6. a failed sign-in is FAIL" || fail "6. fail: $(cat "$T/o")"; }
rm -f "$T/seatfail"

# --- 7. the default address is the desk box id ------------------------------
rm -rf "$P"
seat SPOOL_DESK_BOX=tnkx >"$T/o" 2>&1
grep -q 'invite delivery-probe-tnkx@example.com' "$T/o" && pass "7. the default address is the desk box id" || fail "7. box: $(cat "$T/o")"

# --- 8. the first version's login in the ws dir is moved into probe/ --------
rm -rf "$P" "$T/invites"
echo delivery-probe-box@example.com >"$WS/human-email"
( umask 077; echo "old-probe-secret" >"$WS/pw-human" ); touch "$WS/probe-invited"
seat DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$WS/human-email" && ! -e "$WS/pw-human" && ! -e "$WS/probe-invited" ]] &&
  [[ "$(cat "$P/human-email")" == delivery-probe-box@example.com && -e "$P/probe-invited" && "$(n "$T/invites")" == 0 ]] &&
  grep -q 'moved the probe login out of' "$T/o" &&
  pass "8. the first version's login is moved into probe/, same member, no new invite" || fail "8. migrate: rc=$rc $(cat "$T/o"; ls -a "$WS" "$P")"

# --- 9. prd e2e-2: relay plus-address, the role, IMAP ------------------------
rm -f "$T/invites" "$T/seats"
P2="$ST/m3-e2e/e2e-2/probe"
seat ENV=prd TENANT_ID=e2e-2 PROBE_MEMBER_ROLE=biz_owner >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$P2" && "$(n "$T/invites")" == 0 ]] &&
  grep -q 'invite relay+spl-probe-e2e-2@example.com to e2e-2 as biz_owner, then register + verify (the mail over IMAP)' "$T/o" &&
  pass "9. prd dry run: the relay plus-address, biz_owner, IMAP; nothing written" || fail "9. prd dry: rc=$rc $(cat "$T/o")"
seat ENV=prd TENANT_ID=e2e-2 PROBE_MEMBER_ROLE=biz_owner DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$T/invites")" == "e2e-2 relay+spl-probe-e2e-2@example.com biz_owner" ]] &&
  grep -qx "e2e-2 relay+spl-probe-e2e-2@example.com https://hub.example.com $P2 relay@example.com imap.example.com 600" "$T/seats" &&
  [[ ! -e "$P2/imap-pass" && "$(cat "$P2/pw-human")" == probe-secret && "$(stat -c %a "$P2")" == 700 ]] &&
  pass "9. prd: invited as biz_owner, verified over IMAP (0600 relay password), the password file gone after" ||
  fail "9. prd seat: rc=$rc $(cat "$T/o" "$T/seats" 2>&1; ls -a "$P2")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
