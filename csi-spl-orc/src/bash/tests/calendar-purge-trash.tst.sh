#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_calendar_purge_trash (spec 097 T004, 4.8, FR-008) removes
#          only the calendar events deleted more than cnf
#          env.calendar.trash_retention_days ago, in every workspace. Part A
#          stubs the cloud (spl_via_proxy records its call); part B runs the
#          SQL against a REAL throwaway Postgres with the real rdb migrations,
#          as a NON-owner login so row-level security binds (SKIP when no
#          docker / psql / cached postgres image).
#   A1. ENV must be dev or prd
#   A2. DRY_RUN defaults to 1 (the count path); DRY_RUN=0 is the delete path
#   A3. absent retention = 30; CONTROL: a retention that is not a whole
#       number of days >= 1 is refused before any DB call
#   B1. dry run: counts the events deleted more than 30 days ago in both
#       workspaces, deletes nothing
#   B2. the purge drops exactly those two, keeps a 29-day deletion and the
#       live events; a series' exception goes with its series (CASCADE);
#       CONTROL: at 28 days the 29-day one goes too, the live ones stay
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-calendar-purge-trash.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# A ---------------------------------------------------------------------------
# runa <days|-> [VAR=val ...]: the action with the cloud stubbed; - leaves the
# key out of the cnf
runa() {
  local days="$1"; shift
  : >"$T/calls"
  printf 'env:\n  calendar:\n' >"$T/cnf.yaml"
  [[ "$days" != - ]] && printf '    trash_retention_days: %s\n' "$days" >>"$T/cnf.yaml"
  env -u DRY_RUN FUNC="$FUNC" T="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { echo "proxy dry=$CAL_DRY days=$CAL_TRASH_DAYS $*" >>"$T/calls"; echo 0 >"$2"; }
    do_spl_calendar_purge_trash' >"$T/o" 2>"$T/e"
}

runa 30 ENV=lde; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. ENV=lde refused before any DB call" || fail "A1. rc=$rc $(cat "$T/calls")"

runa 45 ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy dry=1 days=45 _spl_calendar_purge_trash_run' "$T/calls" &&
  grep -q '"dry_run":true,"retention_days":45,"older":0' "$T/o" &&
  pass "A2. DRY_RUN defaults to 1; the retention is cnf's 45" || fail "A2. rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"
runa 45 ENV=prd DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy dry=0 days=45 ' "$T/calls" && grep -q '"env":"prd","dry_run":false' "$T/o" &&
  pass "A2. DRY_RUN=0 is the delete path" || fail "A2. delete rc=$rc $(cat "$T/calls" "$T/o")"

runa - ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q ' days=30 ' "$T/calls" && pass "A3. no cnf retention: 30 days" || fail "A3. rc=$rc $(cat "$T/calls" "$T/e")"
for bad in 0 -5 abc 1.5; do
  runa "$bad" ENV=dev DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'trash_retention_days is not a whole number' "$T/e" &&
    pass "A3. CONTROL: retention '$bad' refused, no DB call" || fail "A3. '$bad' rc=$rc $(cat "$T/calls" "$T/e")"
done

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
PG_CTR="spl-cal-purge-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

# t1: deleted 40 and 29 days ago, one live; t2: deleted 31 days ago (a series
# with one exception row), one live.
for t in t1 t2; do
  q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null
done
ev() { # ev <tenant> <title> <deleted days ago|-> [rrule]
  local del=NULL rr=NULL
  [[ "$3" != - ]] && del="now() - make_interval(days => $3)"
  [[ -n "${4:-}" ]] && rr="'$4'"
  q "INSERT INTO calendar_events (tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id, rrule, deleted_at, deleted_by)
     VALUES ('$1', '$2', 'other', now(), now() + interval '1 hour', 'human', 'HUM-1', $rr, $del, CASE WHEN $del IS NULL THEN NULL ELSE 'HUM-1' END)
     RETURNING event_id"
}
ev t1 old40 40 >/dev/null; ev t1 recent29 29 >/dev/null; ev t1 live1 - >/dev/null
series="$(ev t2 series31 31 'FREQ=DAILY')"; ev t2 live2 - >/dev/null
q "INSERT INTO calendar_events (tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id, recurring_event_id, original_start)
   VALUES ('t2', 'exception', 'other', now(), now() + interval '1 hour', 'human', 'HUM-1', '$series', now())" >/dev/null
left() { q "SELECT coalesce(string_agg(title, ',' ORDER BY title), '') FROM calendar_events"; }

# runp <days> <dry>: the purge SQL path, through the real DB as the runtime login
runp() {
  env FUNC="$FUNC" CAL_DRY="$2" CAL_TRASH_DAYS="$1" SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$FUNC"
    _spl_calendar_purge_trash_run /dev/stdout' >"$T/o" 2>&1
}
all="exception,live1,live2,old40,recent29,series31"
runp 30 1; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 2 && "$(left)" == "$all" ]] &&
  pass "B1. dry run: 2 events past 30 days in both workspaces, nothing deleted" || fail "B1. rc=$rc $(cat "$T/o") / $(left)"

runp 30 0; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 2 && "$(left)" == "live1,live2,recent29" ]] &&
  pass "B2. the purge dropped old40 and series31 with its exception, kept recent29 and the live ones" ||
  fail "B2. rc=$rc $(cat "$T/o") / $(left)"
runp 28 0; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 1 && "$(left)" == "live1,live2" ]] &&
  pass "B2. CONTROL: at 28 days recent29 goes too, the live events stay" || fail "B2. control rc=$rc $(cat "$T/o") / $(left)"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
