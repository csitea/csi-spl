#!/usr/bin/env bash
# rdb NNNN_dedicated_agents.sql (specs/144 T001): migrate a throwaway Postgres
# with the real `spool migrate`, then check the table, its keys and CHECKs,
# the private-scope columns and the agent row level security on messages,
# deliveries and dedicated_agents, every read and write AS THE RUNTIME LOGIN
# (spool-hub-roles/runtime-role.sql + runtime-grants.sql), never a superuser
# nor the owner (tasks.md rule 2).
# CONTROL: a second database migrated with that file cut before its row level
# security (the table and the columns only); there the non-dedicated worker
# reads the private rows, so the probe can see a leak.
# DEDICATED_RLS_CONTROL=1 runs the checks against that control database:
# they print FAIL and the script exits 1 (the red control of the brief).
# Postgres: local server binaries (initdb) when installed, else a locally
# CACHED postgres image (never pulled); with neither it skips (exit 0), the
# hub-pg.tst.sh shape. The spool binary: $SPOOL_BIN, else built from
# csi-spl-api.
# Usage: bash csi-spl-rdb/src/bash/tests/dedicated-agents-rls.tst.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
SQL_DIR="${SPOOL_TEST_SQL_DIR:-$ROOT/csi-spl-rdb/src/sql/postgres/spool-hub}"
ROLES_SQL="$ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles"
MIG="$(cd "$SQL_DIR" && ls -- *_dedicated_agents.sql)" # the number is the next free one at landing
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
OWNER=spool_app RT=spool_rt

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
  PG_CTR="spool-rdb-dedicated-test-$$"
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
  echo "skip - no Postgres server binaries and no cached $PG_IMAGE image; $MIG RLS test not run"
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
own() { # <db> <file> [psql args]: a roles file AS THE OWNER
  local db="$1" f="$2"; shift 2
  local out
  out="$({ echo "SET ROLE $OWNER;"; cat "$f"; } | psql_as -U spool -d "$db" "$@" -f - 2>&1)" || { echo "FAIL - $f on $db: $out"; exit 1; }
}
# The control's sql dir: every file, $MIG cut before its row level security.
CTL_SQL="$WORK/sql-control"
mkdir -p "$CTL_SQL"
cp "$SQL_DIR"/*.sql "$CTL_SQL/"
sed -i '/^ALTER TABLE dedicated_agents ENABLE/,$d' "$CTL_SQL/$MIG"
grep 'CREATE POLICY' "$CTL_SQL/$MIG" >/dev/null && { echo "FAIL - control cut kept a policy"; exit 1; }
for db in hub ctl; do
  psql_as -U spool -d postgres -c "CREATE DATABASE $db OWNER $OWNER"
  dir="$SQL_DIR"; [ "$db" = ctl ] && dir="$CTL_SQL"
  out="$("$BIN" migrate --db "$(dsn "$db")" --sql-dir "$dir")"
  grep "applied $MIG" <<<"$out" >/dev/null || { echo "FAIL - $db: $MIG not applied: $(echo "$out" | tail -3)"; exit 1; }
  own "$db" "$ROLES_SQL/runtime-role.sql" -v runtime_role="$RT" -v runtime_verifier="$RT"
  own "$db" "$ROLES_SQL/runtime-grants.sql" -v runtime_role="$RT"
done
echo "ok   - spool migrate applies $MIG (and the control cut of it); runtime login $RT granted"

T1=10000000-0000-4000-8000-000000000001 # the private topic, in ch-pub
# Seed as the owner in the operator scope (rdb 0014): two tenants, a public
# and a private-scope channel, four messages and their deliveries, bindings.
seed() { # <db>
  psql_as -U "$OWNER" -d "$1" >/dev/null <<SQL
BEGIN;
SET LOCAL app.rls_scope = 'operator';
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t-a', decode(repeat('ab', 32), 'hex')), ('t-b', decode(repeat('cd', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by, is_private_scope, private_scope_at) VALUES
  ('t-a', 'ch-pub', 'pub', 'HUM-1', false, NULL), ('t-a', 'ch-priv', 'priv', 'HUM-1', true, now()),
  ('t-b', 'ch-pub', 'pub', 'HUM-2', false, NULL);
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at, is_private_scope)
SELECT t, id::uuid, task::uuid, ch, now(), 'box-a', 'HUM-1', 'box-a', 'c-100', 'note', body, '{}', 'sig', '\x00', now() + interval '1 day', priv
FROM (VALUES
  ('t-a', '00000000-0000-4000-8000-0000000000a1', '$T1', 'ch-pub', 'private topic', true),
  ('t-a', '00000000-0000-4000-8000-0000000000a2', '10000000-0000-4000-8000-000000000002', 'ch-pub', 'public', false),
  ('t-a', '00000000-0000-4000-8000-0000000000a3', '10000000-0000-4000-8000-000000000003', 'ch-priv', 'private channel', false),
  ('t-a', '00000000-0000-4000-8000-0000000000a4', '10000000-0000-4000-8000-000000000004', NULL, 'dm', false),
  ('t-b', '00000000-0000-4000-8000-0000000000b1', '$T1', 'ch-pub', 'other tenant', true)
) v (t, id, task, ch, body, priv);
INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) SELECT tenant_id, msg_id, 'box-a', expires_at FROM messages WHERE tenant_id IN ('t-a', 't-b');
INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES
  ('t-a', 'd-topic', 'box-a', 'topic', '$T1', 'HUM-1'),
  ('t-a', 'd-chan', 'box-a', 'channel', 'ch-priv', 'HUM-1'),
  ('t-b', 'd-topic', 'box-a', 'topic', '$T1', 'HUM-2');
COMMIT;
SQL
}
seed hub
seed ctl
echo "ok   - seeded 2 tenants, 5 messages + deliveries, 3 bindings"

DB=hub
if [ "${DEDICATED_RLS_CONTROL:-0}" = 1 ]; then DB=ctl; echo "note - DEDICATED_RLS_CONTROL=1: the checks below run on the control database"; fi
fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
# rt <tenant> <agent> <box> <sql>: one value, as the runtime login, in one
# transaction with the transaction-local settings the hub will set.
rt() {
  psql_as -U "$RT" -d "$DB" -tA <<SQL 2>&1
BEGIN;
SELECT set_config('app.tenant_id', '$1', true) AS t, set_config('app.agent_id', '$2', true) AS a, set_config('app.agent_box', '$3', true) AS b \gset
$4;
COMMIT;
SQL
}
own_q() { psql_as -U "$OWNER" -d "$DB" -tA -c "$1" 2>&1; }
expect() { # <label> <want> <got>
  if [ "$3" = "$2" ]; then ok "$1: $3"; else fail "$1: want '$2', got '$3'"; fi
}
expect_err() { # <label> <pattern> <got>
  if grep -E "$2" <<<"$3" >/dev/null; then ok "$1: refused ($(grep -oE "$2" <<<"$3" | sed -n 1p))"; else fail "$1: not refused: $3"; fi
}
msgs="SELECT coalesce(string_agg(body, ',' ORDER BY body), '-') FROM messages"
dels="SELECT count(*) FROM deliveries"
binds="SELECT coalesce(string_agg(agent_id || ':' || scope_id, ',' ORDER BY agent_id), '-') FROM dedicated_agents"

# 1. the catalogue
expect "dedicated_agents primary key" "tenant_id,agent_id,box_id" "$(own_q "SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM pg_constraint c, unnest(c.conkey) WITH ORDINALITY k (n, ord), pg_attribute a WHERE c.conname = 'pk_dedicated_agents' AND a.attrelid = c.conrelid AND a.attnum = k.n")"
expect "FK to tenants ON DELETE CASCADE" "tenants c" "$(own_q "SELECT confrelid::regclass::text || ' ' || confdeltype::text FROM pg_constraint WHERE conname = 'fk_dedicated_agents_tenant'")"
expect "idx_dedicated_agents_scope" "(tenant_id, scope_type, scope_id)" "$(own_q "SELECT regexp_replace(indexdef, '.* USING btree ', '') FROM pg_indexes WHERE indexname = 'idx_dedicated_agents_scope'")"
expect "private-scope columns" "channels.is_private_scope false,channels.private_scope_at -,messages.is_private_scope false" "$(own_q "SELECT string_agg(table_name || '.' || column_name || ' ' || coalesce(column_default, '-'), ',' ORDER BY table_name, column_name) FROM information_schema.columns WHERE table_schema = 'public' AND column_name IN ('is_private_scope', 'private_scope_at')")"
expect "RLS on + forced on dedicated_agents" "t t" "$(own_q "SELECT relrowsecurity || ' ' || relforcerowsecurity FROM pg_class WHERE relname = 'dedicated_agents'" | tr -d '\n' | sed 's/true/t/g; s/false/f/g')"
# 2. keys and CHECKs (as the owner in the operator scope)
chk() { psql_as -U "$OWNER" -d "$DB" -tA -c "BEGIN; SET LOCAL app.rls_scope = 'operator'; INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES ($1); ROLLBACK" 2>&1; }
expect_err "scope_type 'dm'" chk_dedicated_scope_type "$(chk "'t-a', 'x', 'box-a', 'dm', 'ch-pub', 'HUM-1'")"
expect_err "topic scope_id not a uuid" chk_dedicated_scope_id "$(chk "'t-a', 'x', 'box-a', 'topic', 'ch-pub', 'HUM-1'")"
expect_err "channel scope_id upper case" chk_dedicated_scope_id "$(chk "'t-a', 'x', 'box-a', 'channel', 'Ch', 'HUM-1'")"
expect_err "unknown tenant" fk_dedicated_agents_tenant "$(chk "'t-none', 'x', 'box-a', 'channel', 'ch-pub', 'HUM-1'")"
expect_err "second scope for one agent" pk_dedicated_agents "$(chk "'t-a', 'd-topic', 'box-a', 'channel', 'ch-pub', 'HUM-1'")"
# 3. reads, as the runtime login
expect "no agent set (human/staff session): every message" "dm,private channel,private topic,public" "$(rt t-a '' '' "$msgs")"
expect "no agent set: every delivery" 4 "$(rt t-a '' '' "$dels")"
expect "no agent set: every binding of the tenant" "d-chan:ch-priv,d-topic:$T1" "$(rt t-a '' '' "$binds")"
# The Reporting SQL tab (spec 143) EXPLAINs an admin's query and refuses a
# plan calling a function off its list: the agent rule must plan inline.
for rel in messages deliveries; do
  plan="$(rt t-a '' '' "EXPLAIN (VERBOSE) SELECT * FROM $rel")"
  if grep -oE 'spool_[a-z_]+\(' <<<"$plan" >/dev/null; then fail "plan of $rel calls $(grep -oE 'spool_[a-z_]+\(' <<<"$plan" | sort -u | tr '\n' ' ')"
  else ok "plan of $rel calls no spool_ function (the SQL tab can read it)"; fi
done
expect "non-dedicated worker: no private row" "dm,public" "$(rt t-a w-1 box-a "$msgs")"
expect "non-dedicated worker: private topic by id" 0 "$(rt t-a w-1 box-a "SELECT count(*) FROM messages WHERE task_id = '$T1'")"
expect "non-dedicated worker: deliveries of public rows only" 2 "$(rt t-a w-1 box-a "$dels")"
expect "non-dedicated worker: no binding" "-" "$(rt t-a w-1 box-a "$binds")"
expect "topic-dedicated agent: its topic only" "private topic" "$(rt t-a d-topic box-a "$msgs")"
expect "topic-dedicated agent: its deliveries only" 1 "$(rt t-a d-topic box-a "$dels")"
expect "topic-dedicated agent: its own binding" "d-topic:$T1" "$(rt t-a d-topic box-a "$binds")"
expect "channel-dedicated agent: its channel only" "private channel" "$(rt t-a d-chan box-a "$msgs")"
expect "dedicated agent id on another box: a plain worker" "dm,public" "$(rt t-a d-topic box-b "$msgs")"
expect "agent set, box unset: fails closed" "dm,public" "$(rt t-a d-topic '' "$msgs")"
expect "tenant B's topic agent: tenant B's row only" "other tenant" "$(rt t-b d-topic box-a "$msgs")"
expect "tenant B, no agent: tenant B's binding only" "d-topic:$T1" "$(rt t-b '' '' "$binds")"
# 4. writes, as the runtime login
expect_err "worker binds itself to the private topic" "row-level security" "$(rt t-a w-1 box-a "INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES ('t-a', 'w-1', 'box-a', 'topic', '$T1', 'w-1')")"
expect "dedicated agent deletes its binding: 0 rows" 0 "$(rt t-a d-topic box-a "WITH d AS (DELETE FROM dedicated_agents RETURNING 1) SELECT count(*) FROM d")"
expect "dedicated agent moves its binding: 0 rows" 0 "$(rt t-a d-topic box-a "WITH u AS (UPDATE dedicated_agents SET scope_id = 'ch-pub', scope_type = 'channel' RETURNING 1) SELECT count(*) FROM u")"
expect_err "worker flags a public message private" "row-level security" "$(rt t-a w-1 box-a "UPDATE messages SET is_private_scope = true WHERE body = 'public'")"
expect_err "worker posts into the private channel" "row-level security" "$(rt t-a w-1 box-a "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at) VALUES ('t-a', gen_random_uuid(), gen_random_uuid(), 'ch-priv', now(), 'box-a', 'w-1', 'box-a', 'HUM-1', 'note', 'x', '{}', 's', '\x00', now() + interval '1 day')")"
expect "hub (no agent) binds an agent" 1 "$(rt t-a '' '' "WITH i AS (INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES ('t-a', 'd-new', 'box-a', 'channel', 'ch-pub', 'HUM-1') RETURNING 1) SELECT count(*) FROM i")"

# 5. CONTROL: the same worker probe on the control database (no $MIG
# policies) reads the private rows; a probe that reads 0 there proves nothing.
got="$(DB=ctl rt t-a w-1 box-a "$msgs")"
if [ "$got" = "dm,private channel,private topic,public" ]; then ok "CONTROL: without the $MIG policies the worker reads the private rows ($got)"
else fail "CONTROL: the worker probe saw '$got' without the policies"; fi

if [ "$fails" -gt 0 ]; then echo "FAIL: $fails check(s) of $MIG"; exit 1; fi
echo "PASS: all dedicated-agents-rls.tst.sh assertions"
