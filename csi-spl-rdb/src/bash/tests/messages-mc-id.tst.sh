#!/usr/bin/env bash
# rdb NNNN_messages_mc_id.sql (spec 186 row M1, 7.1.3): migrate a throwaway
# Postgres with the real `spool migrate`, run the migrate again and the file
# once more by hand (it applies twice), then check messages.mc_id is a
# nullable uuid with no default and no constraint, the partial index
# messages_mc_id is (tenant_id, mc_id) WHERE mc_id IS NOT NULL, and the RLS
# of messages is unchanged (on and forced).
# RED CONTROL: without the file `ls *_messages_mc_id.sql` finds nothing, the
# script prints FAIL and exits 1.
# Postgres: local server binaries (initdb) when installed, else a locally
# CACHED postgres image (never pulled); with neither it skips (exit 0), the
# dedicated-agents-rls.tst.sh shape. The spool binary: $SPOOL_BIN, else
# built from csi-spl-api.
# Usage: bash csi-spl-rdb/src/bash/tests/messages-mc-id.tst.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
SQL_DIR="${SPOOL_TEST_SQL_DIR:-$ROOT/csi-spl-rdb/src/sql/postgres/spool-hub}"
MIG="$(cd "$SQL_DIR" && ls -- *_messages_mc_id.sql 2>/dev/null || true)" # the number is the next free one at landing
[ -n "$MIG" ] || { echo "FAIL - no *_messages_mc_id.sql in $SQL_DIR: messages.mc_id does not exist"; exit 1; }
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
OWNER=spool_app

WORK="$(mktemp -d)"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)}"
PG_CTR=""
cleanup() {
  [ -x "${PG_BIN:-/nonexistent}/pg_ctl" ] && "$PG_BIN/pg_ctl" -D "$WORK/pgdata" -m immediate stop >/dev/null 2>&1 || true
  [ -n "$PG_CTR" ] && docker rm -fv "$PG_CTR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ -n "$PG_BIN" ] && [ -x "$PG_BIN/initdb" ]; then
  PGPORT="$(( 20000 + RANDOM % 20000 ))"
  "$PG_BIN/initdb" -D "$WORK/pgdata" -U spool -A trust >/dev/null
  "$PG_BIN/pg_ctl" -D "$WORK/pgdata" -l "$WORK/pg.log" -w \
    -o "-k $WORK -p $PGPORT -c listen_addresses=''" start >/dev/null
  dsn() { echo "postgres://$OWNER@/$1?host=$WORK&port=$PGPORT&sslmode=disable"; }
  psql_as() { "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PGPORT" "$@"; }
elif command -v docker >/dev/null && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  PG_CTR="spool-rdb-mc-id-test-$$"
  docker run -d --rm --label "csi-spl.lane=${AGENT_ID:-${SPOOL_AGENT_ID:-}}" --pull never --name "$PG_CTR" \
    -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool -e POSTGRES_DB=spool -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
  PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
  for _ in $(seq 1 60); do
    docker exec "$PG_CTR" pg_isready -U spool -h 127.0.0.1 >/dev/null 2>&1 && break
    sleep 0.5
  done
  dsn() { echo "postgres://$OWNER:$OWNER@127.0.0.1:$PGPORT/$1?sslmode=disable"; }
  psql_as() { docker exec -i "$PG_CTR" psql -X -q -v ON_ERROR_STOP=1 "$@"; }
else
  echo "skip - no Postgres server binaries and no cached $PG_IMAGE image; $MIG test not run"
  exit 0
fi
echo "ok   - temp Postgres up"

BIN="${SPOOL_BIN:-}"
if [ -z "$BIN" ]; then
  BIN="$WORK/spool"
  # shellcheck source=/dev/null
  source "$ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
  spl_export_go_path
  ( cd "$ROOT/csi-spl-api/src/go/spool-hub-api" &&
    GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local go build -o "$BIN" ./cmd/spool )
fi

psql_as -U spool -d postgres -c "CREATE ROLE $OWNER LOGIN PASSWORD '$OWNER' NOSUPERUSER NOBYPASSRLS CREATEROLE"
psql_as -U spool -d postgres -c "CREATE DATABASE hub OWNER $OWNER"
out="$("$BIN" migrate --db "$(dsn hub)" --sql-dir "$SQL_DIR")"
grep "applied $MIG" <<<"$out" >/dev/null || { echo "FAIL - $MIG not applied: $(echo "$out" | tail -3)"; exit 1; }
echo "ok   - spool migrate applies $MIG"
out="$("$BIN" migrate --db "$(dsn hub)" --sql-dir "$SQL_DIR" 2>&1)" || { echo "FAIL - second spool migrate: $(echo "$out" | tail -3)"; exit 1; }
echo "ok   - a second spool migrate passes"
out="$({ echo "BEGIN;"; cat "$SQL_DIR/$MIG"; echo "COMMIT;"; } | psql_as -U "$OWNER" -d hub -f - 2>&1)" ||
  { echo "FAIL - $MIG applied by hand a second time: $out"; exit 1; }
echo "ok   - $MIG applies a second time by hand (idempotent)"

fails=0
q() { psql_as -U "$OWNER" -d hub -tA -c "$1" 2>&1; }
expect() { # <label> <want> <got>
  if [ "$3" = "$2" ]; then echo "ok   - $1: $3"; else echo "FAIL - $1: want '$2', got '$3'"; fails=$((fails + 1)); fi
}
expect "messages.mc_id: uuid, nullable, no default" "uuid YES -" \
  "$(q "SELECT data_type || ' ' || is_nullable || ' ' || coalesce(column_default, '-') FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'messages' AND column_name = 'mc_id'")"
expect "partial index messages_mc_id" "ON public.messages USING btree (tenant_id, mc_id) WHERE (mc_id IS NOT NULL)" \
  "$(q "SELECT regexp_replace(indexdef, '^CREATE INDEX messages_mc_id ', '') FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'messages_mc_id'")"
expect "no constraint names mc_id (no FK)" 0 \
  "$(q "SELECT count(*) FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey) WHERE c.conrelid = 'public.messages'::regclass AND a.attname = 'mc_id'")"
expect "RLS on + forced on messages" "t t" \
  "$(q "SELECT relrowsecurity || ' ' || relforcerowsecurity FROM pg_class WHERE oid = 'public.messages'::regclass" | sed 's/true/t/g; s/false/f/g')"
echo "---- \\d messages (mc_id lines)"
psql_as -U spool -d hub -c '\d messages' | grep -E 'mc_id' || true

if [ "$fails" -gt 0 ]; then echo "FAIL: $fails check(s) of $MIG"; exit 1; fi
echo "PASS: all messages-mc-id.tst.sh assertions"
