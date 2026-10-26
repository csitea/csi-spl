#!/usr/bin/env bash
# do_spl_workspace_seat_alarm's hub query (_spl_sal_read, spec 158 B,
# SPL-3504) against a REAL throwaway Postgres carrying the real rdb
# migrations, as the NON-owner runtime login, so row-level security binds and
# the operator scope is what lets it read every workspace.
#   1. the query runs on the migrated schema: ws-new (member posts, no seat)
#      is listed with its post count; t1 (an agent seat) is not
#   2. CONTROL: a workspace with only HUM roster rows still counts as 0 seats;
#      a suspended / archived one, one with no member post in the window, and
#      one whose only posts are agents' are not listed
#   3. RED CONTROL: seat an agent in ws-new -> it leaves the list
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
PG_CTR="spl-seat-alarm-pg-$$"
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

# m <tenant> <msg n> <from> <minutes ago>
m() {
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', '10000000-0000-4000-8000-0000000000$2', '00000000-0000-4000-8000-0000000000$2', 'general', now(),
            'box-wui', '$3', 'box-desk', 'ALL-0', 'note', 'hello', '{}'::jsonb, 'sig', '\\x00',
            now() - interval '$4 minutes', now() + interval '30 days')" >/dev/null || fail "seed $1 msg $2"
}
seat() {
  psql_owner -c "INSERT INTO boxes (tenant_id, box_id) VALUES ('$1', '$2') ON CONFLICT DO NOTHING;
                 INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('$1', '$2', '$3')" >/dev/null || fail "seat $1 $3"
}
i=10
for t in t1 ws-new ws-hum ws-arch ws-old ws-bots; do
  psql_owner -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('$i', 32), 'hex'))" >/dev/null || fail "tenant $t"
  i=$((i + 1))
done
psql_owner -c "UPDATE tenants SET archived_at = now(), suspended_at = now() WHERE tenant_id = 'ws-arch'" >/dev/null
m t1 01 HUM-1 30; seat t1 box-desk c-001
m ws-new 02 HUM-7 20; m ws-new 03 HUM-7 10; m ws-new 04 HUM-8 5
m ws-hum 05 HUM-2 15; seat ws-hum box-wui HUM-2
m ws-arch 06 HUM-3 15
m ws-old 07 HUM-4 $((8 * 24 * 60))
m ws-bots 08 c-002 15

read_rows() {
  env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" OUT="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-workspace-seat-alarm.func.sh"
    _spl_sal_read "$OUT"'
}
read_rows "$T/rows" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qE $'^ws-new\t3\t[0-9]+$' "$T/rows" && ! grep -q '^t1' "$T/rows" &&
  pass "1. the query runs as the runtime role: ws-new (3 member posts, no seat) listed, t1 (seated) not" ||
  fail "1. rc=$rc rows=$(cat "$T/rows" 2>/dev/null) $(cat "$T/o")"
[[ "$(cut -f1 "$T/rows" | tr '\n' ' ')" == "ws-hum ws-new " ]] &&
  pass "2. a HUM-only roster is 0 seats; archived, out-of-window and agent-only workspaces are not listed" ||
  fail "2. got: $(cut -f1 "$T/rows" | tr '\n' ' ')"
seat ws-new box-desk c-002
read_rows "$T/rows2" >"$T/o" 2>&1
[[ "$(cut -f1 "$T/rows2" | tr '\n' ' ')" == "ws-hum " ]] &&
  pass "3. RED CONTROL: an agent seated in ws-new takes it off the list" || fail "3. got: $(cat "$T/rows2") $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
