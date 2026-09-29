#!/usr/bin/env bash
# do_spl_topic_delete: the argument guards (hermetic), then the recursive topic
# walk against a REAL throwaway Postgres carrying the real rdb migrations, as a
# NON-owner login so rdb 0014 row-level security binds.
#
# The controls are the point:
#   - DRY_RUN=1 runs the same delete and rolls it back: counts unchanged
#   - DRY_RUN=0 without TOPIC_DELETE_CONFIRM=<env>/<tenant>/<task> is refused
#     before any cloud call
#   - the walk takes the topic's rows, its message-rooted thread and its
#     sub-task, and NOTHING of a sibling topic
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-topic-delete.func.sh"
grep -qE 'DELETE FROM (tenants|humans|pins|boxes|roster|channels)' "$FUNC" \
  && fail "the delete touches an identity table" || pass "the delete removes messages rows only"
grep -q 'do_spl_db_backup' "$FUNC" && pass "DRY_RUN=0 takes a backup first (do_spl_db_backup)" || fail "no backup step"

# --- the argument guards, sourced like the other orc tests (no ./run) ---------
GOODTASK=008fd14a-5311-418b-a5b6-33d0ea690215
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u TENANT_ID -u TASK_ID -u DRY_RUN -u TOPIC_DELETE_CONFIRM \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_topic_delete' >"$T/out" 2>&1 </dev/null
}
guard() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  act "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
guard "a bad TENANT_ID"               "TENANT_ID must be a tenant slug" TENANT_ID=T_1 TASK_ID=$GOODTASK
guard "a missing TASK_ID"             "TASK_ID must be a lowercase task uuid" TENANT_ID=t1
guard "a bad TASK_ID"                 "TASK_ID must be a lowercase task uuid" TENANT_ID=t1 TASK_ID=not-a-uuid
guard "a bad DRY_RUN"                 "DRY_RUN must be 0 or 1"          TENANT_ID=t1 TASK_ID=$GOODTASK DRY_RUN=yes
guard "DRY_RUN=0 without the confirm" "set TOPIC_DELETE_CONFIRM=dev/t1/$GOODTASK" TENANT_ID=t1 TASK_ID=$GOODTASK DRY_RUN=0
guard "a confirm for another task"    "set TOPIC_DELETE_CONFIRM=dev/t1/$GOODTASK" TENANT_ID=t1 TASK_ID=$GOODTASK DRY_RUN=0 TOPIC_DELETE_CONFIRM=dev/t1/other
act TENANT_ID=t1 TASK_ID=$GOODTASK DRY_RUN=0 TOPIC_DELETE_CONFIRM=dev/t1/$GOODTASK
grep -q REACHED-CLOUD "$T/out" && pass "CONTROL: the matching confirm passes the guards and reaches the cloud step" \
  || fail "the matching confirm was refused: $(cat "$T/out")"

# --- the recursive walk against a real Postgres ------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no cached $PG_IMAGE image; the SQL part is not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") guard assertions (SQL part skipped)"; exit 0; }
  echo "FAIL: $fails assertion(s)"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-topic-delete-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }

psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

# A topic T with: its card, a reply, a message-rooted thread on the card, and a
# sub-task under T; a sibling topic U that must survive. row(tenant,msg,task,parent,is_parent)
row() { # tenant msg task parent is_parent
  local parent="$4"; local pcol="NULL"; [[ -n "$parent" ]] && pcol="'$parent'"
  psql_owner -c "INSERT INTO messages (tenant_id,msg_id,task_id,parent_task_id,is_parent,ts,from_box,from_id,to_box,to_id,kind,body,msg,env_sig,env,expires_at)
    VALUES ('$1','$2','$3',$pcol,$5,now(),'box-a','ORC-1','box-a','ORC-2','note','x','{}'::jsonb,'sig','\\x00',now()+interval '30 days')" >/dev/null
}
psql_owner -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab',32),'hex')) ON CONFLICT DO NOTHING" >/dev/null
Tt=aaaaaaaa-0000-4000-8000-000000000001   # topic T task
Tc=aaaaaaaa-0000-4000-8000-0000000000c0   # T's card msg
St=aaaaaaaa-0000-4000-8000-0000000000a0   # sub-task of T
Uu=bbbbbbbb-0000-4000-8000-000000000001   # sibling topic U task
row t1 "$Tc" "$Tt" "" 1                                   # T card
row t1 aaaaaaaa-0000-4000-8000-0000000000d0 "$Tt" "" 0    # a reply in T
row t1 aaaaaaaa-0000-4000-8000-0000000000e0 "$Tc" "" 0    # a message-rooted thread on the card (task = card msg_id)
row t1 aaaaaaaa-0000-4000-8000-0000000000f0 "$St" "$Tt" 1 # a sub-task whose parent is T
row t1 bbbbbbbb-0000-4000-8000-0000000000c0 "$Uu" "" 1    # sibling topic U card
cnt() { psql_owner -c "SELECT count(*) FROM messages WHERE tenant_id='t1' AND task_id='$1'"; }
walk_cnt() { psql_owner -c "SELECT count(*) FROM messages WHERE tenant_id='t1'"; }

del() { # dry
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com \
    SPL_PROXY_DSN="$RT_DSN" SPL_TD_TENANT=t1 SPL_TD_TASK="$Tt" SPL_TD_DRY="$1" \
    bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-topic-delete.func.sh"
    _spl_topic_delete_run' >"$T/out" 2>&1
}
before_total="$(walk_cnt)"
del 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "deleted=4 committed=f" "$T/out" && [[ "$(walk_cnt)" == "$before_total" ]] \
  && pass "DRY_RUN walks 4 rows (card + reply + thread + sub-task) and rolls back: nothing removed" \
  || fail "dry: rc=$rc $(cat "$T/out") total=$(walk_cnt) want $before_total"

del 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "deleted=4 committed=t" "$T/out" && pass "DRY_RUN=0 removes the 4 topic rows and commits" \
  || fail "del: rc=$rc $(cat "$T/out")"
[[ "$(cnt "$Tt")" == 0 && "$(cnt "$St")" == 0 && "$(cnt "$Tc")" == 0 ]] \
  && pass "the topic, its thread and its sub-task are gone" || fail "leftovers: T=$(cnt "$Tt") St=$(cnt "$St") thread=$(cnt "$Tc")"
[[ "$(cnt "$Uu")" == 1 ]] && pass "CONTROL: the sibling topic U survives" || fail "sibling U taken: $(cnt "$Uu")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
