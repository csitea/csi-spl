#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_native_email_verify stays offline on DRY_RUN and on bad input,
#          a real run flips password_credentials.email_verified_at with the email
#          carried as a psql variable (never spliced), touches exactly the one
#          unverified row, and REFUSES a missing (NOT_FOUND) or already-verified
#          (ALREADY_VERIFIED) credential - it verifies, it never creates or
#          re-stamps. gcloud and psql are stubbed; no secret leaks.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "FAIL: no yq"; exit 1; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
EMAIL=facebook-test-user@facebook.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<EOF
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
if [[ -n "${STUB_PSQL_OUT+x}" ]]; then
  printf '%s\n' "$STUB_PSQL_OUT"
else
  printf '%s\n' 'VERIFIED facebook-test-user@facebook.com | 2026-09-29 14:00:00+00'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u EMAIL \
    -u STUB_PSQL_OUT -u STUB_PSQL_RC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/spl-native-email-verify.func.sh"
SQL0009="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub/0009_native_credentials.sql"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
grep -q 'email_verified_at' "$SQL0009" && grep -q 'email_verified_at' "$FUNC" \
  && pass "0. it targets the 0009 password_credentials.email_verified_at column" \
  || fail "0. column drifted from 0009 password_credentials"

# --- 1. DRY_RUN ----------------------------------------------------------------
in_orc 'do_spl_native_email_verify' EMAIL="$EMAIL"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q "DRY_RUN would mark $EMAIL verified in the dev hub DB on csi-spl-dev:" "$T/out" \
  && pass "1. DRY_RUN (default): plan only, no cloud" \
  || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
in_orc 'do_spl_native_email_verify' ENV=prd EMAIL="$EMAIL" DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'the prd hub DB on csi-spl-prd:' "$T/out" \
  && pass "1. prd DRY_RUN names the prd connection and calls no cloud" \
  || fail "1. prd dry: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_native_email_verify' EMAIL="FaceBook-Test-User@Facebook.COM"; rc=$?
[[ $rc -eq 0 ]] && grep -q "would mark facebook-test-user@facebook.com verified" "$T/out" \
  && pass "1. EMAIL is lower-cased in the plan" || fail "1. lowercase: rc=$rc $(cat "$T/out")"

# --- 2. refusals --------------------------------------------------------------
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_native_email_verify' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing EMAIL" DRY_RUN=0
refuse "not an address" EMAIL=notanemail DRY_RUN=0
refuse "injected EMAIL" "EMAIL=x@y.co'; drop table password_credentials --" DRY_RUN=0
refuse "space in EMAIL" "EMAIL=a b@c.co" DRY_RUN=0
refuse "DRY_RUN=2" EMAIL="$EMAIL" DRY_RUN=2
in_orc 'do_spl_native_email_verify' ENV=stg EMAIL="$EMAIL" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. ENV=stg refused before any call" || fail "2. ENV=stg: rc=$rc $(cat "$T/out")"

# --- 3. no key ----------------------------------------------------------------
in_orc 'do_spl_native_email_verify' EMAIL="$EMAIL" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "3. no SA key: refused, no proxy, no psql" || fail "3. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 4. the statement ---------------------------------------------------------
in_orc 'do_spl_native_email_verify' EMAIL="$EMAIL" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] \
  && grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" && grep -qx 'ROLLBACK;' "$T/stdin" \
  && grep -q "email_verified_at = now()" "$T/stdin" \
  && grep -q "subject = :'email'" "$T/stdin" \
  && grep -q 'UPDATE password_credentials' "$T/stdin" \
  && ! grep -q 'app.tenant_id' "$T/stdin" \
  && ! grep -qiE '\b(insert|delete|drop|truncate|alter)\b' "$T/stdin" \
  && grep -q "\[email=$EMAIL\]" "$T/calls.log" \
  && ! grep -q "$EMAIL" "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK $EMAIL email_verified_at set by" "$T/out" \
  && pass "4. DRY_RUN=0: one row, email as -v, no tenant scope, as $DEV_SA" \
  || fail "4. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "4. the DSN password leaked" || pass "4. the DSN password is in neither output, argv nor SQL"

# --- 5. control: a missing credential is refused, not created -----------------
in_orc 'do_spl_native_email_verify' EMAIL="$EMAIL" DRY_RUN=0 STUB_PSQL_OUT='NOT_FOUND'; rc=$?
[[ $rc -ne 0 ]] && grep -q "no password credential for $EMAIL" "$T/out" \
  && pass "5. control: NOT_FOUND is refused (verifies, never creates)" || fail "5. not-found: rc=$rc $(cat "$T/out")"

# --- 6. control: an already-verified credential is refused, not re-stamped ----
in_orc 'do_spl_native_email_verify' EMAIL="$EMAIL" DRY_RUN=0 STUB_PSQL_OUT='ALREADY_VERIFIED'; rc=$?
[[ $rc -ne 0 ]] && grep -q "$EMAIL is already verified" "$T/out" \
  && pass "6. control: ALREADY_VERIFIED is refused (never re-stamps a live account)" || fail "6. already: rc=$rc $(cat "$T/out")"

# --- 7. zero rows updated (a race between the check and the UPDATE) -----------
in_orc 'do_spl_native_email_verify' EMAIL="$EMAIL" DRY_RUN=0 STUB_PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q '0 row(s) matched' "$T/out" \
  && pass "7. zero rows updated is a rollback" || fail "7. zero: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
