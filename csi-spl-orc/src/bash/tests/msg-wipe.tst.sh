#!/usr/bin/env bash
# do_spl_msg_wipe (spec 033 T013): the argument guards (hermetic), then the SQL
# against a REAL throwaway Postgres carrying the real rdb migrations, connected
# as a NON-owner login so rdb 0014 row-level security actually binds.
#
# The controls are the point:
#   - DRY_RUN=1 runs the same delete and rolls it back: every count unchanged
#   - DRY_RUN=0 without MSG_WIPE_CONFIRM=<env>/<scope> is refused before any
#     cloud call, so a wrong ENV or a forgotten TENANT_ID wipes nothing
#   - TENANT_ID=t1 leaves t2's messages alone
#   - identities (pins, channels, roster) survive: it wipes history only
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-msg-wipe.func.sh"
grep -qE 'DELETE FROM (tenants|humans|pins|boxes|roster|channels)' "$FUNC" \
  && fail "the wipe deletes an identity table" || pass "the wipe deletes from messages only (identities are never touched)"
grep -q 'do_spl_db_backup' "$FUNC" && pass "DRY_RUN=0 takes a backup first (do_spl_db_backup)" || fail "no backup step"

# --- the argument guards, sourced like the other orc tests (no ./run) ---------
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u TENANT_ID -u DRY_RUN -u MSG_WIPE_CONFIRM \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_msg_wipe' >"$T/out" 2>&1 </dev/null
}
guard() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  act "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
guard "a bad TENANT_ID"                  "TENANT_ID must be a tenant slug"  TENANT_ID=T_1
guard "a bad DRY_RUN"                    "DRY_RUN must be 0 or 1"           DRY_RUN=yes
guard "DRY_RUN=0 without the confirm"    "set MSG_WIPE_CONFIRM=dev/all"     DRY_RUN=0
guard "a confirm for another tenant"     "set MSG_WIPE_CONFIRM=dev/t1"      DRY_RUN=0 TENANT_ID=t1 MSG_WIPE_CONFIRM=dev/all
guard "a confirm for another env"        "set MSG_WIPE_CONFIRM=dev/all"     DRY_RUN=0 MSG_WIPE_CONFIRM=prd/all
act DRY_RUN=0 TENANT_ID=t1 MSG_WIPE_CONFIRM=dev/t1
grep -q REACHED-CLOUD "$T/out" && pass "CONTROL: the matching confirm passes the guards and reaches the cloud step" \
  || fail "the matching confirm was refused: $(cat "$T/out")"

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
PG_CTR="spl-msg-wipe-pg-$$"
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

seed() { # <tenant> <n messages>: each with one delivery, one revision, one reaction
  local t="$1" n="$2" i
  psql_owner <<PSQL >/dev/null
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex')) ON CONFLICT DO NOTHING;
INSERT INTO pins (tenant_id, box_id, pubkey) VALUES ('$t', 'box-a', decode(md5('$t/box-a') || md5('$t/box-a/2'), 'hex'));
PSQL
  for i in $(seq 1 "$n"); do
    psql_owner <<PSQL >/dev/null
WITH m AS (
  INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at)
  VALUES ('$t', gen_random_uuid(), gen_random_uuid(), now(), 'box-a', 'ORC-1', 'box-a', 'ORC-2', 'note', 'seed $i', '{}'::jsonb, 'sig', '\\x00', now() + interval '30 days')
  RETURNING tenant_id, msg_id),
 d AS (INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) SELECT tenant_id, msg_id, 'box-a', now() + interval '1 day' FROM m RETURNING 1),
 r AS (INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at) SELECT tenant_id, msg_id, 1, 'seed', 'ORC-1', now() FROM m RETURNING 1)
INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji) SELECT tenant_id, msg_id, 'HUM-1', '+1' FROM m;
PSQL
  done
}
seed t1 3
seed t2 2

wipe() { # <tenant or ''> <dry>
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com \
    SPL_PROXY_DSN="$RT_DSN" SPL_WIPE_TENANT="$1" SPL_WIPE_DRY="$2" \
    bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-msg-wipe.func.sh"
    _spl_msg_wipe_run' >"$T/out" 2>&1
}
counts() { # <tenant> -> "msgs deliveries revisions reactions meter"
  psql_owner -c "SELECT (SELECT count(*) FROM messages WHERE tenant_id='$1') || ' ' || (SELECT count(*) FROM deliveries WHERE tenant_id='$1')
    || ' ' || (SELECT count(*) FROM message_revisions WHERE tenant_id='$1') || ' ' || (SELECT count(*) FROM message_reactions WHERE tenant_id='$1')
    || ' ' || (SELECT coalesce(sum(messages), 0) FROM message_period_counts WHERE tenant_id='$1')"
}
[[ "$(counts t1)" == "3 3 3 3 3" && "$(counts t2)" == "2 2 2 2 2" ]] \
  && pass "seeded: t1 3/3/3/3 meter 3, t2 2/2/2/2 meter 2" || fail "seed: t1=$(counts t1) t2=$(counts t2)"

wipe "" 1; rc=$?
[[ $rc -eq 0 ]] && grep -q "5 5 5 5 5 -> 0 0 0 0 0 deleted=5 committed=f" "$T/out" && grep -q "DRY_RUN rolled back" "$T/out" \
  && [[ "$(counts t1)" == "3 3 3 3 3" && "$(counts t2)" == "2 2 2 2 2" ]] \
  && pass "DRY_RUN shows 5 -> 0 across both tenants and rolls back: every count unchanged" || fail "dry: rc=$rc $(cat "$T/out") t1=$(counts t1) t2=$(counts t2)"

wipe t1 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "3 3 3 3 3 -> 0 0 0 0 0 deleted=3 committed=t" "$T/out" \
  && pass "TENANT_ID=t1 reports 3 -> 0 and commits" || fail "t1: rc=$rc $(cat "$T/out")"
[[ "$(counts t1)" == "0 0 0 0 0" ]] && pass "t1: messages gone, deliveries/revisions/reactions cascaded, meter back to 0" || fail "t1 after: $(counts t1)"
[[ "$(counts t2)" == "2 2 2 2 2" ]] && pass "CONTROL: t2 is untouched by a t1 wipe" || fail "t2 after a t1 wipe: $(counts t2)"
[[ "$(psql_owner -c "SELECT count(*) FROM pins")" == 2 && "$(psql_owner -c "SELECT count(*) FROM tenants")" == 2 ]] \
  && pass "identities survive: both tenants and both pins are still there" || fail "identity lost"

wipe "" 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "deleted=2 committed=t" "$T/out" && [[ "$(counts t2)" == "0 0 0 0 0" ]] \
  && pass "an all-tenant wipe takes the rest: t2 0/0/0/0 meter 0" || fail "all: rc=$rc $(cat "$T/out") t2=$(counts t2)"

# spec 099 T006: the triggers kept every topic head right through this run
hd="$(psql_owner -c "SELECT (SELECT count(*) FROM tenants t, LATERAL topic_head_diff(t.tenant_id)) + (SELECT count(*) FROM topic_heads h WHERE NOT EXISTS (SELECT 1 FROM tenants t WHERE t.tenant_id = h.tenant_id))" 2>&1)"
[[ "$hd" == 0 ]] && pass "topic_head_diff is empty after the run (rdb 0144)" || fail "topic_head_diff after the run: $hd"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
