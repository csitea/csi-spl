#!/usr/bin/env bash
# do_spl_desk_rebox copy + verify (specs/058 6.5): the SQL against a REAL
# throwaway Postgres carrying the real rdb migrations, connected as a NON-owner
# login so rdb 0014 row-level security binds (desk-rebox.tst.sh stubs psql).
#
#   1. copy carries channel seats (backfilled_at set), legacy-id aliases and the
#      LIVE lane rows of FROM_BOX to TO_BOX; a done lane row stays; a lane row
#      already on TO_BOX is not overwritten (that agent's FROM_BOX row stays)
#   2. CONTROL: another tenant's FROM_BOX rows are not touched (RLS + tenant)
#   3. a second copy is a no-op (idempotent)
#   4. verify prints both boxes; an unacked delivery fails it once the drain
#      record exists, an expired one does not count
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no docker / psql / cached $PG_IMAGE image; $(basename "$0") is not run"; exit 0
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-desk-rebox-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }

psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

for t in t1 t2; do
  psql_owner <<PSQL >/dev/null || fail "seed $t"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'));
INSERT INTO pins (tenant_id, box_id, pubkey) VALUES ('$t', 'box-desk', decode(md5('$t/box-desk') || md5('$t/box-desk/2'), 'hex'));
INSERT INTO boxes (tenant_id, box_id) VALUES ('$t', 'box-desk');
INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('$t', 'box-desk', 'c-002');
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('$t', 'lobby', 'lobby', 'hub'), ('$t', 'ops', 'ops', 'hub') ON CONFLICT DO NOTHING;
INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id, backfilled_at)
VALUES ('$t', 'lobby', 'c-002', 'box-desk', NULL), ('$t', 'ops', 'c-002', 'box-desk', now() - interval '1 day');
INSERT INTO agent_id_aliases (tenant_id, old_id, new_id, kind, box_id) VALUES ('$t', 'CLE-002', 'c-002', 'claude', 'box-desk');
INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, state, writer_box)
VALUES ('$t', 'main', 'c-010', 'box-desk', 'live', 'box-desk'), ('$t', 'main', 'c-011', 'box-desk', 'done', 'box-desk'),
       ('$t', 'main', 'c-012', 'box-desk', 'live', 'box-desk'), ('$t', 'main', 'c-012', 'hom', 'live', 'hom');
PSQL
done

step() { # <copy|verify> <tenant> [seated]
  rm -rf "$T/from"; mkdir -p "$T/from"; [[ -n "${3:-}" ]] && echo c-002 >"$T/from/rebox-seated.txt"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev SPL_PROXY_DSN="$RT_DSN" SPL_REBOX_FROM="$T/from" STEP="$1" TEN="$2" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-desk-rebox.func.sh"
    "_spl_rebox_${STEP}_run" "$TEN" box-desk hom' >"$T/out" 2>&1
}
q() { psql_owner -c "$1"; }

# 1 --------------------------------------------------------------------------
step copy t1; rc=$?
[[ $rc -eq 0 ]] && grep -q "channel_seats 2 aliases 1 live_lanes 1" "$T/out" &&
  pass "1 copy reports 2 channel seats, 1 alias, 1 live lane moved" || fail "1 copy rc=$rc: $(cat "$T/out")"
[[ "$(q "SELECT count(*) FROM channel_subscriptions WHERE tenant_id='t1' AND box_id='hom' AND backfilled_at IS NOT NULL")" == 2 &&
   "$(q "SELECT count(*) FROM channel_subscriptions WHERE tenant_id='t1' AND box_id='box-desk'")" == 2 ]] &&
  pass "1 channel seats copied with backfilled_at set (no back-fill burst), the old ones kept until retire" || fail "1 seats"
[[ "$(q "SELECT new_id FROM agent_id_aliases WHERE tenant_id='t1' AND old_id='CLE-002' AND box_id='hom'")" == c-002 ]] &&
  pass "1 the legacy id CLE-002 resolves to c-002 on the new box too" || fail "1 alias"
[[ "$(q "SELECT string_agg(agent_id || '@' || agent_box || ':' || state, ' ' ORDER BY agent_id, agent_box) FROM fleet_lanes WHERE tenant_id='t1'")" == \
   "c-010@hom:live c-011@box-desk:done c-012@box-desk:live c-012@hom:live" ]] &&
  pass "1 the live lane moved, the done lane stayed, an existing new-box row was not overwritten" ||
  fail "1 lanes: $(q "SELECT string_agg(agent_id || '@' || agent_box || ':' || state, ' ' ORDER BY agent_id, agent_box) FROM fleet_lanes WHERE tenant_id='t1'")"

# 2 --------------------------------------------------------------------------
[[ "$(q "SELECT count(*) FROM channel_subscriptions WHERE tenant_id='t2' AND box_id='hom'")" == 0 &&
   "$(q "SELECT count(*) FROM fleet_lanes WHERE tenant_id='t2' AND agent_box='hom'")" == 1 &&
   "$(q "SELECT count(*) FROM agent_id_aliases WHERE tenant_id='t2' AND box_id='hom'")" == 0 ]] &&
  pass "2 CONTROL: t2's rows are untouched by t1's copy" || fail "2 t2 touched"

# 3 --------------------------------------------------------------------------
step copy t1; rc=$?
[[ $rc -eq 0 ]] && grep -q "channel_seats 0 aliases 0 live_lanes 0" "$T/out" && pass "3 a second copy is a no-op" || fail "3 rerun: $(cat "$T/out")"

# 4 --------------------------------------------------------------------------
step verify t1 seated; rc=$?
[[ $rc -eq 0 ]] && grep -q "box-desk 1 1 2 0" "$T/out" && grep -q "hom 0 0 2 0" "$T/out" &&
  pass "4 verify: box pinned roster seats unacked for both boxes" || fail "4 verify rc=$rc: $(cat "$T/out")"
q "INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at)
   VALUES ('t1', '11111111-1111-4111-8111-111111111111', gen_random_uuid(), now(), 'box-wui', 'HUM-1', 'box-desk', 'c-002', 'note', 'x', '{}'::jsonb, 'sig', '\\x00', now() + interval '1 day'),
          ('t1', '22222222-2222-4222-8222-222222222222', gen_random_uuid(), now(), 'box-wui', 'HUM-1', 'box-desk', 'c-002', 'note', 'y', '{}'::jsonb, 'sig', '\\x00', now() + interval '1 day')" >/dev/null
q "INSERT INTO deliveries (tenant_id, msg_id, to_box, state, expires_at) VALUES ('t1', '22222222-2222-4222-8222-222222222222', 'box-desk', 'expired', now())" >/dev/null
step verify t1 seated; rc=$?
[[ $rc -eq 0 ]] && grep -q "box-desk 1 1 2 0" "$T/out" && pass "4 an expired delivery does not count as left behind" || fail "4 expired: $(cat "$T/out")"
q "INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) VALUES ('t1', '11111111-1111-4111-8111-111111111111', 'box-desk', now() + interval '1 day')" >/dev/null
step verify t1 seated; rc=$?
[[ $rc -ne 0 ]] && grep -q "1 delivery(ies) for box-desk are not acked after its drain" "$T/out" &&
  pass "4 a queued delivery left under the drained box fails verify" || fail "4 queued: rc=$rc $(cat "$T/out")"
step verify t1; rc=$?
[[ $rc -eq 0 ]] && grep -q "box-desk 1 1 2 1" "$T/out" && pass "4 before a drain the same row is only reported" || fail "4 pre-drain: rc=$rc $(cat "$T/out")"
[[ "$(q "SELECT count(*) FROM deliveries")" == 2 ]] && pass "4 verify wrote nothing" || fail "4 verify wrote"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
