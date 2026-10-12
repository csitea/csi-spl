#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_split_reset drops a workspace's saved per-kind split
#          (rdb 0163), the PATCH /v1/agent-split {kinds:{<k>:null}} effect.
#          Bad input never calls the cloud. DRY_RUN=1 (default) only SELECTs,
#          read-only, and prints the rows it would delete. DRY_RUN=0 prints
#          each kind's show line, DELETEs in one transaction, then prints the
#          show line again (source=cnf). Tenant and kinds are psql variables;
#          the identity is the env project SA. gcloud and psql are stubbed.
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
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state" "$T/seq"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<STUB
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
STUB
# psql answers the Nth call with $STUB_SEQ/N (empty when absent) and exits
# with $STUB_SEQ/N.rc (0 when absent); stdin of every call goes to $T_STDIN.
cat >"$T/stub/psql" <<'STUB'
#!/usr/bin/env bash
printf 'psql PGOPTIONS=%s' "${PGOPTIONS-}" >>"$STUB_LOG"
printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || { cat >>"$T_STDIN"; echo "-- end of call" >>"$T_STDIN"; }
n=$(( $(cat "$STUB_SEQ/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_SEQ/n"
[[ -f "$STUB_SEQ/$n" ]] && cat "$STUB_SEQ/$n"
exit "$(cat "$STUB_SEQ/$n.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$T/stub/"*

# seq <n> <text> [rc] -> what the stub psql answers on its nth call
seq_out() { printf '%s\n' "$2" >"$T/seq/$1"; [[ -n "${3:-}" ]] && echo "$3" >"$T/seq/$1.rc"; return 0; }

in_orc() {
  local snip="$1" rc; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u TENANT_ID \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" STUB_SEQ="$T/seq" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null; rc=$?
  rm -f "$T/seq/"*
  return $rc
}

FUNC="$PROJ_ROOT/src/bash/run/spl-agent-split-reset.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
grep -q "default_transaction_read_only=on" "$FUNC" && pass "0. the dry run is a read-only session" || fail "0. no read-only dry run"
grep -q "kind = ANY(string_to_array(:'kinds', ','))" "$FUNC" && pass "0. the kinds are a psql variable" || fail "0. kinds are spliced"

# --- 1. refusals --------------------------------------------------------------
refuse() {
  local label="$1" snip="$2"; shift 2
  in_orc "$snip" "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $label refused before any call" || fail "1. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "no --kind" 'do_spl_agent_split_reset' TENANT_ID=t1
refuse "an empty --kind" 'do_spl_agent_split_reset --kind ""' TENANT_ID=t1
refuse "a kind outside the seven" 'do_spl_agent_split_reset --kind tests --kind opus' TENANT_ID=t1
refuse "an injected kind" 'do_spl_agent_split_reset --kind "x'"'"'; drop table tenants"' TENANT_ID=t1
refuse "missing TENANT_ID" 'do_spl_agent_split_reset --kind tests'
refuse "injected TENANT_ID" 'do_spl_agent_split_reset --kind tests' "TENANT_ID=t1'; drop table tenants"
refuse "DRY_RUN=2" 'do_spl_agent_split_reset --kind tests' TENANT_ID=t1 DRY_RUN=2
refuse "ENV=stg" 'do_spl_agent_split_reset --kind tests' ENV=stg TENANT_ID=t1
in_orc 'do_spl_agent_split_reset --kind tests' TENANT_ID=t1 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "1. no SA key: refused, no proxy, no psql" || fail "1. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 2. DRY_RUN=1 (default) ---------------------------------------------------
seq_out 1 $'t1|simple_coding|claude|20|false\nt1|simple_coding|grok|30|false\nt1|tests|claude|50|true'
in_orc 'do_spl_agent_split_reset --kind default --kind tests --kind=simple_coding' TENANT_ID=t1; rc=$?
[[ $rc -eq 0 ]] \
  && grep -qx 'would delete t1|simple_coding|claude|20|false' "$T/out" \
  && grep -qx 'would delete t1|tests|claude|50|true' "$T/out" \
  && grep -q 'OK DRY_RUN would delete 3 row(s) of t1 kinds simple_coding,tests on csi-spl-dev' "$T/out" \
  && [[ "$(grep -c '^psql' "$T/calls.log")" -eq 1 ]] \
  && grep -q 'PGOPTIONS=-c default_transaction_read_only=on' "$T/calls.log" \
  && grep -q '\[kinds=simple_coding,tests\]' "$T/calls.log" \
  && grep -q '\[tenant=t1\]' "$T/calls.log" \
  && grep -q 'BEGIN TRANSACTION READ ONLY;' "$T/stdin" \
  && ! grep -qiE '\b(insert|update|delete|drop|truncate|alter)\b' "$T/stdin" \
  && ! grep -q 't1' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "2. DRY_RUN prints the rows, one read-only SELECT, aliases and repeats folded, as $DEV_SA" \
  || fail "2. dry: rc=$rc $(cat "$T/out") --- $(cat "$T/calls.log") --- $(cat "$T/stdin")"
in_orc 'do_spl_agent_split_reset --kind tests' TENANT_ID=t1 DRY_RUN=1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'has no saved split for tests: nothing to delete' "$T/out" && ! grep -q '^would delete' "$T/out" \
  && pass "2. DRY_RUN with no saved rows says so" || fail "2. dry empty: rc=$rc $(cat "$T/out")"
seq_out 1 'permission denied' 3
in_orc 'do_spl_agent_split_reset --kind tests' TENANT_ID=t1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL agent split reset read of t1 failed' "$T/out" \
  && pass "2. a failed read is a FATAL" || fail "2. dry fail: rc=$rc $(cat "$T/out")"

# --- 3. DRY_RUN=0 -------------------------------------------------------------
seq_out 1 $'agy|0|false\nclaude|20|false\ngrok|30|true\nmistral|50|false\nqwen|0|false'
seq_out 2 $'agy|0|false\nclaude|50|true\ngrok|20|false\nmistral|30|false\nqwen|0|false'
seq_out 3 $'t1|simple_coding|claude|20|false\nt1|tests|claude|50|true'
in_orc 'do_spl_agent_split_reset --kind simple_coding --kind tests' TENANT_ID=t1 DRY_RUN=0; rc=$?
cnf_sc="$(sed -n '/^after simple_coding:$/{n;p}' "$T/out")"
[[ $rc -eq 0 ]] \
  && [[ "$(sed -n '/^before simple_coding:$/{n;p}' "$T/out")" == 'claude=20 grok=30 agy=0 qwen=0 mistral=50 backup=grok' ]] \
  && [[ "$(sed -n '/^before tests:$/{n;p}' "$T/out")" == 'claude=50 grok=20 agy=0 qwen=0 mistral=30 backup=claude' ]] \
  && [[ "$(grep -c 'source=workspace' "$T/out")" -eq 2 ]] \
  && grep -qx 'deleted t1|tests|claude|50|true' "$T/out" \
  && grep -q 'OK deleted 2 row(s) of t1 kinds simple_coding,tests on csi-spl-dev' "$T/out" \
  && [[ "$cnf_sc" =~ ^claude=[0-9]+\ grok=[0-9]+\ agy=[0-9]+\ qwen=[0-9]+\ mistral=[0-9]+\ backup=[a-z]+$ ]] \
  && grep -q '^after tests:$' "$T/out" \
  && [[ "$(grep -c 'source=cnf' "$T/out")" -eq 2 ]] \
  && [[ "$(grep -c '^psql' "$T/calls.log")" -eq 5 ]] \
  && grep -q "DELETE FROM tenant_agent_split_kind" "$T/stdin" \
  && grep -q '^COMMIT;' "$T/stdin" \
  && ! grep -qiE '\b(insert|update|drop|truncate|alter)\b' "$T/stdin" \
  && ! grep -q 't1' "$T/stdin" \
  && [[ "$(grep -c '^proxy-start' "$T/calls.log")" -eq 1 ]] \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "3. DRY_RUN=0: before (workspace), one DELETE, after (cnf), one proxy, as $DEV_SA" \
  || fail "3. real: rc=$rc $(cat "$T/out") --- $(cat "$T/calls.log")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "3. the DSN password leaked" || pass "3. the DSN password is in neither output, argv nor SQL"
seq_out 1 $'agy|0|false\nclaude|50|true\ngrok|20|false\nmistral|30|false\nqwen|0|false'
seq_out 2 'ERROR: permission denied' 3
in_orc 'do_spl_agent_split_reset --kind tests' TENANT_ID=t1 DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL agent split reset of t1 kinds tests failed' "$T/out" && ! grep -q '^after' "$T/out" \
  && pass "3. a failed DELETE is a FATAL with no after line" || fail "3. delete fail: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
