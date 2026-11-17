#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 180 T6, do_spl_calendar_adopt_outlook. Synthetic rows only.
#   A1. a bad var fails fast, before any DB call; DRY_RUN=0 needs
#       ADOPT_EXPECT, and on prd OWNER_GO
#   A2. DRY_RUN (the default) takes the read-only path
#   B1. on a REAL throwaway Postgres (real rdb migrations, a non-owner login
#       so RLS binds): the dry run counts the owner's live private keyless
#       rows whose "source: <id>" (anywhere in the text, as the 2026-11-17
#       one-off wrote it) is an Outlook id, and the other "source:" rows it
#       leaves alone; writes nothing
#   B2. DRY_RUN=0 keys exactly those: outlook:<owner>:<24 hex of SHA-256>,
#       the same as sha256sum; another owner's row, a row with no source,
#       a source that is not an Outlook id, a deleted row and another
#       workspace's row keep no key
#   B3. CONTROL: a wrong ADOPT_EXPECT rolls back, nothing keyed
# Part B needs docker, psql and a cached postgres image; without them it
# does not run and the test says so in a NOTE line (CI's orc job has them).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-calendar-adopt-outlook.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# A ---------------------------------------------------------------------------
runa() {
  : >"$T/calls"
  env -u DRY_RUN FUNC="$FUNC" T="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "${FUNC%/src/bash/run/*}"/lib/bash/funcs/*.func.sh; do source "$f"; done
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { echo "proxy dry=$ADOPT_DRY $*" >>"$T/calls"; echo "3|3|3|0" >"$2"; echo "adopted=3 committed=t" >>"$2"; }
    do_spl_calendar_adopt_outlook' >"$T/o" 2>"$T/e"
}
SET=(ENV=prd TENANT_ID=csitea EVENT_OWNER=HUM-10)
for bad in "ENV=" "ENV=stg" "TENANT_ID=" "TENANT_ID=W_1" "EVENT_OWNER=" "EVENT_OWNER=c-042" "DRY_RUN=yes"; do
  runa "${SET[@]}" "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. $bad fails fast, no DB call" || fail "A1. $bad rc=$rc $(cat "$T/calls")"
done
runa "${SET[@]}" DRY_RUN=0 OWNER_GO=1f5e074b; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'needs ADOPT_EXPECT' "$T/e" && pass "A1. DRY_RUN=0 without ADOPT_EXPECT refused" || fail "A1. expect rc=$rc"
runa "${SET[@]}" DRY_RUN=0 ADOPT_EXPECT=3; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'needs OWNER_GO' "$T/e" && pass "A1. prd DRY_RUN=0 without OWNER_GO refused" || fail "A1. go rc=$rc"
runa "${SET[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy dry=1 _spl_calendar_adopt_outlook_run' "$T/calls" \
  && grep -qxF '{"env":"prd","tenant":"csitea","owner":"HUM-10","dry_run":true,"candidates":3,"distinct_keys":3,"other_source":3,"taken":0}' "$T/o" \
  && pass "A2. DRY_RUN (default) is the read-only path, counts only" || fail "A2. rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"
runa "${SET[@]}" DRY_RUN=0 ADOPT_EXPECT=3 OWNER_GO=1f5e074b; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy dry=0 ' "$T/calls" && grep -q 'OK adopted 3 rows' "$T/e" \
  && pass "A2. DRY_RUN=0 with ADOPT_EXPECT and OWNER_GO is the write path" || fail "A2. write rc=$rc $(cat "$T/e")"

# B ---------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "NOTE: part B did not run: no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-cal-adopt-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$TEST_DIR/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
for t in ws-a ws-b; do q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null; done
ev() { # ev <tenant> <title> <owner> <description> [deleted]
  local del=NULL
  [[ -n "${5:-}" ]] && del="now()"
  q "INSERT INTO calendar_events (tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id, owner_id, audience, mentions, description, deleted_at, deleted_by)
     VALUES ('$1', '$2', 'other', now(), now() + interval '1 hour', 'agent', 'c-840', '$3', 'private', ARRAY['$3'], '$4',
       $del, CASE WHEN $del IS NULL THEN NULL ELSE 'c-840' END)" >/dev/null
}
ID1=0400000082000E0001A@20270201T090000 ID2=0400000082000E0002B@20270202T103000
ev ws-a one HUM-10 "Imported from Outlook (busy), Room 1. source: $ID1"
ev ws-a two HUM-10 $'Imported\nsource:'"$ID2"$'\r\nmore'
ev ws-a nosrc HUM-10 'no source here'
ev ws-a notid HUM-10 'source: a mail thread, not an Outlook id'
ev ws-a theirs HUM-11 "source: 0400000082000E0003C@20270201T090000"
ev ws-a gone HUM-10 "source: 0400000082000E0004D@20270201T090000" deleted
ev ws-b wsb HUM-10 "source: 0400000082000E0005E@20270201T090000"
keys() { q "SELECT title || '=' || coalesce(source_key, '-') FROM calendar_events ORDER BY title" | tr '\n' ' '; }
want_key() { printf 'outlook:HUM-10:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-24)"; }
runp() { # runp <dry> [expect]
  env FUNC="$FUNC" ADOPT_DRY="$1" ADOPT_EXPECT="${2:-}" TENANT_ID=ws-a EVENT_OWNER=HUM-10 SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "${FUNC%/src/bash/run/*}"/lib/bash/funcs/*.func.sh; do source "$f"; done
    source "$FUNC"
    _spl_calendar_adopt_outlook_run /dev/stdout' >"$T/o" 2>&1
}
none="gone=- nosrc=- notid=- one=- theirs=- two=- wsb=- "
runp 1; rc=$?
[[ $rc -eq 0 ]] && grep -qxF '2|2|1|0' "$T/o" && [[ "$(keys)" == "$none" ]] \
  && pass "B1. dry run: 2 candidates, 1 other source left alone, nothing keyed" || fail "B1. rc=$rc $(cat "$T/o") / $(keys)"
runp 0 3; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'adopted=2 committed=f' "$T/o" && [[ "$(keys)" == "$none" ]] \
  && pass "B3. CONTROL: ADOPT_EXPECT=3 against 2 rows rolls back, nothing keyed" || fail "B3. rc=$rc $(cat "$T/o") / $(keys)"
runp 0 2; rc=$?
want="gone=- nosrc=- notid=- one=$(want_key "$ID1") theirs=- two=$(want_key "$ID2") wsb=- "
[[ $rc -eq 0 ]] && grep -qxF 'adopted=2 committed=t' "$T/o" && [[ "$(keys)" == "$want" ]] \
  && pass "B2. DRY_RUN=0 keys exactly the 2 rows with sha256sum's key, the others keep none" || fail "B2. rc=$rc $(cat "$T/o") / $(keys) / want $want"
runp 1; rc=$?
[[ $rc -eq 0 ]] && grep -qxF '0|0|1|0' "$T/o" && pass "B2. a second dry run finds nothing left" || fail "B2. again rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
