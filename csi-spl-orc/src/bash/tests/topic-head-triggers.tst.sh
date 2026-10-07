#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_head_triggers (spec 099 T006, rollback level 2) with
#          curl, psql and every cloud call stubbed. The real-Postgres run is
#          topic-head-pg.tst.sh.
#   1. a bad OP / DRY_RUN is refused before anything is called
#   2. it REFUSES unless GET /version reports topic_heads "off": "shadow",
#      "on", an absent field, non-JSON and a failed curl all stop it before
#      any DB call; the URL is https://<cnf env.dns.api_fqdn>/version
#   3. DRY_RUN=1 (default): the check, then the plan; no DB call
#   4. OP=disable: one transaction as the OWNER DSN, lock_timeout 5s, the four
#      triggers disabled and the backfill marks deleted
#   5. OP=enable: the four enabled, then the REBUILD=all chunk loop
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

printf 'env:\n  dns:\n    api_fqdn: api.dev.example.net\n' >"$T/cnf.yaml"
mkdir -p "$T/stub"
cat >"$T/stub/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
[ -n "${CURL_RC:-}" ] && { echo "curl: (6) could not resolve"; exit "$CURL_RC"; }
printf '%s' "$CURL_OUT"
STUB
chmod +x "$T/stub/curl"
STUBS='do_spl_cloud_cnf() { SPL_CNF="$CNF"; SPL_DB_NAME=spool_hub; SPL_OWNER_DSN_SECRET=owner-dsn; SPL_PROJECT=p; }
do_gcp_pin_account() { echo "REACHED-CLOUD"; GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }
spl_read_dsn() { echo "READ-DSN $1" >>"$STUB_LOG"; echo "postgres://owner:pw@/db?host=/cloudsql/x"; }
spl_sql_proxy_start() { echo "PROXY-START" >>"$STUB_LOG"; SPL_PROXY_PORT=5999; }
spl_sql_proxy_stop() { echo "PROXY-STOP" >>"$STUB_LOG"; }
spl_local_dsn() { echo "postgres://owner:pw@127.0.0.1:$2/db"; }
spl_pg_env() { echo "PSQL-DSN $1" >>"$STUB_LOG"; shift; local n line; n=$(( $(cat "$PG_N" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$PG_N"
  { echo "PSQL#$n $*"; cat; } >>"$SQL_LOG"; line="$(sed -n "${n}p" "$PG_SEQ")"; printf "%s\n" "$line"; }'
run() { # [VAR=value]...
  rm -f "$T/n"; : >"$T/sql.log"; : >"$T/calls.log"
  SNIPPET="$STUBS; do_spl_topic_head_triggers" in_orc CNF="$T/cnf.yaml" SQL_LOG="$T/sql.log" PG_N="$T/n" PG_SEQ="$T/seq" \
    SPL_TH_RETRY_SLEEP=0 "$@" 2>&1
}
OFF='{"commit":"abc","topic_heads":"off"}'

# 1 --------------------------------------------------------------------------
for g in "OP=|OP must be disable or enable" "OP=drop|OP must be disable or enable" "OP=disable DRY_RUN=yes|DRY_RUN must be 0 or 1"; do
  # shellcheck disable=SC2086 # the case's VAR=value words
  out="$(run ${g%%|*} CURL_OUT="$OFF")"; rc=$?
  [[ $rc -ne 0 ]] && grep -q "${g#*|}" <<<"$out" && ! grep -q 'curl\|PSQL' "$T/calls.log" \
    && pass "1. '${g%%|*}' is refused before any call" || fail "1. ${g%%|*}: rc=$rc $out $(cat "$T/calls.log")"
done

# 2 --------------------------------------------------------------------------
for v in '{"topic_heads":"shadow"}|shadow' '{"topic_heads":"on"}|on' '{"commit":"abc"}|<absent>' 'not json|' ; do
  out="$(run OP=disable DRY_RUN=0 CURL_OUT="${v%%|*}")"; rc=$?
  [[ $rc -ne 0 ]] && grep -qE "refused: .* topic_heads='${v#*|}'|is not JSON" <<<"$out" \
    && ! grep -q REACHED-CLOUD <<<"$out" && ! grep -q PSQL "$T/calls.log" \
    && pass "2. /version '${v%%|*}' is refused before any DB call" || fail "2. ${v%%|*}: rc=$rc $out"
done
out="$(run OP=enable DRY_RUN=0 CURL_RC=6)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL GET https://api.dev.example.net/version failed' <<<"$out" && ! grep -q PSQL "$T/calls.log" \
  && pass "2. an unreachable hub is refused" || fail "2. curl fail: rc=$rc $out"
grep -q 'curl .*--max-time 15 .*https://api.dev.example.net/version' "$T/calls.log" \
  && pass "2. the URL is the cnf api_fqdn's /version, time-bounded" || fail "2. url: $(cat "$T/calls.log")"

# 3 --------------------------------------------------------------------------
out="$(run OP=disable CURL_OUT="$OFF")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would: .*disable the 4 topic_head triggers' <<<"$out" && ! grep -q 'REACHED-CLOUD' <<<"$out" \
  && ! grep -q PSQL "$T/calls.log" && pass "3. DRY_RUN=1 checks /version, plans, and touches no DB" || fail "3. rc=$rc $out"

# 4 --------------------------------------------------------------------------
printf 'topic_head_apply=D topic_head_mark_del=D topic_head_mark_ins=D topic_head_mark_upd=D\n' >"$T/seq"
out="$(run OP=disable DRY_RUN=0 CURL_OUT="$OFF")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK dev topic_head triggers disabled: topic_head_apply=D' <<<"$out" \
  && pass "4. disable runs and prints the trigger states" || fail "4. rc=$rc $out"
grep -q 'READ-DSN owner' "$T/calls.log" && grep -q 'PSQL-DSN postgres://owner:pw@127.0.0.1:5999/db' "$T/calls.log" \
  && grep -q PROXY-STOP "$T/calls.log" && pass "4. ...as the OWNER DSN through the proxy, stopped after" || fail "4. dsn: $(cat "$T/calls.log")"
for t in mark_ins mark_upd mark_del apply; do
  grep -q "DISABLE TRIGGER topic_head_$t" "$T/sql.log" || fail "4. topic_head_$t not disabled"
done
[[ "$(grep -c '^BEGIN;' "$T/sql.log")" == 1 ]] && grep -q "SET LOCAL lock_timeout = '5s'" "$T/sql.log" \
  && grep -q '^DELETE FROM topic_head_tenants;' "$T/sql.log" && ! grep -q 'topic_head_backfill' "$T/sql.log" \
  && pass "4. one transaction: 4 triggers off + the marks deleted, no backfill" || fail "4. SQL: $(cat "$T/sql.log")"

# 5 --------------------------------------------------------------------------
printf 'topic_head_apply=O topic_head_mark_del=O topic_head_mark_ins=O topic_head_mark_upd=O\n7 t1/aaaaaaaa-0000-4000-8000-000000000001\n0 \n' >"$T/seq"
out="$(run OP=enable DRY_RUN=0 CURL_OUT="$OFF")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'triggers enabled: topic_head_apply=O' <<<"$out" && grep -q 'chunks=2 topics=7 rebuild_all=true' <<<"$out" \
  && pass "5. enable turns the 4 on, then backfills with REBUILD=all to the empty chunk" || fail "5. rc=$rc $out"
grep -q 'ENABLE TRIGGER topic_head_apply' "$T/sql.log" && ! grep -q 'DELETE FROM topic_head_tenants' "$T/sql.log" \
  && grep -q -- '-v all=true' "$T/sql.log" && pass "5. ...ENABLE, no mark delete, all=true" || fail "5. SQL: $(cat "$T/sql.log")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
