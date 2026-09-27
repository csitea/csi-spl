#!/usr/bin/env bash
# Hub Postgres gate (specs/003 T021, T001b): start a throwaway Postgres in a
# temp dir, run `spool migrate` twice (the second run must be a no-op), run the
# internal/store, hub and auth suites against it under -race (016 T002), then
# drive the M1 demo end to end
# with the real binary: serve, two boxes, cross-box send/recv, queued delivery,
# hub-down pending + flush.
# Postgres comes from local server binaries (initdb) when installed, else from
# a locally CACHED docker image (never pulled); with neither it skips (exit 0).
# Usage: bash csi-spl-api/src/bash/tests/hub-pg.tst.sh
set -euo pipefail

export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
MOD="$HERE/../../go/spool-hub-api"
SQL_DIR="$(cd "$HERE/../../../../csi-spl-rdb/src/sql/postgres/spool-hub" && pwd)"
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"

WORK="$(mktemp -d)"
PGDATA="$WORK/pgdata"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)}"
PG_CTR=""
HUB_PID=""
cleanup() {
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null || true
  [ -x "${PG_BIN:-/nonexistent}/pg_ctl" ] && "$PG_BIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  [ -n "$PG_CTR" ] && docker rm -fv "$PG_CTR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ -n "$PG_BIN" ] && [ -x "$PG_BIN/initdb" ]; then
  PGPORT="$(( 20000 + RANDOM % 20000 ))"
  "$PG_BIN/initdb" -D "$PGDATA" -U spool -A trust >/dev/null
  "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$WORK/pg.log" -w \
    -o "-k $WORK -p $PGPORT -c listen_addresses=''" start >/dev/null
  "$PG_BIN/createdb" -h "$WORK" -p "$PGPORT" -U spool spool_hub
  DSN="postgres://spool@/spool_hub?host=$WORK&port=$PGPORT&sslmode=disable"
  echo "ok   - temp Postgres up (local $("$PG_BIN/initdb" --version))"
elif command -v docker >/dev/null && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  PG_CTR="spool-hub-pg-test-$$"
  docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool \
    -e POSTGRES_PASSWORD=spool -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
  PGPORT="$(docker port "$PG_CTR" 5432 | head -1 | sed 's/.*://')"
  for _ in $(seq 1 60); do
    docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break
    sleep 0.5
  done
  DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
  echo "ok   - temp Postgres up (docker $PG_IMAGE)"
else
  echo "skip - no Postgres server binaries and no cached $PG_IMAGE image; hub Postgres gate not run"
  exit 0
fi

# 017 FR-SEC-013: everything below runs as APP_ROLE, a plain LOGIN role
# that OWNS its databases (so it owns the tables `spool migrate` creates),
# the Cloud SQL hub shape. The bootstrap role above is a superuser, and a
# superuser skips every row level security policy (rdb 0014).
APP_ROLE=spool_app
su_sql() {
  if [ -n "$PG_CTR" ]; then docker exec -i "$PG_CTR" psql -q -v ON_ERROR_STOP=1 -U spool -d spool_hub -c "$1"
  else "$PG_BIN/psql" -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PGPORT" -U spool -d spool_hub -c "$1"; fi
}
# CREATEROLE like the Cloud SQL API user that owns the schema there (017
# T029): the owner creates the runtime role below.
su_sql "CREATE ROLE $APP_ROLE LOGIN PASSWORD '$APP_ROLE' NOSUPERUSER NOBYPASSRLS CREATEROLE" >/dev/null
app_dsn() { # <db>
  if [ -n "$PG_CTR" ]; then echo "postgres://$APP_ROLE:$APP_ROLE@127.0.0.1:$PGPORT/$1?sslmode=disable"
  else echo "postgres://$APP_ROLE@/$1?host=$WORK&port=$PGPORT&sslmode=disable"; fi
}
mkdb() { # <db>: owned by APP_ROLE
  if [ -n "$PG_CTR" ]; then docker exec "$PG_CTR" createdb -U spool -O "$APP_ROLE" "$1"
  else "$PG_BIN/createdb" -h "$WORK" -p "$PGPORT" -U spool -O "$APP_ROLE" "$1"; fi
}
mkdb spool_hub_app
DSN="$(app_dsn spool_hub_app)"
echo "ok   - databases owned by non-superuser role $APP_ROLE (RLS binds it)"

BIN="$WORK/spool"
( cd "$MOD" && go build -o "$BIN" ./cmd/spool )

out1="$("$BIN" migrate --db "$DSN" --sql-dir "$SQL_DIR")"
out2="$(SPOOL_HUB_DB_DSN="$DSN" SPOOL_HUB_MIGRATIONS_DIR="$SQL_DIR" "$BIN" migrate)"
echo "$out1" | grep -q 'applied 0001_hub_core.sql' || { echo "FAIL - first migrate: $out1"; exit 1; }
if echo "$out2" | grep -q '^applied'; then echo "FAIL - second migrate re-applied: $out2"; exit 1; fi
echo "ok   - spool migrate applies $(echo "$out1" | grep -c '^applied') file(s); re-run is a no-op"

# One database per package: `go test` runs packages in parallel, and the
# store suite's retention test calls Sweep(now+31d), which is global by
# design (the hub sweeper). Against a shared database it purged the hub
# suite's queued messages mid-test: TestChannelMentionRouting timed out
# waiting for the drained recv (CI 35436333578; reproduced with the sweep
# SQL in a loop, 4 fails in 40 s against 16/16 clean before; H6).
# 017 FR-SEC-014: RT_ROLE is a runtime role that does NOT own the tables
# (DML grants only), the shape TestRLSHubRoleCannotLiftRLS requires; the
# owner APP_ROLE is its CONTROL.
# 017 T029: the REAL split, the same SQL the cloud action runs
# (csi-rdb spool-hub-roles/): the OWNER creates the runtime role and grants
# it DML only, per database, after its migrate.
RT_ROLE=spool_rt
ROLES_SQL="$(cd "$SQL_DIR/../spool-hub-roles" && pwd)"
own_sql() { # <db> <file> [psql -v args]: run a roles file AS THE OWNER (SET ROLE $APP_ROLE)
  local db="$1" f="$2"; shift 2
  { echo "SET ROLE $APP_ROLE;"; cat "$f"; } |
  if [ -n "$PG_CTR" ]; then docker exec -i "$PG_CTR" psql -X -q -v ON_ERROR_STOP=1 -U spool -d "$db" "$@" -f -
  else "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PGPORT" -U spool -d "$db" "$@" -f -; fi
}
own_sql spool_hub_app "$ROLES_SQL/runtime-role.sql" -v runtime_role="$RT_ROLE" -v runtime_verifier="$RT_ROLE" >/dev/null
own_sql spool_hub_app "$ROLES_SQL/runtime-role.sql" -v runtime_role="$RT_ROLE" -v runtime_verifier="$RT_ROLE" >/dev/null # idempotent
own_sql spool_hub_app "$ROLES_SQL/runtime-grants.sql" -v runtime_role="$RT_ROLE" >/dev/null
# SPL-984 (029 D3): the runtime login carries its own timeouts, set by the
# owner (CREATEROLE, like the cloud) - not by a superuser.
cfg="$(su_sql "SELECT ',' || array_to_string(rolconfig, ',') FROM pg_roles WHERE rolname = '$RT_ROLE'")"
{ echo "$cfg" | grep -q '[^_]statement_timeout=30s' && echo "$cfg" | grep -q 'idle_in_transaction_session_timeout=60s'; } ||
  { echo "FAIL - runtime role timeouts: '$cfg'"; exit 1; }
echo "ok   - 029 D3: $RT_ROLE has statement_timeout=30s, idle_in_transaction_session_timeout=60s"
rt_dsn() { # <db>
  if [ -n "$PG_CTR" ]; then echo "postgres://$RT_ROLE:$RT_ROLE@127.0.0.1:$PGPORT/$1?sslmode=disable"
  else echo "postgres://$RT_ROLE@/$1?host=$WORK&port=$PGPORT&sslmode=disable"; fi
}
pids=()
for pkg in store hub auth; do
  db="spool_hub_$pkg"
  mkdb "$db"
  pdsn="$(app_dsn "$db")"
  "$BIN" migrate --db "$pdsn" --sql-dir "$SQL_DIR" >/dev/null # auth's suite expects a migrated db
  own_sql "$db" "$ROLES_SQL/runtime-grants.sql" -v runtime_role="$RT_ROLE" >/dev/null
  ( cd "$MOD" && SPOOL_TEST_PG_DSN="$pdsn" SPOOL_TEST_SQL_DIR="$SQL_DIR" SPOOL_TEST_PG_RUNTIME_DSN="$(rt_dsn "$db")" \
      CGO_ENABLED=1 go test -race -count=1 "./internal/$pkg/" ) &
  pids+=("$!")
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || { echo "FAIL - Postgres package suites"; exit 1; }
echo "ok   - internal/store + internal/hub + internal/auth (015 CredStore) suites green against Postgres"

# 017 T021 + FR-SEC-014 CONTROL: EVERY ^TestRLS test must RUN and PASS (a
# skip is a failure), counted from the source so a new one cannot hide.
rls="$(cd "$MOD" && SPOOL_TEST_PG_DSN="$(app_dsn spool_hub_store)" SPOOL_TEST_SQL_DIR="$SQL_DIR" \
  SPOOL_TEST_PG_RUNTIME_DSN="$(rt_dsn spool_hub_store)" \
  go test -count=1 -run '^TestRLS' -v ./internal/store/ 2>&1)" || { echo "FAIL - RLS control: $rls"; exit 1; }
want_rls="$(cat "$MOD"/internal/store/*_test.go | grep -c '^func TestRLS')"
[ "$(grep -c -- '--- PASS: TestRLS' <<<"$rls")" -eq "$want_rls" ] || { echo "FAIL - RLS control: not all $want_rls TestRLS ran: $rls"; exit 1; }
echo "ok   - RLS: $want_rls TestRLS PASS - every tenant_id table (from the catalogue) ENABLE+FORCE with a fail-closed tenant policy, the gate goes red on 6 scratch shapes, '' leaked under the 0014 form, store refuses an empty tenant, a non-owner runtime role cannot lift RLS (CONTROLS)"

# 017 FR-SEC-015: the ONE cross-tenant suite (TestCrossTenant* in store and
# hub, CLE-3415's TestCrossTenantIdentity* included) must RUN and PASS in
# full against Postgres - counted from the source, so a skip is a failure.
for pkg in store hub; do
  ct="$(cd "$MOD" && SPOOL_TEST_PG_DSN="$(app_dsn "spool_hub_$pkg")" SPOOL_TEST_SQL_DIR="$SQL_DIR" \
    go test -count=1 -run '^TestCrossTenant' -v "./internal/$pkg/" 2>&1)" || { echo "FAIL - cross-tenant suite ($pkg): $ct"; exit 1; }
  want_ct="$(cat "$MOD/internal/$pkg/"*_test.go | grep -c '^func TestCrossTenant')"
  [ "$want_ct" -gt 0 ] && [ "$(grep -c -- '^--- PASS: TestCrossTenant' <<<"$ct")" -eq "$want_ct" ] ||
    { echo "FAIL - cross-tenant suite ($pkg): not all $want_ct TestCrossTenant ran: $ct"; exit 1; }
  echo "ok   - cross-tenant suite ($pkg): $want_ct TestCrossTenant PASS against Postgres"
done

# FR-SEC-014 CONTROL through a real migration: a scratch file adding a
# tenant_id table without RLS turns the catalogue gate red.
mkdir -p "$WORK/sql-scratch"
cp "$SQL_DIR"/*.sql "$WORK/sql-scratch/"
printf '%s\n' 'CREATE TABLE scratch_unprotected (tenant_id text NOT NULL REFERENCES tenants (tenant_id));' >"$WORK/sql-scratch/9999_scratch_unprotected.sql"
mkdb spool_hub_scratch
"$BIN" migrate --db "$(app_dsn spool_hub_scratch)" --sql-dir "$WORK/sql-scratch" >/dev/null
if red="$(cd "$MOD" && SPOOL_TEST_PG_DSN="$(app_dsn spool_hub_scratch)" SPOOL_TEST_SQL_DIR="$WORK/sql-scratch" \
  go test -count=1 -run '^TestRLSPoliciesFailClosed$' ./internal/store/ 2>&1)"; then
  echo "FAIL - the RLS gate stayed green with an unprotected tenant_id table: $red"; exit 1
fi
grep -q 'scratch_unprotected: carries tenant_id but row security is enable=false force=false' <<<"$red" ||
  { echo "FAIL - the RLS gate went red for the wrong reason: $red"; exit 1; }
echo "ok   - RLS gate CONTROL: a scratch migration with an unprotected tenant_id table turns TestRLSPoliciesFailClosed red"

# 010 FR-014: the operator invite seats a first owner where bootstrap is off.
INV_PUB="$("$BIN" root-keygen --out "$WORK/inv-root.key")"
SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-tenant --tenant t-invite --root-pubkey "$INV_PUB" >/dev/null
inv="$(SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-invite --tenant t-invite --email Owner@Example.com)"
echo "$inv" | grep -q '"status":"invited"' || { echo "FAIL - hub-invite: $inv"; exit 1; }
if SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-invite --tenant t-nosuch --email x@example.com >/dev/null 2>&1; then
  echo "FAIL - hub-invite accepted an unknown tenant"; exit 1
fi
echo "ok   - spool hub-invite: invite for an existing tenant, unknown tenant refused"

# 010 FR-016: the invitation email. Transport none (the default above) sends
# nothing and says so; transport log mails once, a resend in the gap is
# refused (exit 3), the log line carries a digest, never the address.
echo "$inv" | grep -q '"outcome":"skipped_no_relay"' || { echo "FAIL - hub-invite without a relay: $inv"; exit 1; }
MAILENV=(SPOOL_HUB_DB_DSN="$DSN" SPOOL_HUB_MAIL_TRANSPORT=log SPOOL_HUB_AUTH_APP_URL=https://app.example.com SPOOL_HUB_DEFAULT_LOCALE=bg)
inv="$(env "${MAILENV[@]}" "$BIN" hub-invite --tenant t-invite --email Mem@Example.com --role member 2>"$WORK/inv.log")"
echo "$inv" | grep -q '"outcome":"sent"' && echo "$inv" | grep -q '"delivered":false' &&
  echo "$inv" | grep -q '"sign_in_url":"https://app.example.com/login?tenant=t-invite"' ||
  { echo "FAIL - hub-invite log transport: $inv"; exit 1; }
if grep -qi 'mem@example.com' "$WORK/inv.log" || ! grep -q '"message":"invite.mail_sent"' "$WORK/inv.log"; then
  echo "FAIL - invite mail log leaks the address or lacks the line: $(cat "$WORK/inv.log")"; exit 1
fi
rc=0; out="$(env "${MAILENV[@]}" "$BIN" hub-invite-mail --tenant t-invite --email mem@example.com 2>/dev/null)" || rc=$?
[ "$rc" -eq 3 ] && echo "$out" | grep -q '"outcome":"rate_limited"' || { echo "FAIL - resend in the gap: rc=$rc $out"; exit 1; }
out="$(env "${MAILENV[@]}" "$BIN" hub-invite-mail --tenant t-invite --email mem@example.com --min-gap 0s --locale en 2>/dev/null)" &&
  echo "$out" | grep -q '"outcome":"sent"' && echo "$out" | grep -q '"locale":"en"' && echo "$out" | grep -q '"mail_count":2' ||
  { echo "FAIL - resend after the gap: $out"; exit 1; }
rc=0; out="$(env "${MAILENV[@]}" "$BIN" hub-invite-mail --tenant t-invite --email nobody@example.com 2>/dev/null)" || rc=$?
[ "$rc" -eq 3 ] && echo "$out" | grep -q '"outcome":"not_found"' || { echo "FAIL - resend unknown invite: rc=$rc $out"; exit 1; }
out="$(env "${MAILENV[@]}" "$BIN" hub-invite --tenant t-invite --email nm@example.com --no-mail 2>/dev/null)" &&
  echo "$out" | grep -q '"outcome":"skipped_no_mail_flag"' || { echo "FAIL - --no-mail: $out"; exit 1; }
echo "ok   - 010 FR-016: invite mail sent once (log transport), resend in the gap refused (exit 3), unknown not found, --no-mail, digest-only log"

# 017 T029: the M1 demo runs as the RUNTIME role (DML grants only, as the
# cloud hub after do_spl_db_owner_split); the hub's own startup check must
# log db.rls_not_liftable.
own_sql spool_hub_app "$ROLES_SQL/runtime-grants.sql" -v runtime_role="$RT_ROLE" >/dev/null # idempotent re-run
EXPECT_NOT_LIFTABLE=1 bash "$HERE/hub-e2e.tst.sh" "$BIN" "$(rt_dsn spool_hub_app)"
echo "ALL HUB POSTGRES CHECKS PASSED"
