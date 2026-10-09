#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_split_show is a read of one tenant's vendor split.
#          Bad input never calls the cloud. A real run SELECTs through the
#          proxy as the project SA, with the tenant id as a psql variable,
#          and prints "claude=N grok=N agy=N qwen=N mistral=N". A row that does not sum
#          to 100 is refused. gcloud and psql are stubbed.
#          --kind <k> (spec 115 HUB-1, rdb 0163) prints that kind's row with
#          its backup, from the workspace's rows, else from the cnf
#          env.box.agent_split_by_kind row; a bad kind never calls the cloud.
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
printf 'psql PGOPTIONS=%s' "${PGOPTIONS-}" >>"$STUB_LOG"
printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
if [[ -n "${STUB_PSQL_OUT+x}" ]]; then
  printf '%s\n' "$STUB_PSQL_OUT"
else
  printf '%s\n' '20|0|25|0|55'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u TENANT_ID \
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

FUNC="$PROJ_ROOT/src/bash/run/spl-agent-split-show.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
grep -q "default_transaction_read_only=on" "$FUNC" && pass "0. the session is read-only" || fail "0. no read-only session"
grep -q "SET LOCAL app.tenant_id = :'tenant'" "$FUNC" && pass "0. the tenant id is a psql variable" || fail "0. tenant id is spliced"

# --- 1. refusals --------------------------------------------------------------
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_agent_split_show' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $label refused before any call" || fail "1. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing TENANT_ID"
refuse "injected TENANT_ID" "TENANT_ID=t1'; drop table tenants"
refuse "ENV=stg" ENV=stg TENANT_ID=t1
in_orc 'do_spl_agent_split_show' TENANT_ID=t1 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "1. no SA key: refused, no proxy, no psql" || fail "1. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 2. the statement ---------------------------------------------------------
in_orc 'do_spl_agent_split_show' TENANT_ID=t1; rc=$?
[[ $rc -eq 0 ]] \
  && grep -qx 'claude=20 grok=0 agy=25 qwen=0 mistral=55' "$T/out" \
  && grep -q 'agent_split_mistral' "$T/stdin" \
  && grep -q 'BEGIN TRANSACTION READ ONLY;' "$T/stdin" \
  && grep -q "SET LOCAL app.tenant_id = :'tenant'" "$T/stdin" \
  && grep -q 'agent_split_claude' "$T/stdin" \
  && grep -q 'ROLLBACK;' "$T/stdin" \
  && ! grep -qiE '\b(insert|update|delete|drop|truncate|alter)\b' "$T/stdin" \
  && ! grep -q 't1' "$T/stdin" \
  && grep -q '\[tenant=t1\]' "$T/calls.log" \
  && grep -q 'PGOPTIONS=-c default_transaction_read_only=on' "$T/calls.log" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK agent split of t1 on csi-spl-dev:" "$T/out" \
  && pass "2. prints the split, SELECT only, tenant as -v, as $DEV_SA" \
  || fail "2. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "2. the DSN password leaked" || pass "2. the DSN password is in neither output, argv nor SQL"

# --- 3. a bad row -------------------------------------------------------------
in_orc 'do_spl_agent_split_show' TENANT_ID=t1 STUB_PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no agent split row for tenant t1' "$T/out" \
  && ! grep -q '^claude=' "$T/out" \
  && pass "3. zero rows is a refusal" || fail "3. zero: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show' TENANT_ID=t1 STUB_PSQL_OUT='40|50|10|0|10'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'sums to 110, not 100' "$T/out" \
  && ! grep -q '^claude=' "$T/out" \
  && pass "3. a row that does not sum to 100 is not printed" || fail "3. sum: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show' TENANT_ID=t1 STUB_PSQL_OUT='40|50|10|0'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no agent split row for tenant t1' "$T/out" && ! grep -q '^claude=' "$T/out" \
  && pass "3. control: a four-column row (no mistral) is not read as a split" || fail "3. four: rc=$rc $(cat "$T/out")"

# --- 4. --kind (spec 115 HUB-1) ---------------------------------------------
in_orc 'do_spl_agent_split_show --kind=opus' TENANT_ID=t1; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "FATAL --kind must be" "$T/out" \
  && pass "4. a kind outside the six is refused before any call" || fail "4. opus: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show --kind "x'"'"'; drop table tenants"' TENANT_ID=t1; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "4. an injected kind is refused before any call" || fail "4. injected kind: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show --kind simple_coding' TENANT_ID=t1 STUB_PSQL_OUT=$'agy|0|false\nclaude|30|true\ngrok|10|false\nmistral|60|false\nqwen|0|false'; rc=$?
[[ $rc -eq 0 ]] \
  && grep -qx 'claude=30 grok=10 agy=0 qwen=0 mistral=60 backup=claude' "$T/out" \
  && grep -q 'FROM tenant_agent_split_kind' "$T/stdin" \
  && grep -q "kind = :'kind'" "$T/stdin" \
  && grep -q 'BEGIN TRANSACTION READ ONLY;' "$T/stdin" \
  && ! grep -qiE '\b(insert|update|delete|drop|truncate|alter)\b' "$T/stdin" \
  && grep -q '\[kind=simple_coding\]' "$T/calls.log" \
  && grep -q 'source=workspace' "$T/out" \
  && pass "4. --kind prints the workspace's row and its backup, kind as -v" \
  || fail "4. kind: rc=$rc $(cat "$T/out") --- $(cat "$T/calls.log")"
in_orc 'do_spl_agent_split_show --kind hard' TENANT_ID=t1 STUB_PSQL_OUT=''; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'claude=80 grok=0 agy=0 qwen=0 mistral=20 backup=mistral' "$T/out" \
  && grep -q '\[kind=complex_coding\]' "$T/calls.log" && grep -q 'source=cnf' "$T/out" \
  && pass "4. an unset kind (alias hard) prints the cnf row" || fail "4. cnf: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show --kind i18n' TENANT_ID=t1 STUB_PSQL_OUT=''; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'claude=0 grok=0 agy=100 qwen=0 mistral=0 backup=claude' "$T/out" \
  && pass "4. a cnf backup with no weight is printed as the backup" || fail "4. cnf backup: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show --kind tests' TENANT_ID=t1 STUB_PSQL_OUT=$'claude|70|false\nmistral|29|true'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'sums to 99, not 100' "$T/out" && ! grep -q '^claude=' "$T/out" \
  && pass "4. a kind that does not sum to 100 is not printed" || fail "4. kind sum: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_agent_split_show --kind tests' TENANT_ID=t1 STUB_PSQL_OUT=$'claude|70|false\nmistral|30|false'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'names no backup' "$T/out" && ! grep -q '^claude=' "$T/out" \
  && pass "4. control: a kind with no backup is not printed" || fail "4. no backup: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
