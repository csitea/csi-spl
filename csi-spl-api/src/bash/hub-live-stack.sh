#!/usr/bin/env bash
# A throwaway hub for live tests (SPL-2167): a temp Postgres, `spool migrate`,
# the runtime role (the cloud shape, as hub-pg.tst.sh), one tenant, then
# `spool serve` with the view door off on a kernel-picked port. It runs the
# command given with HUB_URL=http://<tenant>.localhost:<port> and exits with
# that command's status; everything is torn down on exit. The command also
# gets SPOOL_TEST_PG_DSN (SPL-3107): the migrated database as the schema-owner
# role spool_app, the role the Go store suites use (app_dsn in hub-pg.tst.sh).
#
# Usage: bash csi-spl-api/src/bash/hub-live-stack.sh <cmd> [args...]
#   e.g. bash csi-spl-api/src/bash/hub-live-stack.sh pnpm -C csi-spl-wui run test:live
# Env: HUB_LIVE_TENANT (default t1), HUB_LIVE_BIN (a prebuilt spool binary;
#   default: built here from csi-spl-api/src/go/spool-hub-api), PG_BIN.
# Postgres comes from local server binaries (initdb), else a CACHED docker
# image (never pulled). A stack that does not come up exits 70, never 0:
# unlike hub-pg.tst.sh there is no skip, since the caller asked for a hub.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 <cmd> [args...]" >&2; exit 64; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../go/spool-hub-api"
SQL_DIR="$(cd "$HERE/../../../csi-spl-rdb/src/sql/postgres/spool-hub" && pwd)"
ROLES_SQL="$(cd "$SQL_DIR/../spool-hub-roles" && pwd)"
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)}"
TENANT="${HUB_LIVE_TENANT:-t1}"
# wui-live-ws.md section 1; same value as cnf env.hub.env.SPOOL_HUB_LOBBY_TASK_ID.
LOBBY="00000000-0000-4000-8000-000000000001"
APP_ROLE=spool_app
RT_ROLE=spool_rt

WORK="$(mktemp -d)"
PGDATA="$WORK/pgdata"
PG_CTR=""
HUB_PID=""
cleanup() {
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  [ -x "${PG_BIN:-/nonexistent}/pg_ctl" ] && [ -d "$PGDATA" ] && "$PG_BIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  [ -n "$PG_CTR" ] && docker rm -fv "$PG_CTR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

down() { echo "FAIL hub-live-stack: $*" >&2; [ -f "$WORK/hub.log" ] && tail -20 "$WORK/hub.log" >&2; exit 70; }
say() { echo "hub-live-stack: $*" >&2; }

# 1. Postgres
if [ -n "$PG_BIN" ] && [ -x "$PG_BIN/initdb" ]; then
  PGPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  "$PG_BIN/initdb" -D "$PGDATA" -U spool -A trust >/dev/null || down "initdb"
  "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$WORK/pg.log" -w \
    -o "-k $WORK -p $PGPORT -c listen_addresses=''" start >/dev/null || down "pg_ctl start: $(tail -5 "$WORK/pg.log")"
  "$PG_BIN/createdb" -h "$WORK" -p "$PGPORT" -U spool spool_hub || down "createdb"
  say "Postgres up (local $("$PG_BIN/initdb" --version))"
elif command -v docker >/dev/null && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  PG_CTR="spool-hub-live-pg-$$"
  docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool \
    -e POSTGRES_PASSWORD=spool -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null || down "docker run $PG_IMAGE"
  PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
  for _ in $(seq 1 60); do
    docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break
    sleep 0.5
  done
  docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 || down "Postgres in $PG_CTR not ready"
  say "Postgres up (docker $PG_IMAGE)"
else
  down "no Postgres server binaries and no cached $PG_IMAGE image"
fi

psql_su() { # <db> [psql args]: psql as the bootstrap superuser
  local db="$1"; shift
  if [ -n "$PG_CTR" ]; then docker exec -i "$PG_CTR" psql -X -q -v ON_ERROR_STOP=1 -U spool -d "$db" "$@"
  else "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PGPORT" -U spool -d "$db" "$@"; fi
}
dsn() { # <role>
  if [ -n "$PG_CTR" ]; then echo "postgres://$1:$1@127.0.0.1:$PGPORT/spool_hub_live?sslmode=disable"
  else echo "postgres://$1@/spool_hub_live?host=$WORK&port=$PGPORT&sslmode=disable"; fi
}
own_sql() { # <file> [psql -v args]: a roles file run AS THE OWNER
  local f="$1"; shift
  { echo "SET ROLE $APP_ROLE;"; cat "$f"; } | psql_su spool_hub_live "$@" -f -
}

# 2. The cloud shape: a non-superuser owner migrates, the hub runs as a
# DML-only runtime role (017 FR-SEC-013/014, T029).
psql_su spool_hub -c "CREATE ROLE $APP_ROLE LOGIN PASSWORD '$APP_ROLE' NOSUPERUSER NOBYPASSRLS CREATEROLE" >/dev/null || down "create role"
psql_su spool_hub -c "CREATE DATABASE spool_hub_live OWNER $APP_ROLE" >/dev/null || down "create database"

BIN="${HUB_LIVE_BIN:-}"
if [ -z "$BIN" ]; then
  BIN="$WORK/spool"
  # shellcheck source=use-go-toolchain.sh
  source "$HERE/use-go-toolchain.sh"
  spl_export_go_path
  ( cd "$MOD" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local go build -o "$BIN" ./cmd/spool ) || down "go build ./cmd/spool"
fi
"$BIN" migrate --db "$(dsn "$APP_ROLE")" --sql-dir "$SQL_DIR" >"$WORK/migrate.log" 2>&1 || down "spool migrate: $(tail -5 "$WORK/migrate.log")"
# psql's per-function "no privileges were granted" warnings go to a log.
own_sql "$ROLES_SQL/runtime-role.sql" -v runtime_role="$RT_ROLE" -v runtime_verifier="$RT_ROLE" >/dev/null 2>>"$WORK/roles.log" \
  || down "runtime-role.sql: $(tail -3 "$WORK/roles.log")"
own_sql "$ROLES_SQL/runtime-grants.sql" -v runtime_role="$RT_ROLE" >/dev/null 2>>"$WORK/roles.log" \
  || down "runtime-grants.sql: $(tail -3 "$WORK/roles.log")"
say "migrated $(grep -c '^applied' "$WORK/migrate.log") file(s); hub runs as $RT_ROLE"

# 3. One tenant, its root key here (thrown away with the stack).
ROOT_PUB="$("$BIN" root-keygen --out "$WORK/root.key")" || down "root-keygen"
SPOOL_HUB_DB_DSN="$(dsn "$APP_ROLE")" "$BIN" hub-tenant --tenant "$TENANT" --root-pubkey "$ROOT_PUB" >/dev/null || down "hub-tenant $TENANT"

# 4. serve on a port the kernel picks; the hub logs it once bound.
SPOOL_HUB_DB_DSN="$(dsn "$RT_ROLE")" SPOOL_HUB_MIGRATIONS_DIR="$SQL_DIR" SPOOL_HUB_FILES_DIR="$WORK/blobs" \
SPOOL_HUB_TENANT_HOST_PATTERN="{tenant}.localhost" SPOOL_HUB_LISTEN_ADDR="127.0.0.1:0" \
SPOOL_HUB_LOG_FORMAT=json SPOOL_HUB_ENV=lde SPOOL_HUB_VIEW_DOOR=off SPOOL_HUB_LOBBY_TASK_ID="$LOBBY" \
  "$BIN" serve >>"$WORK/hub.log" 2>&1 &
HUB_PID=$!
PORT=""
for _ in $(seq 1 200); do
  PORT="$(sed -n 's/.*"addr":"127\.0\.0\.1:\([0-9][0-9]*\)".*"message":"hub listening".*/\1/p' "$WORK/hub.log" | tail -1)"
  [ -n "$PORT" ] && break
  kill -0 "$HUB_PID" 2>/dev/null || down "spool serve exited before it listened"
  sleep 0.1
done
[ -n "$PORT" ] || down "spool serve never logged a listening address"
for _ in $(seq 1 100); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 || down "/healthz did not answer on 127.0.0.1:$PORT"
HUB_URL="http://$TENANT.localhost:$PORT"
# The tenant is the Host; a runner whose resolver lacks *.localhost would
# turn every live check into a connection error, so say that up front.
curl -fsS --max-time 2 "$HUB_URL/healthz" >/dev/null 2>&1 || down "$TENANT.localhost does not resolve to the hub (resolver lacks *.localhost?)"
say "hub up at $HUB_URL (pid $HUB_PID)"

# 5. the caller's command, with the hub log on a failure
export HUB_URL
SPOOL_TEST_PG_DSN="$(dsn "$APP_ROLE")"
export SPOOL_TEST_PG_DSN
rc=0
"$@" || rc=$?
if [ "$rc" -ne 0 ]; then
  say "command exited $rc; last hub log lines:"
  tail -20 "$WORK/hub.log" >&2
fi
exit "$rc"
