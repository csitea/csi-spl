#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_goals_backfill_db (spec 112 8.2, ORC-3, the read half).
#          Part A stubs the cloud (spl_via_proxy records its call); part B
#          runs the action's SQL against a REAL throwaway Postgres with the
#          real rdb migrations, as a NON-owner login so rdb 0014 row-level
#          security binds (SKIP when no docker / psql / cached postgres image).
#   A1. no WORKSPACE: refused with "WORKSPACE must be set (no default)",
#       before any DB call; a non-slug WORKSPACE and ENV=lde are refused too
#   A2. no APPROVER_ROLE and no cnf env.roadmap.approver_role: refused;
#       CONTROL: the cnf key alone is enough
#   A3. the output dir must sit under $HOME; a bad SINCE is refused
#   A4. the SQL: BEGIN TRANSACTION READ ONLY + SET LOCAL app.tenant_id, no
#       rls_scope, and the output file is 0600 in a 0700 dir under $HOME
#   B1. two workspaces seeded; run in A as the runtime login: the output
#       holds A's owner decision / drill / launch candidates and none of B's
#       topic ids; a non-approver's "yes" and owner chatter are not
#       candidates; an owner's "go" typed through a box is
#   B2. quote: <= 140 chars, one line, no tab; no other message text
#   B3. CONTROL: B's rows exist, counted as the operator; the same count in
#       A's tenant scope is 0
#   B4. CONTROL: run as a login that bypasses RLS (the superuser): refused,
#       nothing written
#   B5. SINCE: only the messages after it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-goals-backfill-db.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/home"

# A ---------------------------------------------------------------------------
# runa <cnf-role|-> [VAR=val ...]: the action with the cloud stubbed; - leaves
# env.roadmap out of the cnf. The stub proxy writes one fake candidate.
runa() {
  local role="$1"; shift
  : >"$T/calls"
  printf 'env:\n  gcp:\n    project: x\n' >"$T/cnf.yaml"
  [[ "$role" != - ]] && printf '  roadmap:\n    approver_role: %s\n' "$role" >>"$T/cnf.yaml"
  env -u WORKSPACE -u APPROVER_ROLE -u SINCE -u GOALS_BACKFILL_DIR HOME="$T/home" FUNC="$FUNC" T="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { echo "proxy $*" >>"$T/calls"; printf "topic_id\tmsg_id\tts\tkind\tquote\nt\tm\tts\tdecision\tgo\n" >"$2"; }
    do_spl_goals_backfill_db' >"$T/o" 2>"$T/e"
}

runa admin ENV=dev; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'WORKSPACE must be set (no default)' "$T/e" &&
  pass "A1. no WORKSPACE: refused before any DB call" || fail "A1. rc=$rc $(cat "$T/calls" "$T/e")"
runa admin ENV=dev WORKSPACE='T1;x'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. a non-slug WORKSPACE is refused" || fail "A1. slug rc=$rc $(cat "$T/calls")"
runa admin ENV=lde WORKSPACE=ta; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. ENV=lde is refused" || fail "A1. lde rc=$rc $(cat "$T/calls")"

runa - ENV=dev WORKSPACE=ta; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'approver_role must be an rbac role id' "$T/e" &&
  pass "A2. no approver role anywhere: refused, no DB call" || fail "A2. rc=$rc $(cat "$T/calls" "$T/e")"
runa admin ENV=dev WORKSPACE=ta; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy _spl_goals_backfill_db_run .* ta admin 1970-01-01T00:00:00Z$' "$T/calls" &&
  pass "A2. CONTROL: the cnf approver role is used" || fail "A2. cnf rc=$rc $(cat "$T/calls" "$T/e")"
runa admin ENV=dev WORKSPACE=ta APPROVER_ROLE=biz_owner; rc=$?
[[ $rc -eq 0 ]] && grep -q ' ta biz_owner ' "$T/calls" && pass "A2. APPROVER_ROLE overrides the cnf" || fail "A2. env rc=$rc $(cat "$T/calls")"

runa admin ENV=dev WORKSPACE=ta GOALS_BACKFILL_DIR="$T/outside"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'must be under \$HOME' "$T/e" &&
  pass "A3. an output dir outside \$HOME is refused" || fail "A3. rc=$rc $(cat "$T/calls" "$T/e")"
runa admin ENV=dev WORKSPACE=ta SINCE=yesterday; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A3. a bad SINCE is refused" || fail "A3. since rc=$rc $(cat "$T/calls")"

runa admin ENV=dev WORKSPACE=ta; rc=$?
f=$(compgen -G "$T/home/.csi-spl/goals-backfill/db-candidates-dev-ta-*.tsv")
[[ $rc -eq 0 && -n "$f" ]] && grep -q "OK 1 backfill candidate(s) of workspace ta in dev" "$T/e" && ! grep -q 'decision' "$T/e" &&
  pass "A4. the file is under \$HOME, the log names the count and no quote" || fail "A4. rc=$rc f=$f $(cat "$T/e")"
sql=$(bash -c 'source "$1"; spl_goals_backfill_db_sql' _ "$FUNC")
[[ "$(sed -n 1p <<<"$sql")" == "BEGIN TRANSACTION READ ONLY;" && "$(sed -n 2p <<<"$sql")" == "SET LOCAL app.tenant_id = :'ws';" ]] &&
  ! grep -q rls_scope <<<"$sql" && ! grep -q "app.rls_scope" "$FUNC" &&
  pass "A4. the SQL is READ ONLY + SET LOCAL app.tenant_id, no rls_scope" || fail "A4. sql: $(head -3 <<<"$sql")"

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
PG_CTR="spl-goals-backfill-pg-$$"
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

# ta: HUM-1 admin (the approver), HUM-3 developer. tb: HUM-2 admin, HUM-1 admin.
TA1=aaaaaaaa-0000-4000-8000-000000000001 TA2=aaaaaaaa-0000-4000-8000-000000000002
TB1=bbbbbbbb-0000-4000-8000-000000000001 TB2=bbbbbbbb-0000-4000-8000-000000000002
q "INSERT INTO humans (human_id) VALUES ('HUM-1'), ('HUM-2'), ('HUM-3')" >/dev/null
for t in ta tb; do q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null; done
q "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
     ('ta', 'HUM-1', 'admin', 'operator'), ('ta', 'HUM-3', 'developer', 'operator'),
     ('tb', 'HUM-2', 'admin', 'operator'), ('tb', 'HUM-1', 'admin', 'operator')" >/dev/null
LONG="launched the relay in prd"$'\t'"today"$'\n'"$(printf 'x%.0s' $(seq 1 200))"
ins() { # <tenant> <msg_id> <task_id> <ts> <from_id> <typed_by|NULL> <body>
  q "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at, typed_by)
     VALUES ('$1', '$2', '$3', 'lobby', '$4', 'box-wui', '$5', 'box-a', 'c-001', 'note', \$b\$$7\$b\$, '{}'::jsonb, 'sig', '\\x00'::bytea, now() + interval '1 day', $6)" >/dev/null
}
ins ta 10000000-0000-4000-8000-000000000001 "$TA1" 2026-10-01T10:00:00Z HUM-1 NULL "go, ship it"
ins ta 10000000-0000-4000-8000-000000000002 "$TA1" 2026-10-01T11:00:00Z HUM-1 NULL "the failover drill passed"
ins ta 10000000-0000-4000-8000-000000000003 "$TA2" 2026-10-02T10:00:00Z HUM-1 NULL "$LONG"
ins ta 10000000-0000-4000-8000-000000000004 "$TA2" 2026-10-02T11:00:00Z HUM-1 NULL "how is the weather"
ins ta 10000000-0000-4000-8000-000000000005 "$TA2" 2026-10-02T12:00:00Z HUM-3 NULL "yes, approved"
ins ta 10000000-0000-4000-8000-000000000006 "$TA2" 2026-10-03T10:00:00Z c-002 "'HUM-1'" "yes, do it"
ins tb 20000000-0000-4000-8000-000000000001 "$TB1" 2026-10-01T10:00:00Z HUM-2 NULL "go"
ins tb 20000000-0000-4000-8000-000000000002 "$TB2" 2026-10-01T12:00:00Z HUM-1 NULL "yes, the drill and the launch"

# runb <dsn> [SINCE]: the action's SQL path on a real DB, workspace ta, role admin
runb() {
  rm -f "$T/out.tsv"
  env FUNC="$FUNC" SPL_PROXY_DSN="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$FUNC"
    _spl_goals_backfill_db_run "$1" ta admin "$2"' _ "$T/out.tsv" "${2:-1970-01-01T00:00:00Z}" >"$T/o" 2>&1
}
col() { tail -n +2 "$T/out.tsv" | cut -f"$1" | paste -sd, -; }

runb "$RT_DSN"; rc=$?
[[ $rc -eq 0 && "$(head -1 "$T/out.tsv")" == $'topic_id\tmsg_id\tts\tkind\tquote' ]] &&
  pass "B1. ran in ta as the runtime login, header written" || fail "B1. rc=$rc $(cat "$T/o")"
[[ "$(col 2)" == 10000000-0000-4000-8000-000000000001,10000000-0000-4000-8000-000000000002,10000000-0000-4000-8000-000000000003,10000000-0000-4000-8000-000000000006 ]] &&
  pass "B1. candidates: the owner's go, drill, launch and box-typed yes" || fail "B1. msg ids: $(col 2)"
[[ "$(col 4)" == decision,drill,launch,decision ]] && pass "B1. kinds decision,drill,launch,decision" || fail "B1. kinds: $(col 4)"
[[ "$(col 3)" == 2026-10-01T10:00:00Z,* ]] && pass "B1. ts is UTC ISO-8601" || fail "B1. ts: $(col 3)"
grep -qE "$TB1|$TB2|20000000-" "$T/out.tsv" && fail "B1. B's ids leaked: $(cat "$T/out.tsv")" || pass "B1. the output holds none of B's topic ids"
grep -q -- '-000000000004\|-000000000005' "$T/out.tsv" && fail "B1. chatter / non-approver listed" || pass "B1. owner chatter and a non-approver's yes are not candidates"
st=$(stat -c '%a' "$T/out.tsv")
[[ "$st" == 600 ]] && pass "B1. the file is 0600" || fail "B1. mode $st"

q3=$(awk -F'\t' 'NR==4 {print $5}' "$T/out.tsv")
[[ ${#q3} -le 140 && ${#q3} -ge 100 && "$q3" == "launched the relay in prd today xxx"* && $(wc -l <"$T/out.tsv") -eq 5 ]] &&
  awk -F'\t' 'NR>1 && NF!=5 {bad=1} END {exit bad}' "$T/out.tsv" &&
  pass "B2. the quote is <= 140 chars, one line, whitespace folded" || fail "B2. quote(${#q3}): $q3"

ob=$(rt "BEGIN; SET LOCAL app.rls_scope = 'operator'; SELECT count(*) FROM messages WHERE tenant_id = 'tb'; COMMIT;")
ab=$(rt "BEGIN; SET LOCAL app.tenant_id = 'ta'; SELECT count(*) FROM messages WHERE tenant_id = 'tb'; COMMIT;")
[[ "$ob" == 2 && "$ab" == 0 ]] && pass "B3. CONTROL: B's 2 rows exist as the operator, 0 in A's tenant scope" || fail "B3. operator=$ob tenant=$ab"

runb "$OWNER_DSN"; rc=$?
[[ $rc -ne 0 && ! -e "$T/out.tsv" ]] && grep -q 'bypasses row-level security: refused' "$T/o" &&
  pass "B4. CONTROL: a superuser login is refused, nothing written" || fail "B4. rc=$rc $(cat "$T/o")"

runb "$RT_DSN" 2026-10-02T00:00:00Z; rc=$?
[[ $rc -eq 0 && "$(col 2)" == 10000000-0000-4000-8000-000000000003,10000000-0000-4000-8000-000000000006 ]] &&
  pass "B5. SINCE: only the later candidates" || fail "B5. rc=$rc $(col 2) $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
