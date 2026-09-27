#!/usr/bin/env bash
# do_spl_box_purge: the argument guards (hermetic), then the SQL against a REAL
# throwaway Postgres carrying the real rdb migrations, connected as a NON-owner
# login so rdb 0014 row-level security actually binds.
#
# The controls are the point:
#   - a box that said hello inside PURGE_MIN_IDLE_HOURS is held back, and the
#     whole statement rolls back, so a typo cannot half-purge a tenant
#   - another tenant's box is invisible (RLS), so it reads as "not pinned"
#     instead of being deleted
#   - messages and pins_history survive a purge: it removes an identity, not
#     history
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-box-purge.func.sh"
grep -q 'BOX_IDS' "$FUNC" && ! grep -qE "LIKE '|~ '\^box-|glob" "$FUNC" \
  && pass "the action has no pattern form: only the ids BOX_IDS names can be deleted" || fail "a pattern selector crept in"
grep -q 'DELETE FROM pins_history\|DELETE FROM messages\|DELETE FROM deliveries' "$FUNC" \
  && fail "the purge deletes history" || pass "the purge touches no history table (messages / deliveries / pins_history)"

# --- the argument guards, sourced like the other orc tests (no ./run) ---------
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_box_purge' >"$T/out" 2>&1 </dev/null
}
guard() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  act "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
guard "a bad TENANT_ID"            "TENANT_ID must be a tenant slug" TENANT_ID=T_1 BOX_IDS=box-a
guard "a BOX_IDS that is not a box id" "which is not a box id"       TENANT_ID=t1  BOX_IDS='box-a BAD!'
guard "box-wui"                    "box-wui is reserved"             TENANT_ID=t1  BOX_IDS='box-a box-wui'
guard "a duplicate in BOX_IDS"     "names box-a twice"               TENANT_ID=t1  BOX_IDS='box-a box-a'
guard "an empty BOX_IDS"           "BOX_IDS is required"             TENANT_ID=t1  BOX_IDS=''
guard "a silly PURGE_MIN_IDLE_HOURS" "PURGE_MIN_IDLE_HOURS must be"  TENANT_ID=t1  BOX_IDS=box-a PURGE_MIN_IDLE_HOURS=x

# --- the SQL against a real Postgres -----------------------------------------
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
PG_CTR="spl-box-purge-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }

psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
# A NON-owner, non-superuser login: only then does FORCE ROW LEVEL SECURITY bind.
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

seed() { # <tenant> <box> <hello sql> <agents...>
  local t="$1" b="$2" hello="$3"; shift 3
  psql_owner <<PSQL >/dev/null
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex')) ON CONFLICT DO NOTHING;
INSERT INTO pins (tenant_id, box_id, pubkey) VALUES ('$t', '$b', decode(repeat('cd', 32), 'hex'));
INSERT INTO pins_history (tenant_id, box_id, pubkey, reason) VALUES ('$t', '$b', decode(repeat('cd', 32), 'hex'), 'pin');
INSERT INTO boxes (tenant_id, box_id, last_hello_at) VALUES ('$t', '$b', $hello);
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('$t', 'lobby', 'lobby', 'hub') ON CONFLICT DO NOTHING;
INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at)
VALUES ('$t', gen_random_uuid(), gen_random_uuid(), now(), '$b', 'ORC-1', '$b', 'ORC-1', 'note', 'seed', '{}'::jsonb, 'sig', '\\x00', now() + interval '30 days');
PSQL
  local a
  for a in "$@"; do
    psql_owner -c "INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('$t', '$b', '$a')" >/dev/null
    psql_owner -c "INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id) VALUES ('$t', 'lobby', '$a', '$b')" >/dev/null
  done
}
seed t1 box-dead-a "now() - interval '40 hours'" ORC-1 ORC-9
seed t1 box-dead-b "NULL"                        ORC-2
seed t1 box-live   "now() - interval '1 hour'"   CLE-0
seed t1 box-keep   "now() - interval '99 hours'" CLE-7
seed t2 box-other  "now() - interval '99 hours'" ORC-1

purge() { # <tenant> <boxes> <idle> <dry>
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com \
    SPL_PROXY_DSN="$RT_DSN" SPL_PURGE_TENANT="$1" SPL_PURGE_BOXES="$2" SPL_PURGE_IDLE="$3" SPL_PURGE_DRY="$4" \
    bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-box-purge.func.sh"
    _spl_box_purge_run' >"$T/out" 2>&1
}
count() { psql_owner -c "SELECT count(*) FROM $1"; }

purge t1 "box-dead-a box-dead-b" 24 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN would purge 2 box(es)" "$T/out" && [[ "$(count "pins WHERE tenant_id='t1'")" == 4 ]] \
  && pass "DRY_RUN deletes nothing (t1 still has its 4 pins)" || fail "dry: rc=$rc $(cat "$T/out")"
grep -qE '^ *box-keep *\| f ' "$T/out" && grep -qE '^ *box-dead-a *\| t ' "$T/out" && ! grep -q box-other "$T/out" \
  && pass "the plan enumerates every pin of t1 with purge t/f, and no other tenant's" || fail "plan: $(cat "$T/out")"

purge t1 "box-dead-a box-live" 24 0; rc=$?
[[ $rc -ne 0 ]] && grep -q "ROLLED BACK" "$T/out" && [[ "$(count "pins WHERE tenant_id='t1'")" == 4 ]] \
  && pass "CONTROL: one box too fresh -> the whole purge rolls back, box-dead-a survives too" || fail "idle control: rc=$rc $(cat "$T/out")"

purge t1 "box-other" 24 0; rc=$?
[[ $rc -ne 0 ]] && grep -q "not pinned under t1" "$T/out" && [[ "$(count "pins WHERE tenant_id='t2'")" == 1 ]] \
  && pass "CONTROL: another tenant's box reads as not pinned (rdb 0014 RLS), and survives" || fail "cross-tenant: rc=$rc $(cat "$T/out")"

purge t1 "box-dead-a box-dead-b" 24 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "purged 2 box(es)" "$T/out" && pass "the purge reports what it deleted" || fail "purge: rc=$rc $(cat "$T/out")"
[[ "$(count "pins WHERE tenant_id='t1'")" == 2 ]] && [[ "$(count "boxes WHERE tenant_id='t1'")" == 2 ]] \
  && [[ "$(count "roster WHERE tenant_id='t1'")" == 2 ]] && [[ "$(count "channel_subscriptions WHERE tenant_id='t1'")" == 2 ]] \
  && pass "pins, boxes, roster and channel_subscriptions of the two purged boxes are gone; box-live and box-keep keep theirs" \
  || fail "counts: pins=$(count "pins WHERE tenant_id='t1'") boxes=$(count "boxes WHERE tenant_id='t1'") roster=$(count "roster WHERE tenant_id='t1'") subs=$(count "channel_subscriptions WHERE tenant_id='t1'")"
[[ "$(count "messages WHERE tenant_id='t1'")" == 4 ]] && [[ "$(count "pins_history WHERE tenant_id='t1'")" == 4 ]] \
  && pass "history survives: all 4 messages and all 4 pins_history rows are still there" \
  || fail "history lost: messages=$(count "messages WHERE tenant_id='t1'") pins_history=$(count "pins_history WHERE tenant_id='t1'")"

# The roster JSON is built FROM pins (store ViewBoxes), so a gone pin is a gone box.
left="$(psql_owner -c "SELECT string_agg(box_id, ' ' ORDER BY box_id) FROM pins WHERE tenant_id='t1'")"
[[ "$left" == "box-keep box-live" ]] && pass "what GET /v1/view/roster would list for t1 is now: $left" || fail "left: $left"

purge t1 "box-dead-a" 24 0; rc=$?
[[ $rc -ne 0 ]] && grep -q "not pinned under t1" "$T/out" && pass "purging an already-purged box is refused, not a silent no-op" || fail "again: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
