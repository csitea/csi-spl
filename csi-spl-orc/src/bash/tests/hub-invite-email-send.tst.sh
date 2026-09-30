#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: CLE-77780 do_spl_hub_invite_email_send + do_spl_hub_invite route ALL
#   invite mail through the HUB on Cloud Run (no box SMTP), with gcloud / curl
#   stubbed:
#   1. DRY_RUN (default) calls no cloud and names the hub URL + SA
#   2. bad input is refused before any call
#   3. DRY_RUN=0 mints an id token as the env SA and POSTs the operator route;
#      the id token reaches curl via a -K config file, never argv; outcome sent
#      -> exit 0, message id reported
#   4. a not-sent outcome (rate limited / accepted / expired) exits 3
#   5. a 404 (route not enabled) is a clear FATAL, exit 1
#   6. do_spl_hub_invite POSTs /v1/operator/invites (create+mail) with the role,
#      invited_by and ordered_by; 201 -> exit 0; the owner account is in no call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

PRD_SA=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com
FAKE_TOKEN="idtok.$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state"
printf '{"type":"service_account","client_email":"%s"}\n' "$PRD_SA" >"$T/home/.gcp/.csi/key-csi-spl-prd.json"

cat >"$T/stub/gcloud" <<STUB
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "auth print-identity-token"*) echo "$FAKE_TOKEN" ;;
esac
exit 0
STUB

# curl: record the call and fake the hub operator route. The id token must
# arrive via a -K config file (never argv): record all argv so the test can
# prove the token is not there.
cat >"$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T_ARGV"
out=""; hdrfile=""; data=""; url=""; method=GET
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift 2;;
    -K) hdrfile="$2"; shift 2;;
    --data) data="$2"; shift 2;;
    -X) method="$2"; shift 2;;
    -m|-w|-H) shift 2;;
    -sS) shift;;
    http://*|https://*) url="$1"; shift;;
    *) shift;;
  esac
done
authinfile=no
[[ -n "$hdrfile" ]] && grep -q 'Authorization: Bearer' "$hdrfile" && authinfile=yes
echo "curl $method $url auth_in_kfile=$authinfile body=$data" >>"$STUB_LOG"
case "${STUB_OUTCOME:-sent}" in
  sent)   resp='{"tenant_id":"t1","mail":{"outcome":"sent","message_id":"<m1.tenant_invite@x>","delivered":true,"to":"abc"}}';;
  invite) resp='{"tenant_id":"t1","email":"invitee@example.com","role":"developer","invited_by":"HUM-10","status":"invited","mail":{"outcome":"sent","message_id":"<m2.tenant_invite@x>","delivered":true}}';;
  *)      resp="{\"tenant_id\":\"t1\",\"mail\":{\"outcome\":\"${STUB_OUTCOME}\",\"to\":\"abc\"}}";;
esac
[[ -n "$out" ]] && printf '%s' "$resp" >"$out"
printf '%s' "${STUB_HTTP:-200}"
exit 0
STUB
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/argv"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_ARGV="$T/argv" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=prd CNF_OVERRIDE="${CNF_OVERRIDE:-}" SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    if [[ -n "$CNF_OVERRIDE" ]]; then
      eval "$(declare -f do_spl_cloud_cnf | sed "1s/do_spl_cloud_cnf/_orig_cloud_cnf/")"
      do_spl_cloud_cnf() { _orig_cloud_cnf || return 1; yq -i "$CNF_OVERRIDE" "$SPL_CNF"; }
    fi
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

# the hub URL is derived by the cnf merge (do_spl_merged_cnf); read it there
in_orc 'do_spl_cloud_cnf && spl_hub_operator_url && echo "HUB=$SPL_HUB_URL"'
HUB="$(sed -n 's/^HUB=//p' "$T/out")"
[[ "$HUB" =~ ^https://[a-z0-9.-]+$ ]] || { echo "FAIL: no prd hub url from the merged cnf: $(cat "$T/out")"; exit 1; }
ARGS=(TENANT_ID=t1 EMAIL=Invitee@Example.com)

# --- 1. dry run -----------------------------------------------------------------
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q "DRY_RUN would ask the hub $HUB to mail the t1 invitation to invitee@example.com" "$T/out" \
  && pass "1. DRY_RUN: no cloud call; names the hub URL and the lower-cased address" \
  || fail "1. dry: rc=$rc $(cat "$T/calls.log" "$T/out")"

# --- 2. refusals ------------------------------------------------------------------
for bad in EMAIL=nope TENANT_ID=T_1 LOCALE=english; do
  in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" "$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc"
done

# --- 3. real run ------------------------------------------------------------------
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] \
  && grep -qx "curl POST $HUB/v1/operator/invites/mail auth_in_kfile=yes body={\"tenant\":\"t1\",\"email\":\"invitee@example.com\"}" "$T/calls.log" \
  && grep -q "the hub relay accepted the t1 invitation for invitee@example.com" "$T/out" \
  && grep -qF "message_id <m1.tenant_invite@x>" "$T/out" \
  && pass "3. DRY_RUN=0: POST the operator mail route as the SA; outcome sent; message id reported" \
  || fail "3. real: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qF "$FAKE_TOKEN" "$T/argv" && fail "3. the id token leaked into curl argv" || pass "3. the id token is in the -K file, never curl argv"
grep -qx "proxy-start as $PRD_SA" "$T/calls.log" && fail "3. still starts the SQL proxy (should not: the hub owns the DB)" || pass "3. no SQL proxy (the hub owns the DB and the relay)"

# LOCALE reaches the body
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" LOCALE=en DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'operator/invites/mail auth_in_kfile=yes body={"tenant":"t1","email":"invitee@example.com","locale":"en"}' "$T/calls.log" \
  && pass "3. LOCALE reaches the operator route body" || fail "3. locale: rc=$rc $(cat "$T/calls.log")"

# --- 4. not sent -----------------------------------------------------------------
for o in rate_limited accepted expired not_found; do
  in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" DRY_RUN=0 STUB_OUTCOME=$o; rc=$?
  [[ $rc -eq 3 ]] && grep -q "NOT SENT: the t1 invitation for invitee@example.com is $o" "$T/out" \
    && pass "4. $o: exit 3, NOT SENT" || fail "4. $o: rc=$rc $(cat "$T/out")"
done

# --- 5. route not enabled (404) --------------------------------------------------
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" DRY_RUN=0 STUB_HTTP=404; rc=$?
[[ $rc -eq 1 ]] && grep -q "hub operator route is not enabled (404)" "$T/out" \
  && pass "5. 404: FATAL route not enabled, exit 1" || fail "5. 404: rc=$rc $(cat "$T/out")"

# --- 6. do_spl_hub_invite creates + mails through the hub -------------------------
in_orc 'do_spl_hub_invite' TENANT_ID=t1 INVITE_EMAIL=invitee@example.com INVITE_ROLE=member INVITED_BY=HUM-10 ORDERED_BY=HUM-10 ORDERED_VIA=CLE-1 DRY_RUN=0 STUB_OUTCOME=invite STUB_HTTP=201; rc=$?
[[ $rc -eq 0 ]] \
  && grep -q 'curl POST '"$HUB"'/v1/operator/invites auth_in_kfile=yes body={"tenant":"t1","email":"invitee@example.com","role":"developer","invited_by":"HUM-10","ordered_by":"HUM-10","ordered_via":"CLE-1"}' "$T/calls.log" \
  && grep -q "invited invitee@example.com to t1 as developer (invited_by=HUM-10, ordered_by=HUM-10 via CLE-1)" "$T/out" \
  && pass "6. do_spl_hub_invite POSTs the operator create route (member -> developer, invited_by + ordered_by in the body)" \
  || fail "6. invite: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qF "$FAKE_TOKEN" "$T/argv" && fail "6. invite: the id token leaked into curl argv" || pass "6. invite: the id token is not in curl argv"
# ORDERED_BY is required with DRY_RUN=0
in_orc 'do_spl_hub_invite' TENANT_ID=t1 INVITE_EMAIL=invitee@example.com DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "ORDERED_BY .* is required" "$T/out" \
  && pass "6. ORDERED_BY required with DRY_RUN=0 (CLE-77778 provenance)" || fail "6. ordered_by-required: rc=$rc $(cat "$T/out")"
owner="$(yq -r '.env.gcp.gcp_account_owner_email // "no-owner-in-cnf"' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
grep -qF "$owner" "$T/calls.log" "$T/argv" && fail "6. the owner account was used" || pass "6. the owner account appears in no call"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
