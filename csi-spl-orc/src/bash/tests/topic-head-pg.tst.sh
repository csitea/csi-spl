#!/usr/bin/env bash
# The topic-head actions (spec 099 T006) against a REAL throwaway Postgres
# (postgres:16-alpine) carrying the real rdb migrations, 0144 included. The
# backfill and the verify run as the NON-owner runtime login, so RLS binds
# (the operator scope is theirs to set); the triggers action runs as the
# owner, as in the cloud. Their stubbed cases are topic-head-*.tst.sh.
#
#   1. heads wiped (a pre-0144 DB): verify exits 1 and names the topics
#   2. the backfill in chunks of 2 rebuilds them and marks every tenant;
#      verify then exits 0
#   3. an orphan head (its topic's rows gone with the triggers off): a plain
#      backfill keeps it, REBUILD=all deletes it
#   4. OP=disable: the 4 triggers off, the marks gone; a send leaves the heads
#      stale (verify exits 1). OP=enable: on again, REBUILD=all, verify 0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no cached $PG_IMAGE image; $(basename "$0") is not run"; exit 0
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-topic-head-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
[[ "$(psql_owner -c "SELECT count(*) FROM spool_schema_migrations WHERE filename LIKE '%topic_heads.sql'")" == 1 ]] \
  || { fail "rdb 0144 topic_heads is not applied"; exit 1; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

row() { # tenant msg task
  psql_owner -c "INSERT INTO messages (tenant_id,msg_id,task_id,is_parent,ts,from_box,from_id,to_box,to_id,kind,body,msg,env_sig,env,expires_at)
    VALUES ('$1','$2','$3',0,now(),'box-a','ORC-1','box-a','ORC-2','note','x','{}'::jsonb,'sig','\\x00',now()+interval '30 days')" >/dev/null
}
for t in t1 t2; do
  psql_owner -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab',32),'hex'))" >/dev/null
done
for i in 1 2 3 4 5; do
  row t1 "aaaaaaaa-0000-4000-8000-00000000010$i" "aaaaaaaa-0000-4000-8000-00000000000$i"
  row t1 "aaaaaaaa-0000-4000-8000-00000000020$i" "aaaaaaaa-0000-4000-8000-00000000000$i"
done
row t2 bbbbbbbb-0000-4000-8000-000000000101 bbbbbbbb-0000-4000-8000-000000000001
row t2 bbbbbbbb-0000-4000-8000-000000000102 bbbbbbbb-0000-4000-8000-000000000002

# act <function> [VAR=value]... -> the action's DB half, its DSN in SPL_PROXY_DSN
act() {
  local fn="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com SPL_PROXY_DSN="$RT_DSN" \
    SPL_TH_CHUNK=2 SPL_TH_ALL=false SPL_TH_RETRY_SLEEP=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    for f in "$PROJ_PATH"/src/bash/run/spl-topic-head-*.func.sh; do source "$f"; done
    '"$fn" >"$T/out" 2>&1
}
heads() { psql_owner -c "SELECT count(*) FROM topic_heads"; }

[[ "$(heads)" == 7 ]] && pass "0. the triggers wrote 7 heads for 7 topics" || fail "0. heads=$(heads)"
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 0 ]] && grep -q 'topics=7 tenants=2 marked=0 mismatches=0' "$T/out" \
  && pass "0. verify as the runtime login: 7 topics, 0 mismatches" || fail "0. verify: rc=$rc $(cat "$T/out")"

# 1 --------------------------------------------------------------------------
psql_owner -c "DELETE FROM topic_head_parts; DELETE FROM topic_heads" >/dev/null
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 1 ]] && grep -q 'mismatches=7' "$T/out" && grep -q '^t2 bbbbbbbb-0000-4000-8000-000000000001 missing head' "$T/out" \
  && pass "1. heads wiped: verify exits 1 and names the 7 topics" || fail "1. rc=$rc $(cat "$T/out")"

# 2 --------------------------------------------------------------------------
act _spl_topic_head_backfill_dry SPL_TH_ALL=false; rc=$?
[[ $rc -eq 0 ]] && grep -q 'would pass topics=7 heads=0 tenants=2 marked=0' "$T/out" && [[ "$(heads)" == 0 ]] \
  && pass "2. the dry run counts 7 topics and writes nothing" || fail "2. dry: rc=$rc $(cat "$T/out") heads=$(heads)"
act _spl_topic_head_backfill_run; rc=$?
[[ $rc -eq 0 ]] && grep -q 'backfill done: chunks=5 topics=7 rebuild_all=false' "$T/out" \
  && pass "2. the backfill, chunk 2: 4 chunks + the empty one, 7 topics" || fail "2. rc=$rc $(cat "$T/out")"
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 0 ]] && grep -q 'topics=7 tenants=2 marked=2 mismatches=0' "$T/out" \
  && pass "2. ...then verify: 0 mismatches, both tenants marked" || fail "2. verify: rc=$rc $(cat "$T/out")"

# 3 --------------------------------------------------------------------------
psql_owner -c "ALTER TABLE messages DISABLE TRIGGER USER" -c "DELETE FROM messages WHERE task_id='bbbbbbbb-0000-4000-8000-000000000002'" \
  -c "ALTER TABLE messages ENABLE TRIGGER USER" >/dev/null
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 1 ]] && grep -q 'bbbbbbbb-0000-4000-8000-000000000002 orphan head' "$T/out" \
  && pass "3. a head whose rows are gone: verify names the orphan" || fail "3. rc=$rc $(cat "$T/out")"
act _spl_topic_head_backfill_run; act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 1 ]] && grep -q 'orphan head' "$T/out" && pass "3. CONTROL: a plain backfill keeps the orphan" || fail "3. plain: rc=$rc $(cat "$T/out")"
act _spl_topic_head_backfill_run SPL_TH_ALL=true; rc=$?
[[ $rc -eq 0 ]] && grep -q 'topics=7 rebuild_all=true' "$T/out" && pass "3. REBUILD=all walks the 6 topics + the orphan head" || fail "3. all: rc=$rc $(cat "$T/out")"
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 0 ]] && grep -q 'topics=6 .*mismatches=0' "$T/out" && pass "3. ...and deletes it: verify 0" || fail "3. verify: rc=$rc $(cat "$T/out")"

# 4 --------------------------------------------------------------------------
act _spl_topic_head_triggers_run SPL_PROXY_DSN="$OWNER_DSN" SPL_TH_OP=disable; rc=$?
[[ $rc -eq 0 ]] && grep -q 'triggers disabled: topic_head_apply=D topic_head_mark_del=D topic_head_mark_ins=D topic_head_mark_upd=D' "$T/out" \
  && [[ "$(psql_owner -c "SELECT count(*) FROM topic_head_tenants")" == 0 ]] \
  && pass "4. OP=disable: the 4 triggers off, the marks deleted" || fail "4. disable: rc=$rc $(cat "$T/out")"
row t1 aaaaaaaa-0000-4000-8000-000000000301 aaaaaaaa-0000-4000-8000-000000000003
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 1 ]] && grep -q 'mismatches=1' "$T/out" && pass "4. a send with the triggers off leaves its head stale: verify 1" || fail "4. stale: rc=$rc $(cat "$T/out")"
act _spl_topic_head_triggers_run SPL_PROXY_DSN="$OWNER_DSN" SPL_TH_OP=enable; rc=$?
[[ $rc -eq 0 ]] && grep -q 'triggers enabled: topic_head_apply=O topic_head_mark_del=O topic_head_mark_ins=O topic_head_mark_upd=O' "$T/out" \
  && grep -q 'topics=6 rebuild_all=true' "$T/out" && pass "4. OP=enable: on again, then the REBUILD=all backfill" || fail "4. enable: rc=$rc $(cat "$T/out")"
act _spl_topic_head_verify_run; rc=$?
[[ $rc -eq 0 ]] && grep -q 'marked=2 mismatches=0' "$T/out" && pass "4. ...verify 0, both tenants marked again" || fail "4. verify: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
