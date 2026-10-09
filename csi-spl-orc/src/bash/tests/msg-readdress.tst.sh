#!/usr/bin/env bash
# do_spl_msg_readdress (spec 117 FR-6): the argument guards and the n-mismatch
# refusal on a stubbed db path (hermetic), then the SQL against a REAL
# throwaway Postgres carrying the real rdb migrations, connected as a
# NON-owner login so rdb 0014/0021 row-level security actually binds.
#
# The controls are the point:
#   - DRY_RUN=1 lists the 5 rows and changes nothing
#   - an id with no row, a channel row, another sender's row: n mismatch, refused
#   - DRY_RUN=0 reports UPDATE 5; to_id and msg->'to' move, env bytes do not
#   - other tenants, senders and channel rows are untouched; a re-run is refused
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-msg-readdress.func.sh"
grep -q "SET LOCAL app.tenant_id = :'tenant'" "$FUNC" && pass "runs under the tenant's RLS context" || fail "no app.tenant_id"
grep -qE '\$SPL_RA_(TENANT|FROM|TO|IDS)' <(sed -n "/<<'SQL'/,/^SQL$/p" "$FUNC" | tail -n +2) \
  && fail "a value is spliced into the SQL" || pass "values travel as psql variables only"

# --- the argument guards, sourced like the other orc tests (no ./run) ---------
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u TENANT_ID -u FROM_ID -u NEW_TO -u MSG_IDS -u DRY_RUN \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_msg_readdress' >"$T/out" 2>&1 </dev/null
}
OK_ARGS=(TENANT_ID=t1 FROM_ID=HUM-46 NEW_TO=HUM-10 "MSG_IDS=86abbd6a,b7b1b5e7-26a5-4f11-9957-c644d1649e3d")
guard() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  act "${OK_ARGS[@]}" "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
guard "a bad TENANT_ID"         "TENANT_ID must be a tenant slug"   TENANT_ID=T_1
guard "a bad FROM_ID"           "FROM_ID must look like"            "FROM_ID=HUM-46' OR '1'='1"
guard "NEW_TO=ALL-0"            "NEW_TO must look like"             NEW_TO=ALL-0
guard "no MSG_IDS"              "MSG_IDS must list"                 MSG_IDS=
guard "a short id"              "neither a uuid nor"                MSG_IDS=86abbd6
guard "an id with SQL in it"    "neither a uuid nor"                "MSG_IDS=86abbd6a'--"
guard "an id given twice"       "given twice"                       MSG_IDS=86abbd6a,86ABBD6A-1290-43bb-a5cf-5180de114e3b
guard "a bad DRY_RUN"           "DRY_RUN must be 0 or 1"            DRY_RUN=yes
act "${OK_ARGS[@]}" DRY_RUN=0
grep -q REACHED-CLOUD "$T/out" && pass "CONTROL: good inputs pass the guards and reach the cloud step" \
  || fail "good inputs were refused: $(cat "$T/out")"

# --- the stubbed db path: what the run does with each psql answer -------------
stub() { # <dry> <psql stdout>: _spl_msg_readdress_run against a psql stub
  env PROJ_PATH="$PROJ_ROOT" ENV=dev GCP_ACCOUNT=test@example.com SPL_PROXY_DSN=stub SPL_RA_TENANT=t1 \
    SPL_RA_FROM=HUM-46 SPL_RA_TO=HUM-10 SPL_RA_IDS=a,b,c SPL_RA_DRY="$1" STUB_OUT="$2" bash -c '
    do_log() { echo "$*"; }
    spl_pg_env() { cat >/dev/null; printf "%b\n" "$STUB_OUT"; }
    source "$PROJ_PATH/src/bash/run/spl-msg-readdress.func.sh"
    _spl_msg_readdress_run' >"$T/out" 2>&1
}
stub 0 'MATCH|a|t|ALL-0\nMATCH|b|t|ALL-0\nN|2|3|f'; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL n=2 does not match the 3 id(s)" "$T/out" && ! grep -q "^OK" "$T/out" \
  && pass "stub: n=2 of 3 ids is refused" || fail "stub mismatch: rc=$rc $(cat "$T/out")"
stub 0 'N|3|3|t\nUPDATE|2'; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL UPDATE 2 != n=3" "$T/out" && pass "stub: UPDATE 2 for n=3 is reported as rolled back" \
  || fail "stub update count: rc=$rc $(cat "$T/out")"
stub 0 'N|3|3|t\nUPDATE|3'; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK UPDATE 3:" "$T/out" && pass "CONTROL stub: n=3, UPDATE 3 is OK" || fail "stub ok: rc=$rc $(cat "$T/out")"

# --- the SQL against a real Postgres -----------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no cached $PG_IMAGE image; the SQL part is not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") hermetic assertions (SQL part skipped)"; exit 0; }
  echo "FAIL: $fails assertion(s)"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-msg-readdress-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }

psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
# A NON-owner, non-superuser login: only then does FORCE ROW LEVEL SECURITY bind.
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

seed() { # <tenant> <msg_id> <from> <to> <channel or ''>
  psql_owner <<PSQL >/dev/null
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$1', decode(repeat('ab', 32), 'hex')) ON CONFLICT DO NOTHING;
INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, channel, kind, body, msg, env_sig, env, expires_at)
VALUES ('$1', '$2', gen_random_uuid(), now(), 'box-a', '$3', 'box-a', '$4', NULLIF('$5', ''), 'note', 'seed',
        jsonb_build_object('to', '$4', 'from', '$3'), 'sig', '\\x00ab', now() + interval '30 days');
PSQL
}
A=(86abbd6a-1290-43bb-a5cf-5180de114e3b b7b1b5e7-26a5-4f11-9957-c644d1649e3d 50ed77e0-8616-4803-aa14-12ed0619a2e7
   22f73584-a809-4d9f-a0fd-866cd18bc15d 266f4506-3feb-4ac4-9d63-295e5eac98b2)
for id in "${A[@]}"; do seed t2 "$id" HUM-46 ALL-0 ''; done
seed t2 11111111-0000-4000-8000-000000000001 HUM-46 ALL-0 lobby
seed t2 22222222-0000-4000-8000-000000000002 HUM-27 ALL-0 ''
seed t3 33333333-0000-4000-8000-000000000003 HUM-46 ALL-0 ''

run() { # <dry> <ids> [tenant]
  env PROJ_PATH="$PROJ_ROOT" ENV=dev GCP_ACCOUNT=test@example.com SPL_PROXY_DSN="$RT_DSN" \
    SPL_RA_TENANT="${3:-t2}" SPL_RA_FROM=HUM-46 SPL_RA_TO=HUM-10 SPL_RA_IDS="$2" SPL_RA_DRY="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-msg-readdress.func.sh"
    _spl_msg_readdress_run' >"$T/out" 2>&1
}
moved() { psql_owner -c "SELECT count(*) FROM messages WHERE to_id = 'HUM-10'"; }
FIVE="${A[0]:0:8},${A[1]},${A[2]:0:8},${A[3]},${A[4]}"

run 1 "$FIVE"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(grep -c '^MATCH msg=' "$T/out")" == 5 ]] && grep -q "n=5 of 5 id(s)" "$T/out" \
  && grep -q "UPDATE messages SET to_id='HUM-10'" "$T/out" && grep -q "DRY_RUN rolled back" "$T/out" && [[ "$(moved)" == 0 ]] \
  && pass "DRY_RUN=1, 5 ids (prefixes and uuids): lists 5 rows, n=5 and the UPDATE; nothing moved" \
  || fail "dry 5: rc=$rc moved=$(moved) $(cat "$T/out")"
grep -q 'seed' "$T/out" && fail "the output carries a message body" || pass "the output carries ids only, no body"

mismatch() { # <label> <ids>
  run 0 "$2"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "does not match" "$T/out" && ! grep -q '^UPDATE|' "$T/out" && [[ "$(moved)" == 0 ]] \
    && pass "$1: refused, nothing moved" || fail "$1: rc=$rc moved=$(moved) $(cat "$T/out")"
}
mismatch "DRY_RUN=0, 6 ids with one unknown (n=5 of 6)"   "$FIVE,deadbeef"
mismatch "DRY_RUN=0, a channel row among the ids"         "$FIVE,11111111"
mismatch "DRY_RUN=0, another sender's row among the ids"  "${A[0]},22222222"
mismatch "DRY_RUN=0, tenant t3's row (RLS + tenant)" "${A[0]},33333333"
run 0 "${A[0]}" t3; rc=$?
[[ $rc -ne 0 ]] && grep -q "n=0 of 1" "$T/out" && pass "an id of tenant t2 is not found from tenant t3" || fail "cross tenant: $(cat "$T/out")"

env_before="$(psql_owner -c "SELECT string_agg(encode(env, 'hex'), ',' ORDER BY msg_id) FROM messages")"
run 0 "$FIVE"; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK UPDATE 5:" "$T/out" && pass "DRY_RUN=0, 5 ids: UPDATE 5" || fail "real 5: rc=$rc $(cat "$T/out")"
[[ "$(psql_owner -c "SELECT count(*) FROM messages WHERE tenant_id='t2' AND from_id='HUM-46' AND channel IS NULL AND to_id='HUM-10' AND msg->>'to'='HUM-10'")" == 5 ]] \
  && pass "the 5 rows read back to_id=HUM-10 and msg.to=HUM-10" || fail "read back: $(psql_owner -c "SELECT msg_id, to_id, msg->>'to' FROM messages")"
[[ "$(psql_owner -c "SELECT count(*) FROM messages WHERE to_id='ALL-0' AND msg->>'to'='ALL-0'")" == 3 ]] \
  && pass "CONTROL: the channel row, HUM-27's row and tenant t3's row keep ALL-0" || fail "controls moved"
[[ "$(psql_owner -c "SELECT string_agg(encode(env, 'hex'), ',' ORDER BY msg_id) FROM messages")" == "$env_before" ]] \
  && pass "the env bytes are unchanged" || fail "env bytes changed"
run 0 "$FIVE"; rc=$?
[[ $rc -ne 0 ]] && grep -q "n=0 of 5" "$T/out" && pass "a re-run finds n=0 and is refused" || fail "re-run: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
