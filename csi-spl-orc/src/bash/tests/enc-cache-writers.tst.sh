#!/usr/bin/env bash
# spec 136 L11 (SPL-1679), FR9 W5: the unanswered-sweep row cache and the
# msg-dedup DUP line copy a body out of the hub. A workspace whose
# tenants.settings spool_enc is true (L6a, not re-implemented here) contributes
# no body to that cache file or to a printed line. A plain workspace, and one
# with spool_enc false, stay byte for byte what they are today.
#
# The assert that fails on master, before the writers honour the flag:
#   "enc body absent from the sweep rows"
#   "enc body absent from the DUP line"
# On master both rows still carry left(body, …) for every workspace.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

PLAIN_MARK='L11PLAIN9c4e1a'
ENC_MARK='L11ENC9c4e1a'
OFF_MARK='L11OFF9c4e1a'

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
PG_CTR="spl-enc-cache-pg-$$"
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

# plain1: the key absent (the default, false). enc1: spool_enc true.
# off1: the key stored false. None of these ids is a real workspace.
psql_owner <<'PSQL' >/dev/null || { fail "seed tenants"; exit 1; }
INSERT INTO tenants (tenant_id, root_pubkey) VALUES
  ('plain1', decode(repeat('ab', 32), 'hex')),
  ('enc1', decode(repeat('ac', 32), 'hex')),
  ('off1', decode(repeat('ad', 32), 'hex'));
UPDATE tenants SET settings = '{"spool_enc": true}'::jsonb WHERE tenant_id = 'enc1';
UPDATE tenants SET settings = '{"spool_enc": false}'::jsonb WHERE tenant_id = 'off1';
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES
  ('plain1', 'dev', 'dev', 'HUM-1'),
  ('enc1', 'dev', 'dev', 'HUM-1'),
  ('off1', 'dev', 'dev', 'HUM-1');
PSQL

N=0
msg() { # <tenant> <task-n> <seconds> <body>
  N=$((N + 1))
  local id; id="$(printf '20000000-0000-4000-8000-%012d' "$N")"
  local task; task="$(printf '30000000-0000-4000-8000-%012d' "$2")"
  psql_owner -v body="$4" <<PSQL >/dev/null
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at)
VALUES ('$1', '$id', '$task', 'dev', timestamptz '2026-10-13 08:00:00+00' + interval '$3 seconds',
        'box-wui', 'HUM-2', 'box-desk', 'c-002', 'note', :'body', '[]'::jsonb, '{}'::jsonb, 'sig', '\\x00',
        now() - interval '120 minutes' + interval '$3 seconds', now() + interval '30 days');
PSQL
}
# two copies each, so dedup has one later row to print; the sweep keeps the last
msg plain1 1 0 "$PLAIN_MARK"
msg plain1 1 10 "$PLAIN_MARK"
msg enc1 2 0 "$ENC_MARK"
msg enc1 2 10 "$ENC_MARK"
msg off1 3 0 "$OFF_MARK"
msg off1 3 10 "$OFF_MARK"

env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" OUT="$T/rows" bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
  _spl_sweep_rows_read "$OUT"' >"$T/sweep.err" 2>&1; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$T/rows")" == 3 ]] && pass "sweep read: 3 topics" || fail "sweep read: rc=$rc $(cat "$T/sweep.err") $(cat "$T/rows" 2>/dev/null)"

grep -q "$PLAIN_MARK" "$T/rows" && pass "plain body still in the sweep rows" || fail "plain body missing from the sweep rows: $(cat "$T/rows")"
grep -q "$OFF_MARK" "$T/rows" && pass "spool_enc false still puts the body in the sweep rows" || fail "false flag dropped the body: $(cat "$T/rows")"
if grep -q "$ENC_MARK" "$T/rows"; then
  fail "enc body absent from the sweep rows: the cache row still holds $ENC_MARK"
else
  pass "enc body absent from the sweep rows"
fi

mkdir -p "$T/lease" "$T/cls"
env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" RT_DSN="$RT_DSN" LEASE_DIR="$T/lease" ENV=prd bash -c '
  set -uo pipefail
  do_log() { echo "$*" >&2; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
  spl_via_proxy() { "$@"; }
  spl_test_workspaces() { printf ""; }
  export SWEEP_NOW="$(date +%s)" SWEEP_TO_ID=c-002 SWEEP_ORCH_ID=c-001 ENVN="${ENV:-prd}"
  spl_sweep_rows_cached "$1"
  spl_sweep_classify "$1" "$LEASE_DIR/unanswered.state" "$2"' _ "$T/rows2" "$T/cls" >"$T/cache.err" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$T/lease/unanswered.rows" && -f "$T/cls/report.md" ]] && pass "cache and report written" || fail "cache path: rc=$rc $(cat "$T/cache.err")"
if grep -q "$ENC_MARK" "$T/lease/unanswered.rows" "$T/cls/report.md"; then
  fail "enc body absent from the row cache and the printed report"
else
  pass "enc body absent from the row cache and the printed report"
fi
grep -q "$PLAIN_MARK" "$T/lease/unanswered.rows" && grep -q "$PLAIN_MARK" "$T/cls/report.md" \
  && pass "plain body still reaches the cache and the printed report" || fail "plain body dropped from cache or report"

env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com \
  SPL_PROXY_DSN="$RT_DSN" SPL_DEDUP_TENANT="" SPL_DEDUP_DRY=1 bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-msg-dedup.func.sh"
  _spl_msg_dedup_run' >"$T/dedup.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "dedup dry-run ran" || fail "dedup: rc=$rc $(cat "$T/dedup.out")"
grep -q "^DUP tenant=plain1 .*| ${PLAIN_MARK}$" "$T/dedup.out" && pass "plain body still on the DUP line" || fail "plain DUP line: $(grep '^DUP tenant=plain1' "$T/dedup.out")"
grep -q "^DUP tenant=off1 .*| ${OFF_MARK}$" "$T/dedup.out" && pass "spool_enc false still prints the DUP head" || fail "off DUP line: $(grep '^DUP tenant=off1' "$T/dedup.out")"
if grep -q "$ENC_MARK" "$T/dedup.out"; then
  fail "enc body absent from the DUP line: printed $(grep '^DUP tenant=enc1' "$T/dedup.out")"
else
  pass "enc body absent from the DUP line"
fi
grep -qE '^DUP tenant=enc1 .*\| $' "$T/dedup.out" && pass "enc duplicate is still listed, head empty of the body" || fail "enc duplicate head: $(grep '^DUP tenant=enc1' "$T/dedup.out")"
[[ "$(psql_owner -c "SELECT count(*) FROM messages WHERE tenant_id='enc1'")" == 2 ]] && pass "DRY_RUN kept the enc rows" || fail "enc rows changed"

echo "---"
(( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
