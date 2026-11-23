#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_invite_native_e2e + invite-e2e.py link, offline (SPL-6286).
#   1. refused before any cnf read, secret or call: t1 on any env, a prd
#      tenant that is no test workspace, no INE_ORDERED_BY / INE_ORDER_MSG,
#      an address outside the relay mailbox
#   2. the run (hub, proof and Postgres read faked): the invite body carries
#      the role, ordered_by and the order msg; the proof gets the API, the
#      address, the tenant, the state dir, the invite answer, the link and
#      mail commands; invite.json keeps no address; the relay password file
#      is gone; no full address in the output; step 9 PASS -> OK
#   3. CONTROLS, each FAIL: the invite's accepted_at not set, the member in
#      another role, the member row of another human than the session, the
#      proof failing, the hub refusing the invite (the proof never runs)
#   4. invite-e2e.py link: the invite mail's link facts as one JSON line
#      (stub mailbox); no mail in time -> exit 1
#   5. the WUI proof parses (node --check)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-invite-native-e2e.func.sh"
PY="$PROJ_ROOT/src/bash/scripts/invite-e2e.py"
PROOF="$PROJ_ROOT/../csi-spl-wui/tests/e2e/invite-native-live.proof.mjs"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'env:\n  mail:\n    env:\n      SPOOL_HUB_MAIL_SMTP_USER: Relay@example.net\n      SPOOL_HUB_MAIL_SMTP_HOST: smtp.example.net\n' >"$T/cnf.yaml"
mkdir -p "$T/app/org-app-wui"
INV_RE='relay\+invnat-[0-9]{8}t[0-9]{6}@example\.net'

# the proof stand-in: logs what it got, writes bound.json as the real one
cat >"$T/node.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$PWD|$API|$EMAIL|$TENANT|$OUT|$INVITE_JSON|$INVITE_LINK_CMD|$MAIL_TOKEN_CMD" >"$FAKE_LOG.node"
cp "$INVITE_JSON" "$FAKE_LOG.invite"
echo '{"session_hum": "HUM-77", "session_tenant": "e2e"}' >"$OUT/bound.json"
echo '{"steps": [{"step": "0 version", "ok": true}]}' >"$OUT/results.json"
[[ -e "$FAKE_FAIL" ]] && exit 1 || exit 0
FAKE
# the Postgres read stand-in: FAKE_ROWS = ok | pending | role | human
cat >"$T/members.sh" <<'FAKE'
#!/usr/bin/env bash
acc='"2026-11-23T09:00:00Z"'; role=regular_user; hum=HUM-77
case "$FAKE_ROWS" in pending) acc=null ;; role) role=developer ;; human) hum=HUM-88 ;; esac
e="${MATCH}@example.net"
echo "{\"type\" : \"member\", \"tenant_id\" : \"$TENANT_ID\", \"human_id\" : \"$hum\", \"email\" : \"$e\", \"role\" : \"$role\", \"admitted_by\" : \"invite\", \"identities\" : [{\"provider\" : \"password\"}]}"
echo "{\"type\" : \"invite\", \"tenant_id\" : \"$TENANT_ID\", \"email\" : \"$e\", \"role\" : \"regular_user\", \"accepted_at\" : $acc, \"accepted_by\" : \"HUM-77\"}"
FAKE
chmod +x "$T/node.sh" "$T/members.sh"

act() {
  rm -f "$T/log"*
  env ENV=dev TENANT_ID=e2e INE_ORDERED_BY=HUM-10 INE_ORDER_MSG=01649437 APP_PATH="$T/app" SPL_STATE_DIR="$T/state" \
    INE_CMD_NODE="$T/node.sh" INE_CMD_MEMBERS="$T/members.sh" FAKE_LOG="$T/log" FAKE_FAIL="$T/fail" FAKE_ROWS=ok FAKE_OP=201 "$@" bash -c "
    do_log() { echo \"\$*\"; }; do_require_bin() { :; }
    source '$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh'
    do_spl_cloud_cnf() { echo CNF-READ; SPL_CNF='$T/cnf.yaml'; SPL_ORG_APP=org-app; }
    spl_cnf_api_fqdn() { printf -v \"\$1\" %s api.example.net; }
    spl_hub_operator_url() { SPL_HUB_URL=https://api.example.net; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam; }
    spl_m3_imap_pass() { echo SECRET-READ; echo \"\$1\" >'$T/log.pass'; ( umask 077; echo app-pw >\"\$1\" ); }
    spl_hub_operator_call() { echo \"\$1 \$2 \$3\" >'$T/log.op'; SPL_HUB_OP_STATUS=\$FAKE_OP
      SPL_HUB_OP_BODY='{\"tenant_id\":\"e2e\",\"email\":\"x@example.net\",\"role\":\"regular_user\",\"expires_at\":\"2026-11-24T09:00:00Z\",\"mail\":{\"outcome\":\"sent\",\"message_id\":\"<m1@example.net>\"}}'; }
    source '$FN'; do_spl_invite_native_e2e" 2>&1
}
leak() { grep -Eq "$INV_RE" <<<"$1"; }

# 1. refusals
for e in dev prd; do
  out="$(act ENV=$e TENANT_ID=t1)"
  [[ $? -ne 0 ]] && grep -q 'TENANT_ID t1 is refused' <<<"$out" && ! grep -q CNF-READ <<<"$out" &&
    pass "1. t1 on $e is refused before any cnf read" || fail "1. t1 $e: $out"
done
out="$(act ENV=prd TENANT_ID=csitea)"
[[ $? -ne 0 ]] && grep -q 'runs only in a test workspace' <<<"$out" && ! grep -q CNF-READ <<<"$out" &&
  pass "1. a prd tenant that is no test workspace is refused" || fail "1. prd csitea: $out"
out="$(act INE_ORDERED_BY=)"; [[ $? -ne 0 ]] && grep -q 'INE_ORDERED_BY must be HUM-<n>' <<<"$out" && pass "1. no INE_ORDERED_BY is refused" || fail "1. ordered_by: $out"
out="$(act INE_ORDER_MSG='x y')"; [[ $? -ne 0 ]] && grep -q "INE_ORDER_MSG must be the owner's message id" <<<"$out" && pass "1. a bad INE_ORDER_MSG is refused" || fail "1. order msg: $out"
for h in 0 721 abc; do out="$(act INE_TTL_HOURS=$h)"; [[ $? -ne 0 ]] && grep -q 'INE_TTL_HOURS must be 1..720' <<<"$out" && pass "1. INE_TTL_HOURS=$h is refused" || fail "1. ttl $h: $out"; done
out="$(act INE_TTL_HOURS=720)"; [[ $? -eq 0 ]] && pass "1. INE_TTL_HOURS=720 runs" || fail "1. ttl 720: $out"
for a in someone+x@example.com relay@example.net relay+@example.net; do
  out="$(act INE_EMAIL="$a")"
  [[ $? -ne 0 ]] && grep -q 'is no plus-address of the relay mailbox' <<<"$out" && ! grep -q SECRET-READ <<<"$out" &&
    pass "1. $a refused before any secret read" || fail "1. $a: $out"
done

# 2. the run
out="$(act)"; rc=$?
IFS='|' read -r n_pwd n_api n_email n_tenant n_out n_inv n_link n_mail <"$T/log.node"
[[ $rc -eq 0 ]] && grep -q '^OK invite native e2e on dev/e2e' <<<"$out" && grep -q '^PASS 9 read-back' <<<"$out" &&
  pass "2. a held run is OK, step 9 PASS" || fail "2. run: rc=$rc $out"
[[ "$n_pwd" == "$T/app/org-app-wui" && "$n_api" == https://api.example.net && "$n_email" =~ ^$INV_RE$ && "$n_tenant" == e2e &&
  "$n_out" == "$T/state/invite-native-e2e/"* && "$n_inv" == "$n_out/invite.json" &&
  "$n_link" == "python3 $T/app/org-app-orc/src/bash/scripts/invite-e2e.py link" &&
  "$n_mail" == "cd $T/app/org-app-orc && ENV=dev ./run -a do_spl_mail_verify_token" ]] &&
  pass "2. the proof gets the API, a fresh plus-address, the tenant, the state dir, the invite answer, the link + mail commands" ||
  fail "2. proof env: $(cat "$T/log.node")"
op="$(cat "$T/log.op")"
[[ "$op" == "POST /v1/operator/invites "* ]] && jq -e '.tenant == "e2e" and .role == "regular_user" and .ordered_by == "HUM-10"
  and .ordered_via == "invite-native-e2e msg 01649437" and .ttl_hours == 24' <<<"${op#POST /v1/operator/invites }" >/dev/null &&
  pass "2. the invite: role regular_user, ordered_by, the order msg, ttl" || fail "2. invite body: $op"
jq -e '.status == 201 and .mail_outcome == "sent" and .mail_message_id == "<m1@example.net>" and (has("email") | not)' "$T/log.invite" >/dev/null &&
  ! grep -q '@example.net"' <<<"$(jq -c 'del(.mail_message_id)' "$T/log.invite")" &&
  pass "2. invite.json: status, mail outcome + Message-ID, no address" || fail "2. invite.json: $(cat "$T/log.invite")"
[[ ! -e "$(cat "$T/log.pass")" ]] && pass "2. the relay password file is removed" || fail "2. password file left"
leak "$out" && fail "2. the full address is in the output: $out" || pass "2. no full address in the output (tag + digest only)"
grep -Eq 'invitee \+invnat-[0-9]{8}t[0-9]{6} \(digest [0-9a-f]{12}' <<<"$out" && pass "2. the clean-up line names the tag and digest" || fail "2. tag: $out"
jq -e '.steps[-1].step == "9 read-back (hub Postgres)" and .steps[-1].ok and .steps[-1].member_role == "regular_user"' \
  "$(dirname "$n_inv")/results.json" >/dev/null && pass "2. step 9 lands in results.json" || fail "2. results: $(cat "$(dirname "$n_inv")/results.json")"
out="$(act INE_EMAIL=Relay+Tag1@Example.net)"; IFS='|' read -r _ _ n_email _ <"$T/log.node"
[[ "$n_email" == relay+tag1@example.net ]] && pass "2. INE_EMAIL is lower-cased" || fail "2. case: $n_email"

# 3. CONTROLS
for c in "pending:the invite's accepted_at not set" "role:the member in another role" "human:another human than the session"; do
  out="$(act FAKE_ROWS="${c%%:*}")"; rc=$?
  [[ $rc -ne 0 ]] && grep -q '^FAIL 9 read-back' <<<"$out" && grep -q '^FAIL invite native e2e on dev/e2e' <<<"$out" &&
    pass "3. CONTROL ${c#*:}: FAIL" || fail "3. ${c%%:*}: rc=$rc $out"
done
touch "$T/fail"; out="$(act)"; rc=$?; rm -f "$T/fail"
[[ $rc -ne 0 ]] && grep -q '^FAIL invite native e2e' <<<"$out" && pass "3. CONTROL the proof failing: FAIL" || fail "3. proof fail: rc=$rc $out"
out="$(act FAKE_OP=403)"; rc=$?
[[ $rc -ne 0 && ! -e "$T/log.node" ]] && grep -q '^FAIL invite native e2e' <<<"$out" && pass "3. CONTROL the hub refusing the invite: FAIL, no proof run" || fail "3. op 403: rc=$rc $out"

# 4. invite-e2e.py link on a stub mailbox
INV=relay+invnat-1@example.net; mkdir -p "$T/mail"
printf 'From: SPOOL <noreply@example.net>\r\nTo: %s\r\nSubject: You are invited\r\nMessage-ID: <m1@example.net>\r\nContent-Type: text/plain\r\n\r\nSign in: https://e2e.wui.example.net/login?tenant=e2e&redirect=%%2Flobby&login_hint=relay%%2Binvnat-1%%40example.net\r\n' "$INV" >"$T/mail/1.eml"
link() { M3_HUMAN_EMAIL="$INV" M3_TENANT="$1" M3_STATE="$T" INVITE_E2E_MAILDIR="$T/mail" INVITE_E2E_TIMEOUT=1 python3 -B "$PY" link 2>&1; }
out="$(link e2e)"; rc=$?
[[ $rc -eq 0 ]] && jq -e '.link_tenant == "e2e" and .link_login_hint_is_invitee and .mail_message_id == "<m1@example.net>"
  and (.link | startswith("https://e2e.wui.example.net/login?tenant=e2e")) and (has("delivered_to") | not)' <<<"$out" >/dev/null &&
  pass "4. link: the invite mail's link facts as one JSON line" || fail "4. link: rc=$rc $out"
out="$(link other)"; rc=$?
[[ $rc -eq 1 ]] && jq -e '.error | startswith("no invite mail")' <<<"$out" >/dev/null && pass "4. link: no mail for the tenant in time -> exit 1" || fail "4. no mail: rc=$rc $out"

# 5. the WUI proof parses
node --check "$PROOF" 2>&1 && pass "5. the WUI proof parses" || fail "5. node --check $PROOF"

echo "invite-native-e2e: $fails failure(s)"
exit $((fails > 0))
