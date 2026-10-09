#!/usr/bin/env bash
# do_spl_msg_dedup (CLE-77847, t1 topic 35582e7b): the argument guards
# (hermetic), then the SQL against a REAL throwaway Postgres carrying the real
# rdb migrations, connected as a NON-owner login so row-level security binds.
#
# Fixture (the shape prd t1 had on 2026-10-01): one human post answered by
# RSP-01 "Seen" FIVE times (one copy with stray whitespace), a human "ok" sent
# twice in a DM, and the near-misses that are NOT duplicates: same body by
# another sender, in another topic, or with other files. Plus one post that
# two different agents answered (report only), and the responder's Seen
# (c-684, RSP-01's successor) under it, which is no answer.
#   - DRY_RUN=1 lists every later copy (t1: 5, t2: 1) and rolls back
#   - DRY_RUN=0 needs MSG_DEDUP_CONFIRM=<env>/<scope>, is refused before cloud
#   - TENANT_ID=t1 deletes t1's 5 only, keeps the FIRST copy, cascades the
#     deliveries/reactions and decrements the meter; t2 is untouched
#   - a second run finds 0 (idempotent); the multi-agent answer is listed,
#     never deleted
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-msg-dedup.func.sh"
grep -qE 'DELETE FROM (tenants|humans|pins|boxes|roster|channels)' "$FUNC" \
  && fail "the dedup deletes an identity table" || pass "the dedup deletes from messages only"
grep -q 'do_spl_db_backup' "$FUNC" && pass "DRY_RUN=0 takes a backup first (do_spl_db_backup)" || fail "no backup step"

# --- the argument guards, sourced like the other orc tests (no ./run) ---------
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u TENANT_ID -u DRY_RUN -u MSG_DEDUP_CONFIRM \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_msg_dedup' >"$T/out" 2>&1 </dev/null
}
guard() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  act "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
guard "a bad TENANT_ID"                  "TENANT_ID must be a tenant slug"  TENANT_ID=T_1
guard "a bad DRY_RUN"                    "DRY_RUN must be 0 or 1"           DRY_RUN=yes
guard "DRY_RUN=0 without the confirm"    "set MSG_DEDUP_CONFIRM=dev/all"    DRY_RUN=0
guard "a confirm for another tenant"     "set MSG_DEDUP_CONFIRM=dev/t1"     DRY_RUN=0 TENANT_ID=t1 MSG_DEDUP_CONFIRM=dev/all
guard "a msg_wipe confirm does not pass" "set MSG_DEDUP_CONFIRM=dev/all"    DRY_RUN=0 MSG_WIPE_CONFIRM=dev/all
act DRY_RUN=0 TENANT_ID=t1 MSG_DEDUP_CONFIRM=dev/t1
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
PG_CTR="spl-msg-dedup-pg-$$"
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

TA=aaaaaaaa-0000-4000-8000-000000000001; TB=bbbbbbbb-0000-4000-8000-000000000002
TC=cccccccc-0000-4000-8000-000000000003; TD=dddddddd-0000-4000-8000-000000000004
for t in t1 t2; do
  psql_owner <<PSQL >/dev/null
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'));
PSQL
done
N=0
msg() { # <tenant> <task> <from> <seconds> <body> [files json] [channel]: one row + a delivery + a reaction
  N=$((N + 1))
  local id; id="$(printf '00000000-0000-4000-8000-%012d' "$N")"
  psql_owner -v body="$5" <<PSQL >/dev/null
WITH m AS (
  INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, expires_at)
  VALUES ('$1', '$id', '$2', ${7:-NULL}, timestamptz '2026-10-01 08:00:00+00' + interval '$4 seconds', 'box-a', '$3', 'box-wui', 'HUM-10', 'note',
          :'body', '${6:-[]}'::jsonb, '{}'::jsonb, 'sig', '\\x00', now() + interval '30 days')
  RETURNING tenant_id, msg_id),
 d AS (INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) SELECT tenant_id, msg_id, 'box-a', now() + interval '1 day' FROM m RETURNING 1)
INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji) SELECT tenant_id, msg_id, 'HUM-1', '+1' FROM m;
PSQL
  LAST="$id"
}
# t1, topic A: a human post, then RSP-01 "Seen" five times (one with stray whitespace)
msg t1 $TA HUM-10 0 "the counter is off" >/dev/null
msg t1 $TA RSP-01 10 "Seen: routed to the team."; KEEP="$LAST"
msg t1 $TA RSP-01 11 "Seen: routed to the team." >/dev/null
msg t1 $TA RSP-01 12 "  Seen:  routed to the team. " >/dev/null
msg t1 $TA RSP-01 13 "Seen: routed to the team." >/dev/null
msg t1 $TA RSP-01 14 "Seen: routed to the team." >/dev/null
# t1, topic B in a channel: a human "ok" twice -> one duplicate
msg t1 $TB HUM-10 20 "ok" '[]' "'lobby'" >/dev/null
msg t1 $TB HUM-10 21 "ok" '[]' "'lobby'" >/dev/null
# near-misses, NOT duplicates: another sender, another topic, other files
msg t1 $TB HUM-11 22 "ok" '[]' "'lobby'" >/dev/null
msg t1 $TC RSP-01 30 "Seen: routed to the team." >/dev/null
msg t1 $TB HUM-10 23 "ok" '[{"file_id":"f1"}]' "'lobby'" >/dev/null
# t1, topic D: one human post answered by two different agents (report only)
msg t1 $TD HUM-10 40 "who takes this?" >/dev/null
msg t1 $TD CLE-1 41 "I take it." >/dev/null
msg t1 $TD CLE-2 42 "On it." >/dev/null
msg t1 $TD c-684 43 "Seen: routed to the team." >/dev/null
# t2: one duplicate
msg t2 $TA CLE-3 0 "done" >/dev/null
msg t2 $TA CLE-3 5 "done" >/dev/null

dedup() { # <tenant or ''> <dry>
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev GCP_ACCOUNT=test@example.com \
    SPL_PROXY_DSN="$RT_DSN" SPL_DEDUP_TENANT="$1" SPL_DEDUP_DRY="$2" \
    bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-msg-dedup.func.sh"
    _spl_msg_dedup_run' >"$T/out" 2>&1
}
counts() { # <tenant> -> "msgs deliveries reactions meter"
  psql_owner -c "SELECT (SELECT count(*) FROM messages WHERE tenant_id='$1') || ' ' || (SELECT count(*) FROM deliveries WHERE tenant_id='$1')
    || ' ' || (SELECT count(*) FROM message_reactions WHERE tenant_id='$1')
    || ' ' || (SELECT coalesce(sum(messages), 0) FROM message_period_counts WHERE tenant_id='$1')"
}
[[ "$(counts t1)" == "15 15 15 15" && "$(counts t2)" == "2 2 2 2" ]] \
  && pass "seeded: t1 15 messages, t2 2" || fail "seed: t1=$(counts t1) t2=$(counts t2)"

dedup "" 1; rc=$?
if [[ $rc -eq 0 ]] && grep -q "COUNT tenant=t1 duplicates=5" "$T/out" && grep -q "COUNT tenant=t2 duplicates=1" "$T/out" \
   && grep -q "6 duplicate(s) in dev/all would be deleted" "$T/out" \
   && [[ "$(counts t1)" == "15 15 15 15" && "$(counts t2)" == "2 2 2 2" ]]; then
  pass "DRY_RUN lists t1=5, t2=1 and rolls back: every count unchanged"
else
  fail "dry: rc=$rc $(cat "$T/out") t1=$(counts t1) t2=$(counts t2)"
fi
[[ "$(grep -c "^DUP .*sender=RSP-01 kept=$KEEP " "$T/out")" == 4 ]] \
  && pass "the four later Seen copies (whitespace variant included) point at the FIRST one as kept" || fail "Seen dup rows: $(grep '^DUP' "$T/out")"
grep -q "^DUP tenant=t1 channel=lobby topic=$TB .*sender=HUM-10 .*| ok$" "$T/out" \
  && pass "a DUP row names tenant, channel, topic, sender and the body head" || fail "no lobby ok row: $(cat "$T/out")"
grep -q "sender=HUM-11" "$T/out" || grep -q "topic=$TC" "$T/out" \
  && fail "a near-miss (other sender / other topic) was flagged" || pass "CONTROL: another sender or another topic is not a duplicate"
grep -q "^MULTI tenant=t1 channel=- topic=$TD .*agents=CLE-1,CLE-2$" "$T/out" && ! grep -q "^MULTI.*topic=$TA" "$T/out" \
  && pass "two agents answering one post is reported (MULTI); the responder's Seen (RSP-01, c-684) does not count" || fail "multi: $(grep MULTI "$T/out")"

dedup t1 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "deleted 5 duplicate(s) in dev/t1" "$T/out" \
  && pass "TENANT_ID=t1 DRY_RUN=0 deletes 5 and commits" || fail "t1: rc=$rc $(cat "$T/out")"
[[ "$(counts t1)" == "10 10 10 10" ]] && pass "t1: 15 -> 10; deliveries and reactions cascaded, meter decremented" || fail "t1 after: $(counts t1)"
[[ "$(psql_owner -c "SELECT count(*) FROM messages WHERE msg_id='$KEEP'")" == 1 ]] && pass "the FIRST Seen is kept" || fail "the first copy was deleted"
[[ "$(psql_owner -c "SELECT count(*) FROM messages WHERE task_id='$TD'")" == 4 ]] && pass "the multi-agent answers are not deleted" || fail "a MULTI answer was deleted"
[[ "$(counts t2)" == "2 2 2 2" ]] && pass "CONTROL: t2 is untouched by a t1 dedup" || fail "t2 after a t1 dedup: $(counts t2)"

dedup t1 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "deleted 0 duplicate(s) in dev/t1" "$T/out" && [[ "$(counts t1)" == "10 10 10 10" ]] \
  && pass "a second run deletes nothing (idempotent)" || fail "rerun: rc=$rc $(cat "$T/out")"
dedup "" 0; rc=$?
[[ $rc -eq 0 ]] && grep -q "deleted 1 duplicate(s) in dev/all" "$T/out" && [[ "$(counts t2)" == "1 1 1 1" ]] \
  && pass "an all-tenant run takes t2's one" || fail "all: rc=$rc $(cat "$T/out") t2=$(counts t2)"

# spec 099 T006: the triggers kept every topic head right through this run
hd="$(psql_owner -c "SELECT (SELECT count(*) FROM tenants t, LATERAL topic_head_diff(t.tenant_id)) + (SELECT count(*) FROM topic_heads h WHERE NOT EXISTS (SELECT 1 FROM tenants t WHERE t.tenant_id = h.tenant_id))" 2>&1)"
[[ "$hd" == 0 ]] && pass "topic_head_diff is empty after the run (rdb 0144)" || fail "topic_head_diff after the run: $hd"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
