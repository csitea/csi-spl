#!/usr/bin/env bash
# Hub Postgres gate (specs/003 T021, T001b): start a throwaway Postgres in a
# temp dir, run `spool migrate` twice (the second run must be a no-op), run the
# internal/store contract suite against it, then drive the M1 demo end to end
# with the real binary: serve, two boxes, cross-box send/recv, queued delivery,
# hub-down pending + flush.
# Postgres comes from local server binaries (initdb) when installed, else from
# a locally CACHED docker image (never pulled); with neither it skips (exit 0).
# Usage: bash csi-spl-api/src/bash/tests/hub-pg.tst.sh
set -euo pipefail

export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  [ -n "$PG_CTR" ] && docker rm -f "$PG_CTR" >/dev/null 2>&1 || true
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

BIN="$WORK/spool"
( cd "$MOD" && go build -o "$BIN" ./cmd/spool )

out1="$("$BIN" migrate --db "$DSN" --sql-dir "$SQL_DIR")"
out2="$(SPOOL_HUB_DB_DSN="$DSN" SPOOL_HUB_MIGRATIONS_DIR="$SQL_DIR" "$BIN" migrate)"
echo "$out1" | grep -q 'applied 0001_hub_core.sql' || { echo "FAIL - first migrate: $out1"; exit 1; }
if echo "$out2" | grep -q '^applied'; then echo "FAIL - second migrate re-applied: $out2"; exit 1; fi
echo "ok   - spool migrate applies $(echo "$out1" | grep -c '^applied') file(s); re-run is a no-op"

( cd "$MOD" && SPOOL_TEST_PG_DSN="$DSN" SPOOL_TEST_SQL_DIR="$SQL_DIR" go test -count=1 ./internal/store/ ./internal/hub/ )
echo "ok   - internal/store + internal/hub suites green against Postgres"

# 010 FR-014: the operator invite seats a first owner where bootstrap is off.
INV_PUB="$("$BIN" root-keygen --out "$WORK/inv-root.key")"
SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-tenant --tenant t-invite --root-pubkey "$INV_PUB" >/dev/null
inv="$(SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-invite --tenant t-invite --email Owner@Example.com)"
echo "$inv" | grep -q '"status":"invited"' || { echo "FAIL - hub-invite: $inv"; exit 1; }
if SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-invite --tenant t-nosuch --email x@example.com >/dev/null 2>&1; then
  echo "FAIL - hub-invite accepted an unknown tenant"; exit 1
fi
echo "ok   - spool hub-invite: invite for an existing tenant, unknown tenant refused"

bash "$HERE/hub-e2e.tst.sh" "$BIN" "$DSN"
echo "ALL HUB POSTGRES CHECKS PASSED"
