#!/usr/bin/env bash
# SPL-2395 (SPL-2230 step 2): do_spl_db_cost_reinsert puts back deleted
# fleet_tokens cost lines, INSERTS ONLY, in one transaction. Against a REAL
# throwaway Postgres with the real migrations, as the runtime role, with a
# SYNTHETIC reinsert file in the shape SPL-2319 wrote (one statement per line:
# BEGIN, the operator SET, INSERT INTO cost_lines rows, UPDATE cost_lines ...
# WHERE id = N lines, COMMIT, '-- ' comments):
#   1. refused before any SQL: a planted DELETE, an extra UPDATE, an UPDATE of
#      another table, an INSERT into another table, a non fleet_tokens source,
#      a second statement on a line, ON CONFLICT, DDL, no REINSERT_FILE, a wrong
#      md5, a wrong REINSERT_EXPECT
#   2. DRY_RUN=1 (default) prints the plan and writes nothing
#   3. DRY_RUN=0 inserts exactly the rows, commits, and never runs the UPDATEs
#   4. a key already live is refused (the same file run twice), nothing written
#   5. a key twice in the file is refused
#   6. a count mismatch (a trigger swallows one row) rolls back
#   CONTROLS (a mutated copy of the action, each guard removed): the planted
#   line passes, the live-key REFUSED line is gone, the mismatch commits; and
#   DRY_RUN=0 does change the count the dry-run check reads.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the SQL part is not run"
  exit 0
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-cost-reinsert-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$HERE/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
# one live line the file's UPDATE targets (it must stay untouched), and one
# line of another source
psql_owner <<'PSQL' >/dev/null || fail "seed"
INSERT INTO cost_lines (id, day, source, project_or_vendor, agent_id, model, kind, units, amount_micros, currency,
                        usd_micros, eur_micros, fx_rate_day, origin, run_id) VALUES
  (900001, '2026-10-11', 'fleet_tokens.boxa', 'anthropic', 'c-001', 'm1', 'tokens_in', 7, 0, 'USD', 0, 0, '2026-10-11', 'transcript', 'r0'),
  (900002, '2026-10-11', 'gcp.billing', 'proj', NULL, NULL, 'compute', 1, 5, 'USD', 5, 4, '2026-10-11', 'billing_export', 'r0');
PSQL
count() { psql_owner -c "SET app.rls_scope = 'operator'" -c "SELECT count(*) FROM cost_lines" | tail -n 1; }
units_900001() { psql_owner -c "SET app.rls_scope = 'operator'" -c "SELECT units FROM cost_lines WHERE id = 900001" | tail -n 1; }

COLS="day, source, project_or_vendor, tenant_id, agent_id, model, kind, units, amount_micros, currency, usd_micros, eur_micros, fx_rate_day, list_value_micros, origin, run_id"
row() {  # <day> <agent> [source]
  echo "INSERT INTO cost_lines ($COLS) VALUES ('$1', '${3:-fleet_tokens.boxa}', 'anthropic', NULL, '$2', 'm1', 'tokens_in', '12', '0', 'USD', '0', '0', '$1', NULL, 'transcript', 'pitr-r1');"
}
good() {  # the synthetic file: 3 rows, 1 UPDATE (dropped), the frame lines
  echo "-- NOT RUN: synthetic reinsert file"
  echo "BEGIN;"
  echo "SET LOCAL app.rls_scope = 'operator';"
  echo "-- inserts"
  row 2026-10-10 c-101; row 2026-10-11 c-102; row 2026-10-12 "it''s-c-103"
  echo "-- updates"
  echo "UPDATE cost_lines SET units = '99', origin = 'transcript', run_id = 'pitr-r1' WHERE id = 900001 AND superseded_by IS NULL;"
  echo "COMMIT;"
}
good >"$T/good.sql"

run_act() {  # <action file> [VAR=value ...]
  local fn="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" ACT="$fn" RT_DSN="$RT_DSN" ENV=dev TMPDIR="$T" REINSERT_DROP_UPDATES=1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$ACT"
    do_require_bin() { :; }
    do_spl_cloud_cnf() { SPL_CNF=stub; }
    do_gcp_pin_account() { GCP_ACCOUNT=stub-sa@example.com; }
    do_gcp_require_live_account() { :; }
    spl_via_proxy() { echo PROXY >>"$TMPDIR/proxy.calls"; SPL_PROXY_DSN="$RT_DSN" "$@"; }
    do_spl_db_cost_reinsert' 2>&1
}
ACTION="$PROJ_ROOT/src/bash/run/spl-db-cost-reinsert.func.sh"
proxy_calls() { [[ -f "$T/proxy.calls" ]] && wc -l <"$T/proxy.calls" || echo 0; }

# 1. refused before any SQL
plant() {  # <name> <line> : the good file with one line added before COMMIT
  { good | sed '$d'; echo "$2"; echo "COMMIT;"; } >"$T/$1.sql"
}
plant delete "DELETE FROM cost_lines WHERE id = 900001;"
plant update_extra "UPDATE cost_lines SET units = '1', origin = 'transcript', run_id = 'x' WHERE id = 900002 AND superseded_by IS NULL;"
plant update_other "UPDATE cost_coverage SET state = 'ok' WHERE day = '2026-10-10';"
plant other_table "INSERT INTO cost_coverage (day, source, state, run_id) VALUES ('2026-10-10', 'fleet_tokens.boxa', 'ok', 'x');"
plant foreign_src "$(row 2026-10-13 c-104 gcp.billing)"
plant two_stmts "$(row 2026-10-13 c-104 | sed 's/);$/); DELETE FROM cost_lines WHERE (1 = 1);/')"
plant on_conflict "$(row 2026-10-13 c-104 | sed 's/;$/ ON CONFLICT DO NOTHING;/')"
plant ddl "ALTER TABLE cost_lines DISABLE ROW LEVEL SECURITY;"
plant subselect "$(row 2026-10-13 c-104 | sed "s/'12'/(SELECT count(*) FROM tenants)/")"
before="$(count)"
for p in delete update_extra update_other other_table foreign_src two_stmts on_conflict ddl subselect; do
  rm -f "$T/proxy.calls"
  out="$(run_act "$ACTION" REINSERT_FILE="$T/$p.sql" DRY_RUN=0)"; rc=$?
  if [[ $rc -ne 0 && "$(proxy_calls)" == 0 && "$out" == *"nothing run"* && "$(count)" == "$before" ]]; then
    pass "refused before any SQL: $p"
  else
    fail "planted $p: rc=$rc proxy=$(proxy_calls) $out"
  fi
done
grep -q "pitr-r1\|c-10[1-4]" <<<"$(run_act "$ACTION" REINSERT_FILE="$T/foreign_src.sql" DRY_RUN=0)" &&
  fail "a refusal printed a value of the file" || pass "a refusal prints no value of the file"
rm -f "$T/proxy.calls"
out="$(run_act "$ACTION" DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"REINSERT_FILE is required"* && "$(proxy_calls)" == 0 ]] && pass "no REINSERT_FILE: refused, no default path" || fail "no file: rc=$rc $out"
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql" REINSERT_MD5=00000000000000000000000000000000 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"md5 is"* && "$(proxy_calls)" == 0 ]] && pass "a wrong md5 is refused" || fail "md5: rc=$rc $out"
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql" REINSERT_EXPECT=2380 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"holds 3 rows, not REINSERT_EXPECT 2380"* && "$(proxy_calls)" == 0 ]] && pass "a wrong REINSERT_EXPECT is refused" || fail "expect: rc=$rc $out"
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql" REINSERT_DROP_UPDATES=0 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"1 UPDATE cost_lines lines, REINSERT_DROP_UPDATES says 0"* ]] && pass "an UPDATE not declared in REINSERT_DROP_UPDATES is refused" || fail "drop 0: rc=$rc $out"

# 2. DRY_RUN=1 (default) writes nothing
md5="$(md5sum "$T/good.sql" | cut -d' ' -f1)"
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql" REINSERT_MD5="$md5" REINSERT_EXPECT=3)"; rc=$?
[[ $rc -eq 0 && "$out" == *"would insert: rows=3 live_keys=0 dup_keys=0 foreign_src=0 cost_lines=2 fleet_tokens_lines=1"* && "$(count)" == 2 ]] &&
  pass "DRY_RUN=1 prints rows=3 live_keys=0 and the live counts, writes nothing" || fail "dry: rc=$rc count=$(count) $out"
leftover="$(find "$T" -maxdepth 1 -name 'spl-cost-reinsert.*' | wc -l)"
[[ "$leftover" == 0 ]] && pass "the temp SQL dir is removed" || fail "temp dir left: $leftover"

# 3. DRY_RUN=0 inserts exactly the rows and never runs the UPDATE
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql" REINSERT_MD5="$md5" REINSERT_EXPECT=3 DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *"COMMITTED cost_lines=2->5 fleet_tokens_lines=1->4"* && "$(count)" == 5 ]] &&
  pass "DRY_RUN=0 commits exactly 3 rows (2 -> 5)" || fail "run: rc=$rc count=$(count) $out"
[[ "$(units_900001)" == 7 ]] && pass "the dropped UPDATE was never run (units still 7)" || fail "UPDATE ran: units=$(units_900001)"

# 4. a key already live: the same file again
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql" DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"REFUSED rows=3 expect=3 live_keys=3"* && "$(count)" == 5 ]] &&
  pass "a key already live is refused, nothing written" || fail "live key: rc=$rc count=$(count) $out"
out="$(run_act "$ACTION" REINSERT_FILE="$T/good.sql")"; rc=$?
[[ $rc -ne 0 && "$out" == *"live_keys=3"* && "$(count)" == 5 ]] && pass "DRY_RUN=1 reports the live keys and fails" || fail "dry live: rc=$rc $out"

# 5. a key twice in the file
{ row 2026-10-14 c-105; row 2026-10-14 c-105; } >"$T/dup.sql"
out="$(run_act "$ACTION" REINSERT_FILE="$T/dup.sql" REINSERT_DROP_UPDATES=0 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"dup_keys=1"* && "$(count)" == 5 ]] && pass "a key twice in the file is refused" || fail "dup: rc=$rc $out"

# 6. a count mismatch rolls back: a trigger swallows the c-107 row
psql_owner <<'PSQL' >/dev/null || fail "trigger"
CREATE FUNCTION test_swallow() RETURNS trigger LANGUAGE plpgsql AS
  $$ BEGIN IF NEW.agent_id = 'c-107' THEN RETURN NULL; END IF; RETURN NEW; END $$;
CREATE TRIGGER test_swallow BEFORE INSERT ON cost_lines FOR EACH ROW EXECUTE FUNCTION test_swallow();
PSQL
{ row 2026-10-15 c-106; row 2026-10-15 c-107; } >"$T/mismatch.sql"
out="$(run_act "$ACTION" REINSERT_FILE="$T/mismatch.sql" REINSERT_DROP_UPDATES=0 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"ROLLED_BACK cost_lines=5->6"* && "$(count)" == 5 ]] &&
  pass "a delta of 1 for 2 rows rolls back" || fail "mismatch: rc=$rc count=$(count) $out"

# CONTROLS: each guard removed in a copy of the action
mutate() {  # <name> <python old> <python new>
  python3 -I -c 'import sys; s=open(sys.argv[1]).read(); assert sys.argv[3] in s, sys.argv[3]; open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))' \
    "$ACTION" "$T/mut-$1.sh" "$2" "$3"
}
mutate planted 'refuse(n, line, "not an INSERT' 'continue; refuse(n, line, "not an INSERT'
out="$(run_act "$T/mut-planted.sh" REINSERT_FILE="$T/delete.sql")"
[[ "$out" != *"nothing run"* ]] && pass "CONTROL: without the line check the planted DELETE file is accepted" || fail "control planted: $out"
mutate live ':live_keys = 0 AND' 'true AND'
out="$(run_act "$T/mut-live.sh" REINSERT_FILE="$T/good.sql" DRY_RUN=0)"
[[ "$out" != *"REFUSED rows=3"* && "$(count)" == 5 ]] && pass "CONTROL: without the live-key check the REFUSED line is gone (the unique index still stops it)" || fail "control live: $out"
mutate delta '(:after_all - :before_all = :expect)' 'true'
out="$(run_act "$T/mut-delta.sh" REINSERT_FILE="$T/mismatch.sql" REINSERT_DROP_UPDATES=0 DRY_RUN=0)"
[[ "$out" == *COMMITTED* && "$(count)" == 6 ]] && pass "CONTROL: without the delta check the mismatch commits (5 -> 6)" || fail "control delta: count=$(count) $out"
{ row 2026-10-16 c-108; } >"$T/one.sql"
run_act "$ACTION" REINSERT_FILE="$T/one.sql" REINSERT_DROP_UPDATES=0 >/dev/null
c1="$(count)"; run_act "$ACTION" REINSERT_FILE="$T/one.sql" REINSERT_DROP_UPDATES=0 DRY_RUN=0 >/dev/null
[[ "$c1" == 6 && "$(count)" == 7 ]] && pass "CONTROL: the count the dry-run check reads moves on DRY_RUN=0 (6 -> 7)" || fail "control dry: $c1 -> $(count)"

echo "spl-db-cost-reinsert: $fails failure(s)"
exit $((fails > 0))
