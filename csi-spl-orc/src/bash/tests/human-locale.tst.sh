#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_human_locale stays offline on DRY_RUN and on bad input, and
#          a real run updates humans.preferred_locale with psql variables.
#          Exactly one row, or the script rolls back. gcloud and psql are
#          stubbed.
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
  printf '%s\n' 'HUM-4 | bg'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u LOCALE \
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

FUNC="$PROJ_ROOT/src/bash/run/spl-human-locale.func.sh"
SQL0017="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub/0017_human_preferred_locale.sql"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
want=$(python3 -c '
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r"preferred_locale IN\s*\(([^)]*)\)", t)
codes=re.findall(r"'\''([a-z]{2})'\''", m.group(1))
print("|".join(codes))
' "$SQL0017")
grep -q "locales='$want'" "$FUNC" && pass "0. the locale list is rdb 0017's CHECK, in that order" \
  || fail "0. locale list drifted from 0017 (want $want)"

# --- 1. DRY_RUN ----------------------------------------------------------------
in_orc 'do_spl_human_locale' HUMAN_ID=HUM-4 LOCALE=BG; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would set preferred_locale of HUM-4 to bg on csi-spl-dev:' "$T/out" \
  && ! grep -q 'LOCALE=BG' "$T/out" \
  && pass "1. DRY_RUN (default): lower-cased plan, no cloud" \
  || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
in_orc 'do_spl_human_locale' ENV=prd HUMAN_ID=HUM-4 LOCALE=bg DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'on csi-spl-prd:' "$T/out" \
  && pass "1. prd DRY_RUN names the prd connection and calls no cloud" \
  || fail "1. prd dry: rc=$rc $(cat "$T/out")"

# --- 2. refusals --------------------------------------------------------------
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_human_locale' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing HUMAN_ID" LOCALE=bg DRY_RUN=0
refuse "injected HUMAN_ID" "HUMAN_ID=HUM-4' or '1'='1" LOCALE=bg DRY_RUN=0
refuse "missing LOCALE" HUMAN_ID=HUM-4 DRY_RUN=0
refuse "unknown LOCALE" HUMAN_ID=HUM-4 LOCALE=xx DRY_RUN=0
refuse "region LOCALE" HUMAN_ID=HUM-4 LOCALE=en-US DRY_RUN=0
refuse "injected LOCALE" HUMAN_ID=HUM-4 "LOCALE=bg'; drop table humans" DRY_RUN=0
refuse "DRY_RUN=2" HUMAN_ID=HUM-4 LOCALE=bg DRY_RUN=2
in_orc 'do_spl_human_locale' ENV=stg HUMAN_ID=HUM-4 LOCALE=bg DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. ENV=stg refused before any call" || fail "2. ENV=stg: rc=$rc $(cat "$T/out")"

# --- 3. no key ----------------------------------------------------------------
in_orc 'do_spl_human_locale' HUMAN_ID=HUM-4 LOCALE=bg DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "3. no SA key: refused, no proxy, no psql" || fail "3. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 4. the statement ---------------------------------------------------------
in_orc 'do_spl_human_locale' HUMAN_ID=HUM-4 LOCALE=bg DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] \
  && grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" && grep -qx 'ROLLBACK;' "$T/stdin" \
  && grep -q "preferred_locale = :'locale'" "$T/stdin" \
  && grep -q "human_id = :'human'" "$T/stdin" \
  && grep -q 'UPDATE humans SET' "$T/stdin" \
  && ! grep -q 'app.tenant_id' "$T/stdin" \
  && ! grep -qiE '\b(insert|delete|drop|truncate|alter)\b' "$T/stdin" \
  && grep -q '\[human=HUM-4\]' "$T/calls.log" && grep -q '\[locale=bg\]' "$T/calls.log" \
  && ! grep -q 'HUM-4' "$T/stdin" && ! grep -q 'bg' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK HUM-4 preferred_locale is now bg ($DEV_SA):" "$T/out" \
  && pass "4. DRY_RUN=0: one row, values as -v, no tenant scope, as $DEV_SA" \
  || fail "4. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "4. the DSN password leaked" || pass "4. the DSN password is in neither output, argv nor SQL"

# --- 5. zero rows -------------------------------------------------------------
in_orc 'do_spl_human_locale' HUMAN_ID=HUM-4 LOCALE=bg DRY_RUN=0 STUB_PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q '0 row(s) matched HUM-4: rolled back' "$T/out" \
  && pass "5. zero rows is a rollback" || fail "5. zero: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
