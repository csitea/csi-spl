#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the demo post audit (spec 077 FR-011, T025; rdb 0131) outlives the
#          nightly wipe, and do_spl_demo_audit_purge drops only the rows older
#          than cnf env.demo.audit_retention_days. Part A stubs the cloud
#          (spl_via_proxy records its call); part B runs the SQL against a
#          REAL throwaway Postgres with the real rdb migrations, as a NON-owner
#          login so rdb 0014 row-level security binds (SKIP when no docker /
#          psql / cached postgres image).
#   A1. ENV must be dev or prd
#   A2. DRY_RUN defaults to 1 (the count path); the retention is the cnf's
#   A3. absent retention = 90; CONTROL: a retention that is not a whole
#       number of days >= 1 is refused before any DB call
#   A4. the purge runs with the demo off (the audit is kept either way)
#   B1. (077 T025 b) do_spl_demo_wipe's SQL deletes the demo messages and
#       leaves every audit row; CONTROL: the messages are gone
#   B2. the table is append-only: a plain UPDATE / DELETE as the runtime
#       login is refused
#   B3. dry run: counts the rows older than 90 days, deletes nothing
#   B4. (077 T025 d) the purge at 90 days drops exactly the two older demo
#       rows, keeps the newer ones and the other workspace's old row;
#       CONTROL: a purge at 88 days then drops the 89-day row too, and keeps
#       today's
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-demo-audit-purge.func.sh"
WIPE="$PROJ_ROOT/src/bash/run/spl-demo-wipe.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# A ---------------------------------------------------------------------------
# runa <enabled> <days|-> [VAR=val ...]: the action with the cloud stubbed;
# days - leaves the key out of the cnf
runa() {
  local on="$1" days="$2"; shift 2
  : >"$T/calls"
  printf 'env:\n  demo:\n    enabled: %s\n    workspace: demo\n' "$on" >"$T/cnf.yaml"
  [[ "$days" != - ]] && printf '    audit_retention_days: %s\n' "$days" >>"$T/cnf.yaml"
  env -u DRY_RUN FUNC="$FUNC" WIPE="$WIPE" T="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$WIPE"
    source "$FUNC"
    spl_via_proxy() { echo "proxy $DEMO_WS dry=$DEMO_DRY days=$DEMO_AUDIT_DAYS $*" >>"$T/calls"; echo 0 >"$2"; }
    do_spl_demo_audit_purge' >"$T/o" 2>"$T/e"
}

runa true 30 ENV=lde; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. ENV=lde refused before any DB call" || fail "A1. rc=$rc $(cat "$T/calls")"

runa true 30 ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy demo dry=1 days=30 _spl_demo_audit_purge_run' "$T/calls" &&
  grep -q '"dry_run":true,"retention_days":30,"older":0' "$T/o" &&
  pass "A2. DRY_RUN defaults to 1; the retention is cnf's 30" || fail "A2. rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"
runa true 30 ENV=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy demo dry=0 days=30 ' "$T/calls" && grep -q '"dry_run":false' "$T/o" &&
  pass "A2. DRY_RUN=0 is the delete path" || fail "A2. delete rc=$rc $(cat "$T/calls" "$T/o")"

runa true - ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q ' days=90 ' "$T/calls" && pass "A3. no cnf retention: 90 days" || fail "A3. rc=$rc $(cat "$T/calls" "$T/e")"
for bad in 0 -5 abc 1.5; do
  runa true "$bad" ENV=dev DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'audit_retention_days is not a whole number' "$T/e" &&
    pass "A3. CONTROL: retention '$bad' refused, no DB call" || fail "A3. '$bad' rc=$rc $(cat "$T/calls" "$T/e")"
done

runa false 30 ENV=prd DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy demo dry=0 days=30 ' "$T/calls" &&
  pass "A4. the demo off: the purge still runs" || fail "A4. rc=$rc $(cat "$T/calls" "$T/e")"

# B ---------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: part B, no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-demo-audit-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
rt() { PGPASSWORD=rt psql -X -q -v ON_ERROR_STOP=1 -At "$RT_DSN" -c "$1" 2>&1; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

# demo: a visitor's 3 posts; audit rows aged 100, 91, 89 and 0 days. t1: one
# 100-day row (another workspace's, never the demo purge's).
q "INSERT INTO humans (human_id) VALUES ('HUM-1'), ('HUM-2')" >/dev/null
for t in demo t1; do
  q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null
done
q "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
     ('demo', 'HUM-1', 'admin', 'operator'), ('demo', 'HUM-2', 'demo_user', 'operator')" >/dev/null
q "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at)
   SELECT 'demo', gen_random_uuid(), '00000000-0000-4000-8000-000000000001', 'lobby', now(),
          'box-wui', 'HUM-2', 'box-demo', 'c-001', 'note', 'm' || i, '{}'::jsonb, 'sig', '\\x00'::bytea, now() + interval '1 day'
     FROM generate_series(1, 3) AS i" >/dev/null
q "INSERT INTO demo_post_audit (tenant_id, at, action, human_id, pseudonym, provider, subject, email, msg_id, body)
   SELECT t, now() - make_interval(days => d), 'post', 'HUM-2', 'visitor-1', 'google', 's-1', 'v@example.com', gen_random_uuid(), 'prompt ' || d
     FROM (VALUES ('demo', 100), ('demo', 91), ('demo', 89), ('demo', 0), ('t1', 100)) AS v (t, d)" >/dev/null
audit() { q "SELECT coalesce(string_agg(body, ',' ORDER BY at), '') FROM demo_post_audit WHERE tenant_id = '$1'"; }

# B1: the nightly wipe, its own SQL, as the runtime login
env FUNC="$WIPE" DEMO_WS=demo DEMO_DRY=0 SPL_PROXY_DSN="$RT_DSN" bash -c '
  set -uo pipefail
  do_log() { echo "$*" >&2; }
  source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$FUNC"
  _spl_demo_wipe_run /dev/stdout' >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(q "SELECT count(*) FROM messages WHERE tenant_id = 'demo'")" == 0 ]] &&
  pass "B1. CONTROL: the wipe ran and deleted the demo messages" || fail "B1. wipe rc=$rc $(cat "$T/o")"
[[ "$(audit demo)" == "prompt 100,prompt 91,prompt 89,prompt 0" ]] &&
  pass "B1. the wipe left all 4 demo audit rows" || fail "B1. demo audit after the wipe: $(audit demo)"

# B2: append-only, even in the demo's own RLS scope
out="$(rt "BEGIN; SET LOCAL app.tenant_id = 'demo'; DELETE FROM demo_post_audit; COMMIT;")"
[[ "$out" == *"append-only: DELETE refused"* && "$(audit demo)" == "prompt 100,prompt 91,prompt 89,prompt 0" ]] &&
  pass "B2. a plain DELETE is refused" || fail "B2. delete: $out / $(audit demo)"
out="$(rt "BEGIN; SET LOCAL app.tenant_id = 'demo'; UPDATE demo_post_audit SET body = 'x'; COMMIT;")"
[[ "$out" == *"append-only: UPDATE refused"* ]] && pass "B2. an UPDATE is refused" || fail "B2. update: $out"

# runp <days> <dry>: the purge SQL path, through the real DB as the runtime login
runp() {
  env FUNC="$FUNC" DEMO_WS=demo DEMO_DRY="$2" DEMO_AUDIT_DAYS="$1" SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$FUNC"
    _spl_demo_audit_purge_run /dev/stdout' >"$T/o" 2>&1
}

runp 90 1; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 2 && "$(audit demo)" == "prompt 100,prompt 91,prompt 89,prompt 0" ]] &&
  pass "B3. dry run: 2 rows older than 90 days, nothing deleted" || fail "B3. rc=$rc $(cat "$T/o") / $(audit demo)"

runp 90 0; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 2 && "$(audit demo)" == "prompt 89,prompt 0" ]] &&
  pass "B4. the purge at 90 days dropped the 100- and 91-day rows, kept 89 and 0" ||
  fail "B4. rc=$rc $(cat "$T/o") / $(audit demo)"
[[ "$(audit t1)" == "prompt 100" ]] && pass "B4. the other workspace's old row is untouched" || fail "B4. t1: $(audit t1)"
runp 88 0; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 1 && "$(audit demo)" == "prompt 0" ]] &&
  pass "B4. CONTROL: at 88 days the 89-day row goes too, today's stays" || fail "B4. control rc=$rc $(cat "$T/o") / $(audit demo)"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
