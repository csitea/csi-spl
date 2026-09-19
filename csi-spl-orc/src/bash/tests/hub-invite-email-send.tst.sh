#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: 010 FR-016 T064 do_spl_hub_invite_email_send (and the mail env
#          do_spl_hub_invite passes), CALLED with gcloud / spool stubbed:
#   1. DRY_RUN (default) calls no cloud and names relay, sign-in URL, SA
#   2. bad input and a cnf without an smtp relay are refused before any call
#   3. DRY_RUN=0 runs `spool hub-invite-mail` as the env SA through the proxy;
#      the relay password reaches the child's ENVIRONMENT, never argv, the
#      output or a log; the app URL is https://<cnf fqdn>
#   4. a not-sent outcome (rate limited / accepted / expired) exits 3
#   5. do_spl_hub_invite passes the same env; the owner account is in no call
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

PRD_SA=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com
MAIL_PW="relaypw$RANDOM$RANDOM"
DSN_PW="dsnpw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$PRD_SA" >"$T/home/.gcp/.csi/key-csi-spl-prd.json"

cat >"$T/stub/gcloud" <<STUB
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access latest --secret=csi-spl-hub-mail-smtp-password"*) echo "$MAIL_PW" ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
STUB
# spool: record argv and which env arrived (the password only as pw=set)
cat >"$T/stub/spool" <<'STUB'
#!/usr/bin/env bash
echo "spool $* dsn=${SPOOL_HUB_DB_DSN:+set} pw=${SPOOL_HUB_MAIL_SMTP_PASSWORD:+set} transport=${SPOOL_HUB_MAIL_TRANSPORT:-} app=${SPOOL_HUB_AUTH_APP_URL:-} loc=${SPOOL_HUB_DEFAULT_LOCALE:-}" >>"$STUB_LOG"
env >>"$T_ENVDUMP"
case "${STUB_OUTCOME:-sent}" in
  sent) echo '{"mail":{"outcome":"sent","to":"abc123","message_id":"<m1.tenant_invite@x>","delivered":true},"tenant":"t1"}' ;;
  *) echo "{\"mail\":{\"outcome\":\"$STUB_OUTCOME\",\"to\":\"abc123\"},\"tenant\":\"t1\"}"; exit 3 ;;
esac
STUB
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/env"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_ENVDUMP="$T/env" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=prd CNF_OVERRIDE="${CNF_OVERRIDE:-}" SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    if [[ -n "$CNF_OVERRIDE" ]]; then
      eval "$(declare -f do_spl_cloud_cnf | sed "1s/do_spl_cloud_cnf/_orig_cloud_cnf/")"
      do_spl_cloud_cnf() { _orig_cloud_cnf || return 1; yq -i "$CNF_OVERRIDE" "$SPL_CNF"; }
    fi
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    spl_host_spool() { SPL_SPOOL=$(command -v spool); }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

# the fqdn is derived by the cnf merge (do_spl_merged_cnf), so read it there
in_orc 'do_spl_cloud_cnf && echo "FQDN=$SPL_FQDN"'
FQDN="$(sed -n 's/^FQDN=//p' "$T/out")"
[[ "$FQDN" =~ ^[a-z0-9.-]+$ ]] || { echo "FAIL: no prd fqdn from the merged cnf: $(cat "$T/out")"; exit 1; }
ARGS=(TENANT_ID=t1 EMAIL=Invitee@Example.com)

# --- 1. dry run -----------------------------------------------------------------
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q "DRY_RUN would mail the t1 invitation to invitee@example.com" "$T/out" \
  && grep -qF "https://$FQDN/login?tenant=t1" "$T/out" \
  && pass "1. DRY_RUN: no cloud call; names the address (lower-cased), https://<fqdn>/login?tenant=t1" \
  || fail "1. dry: rc=$rc $(cat "$T/calls.log" "$T/out")"

# --- 2. refusals ------------------------------------------------------------------
for bad in EMAIL=nope TENANT_ID=T_1 LOCALE=english MIN_GAP=soon; do
  in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" "$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc"
done
CNF_OVERRIDE='.env.mail.env.SPOOL_HUB_MAIL_TRANSPORT = "log"' in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "not smtp" "$T/out" \
  && pass "2. CONTROL: a cnf transport that is not smtp is refused (nothing would reach an inbox)" || fail "2. log transport: rc=$rc $(cat "$T/out")"

# --- 3. real run ------------------------------------------------------------------
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "proxy-start as $PRD_SA" "$T/calls.log" \
  && grep -qF "spool hub-invite-mail --tenant t1 --email invitee@example.com --min-gap 10m dsn=set pw=set transport=smtp app=https://$FQDN loc=" "$T/calls.log" \
  && grep -q "OK the relay accepted the t1 invitation" "$T/out" && grep -qF "message_id <m1.tenant_invite@x>" "$T/out" \
  && pass "3. DRY_RUN=0: spool hub-invite-mail as $PRD_SA; password in the env; app https://<fqdn>; message id reported" \
  || fail "3. real: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qx "SPOOL_HUB_MAIL_SMTP_PASSWORD=$MAIL_PW" "$T/env" && pass "3. the child's environment carries the relay password" || fail "3. no password in the child env"
grep -qF "$MAIL_PW" "$T/out" "$T/calls.log" && fail "3. the relay password leaked into output / argv" || pass "3. the relay password is in neither output nor any argv"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" && fail "3. the DSN password leaked" || pass "3. the DSN password is in neither output nor argv"
in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" LOCALE=en MIN_GAP=0s DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "hub-invite-mail --tenant t1 --email invitee@example.com --min-gap 0s --locale en " "$T/calls.log" \
  && pass "3. LOCALE / MIN_GAP reach the CLI" || fail "3. locale/gap: rc=$rc $(cat "$T/calls.log")"

# --- 4. not sent -----------------------------------------------------------------
for o in rate_limited skipped_accepted skipped_expired; do
  in_orc 'do_spl_hub_invite_email_send' "${ARGS[@]}" DRY_RUN=0 STUB_OUTCOME=$o; rc=$?
  [[ $rc -eq 3 ]] && grep -q "NOT SENT: the t1 invitation for invitee@example.com is $o" "$T/out" \
    && pass "4. $o: exit 3, NOT SENT" || fail "4. $o: rc=$rc $(cat "$T/out")"
done

# --- 5. do_spl_hub_invite carries the same env; the owner account is never used --
in_orc 'do_spl_hub_invite' TENANT_ID=t1 INVITE_EMAIL=invitee@example.com INVITE_ROLE=member DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qF "spool hub-invite --tenant t1 --email invitee@example.com --role member dsn=set pw=set transport=smtp app=https://$FQDN" "$T/calls.log" \
  && pass "5. do_spl_hub_invite passes the relay env (argv unchanged)" || fail "5. invite env: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qF "$MAIL_PW" "$T/out" "$T/calls.log" && fail "5. invite: the relay password leaked" || pass "5. invite: no password in output / argv"
owner="$(yq -r '.env.gcp.gcp_account_owner_email // "no-owner-in-cnf"' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
grep -qF "$owner" "$T/calls.log" && fail "5. the owner account was used" || pass "5. the owner account appears in no call"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
