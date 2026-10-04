#!/usr/bin/env bash
# do_spl_dispatch_subscribe's hub read (_spl_dispatch_subs_read) - its hum|
# line, the inbound guard's input (CLE-77876) - against a REAL throwaway
# Postgres with the real rdb migrations, as the non-owner runtime role so
# rdb 0014 row-level security binds to the tenant scope the read sets.
# Written after the first version alerted on posts stored BEFORE the
# workspace's box-wui pin (CLE-001, 2026-10-01): those are the replay's.
#   1. the read runs on the migrated schema and prints one hum| line
#   2. unsigned counts a post with no pin, a post after the pin and a post
#      under a revoked pin; NOT a post from before the live pin
#   3. posts: a signed one counts, an agent's, a DM, #issues, a typed_by
#      line and one outside the window do not
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
PG_CTR="spl-inbound-pg-$$"
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

psql_owner <<'PSQL' >/dev/null || fail "seed tenants/channels/pins"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('wp', decode(repeat('ab', 32), 'hex')),
  ('wn', decode(repeat('ac', 32), 'hex')), ('wr', decode(repeat('ad', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('wp', 'ops', 'ops', 'HUM-1'),
  ('wn', 'ops', 'ops', 'HUM-1'), ('wr', 'ops', 'ops', 'HUM-1');
INSERT INTO pins (tenant_id, box_id, pubkey, updated_at) VALUES
  ('wp', 'box-wui', decode(repeat('01', 32), 'hex'), now() - interval '30 minutes'),
  ('wr', 'box-wui', decode(repeat('02', 32), 'hex'), now() - interval '90 minutes');
UPDATE pins SET revoked_at = now() - interval '80 minutes' WHERE tenant_id = 'wr';
INSERT INTO boxes (tenant_id, box_id) VALUES ('wp', 'box-desk'), ('wp', 'box-sat'), ('wn', 'box-desk');
INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('wp', 'box-desk', 'c-001'), ('wp', 'box-desk', 'c-002'),
  ('wp', 'box-sat', 'c-003'), ('wp', 'box-desk', 'c-077'), ('wn', 'box-desk', 'c-002');
PSQL
n=0
# m <tenant> <channel|''> <from> <sig|''> <minutes ago>
m() {
  n=$((n + 1))
  local ch="NULL" box=box-desk id; [[ -n "$2" ]] && ch="'$2'"
  [[ "$3" == HUM-* ]] && box=box-wui
  id="$(printf '10000000-0000-4000-8000-%012d' "$n")"
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', '$id', '$id', $ch, now(), '$box', '$3', 'box-wui', 'ALL-0', 'note', 'x',
            '{}'::jsonb, '$4', '\\x00', now() - interval '$5 minutes', now() + interval '30 days')" >/dev/null ||
    fail "seed $*"
  LAST_ID="$id"
}
m wp ops HUM-2 '' 60           # before the pin: the replay's, not counted unsigned
m wp ops HUM-2 '' 45           # also before the pin
m wp ops HUM-2 '' 20           # after the pin and still unsigned: a live gap
m wp ops HUM-2 sig 10          # signed
m wp ops CLE-5 '' 10           # an agent
m wp '' HUM-2 '' 10            # a DM
m wp issues HUM-2 '' 10        # #issues
m wp ops HUM-2 '' 300          # outside the window
m wp ops HUM-2 '' 2            # inside the grace
m wp ops HUM-2 '' 15; psql_owner -c "UPDATE messages SET typed_by = 'HUM-2' WHERE msg_id = '$LAST_ID'" >/dev/null
m wn ops HUM-3 '' 60           # no pin at all
m wn ops HUM-3 '' 20
m wr ops HUM-4 '' 100          # before a pin that is now revoked
m wr ops HUM-4 '' 50

read_hum() {
  env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" W="$1" DISPATCH_ORCH=c-001 DISPATCH_MASTER=c-002 DISPATCH_FAILOVER=c-003 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-subscribe.func.sh"
    _spl_dispatch_subs_read "$W"' 2>&1
}
out="$(read_hum wp)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^hum|' <<<"$out")" == 1 ]] && pass "1. the read runs on the migrated schema as the runtime role, one hum| line" ||
  fail "1. rc=$rc $out"
[[ "$(grep '^hum|' <<<"$out")" == 'hum|4|1' ]] &&
  pass "2+3. pinned workspace: 4 human posts in the window, only the post-pin unsigned one counts" || fail "2. wp: $(grep '^hum|' <<<"$out")"
[[ "$(read_hum wn | grep '^hum|')" == 'hum|2|2' ]] && pass "2. no pin: every unsigned post counts" || fail "2. wn: $(read_hum wn | grep '^hum|')"
[[ "$(read_hum wr | grep '^hum|')" == 'hum|2|2' ]] && pass "2. a revoked pin covers nothing" || fail "2. wr: $(read_hum wr | grep '^hum|')"

# owner 2026-10-03 (every OD seat in every channel): the read names the
# roster rows of the OD seats, on every box, and no other agent's
[[ "$(grep '^ros|' <<<"$out" | tr '\n' ' ')" == 'ros|box-desk|c-001 ros|box-desk|c-002 ros|box-sat|c-003 ' ]] &&
  pass "4. the OD seats' roster rows, every box, no other agent, no other workspace" || fail "4. ros: $(grep '^ros|' <<<"$out")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
