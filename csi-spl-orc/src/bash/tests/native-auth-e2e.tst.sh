#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_native_auth_e2e + native-auth-e2e.py, offline (SPL-6182).
#   1. refused before any secret read: another env, an address outside the
#      relay mailbox (or the bare mailbox)
#   2. the action: the env reaches the script (auth URL, IMAP mailbox, host,
#      password file, a default fresh plus-address), the relay password file
#      is gone after the run, a failed flow is FAIL
#   2b. NAE_MODE=wui runs the WUI proof with the hosts, address and mail command
#   3. the flow (hub + mailbox faked in-process): 11 steps PASS, exit 0, the
#      reset mail is read with the /reset-password link; no token, password
#      or address on stdout. CONTROLS: a hub that signs in a wrong password,
#      and a reset mail that never comes, each exit 1 with that step FAIL
#   4. m3-e2e.py's reader picks the link kind it is asked for
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-native-auth-e2e.func.sh"
PY="$PROJ_ROOT/src/bash/scripts/native-auth-e2e.py"
M3="$PROJ_ROOT/src/bash/scripts/m3-e2e.py"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'env:\n  mail:\n    env:\n      SPOOL_HUB_MAIL_SMTP_USER: Relay@example.net\n      SPOOL_HUB_MAIL_SMTP_HOST: smtp.example.net\n' >"$T/cnf.yaml"
cat >"$T/fake.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$NAE_AUTH_URL $M3_IMAP_USER $M3_IMAP_HOST $(cat "$M3_IMAP_PASS_FILE") $NAE_EMAIL" >"$FAKE_LOG"
echo "$M3_IMAP_PASS_FILE" >"$FAKE_LOG.pass"
[[ -e "$FAKE_FAIL" ]] && { echo 'FAIL native auth e2e: 3/11 steps PASS'; exit 1; }
echo 'PASS native auth e2e: 11/11 steps PASS'
FAKE
chmod +x "$T/fake.sh"

act() {
  env ENV=dev NAE_CMD_PY="$T/fake.sh" SPL_STATE_DIR="$T/state" FAKE_LOG="$T/log" FAKE_FAIL="$T/fail" "$@" bash -c "
    do_log() { echo \"\$*\"; }; do_require_bin() { :; }
    source '$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh'
    do_spl_cloud_cnf() { SPL_CNF='$T/cnf.yaml'; SPL_ORG_APP=org-app; }
    spl_cnf_api_fqdn() { printf -v \"\$1\" %s api.example.net; }
    spl_m3_imap_pass() { echo SECRET-READ; ( umask 077; echo app-pw >\"\$1\" ); }
    source '$FN'; do_spl_native_auth_e2e" 2>&1
}

out="$(act ENV=lde)"; [[ $? -ne 0 ]] && grep -q 'ENV must be dev or prd' <<<"$out" && pass "1. another env is refused" || fail "1. env: $out"
for a in someone+x@example.com relay@example.net relay+@example.net; do
  out="$(act NAE_EMAIL="$a")"
  [[ $? -ne 0 ]] && grep -q 'is no plus-address of the relay mailbox' <<<"$out" && ! grep -q SECRET-READ <<<"$out" &&
    pass "1. $a refused before any secret read" || fail "1. $a: $out"
done

out="$(act NAE_EMAIL=relay+t1@example.net)"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'https://api.example.net relay@example.net imap.example.net app-pw relay+t1@example.net' "$T/log" &&
  grep -q '^OK native auth e2e on dev' <<<"$out" &&
  pass "2. the env reaches the script (auth URL, mailbox, IMAP host, password file, address)" || fail "2. env: rc=$rc $out $(cat "$T/log" 2>&1)"
[[ ! -e "$(cat "$T/log.pass")" ]] && pass "2. the relay password file is removed after the run" || fail "2. password file left"
grep -q app-pw <<<"$out" && fail "2. the relay password printed" || pass "2. the relay password is in no output"
out="$(act)"; [[ $? -eq 0 ]] && grep -Eq ' relay\+native-e2e-[0-9]{8}t[0-9]{6}@example\.net$' "$T/log" &&
  pass "2. the default address is a fresh plus-address of the relay mailbox" || fail "2. default address: $(cat "$T/log")"
touch "$T/fail"; out="$(act)"; rc=$?
[[ $rc -ne 0 ]] && grep -q '^FAIL native auth e2e on dev' <<<"$out" && [[ ! -e "$(cat "$T/log.pass")" ]] &&
  pass "2. a failed flow is FAIL, the password file still removed" || fail "2. fail: rc=$rc $out"

# 2b. NAE_MODE=wui: the WUI proof gets the WUI + API hosts, the address, the
# state dir, the cred file and a MAIL_TOKEN_CMD; no relay password is read here
cat >"$T/node.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$PWD|$BASE|$API|$EMAIL|$OUT|$CRED_FILE|$MAIL_TOKEN_CMD" >"$FAKE_LOG.wui"
echo "$SEAT_CMD" >"$FAKE_LOG.seat"
[[ -e "$FAKE_FAIL" ]] && exit 1 || exit 0
FAKE
chmod +x "$T/node.sh"; rm -f "$T/fail"; mkdir -p "$T/app/org-app-wui"
printf 'env:\n  dns:\n    fqdn: wui.example.net\n  mail:\n    env:\n      SPOOL_HUB_MAIL_SMTP_USER: relay@example.net\n      SPOOL_HUB_MAIL_SMTP_HOST: smtp.example.net\n' >"$T/cnf.yaml"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_EMAIL=relay+w1@example.net NAE_CRED_FILE=/x/cred)"; rc=$?
IFS='|' read -r w_pwd w_base w_api w_email w_out w_cred w_cmd <"$T/log.wui"
[[ $rc -eq 0 && "$w_pwd" == "$T/app/org-app-wui" && "$w_base" == https://wui.example.net && "$w_api" == https://api.example.net &&
  "$w_email" == relay+w1@example.net && "$w_out" == "$T/state/"* && "$w_cred" == /x/cred &&
  "$w_cmd" == "cd $T/app/org-app-orc && ENV=dev ./run -a do_spl_mail_verify_token" ]] && ! grep -q SECRET-READ <<<"$out" &&
  pass "2b. NAE_MODE=wui: the proof gets both hosts, address, state dir, cred file and the mail command; no password read" || fail "2b. wui: rc=$rc $out $(cat "$T/log.wui")"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_CRED_FILE=cred)"
[[ $? -ne 0 ]] && grep -q 'NAE_CRED_FILE must be an absolute path' <<<"$out" && pass "2b. a relative cred file is refused" || fail "2b. cred: $out"
touch "$T/fail"; out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh")"
[[ $? -ne 0 ]] && grep -q '^FAIL native auth WUI proof on dev' <<<"$out" && pass "2b. a failed WUI proof is FAIL" || fail "2b. wui fail: $out"
rm -f "$T/fail"
[[ -z "$(cat "$T/log.seat")" ]] && pass "2b. no NAE_SEAT_TENANT: no seat command" || fail "2b. seat without tenant: $(cat "$T/log.seat")"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_SEAT_TENANT=t1)"
[[ $? -ne 0 ]] && grep -q 'needs NAE_ORDERED_BY=HUM-<n>' <<<"$out" && pass "2b. a seat with no ORDERED_BY is refused" || fail "2b. ordered_by: $out"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_SEAT_TENANT='T 1' NAE_ORDERED_BY=HUM-10)"
[[ $? -ne 0 ]] && grep -q 'must be a tenant slug' <<<"$out" && pass "2b. a seat tenant that is no slug is refused" || fail "2b. slug: $out"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_SEAT_TENANT=t1 NAE_ORDERED_BY=HUM-10 NAE_ORDERED_VIA=c-806)"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "cd $T/app/org-app-orc && ENV=dev TENANT_ID=t1 EMAIL=\"\$SEAT_EMAIL\" DISPLAY_NAME='Native E2E' MEMBER_ROLE=${NAE_SEAT_ROLE:-regular_user} CREATE_HUMAN=1 ORDERED_BY=HUM-10 ORDERED_VIA='c-806' DRY_RUN=0 ./run -a do_spl_tenant_member_add" "$T/log.seat" &&
  pass "2b. NAE_SEAT_TENANT: the proof gets the member-add seat (CREATE_HUMAN=1, no password)" || fail "2b. seat cmd: rc=$rc $(cat "$T/log.seat")"
IFS='|' read -r w_pwd w_base _ <"$T/log.wui"
[[ "$w_base" == https://wui.example.net ]] && pass "2b. a t1 seat runs on the apex host" || fail "2b. t1 host: $w_base"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_SEAT_TENANT=e2e NAE_ORDERED_BY=HUM-10)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "'e2e' has no tenant host" <<<"$out" && pass "2b. a seat tenant with no mapped host is refused" || fail "2b. unmapped: rc=$rc $out"
printf '    mapped_tenants: [demo, e2e]\n' | sed -i '/^    fqdn:/r /dev/stdin' "$T/cnf.yaml"
out="$(act APP_PATH="$T/app" NAE_MODE=wui NAE_CMD_NODE="$T/node.sh" NAE_SEAT_TENANT=e2e NAE_ORDERED_BY=HUM-10)"; rc=$?
IFS='|' read -r w_pwd w_base _ <"$T/log.wui"
[[ $rc -eq 0 && "$w_base" == https://e2e.wui.example.net ]] && grep -q 'TENANT_ID=e2e .*MEMBER_ROLE=regular_user ' "$T/log.seat" &&
  pass "2b. an e2e seat runs on e2e.<fqdn> as regular_user" || fail "2b. e2e host: rc=$rc $w_base $(cat "$T/log.seat")"

# 3. the flow against a fake hub and mailbox: FAKE_MODE ok | wrongpw | noreset
run_py() {
  mkdir -p "$T/st"
  NAE_AUTH_URL=https://api.example.net NAE_EMAIL=relay+t1@example.net NAE_STATE="$T/st" NAE_FLOOR_S=0 \
    M3_IMAP_USER=relay@example.net FAKE_MODE="$1" python3 -B - "$PY" <<'PYI' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("nae", sys.argv[1]); nae = importlib.util.module_from_spec(spec); spec.loader.exec_module(nae)
mode = os.environ["FAKE_MODE"]
TOK = {"verify": "a" * 64, "reset": "b" * 64}
state = {"pw": None, "verified": False}
class H(dict):
    def get_all(self, k): return self.get(k)
def http(method, url, body=None, headers=None):
    path = url.split("/api/v1/auth/")[-1] if "/api/v1/auth/" in url else url
    ck = H({"Set-Cookie": ["spool_session=s; Path=/"]})
    if url.endswith("/version"): return 200, H(), {"version": "1.2.3", "sha": "abc"}
    if path == "register": state["pw"] = body["password"]; return 202, H(), {"status": "verification_required"}
    if path == "email/verify":
        ok = body["token"] == TOK["verify"] and body["password"] == state["pw"]
        state["verified"] = ok
        return (200, ck, {}) if ok else (401, H(), {"error": "x"})
    if path == "login":
        if body["password"] == state["pw"] or mode == "wrongpw": return 200, ck, {}
        return 401, H(), {"error": "invalid_credentials"}
    if path == "password/forgot": return 204, H(), None
    if path == "password/reset":
        if body["token"] != TOK["reset"]: return 401, H(), {}
        state["pw"] = body["password"]; return 200, ck, {}
    return 404, H(), None
def imap(rcpt, seen, link):
    kind = "reset" if link is nae.m3.RESET_LINK else "verify"
    if kind == "reset" and mode == "noreset": return "", {"mail": "no reset mail to %s within 1s" % rcpt}
    return TOK[kind], {"mail_message_id": "<%s@mail>" % kind, "link_page": "https://wui/x", "link_page_status": 200}
nae.m3.http, nae.m3.imap_verify_token = http, imap
sys.exit(nae.main())
PYI
}
out="$(run_py ok)"; rc=$?
[[ $rc -eq 0 ]] && [[ $(grep -c '^PASS [0-9]' <<<"$out") -eq 11 ]] && grep -q '^PASS native auth e2e: 11/11' <<<"$out" &&
  pass "3. the whole flow: 11 steps PASS, exit 0" || fail "3. flow: rc=$rc $out"
grep -q '^PASS 7 reset mail .*<reset@mail>' <<<"$out" && pass "3. the reset mail is read with the /reset-password link" || fail "3. reset link: $out"
grep -q '"version": {' <<<"$out" && pass "3. the served /version is in the evidence" || fail "3. version: $out"
grep -Eq 'a{64}|b{64}|relay\+t1|spool_session=|https://wui' <<<"$out" && fail "3. a secret, the address or the link printed" || pass "3. no token, cookie, link or address on stdout"
[[ -s "$T/st/results.json" ]] && pass "3. results.json written" || fail "3. no results.json"
out="$(run_py wrongpw)"; rc=$?
[[ $rc -eq 1 ]] && grep -q '^FAIL 5 wrong password (CONTROL)' <<<"$out" && grep -q '^FAIL 9 old password (CONTROL)' <<<"$out" &&
  pass "3. CONTROL: a hub that signs in a wrong password fails steps 5 and 9, exit 1" || fail "3. wrongpw: rc=$rc $out"
out="$(run_py noreset)"; rc=$?
[[ $rc -eq 1 ]] && grep -q '^FAIL 7 reset mail' <<<"$out" && ! grep -q '^PASS 8' <<<"$out" &&
  pass "3. CONTROL: no reset mail -> step 7 FAIL, the flow stops, exit 1" || fail "3. noreset: rc=$rc $out"

out="$(python3 -B - "$M3" <<'PYI' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m3", sys.argv[1]); m3 = importlib.util.module_from_spec(spec); spec.loader.exec_module(m3)
v = "https://app.example.net/fi/verify-email?token=" + "c" * 64
r = "https://app.example.net/reset-password?token=" + "d" * 64
assert m3.VERIFY_LINK.search(v) and not m3.VERIFY_LINK.search(r)
assert m3.RESET_LINK.search(r).group(2) == "d" * 64 and not m3.RESET_LINK.search(v)
print("ok")
PYI
)"
[[ "$out" == ok ]] && pass "4. VERIFY_LINK and RESET_LINK each match only their own page" || fail "4. link regex: $out"

[[ $fails -eq 0 ]] && echo "ALL native-auth-e2e assertions PASS" || { echo "$fails FAIL"; exit 1; }
