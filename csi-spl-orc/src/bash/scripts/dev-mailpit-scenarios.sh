#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every sign-in flow of local dev mode that needs no cloud identity
# provider works end to end, its mail read back from Mailpit's REST API (spec
# 148 section 5, row B9, SPL-4026). Runs against a LIVE local dev stack
# (`cd csi-spl-orc && ./run -a do_dev_mode_up`), started fresh so the dev
# login still owns workspace `main` (`do_dev_mode_down --purge` first):
#    1. dev login: the first sign-in owns `main` (scenarios 14, 2.3.2)
#    2. sign up -> the confirmation mail -> confirm -> sign in (1, 2, 3)
#    3. forgot password -> the reset mail -> reset signs in, and the session
#       from before the reset is dead (4, 5, 13)
#    4. change the password: the old cookie is dead, the new password signs
#       in, the old one does not (7)
#    5. the owner invites a colleague -> the invite mail -> the colleague
#       signs up and lands in `main` (8, 9)
#    6. the owner resets the colleague's password -> the reset mail, the
#       colleague's session is dead (6)
#    7. forgot password for the dev owner, who has no password -> the mail
#       naming the sign-in to use (15)
#    8. session read, workspace switch, sign out (10, 11, 12)
#   CONTROLS: a wrong password, a tampered cookie and a switch to a workspace
#   the caller is not in are refused.
# do_dev_mode_up turns the debug links off (SPOOL_AUTH_DEBUG_LINKS=false): no
# answer carries a token, every token here is read from a mail.
# Every address is new per run (example.com, +<run id>), so a re-run on the
# same stack walks the same flows. No stack on DEV_E2E_URL: FAIL, exit 1.
# A script, not a *.tst.sh: it needs a live stack, and the hermetic suites
# (CI wf 10 refuses any SKIP there) have none.
#   DEV_E2E_URL       the app (default http://localhost:8080)
#   DEV_E2E_MAIL_URL  Mailpit (default http://localhost:8025)
#   DEV_E2E_MAIL_WAIT_S  seconds to wait for each mail (default 20)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")/../tests" && pwd)
# shellcheck source=../tests/test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
BASE="${DEV_E2E_URL:-http://localhost:8080}"
MAIL="${DEV_E2E_MAIL_URL:-http://localhost:8025}"
WAIT_S="${DEV_E2E_MAIL_WAIT_S:-20}"
for b in curl python3; do command -v "$b" >/dev/null || { echo "FAIL: $b is required"; exit 1; }; done
if ! curl -fsS -m 5 "$BASE/healthz" >/dev/null 2>&1 || ! curl -fsS -m 5 "$MAIL/api/v1/info" >/dev/null 2>&1; then
  echo "FAIL: no local dev stack at $BASE + $MAIL (start one: cd csi-spl-orc && ./run -a do_dev_mode_up)"
  exit 1
fi
RUN="$(date +%s)$$"
U="dev-e2e-user+$RUN@example.com"
C="dev-e2e-colleague+$RUN@example.com"
OWNER=dev-owner@spool.local

# req <jar> <method> <path> [json]: CODE = the status, BODY = the answer
req() {
  local jar="$1" m="$2" p="$3" data="${4:-}" args=()
  [[ -n "$data" ]] && args=(-H 'Content-Type: application/json' --data "$data")
  CODE=$(curl -sS -m 20 -o "$T/body" -w '%{http_code}' -X "$m" -c "$jar" -b "$jar" \
    -H "Origin: $BASE" "${args[@]}" "$BASE$p")
  BODY=$(cat "$T/body")
}
# js <json> <python expression over d>: one field of a JSON answer
js() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
# check <name> <want code>: a PASS or FAIL line for the last req
check() {
  if [[ "$CODE" == "$2" ]]; then pass "$1 ($CODE)"; else fail "$1: want $2, got $CODE ${BODY:0:300}"; fi
}
# mails <to>: how many mails Mailpit holds for <to>
mails() {
  curl -fsS -m 10 -G "$MAIL/api/v1/search" --data-urlencode "query=to:\"$1\"" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("messages_count", 0))'
}
# mail_text <to> <count before>: the plain text of the newest mail to <to>,
# once there are more than <count before>; "" after WAIT_S seconds
mail_text() {
  local to="$1" before="$2" end=$((SECONDS + WAIT_S)) id
  while ((SECONDS < end)); do
    if (($(mails "$to") > before)); then
      id=$(curl -fsS -m 10 -G "$MAIL/api/v1/search" --data-urlencode "query=to:\"$to\"" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["messages"][0]["ID"])')
      curl -fsS -m 10 "$MAIL/api/v1/message/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Text"])'
      return 0
    fi
    sleep 1
  done
}
# token_in <text> <page>: the token of the <page>?token=<hex> link in a mail
token_in() { grep -oE "$2\?token=[0-9a-f]+" <<<"$1" | sed -n '1s/.*token=//p'; }

# --- 1. dev login owns main -------------------------------------------------------
req "$T/owner" POST /api/v1/auth/dev-login '{}'
check "1. dev login" 200
[[ "$(js "$BODY" 'd["t"]')" == main ]] && pass "1. dev login lands in workspace main" ||
  fail "1. dev login tenant: ${BODY:0:300} (a stack where someone else signed in first answers dev_login_not_owner: do_dev_mode_down --purge)"
req "$T/owner" GET /v1/view/me
[[ "$CODE" == 200 && "$(js "$BODY" 'd.get("tenant_owner")')" == True ]] && pass "1. the dev owner is the owner of main (/v1/view/me)" ||
  fail "1. /v1/view/me: $CODE ${BODY:0:300}"

# --- 2. sign up, confirm, sign in -------------------------------------------------
n=$(mails "$U")
req "$T/u" POST /api/v1/auth/register "{\"email\":\"$U\",\"password\":\"e2e-pass-one-1\",\"name\":\"E2E User\"}"
check "2. sign up" 202
txt=$(mail_text "$U" "$n"); tok=$(token_in "$txt" /verify-email)
[[ -n "$tok" ]] && pass "2. the confirmation mail reached Mailpit with its link" || fail "2. no confirmation mail with a /verify-email token for $U"
req "$T/u" POST /api/v1/auth/login "{\"email\":\"$U\",\"password\":\"e2e-pass-one-1\"}"
[[ "$CODE" != 200 ]] && pass "2. CONTROL: no sign-in before the email is confirmed ($CODE)" || fail "2. signed in unconfirmed"
req "$T/u" POST /api/v1/auth/email/verify "{\"token\":\"$tok\",\"password\":\"e2e-pass-one-1\"}"
check "2. confirm the email" 204
req "$T/u" POST /api/v1/auth/login "{\"email\":\"$U\",\"password\":\"wrong-pass-0\"}"
check "2. CONTROL: a wrong password is refused" 401
req "$T/u" POST /api/v1/auth/login "{\"email\":\"$U\",\"password\":\"e2e-pass-one-1\"}"
check "2. sign in with the password" 200
req "$T/u" GET /api/v1/auth/session
check "2. the session reads back" 200

# --- 3. forgot, reset, old session dead -------------------------------------------
cp "$T/u" "$T/u-before-reset"
# a reset kills the sessions issued before its cut-off SECOND (auth/revoke.go)
sleep 1
n=$(mails "$U")
req "$T/anon" POST /api/v1/auth/password/forgot "{\"email\":\"$U\"}"
check "3. forgot password" 204
txt=$(mail_text "$U" "$n"); tok=$(token_in "$txt" /reset-password)
[[ -n "$tok" ]] && pass "3. the reset mail reached Mailpit with its link" || fail "3. no reset mail with a /reset-password token for $U"
req "$T/u2" POST /api/v1/auth/password/reset "{\"token\":\"$tok\",\"password\":\"e2e-pass-two-2\"}"
check "3. reset the password (signs in)" 200
req "$T/u2" GET /api/v1/auth/session
check "3. the reset's session reads back" 200
req "$T/u-before-reset" GET /api/v1/auth/session
check "3. the session from before the reset is dead" 401

# --- 4. change the password -------------------------------------------------------
req "$T/u2" POST /api/v1/auth/password/change '{"current_password":"e2e-pass-two-2","new_password":"e2e-pass-three-3"}'
check "4. change the password" 204
req "$T/u2" GET /api/v1/auth/session
check "4. the cookie of before the change is dead" 401
req "$T/u3" POST /api/v1/auth/login "{\"email\":\"$U\",\"password\":\"e2e-pass-two-2\"}"
check "4. CONTROL: the old password is refused" 401
req "$T/u3" POST /api/v1/auth/login "{\"email\":\"$U\",\"password\":\"e2e-pass-three-3\"}"
check "4. the new password signs in" 200

# --- 5. invite, colleague lands in main -------------------------------------------
n=$(mails "$C")
req "$T/owner" POST /v1/members/invites "{\"email\":\"$C\"}"
check "5. the owner invites a colleague" 201
[[ "$(js "$BODY" 'd.get("mail")')" == sent ]] && pass "5. the hub says the invite mail was sent" || fail "5. invite mail: ${BODY:0:300}"
txt=$(mail_text "$C" "$n")
[[ -n "$txt" ]] && grep -q "$BASE" <<<"$txt" && pass "5. the invite mail reached Mailpit with a link to the app" || fail "5. no invite mail for $C: ${txt:0:300}"
n=$(mails "$C")
req "$T/c" POST /api/v1/auth/register "{\"email\":\"$C\",\"password\":\"e2e-colleague-1\",\"name\":\"E2E Colleague\"}"
check "5. the colleague signs up" 202
tok=$(token_in "$(mail_text "$C" "$n")" /verify-email)
req "$T/c" POST /api/v1/auth/email/verify "{\"token\":\"$tok\",\"password\":\"e2e-colleague-1\"}"
check "5. the colleague confirms the email" 204
req "$T/c" POST /api/v1/auth/login "{\"email\":\"$C\",\"password\":\"e2e-colleague-1\"}"
check "5. the colleague signs in" 200
[[ "$(js "$BODY" 'd["t"]')" == main ]] && pass "5. the colleague landed in workspace main" || fail "5. colleague tenant: ${BODY:0:300}"
CID=$(js "$BODY" 'd["hum"]')
[[ -n "$CID" ]] || fail "5. no human id in the colleague's session: ${BODY:0:300}"

# --- 6. admin resets the colleague's password -------------------------------------
n=$(mails "$C")
sleep 1
req "$T/owner" POST "/v1/members/$CID/password-reset" '{}'
[[ "$CODE" == 2?? ]] && pass "6. the owner resets the colleague's password ($CODE)" || fail "6. admin reset: $CODE ${BODY:0:300}"
tok=$(token_in "$(mail_text "$C" "$n")" /reset-password)
[[ -n "$tok" ]] && pass "6. the colleague's reset mail reached Mailpit" || fail "6. no reset mail for $C"
req "$T/c" GET /api/v1/auth/session
check "6. the colleague's session is dead" 401
req "$T/c" POST /api/v1/auth/login "{\"email\":\"$C\",\"password\":\"e2e-colleague-1\"}"
check "6. the colleague's old password is dead" 401

# --- 7. forgot password for an account with no password ---------------------------
n=$(mails "$OWNER")
req "$T/anon" POST /api/v1/auth/password/forgot "{\"email\":\"$OWNER\"}"
check "7. forgot password for the dev owner" 204
txt=$(mail_text "$OWNER" "$n")
if [[ -z "$txt" && $n -gt 0 ]]; then
  # the hub mails one notice per address per rate window (15 min,
  # forgotFederated): a re-run inside it gets none, the earlier one counts
  age=$(curl -fsS -m 10 -G "$MAIL/api/v1/search" --data-urlencode "query=to:\"$OWNER\"" | python3 -c '
import datetime, json, sys
c = json.load(sys.stdin)["messages"][0]["Created"]
print(int((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(c.replace("Z", "+00:00"))).total_seconds()))')
  [[ -n "$age" && $age -lt 900 ]] && pass "7. no new notice: the hub's one-per-15-min floor holds; the last one is ${age}s old" ||
    fail "7. no sign-in notice for $OWNER within 15 min (last ${age:-?}s ago)"
else
  [[ -n "$txt" && -z "$(token_in "$txt" /reset-password)" ]] && pass "7. the sign-in notice reached Mailpit, with no reset link" ||
    fail "7. no sign-in notice for $OWNER (or it carried a reset link): ${txt:0:300}"
fi

# --- 8. session, switch, sign out -------------------------------------------------
req "$T/owner" GET /api/v1/auth/session
check "8. the owner's session reads back" 200
req "$T/owner" POST /api/v1/auth/tenant '{"tenant":"main"}'
check "8. switch to workspace main" 200
req "$T/owner" POST /api/v1/auth/tenant '{"tenant":"no-such-workspace"}'
[[ "$CODE" == 4?? ]] && pass "8. CONTROL: a switch to a workspace the caller is not in is refused ($CODE)" || fail "8. foreign switch: $CODE"
sed -E $'s/\t([^\t]*)$/\tX\\1/' "$T/owner" >"$T/tampered"
req "$T/tampered" GET /api/v1/auth/session
check "8. CONTROL: a tampered cookie is refused" 401
req "$T/owner" POST /api/v1/auth/logout
check "8. sign out" 204
req "$T/owner" GET /api/v1/auth/session
check "8. sign out cleared the session cookie" 401

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
