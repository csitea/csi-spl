#!/usr/bin/env bash
# Perf round 5 P5-01: do_spl_unanswered_sweep DELIVER=1 keeps the last row set
# in <spool root>/dispatch/unanswered.rows and, each minute, reads only the
# topics whose head moved (_spl_sweep_delta_sql), merged in by
# spl_sweep_merge; every SWEEP_FULL_EVERY s it reads the whole set again and
# counts the rows the merge got wrong (drift). Against a REAL throwaway
# Postgres with the real migrations, as the runtime role:
#   1. same rows: cache + delta == a fresh full read, after a new human post,
#      an agent reply, an archived card, an archived channel, a new topic, an
#      edited body, an expired last line, a deleted topic, a row out of the
#      window
#   2. with nothing moved, the delta reads only the due heads, fewer than
#      the full read
#   3. CONTROL: the cache without the delta differs from the full read
#   4. spl_sweep_rows_cached: no cache -> full; next run -> delta; after
#      SWEEP_FULL_EVERY -> full again with drift=0; a cache of another
#      ENV -> full
#   5. the read's DB time is floored, never past the read (a rounded
#      time skips a change made just after a read in the upper half second)
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
PG_CTR="spl-unanswered-delta-pg-$$"
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

# 3 workspaces x 40 topics x 1..9 messages (the narrow-pg fixture's shape):
# ties on received_at, expired last lines, rows out of the window, DMs,
# archived cards, an archived channel; agents and humans alternate.
psql_owner <<'PSQL' >/dev/null || fail "seed"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES
  ('t1', decode(repeat('ab', 32), 'hex')), ('w2', decode(repeat('ac', 32), 'hex')), ('w3', decode(repeat('ad', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by)
  SELECT t, c, c, 'HUM-1' FROM unnest(ARRAY['t1', 'w2', 'w3']) t, unnest(ARRAY['dev', 'old']) c;
UPDATE channels SET archived_at = now(), archived_by = 'HUM-1' WHERE channel_id = 'old';
SELECT setseed(0.29);
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
SELECT s.tenant, md5(s.tenant || s.topic || '-' || s.n)::uuid, md5(s.tenant || s.topic)::uuid,
       CASE WHEN s.topic % 3 = 0 THEN NULL WHEN s.topic % 13 = 0 THEN 'old' ELSE 'dev' END, now(),
       'box-x', CASE WHEN (s.n + s.topic) % 2 = 0 THEN 'HUM-2' ELSE 'c-005' END, 'box-x', 'c-005', 'note',
       'body ' || s.n, '{}'::jsonb, 'sig', '\x00',
       CASE WHEN s.topic % 11 = 0 AND s.n = 1 THEN now() - interval '9 days'
            WHEN s.topic % 5 = 0 AND s.n >= s.cnt - 1 THEN date_trunc('second', now()) - interval '30 minutes'
            ELSE now() - make_interval(mins => (s.cnt - s.n) * 10 + 40 + (random() * 5)::int) END,
       CASE WHEN s.topic % 7 = 0 AND s.n = s.cnt THEN now() - interval '1 minute' ELSE now() + interval '30 days' END
  FROM (SELECT tn.tenant, tp.topic, g.n, tp.cnt
          FROM unnest(ARRAY['t1', 'w2', 'w3']) tn(tenant)
          CROSS JOIN (SELECT topic, 1 + (random() * 8)::int AS cnt FROM generate_series(1, 40) topic) tp
          CROSS JOIN LATERAL generate_series(1, tp.cnt) g(n)) s;
UPDATE messages SET archived_at = now(), archived_by = 'HUM-1'
 WHERE task_id IN (SELECT DISTINCT task_id FROM messages WHERE tenant_id = 'w2' ORDER BY task_id LIMIT 4);
ANALYZE messages;
PSQL

# sweep <fn> <args...>: run a sweep function as the runtime role (the
# action's own frame), with spl_via_proxy reduced to the DSN it hands on
sweep() {
  env PROJ_PATH="$PROJ_ROOT" RT_DSN="$RT_DSN" SPL_PROXY_DSN="$RT_DSN" LEASE_DIR="$T/lease" ENV="${SW_ENV:-prd}" \
    SWEEP_FULL_EVERY="${SW_FULL:-3600}" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    spl_via_proxy() { SPL_PROXY_DSN="$RT_DSN" "$@"; }
    "$@"' _ "$@"
}
srt() { LC_ALL=C sort "$1"; }
mkdir -p "$T/lease"

# 0. the full read, with the DB clock it ran at (2 s after the seed, so the
# seed's head writes are older than the delta's since)
sleep 2.1
sweep _spl_sweep_rows_read "$T/f0" "$T/now0" 2>"$T/e0" || fail "0. full read: $(cat "$T/e0")"
now0="$(cat "$T/now0" 2>/dev/null)"
n0="$(wc -l <"$T/f0" 2>/dev/null || echo 0)"
[[ "$now0" =~ ^[0-9]+$ ]] && (( n0 >= 80 )) && pass "0. full read: $n0 rows at DB time $now0" || fail "0. full read: now='$now0' rows=$n0"
sleep 1.1

# what moves after the cache was taken (one statement each, so each commits
# and drains its own topic heads)
tk() { psql_owner -c "SELECT md5('$1' || $2)::uuid"; }
human_on_agent="$(awk -F'\t' '$9 == "agent" && $1 == "t1" && $10 == "open" && $11 == "live" { print $4; exit }' "$T/f0")"
agent_on_human="$(awk -F'\t' '$9 == "human" && $1 == "w3" && $10 == "open" { print $4; exit }' "$T/f0")"
edit_last="$(awk -F'\t' -v x="$human_on_agent" '$9 == "human" && $1 == "t1" && $10 == "open" && $4 != x { print $5; exit }' "$T/f0")"
expire_last="$(awk -F'\t' '$1 == "w2" && $10 == "open" { print $5; exit }' "$T/f0")"
archive_one="$(awk -F'\t' -v x="$human_on_agent" -v e="$edit_last" '$1 == "t1" && $10 == "open" && $4 != x && $5 != e { print $4 }' "$T/f0" | tail -1)"
gone_topic="$(awk -F'\t' -v x="$agent_on_human" '$1 == "w3" && $9 == "human" && $4 != x { print $4 }' "$T/f0" | tail -1)"
[[ -n "$human_on_agent" && -n "$agent_on_human" && -n "$edit_last" && -n "$expire_last" && -n "$archive_one" && -n "$gone_topic" ]] ||
  fail "fixture: a case is missing ($human_on_agent/$agent_on_human/$edit_last/$expire_last/$archive_one/$gone_topic)"
ins() { # <tenant> <task> <channel|NULL> <from> <body>
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', gen_random_uuid(), '$2', $3, now(), 'box-x', '$4', 'box-x', 'c-005', 'note', '$5', '{}'::jsonb, 'sig', '\\x00', now(), now() + interval '30 days')" >/dev/null ||
    fail "insert into $1 $2"
}
ins t1 "$human_on_agent" "'dev'" HUM-2 "a new human post"
ins w3 "$agent_on_human" "$(awk -F'\t' -v t="$agent_on_human" '$4 == t { print ($3 == "" ? "NULL" : "\047" $3 "\047") }' "$T/f0")" c-005 "an agent reply"
ins t1 "$(tk t1 999)" "'dev'" HUM-2 "a brand new topic"
psql_owner -c "UPDATE messages SET archived_at = now(), archived_by = 'HUM-1' WHERE tenant_id = 't1' AND msg_id = (SELECT msg_id FROM messages WHERE tenant_id = 't1' AND task_id = '$archive_one' ORDER BY received_at LIMIT 1)" >/dev/null || fail "archive card"
psql_owner -c "UPDATE channels SET archived_at = now(), archived_by = 'HUM-1' WHERE tenant_id = 'w2' AND channel_id = 'dev'" >/dev/null || fail "archive channel"
psql_owner <<SQL >/dev/null || fail "edit"
INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at)
  SELECT tenant_id, msg_id, 2, 'edited: is this fixed?', from_id, now() FROM messages WHERE tenant_id = 't1' AND msg_id = '$edit_last';
UPDATE messages SET body = 'edited: is this fixed?', edited_at = now() WHERE tenant_id = 't1' AND msg_id = '$edit_last';
SQL
psql_owner -c "UPDATE messages SET expires_at = now() WHERE tenant_id = 'w2' AND msg_id = '$expire_last'" >/dev/null || fail "expire"
psql_owner -c "DELETE FROM messages WHERE tenant_id = 'w3' AND task_id = '$gone_topic'" >/dev/null || fail "delete topic"
# a cached row that has left the window since (no DB change: the clock alone)
printf 't1\t\tdev\t%s\t%s\t%s\tHUM-2\tc-005\thuman\topen\tlive\t-\told\t\t\n' "$(tk t1 998)" "$(tk t1 997)" "$((now0 - 8 * 86400))" >>"$T/f0"

# the DB time is now()::bigint, which ROUNDS: a change in the same second as
# now1 is still > to_timestamp(now1) and would come back in case 2's delta
# (case 2 has no overlap). 1.1 s keeps every change strictly before now1.
sleep 1.1

# 1. full + delta in ONE transaction (one snapshot, one now()), then merge
# shellcheck disable=SC2046 # two words: the arrays
sweep _spl_sweep_rows_read "$T/f1" "$T/now1" "$now0" "$T/d1" $(sweep spl_sweep_keep "$T/f0") 2>"$T/e1" || fail "1. read: $(cat "$T/e1")"
now1="$(cat "$T/now1" 2>/dev/null)"
sweep spl_sweep_merge "$T/f0" "$T/d1" "$now1" 7 >"$T/m1" 2>"$T/e1m" || fail "1. merge: $(cat "$T/e1m")"
if [[ -s "$T/m1" ]] && cmp -s <(srt "$T/m1") <(srt "$T/f1"); then
  pass "1. cache + delta == the full read: $(wc -l <"$T/f1") rows (post, reply, archive, channel, new, edit, expiry, deleted topic, window)"
else
  fail "1. merged ($(wc -l <"$T/m1")) != full ($(wc -l <"$T/f1")): $(diff <(srt "$T/m1") <(srt "$T/f1") | cut -c1-160 | sed -n 1,8p)"
fi
grep -q 'edited: is this fixed?' "$T/m1" && pass "1. the edited body reached the merged rows" || fail "1. edit missing from the merge"

# 2. with nothing moved, a delta reads only the due heads (an expired key
# line), never the whole set nor the cached human-last topics
sleep 1.1
# shellcheck disable=SC2046 # two words: the arrays
sweep _spl_sweep_rows_read "" "$T/now2" "$now1" "$T/d2" $(sweep spl_sweep_keep "$T/f1") 2>"$T/e2" || fail "2. read: $(cat "$T/e2")"
psql_owner -F $'\t' -c "SELECT tenant_id, task_id FROM topic_heads WHERE valid_until <= now() AND last_at > now() - interval '7 days'" |
  LC_ALL=C sort -u >"$T/want2"
cut -f1,4 "$T/d2" | LC_ALL=C sort -u >"$T/got2"
n_delta="$(wc -l <"$T/got2")"; nf="$(wc -l <"$T/f1")"
[[ -s "$T/got2" ]] && cmp -s "$T/got2" "$T/want2" && (( n_delta < nf )) &&
  pass "2. an idle delta reads $n_delta topics (the due heads), the full read $nf" ||
  fail "2. idle delta: got $n_delta, want $(wc -l <"$T/want2") of $nf: $(diff "$T/got2" "$T/want2" | sed -n 1,4p)"

# 3. CONTROL: without the delta the cache is stale
sweep spl_sweep_merge "$T/f0" /dev/null "$now1" 7 >"$T/m0"
cmp -s <(srt "$T/m0") <(srt "$T/f1") && fail "3. CONTROL: the cache alone equals the full read: check 1 proves nothing" ||
  pass "3. CONTROL: the cache alone differs from the full read in $(diff <(srt "$T/m0") <(srt "$T/f1") | grep -c '^[<>]') line(s)"

# 4. the action's cache: full, delta, reconcile with drift, ENV change
rm -rf "$T/lease"; mkdir -p "$T/lease"
info() { tr '\n' ' ' <"$T/lease/unanswered.rows.info" 2>/dev/null; }
sweep spl_sweep_rows_cached "$T/r1" 2>"$T/e4" && [[ "$(info)" == *"rows=full"* ]] && cmp -s <(srt "$T/r1") <(srt "$T/lease/unanswered.rows") &&
  pass "4. no cache: a full read, kept as the cache ($(info))" || fail "4. first run: $(info) $(cat "$T/e4")"
ins t1 "$(tk t1 996)" "'dev'" HUM-2 "between two runs"
sweep spl_sweep_rows_cached "$T/r2" 2>"$T/e4" && [[ "$(info)" == *"rows=delta"* ]] && grep -q 'between two runs' "$T/r2" &&
  pass "4. the next run reads the delta and sees the new post ($(info))" || fail "4. second run: $(info) $(cat "$T/e4")"
sleep 2.1
SW_FULL=1 sweep spl_sweep_rows_cached "$T/r3" 2>"$T/e4" && [[ "$(info)" == *"rows=full"*"drift=0"* ]] && cmp -s <(srt "$T/r2") <(srt "$T/r3") &&
  pass "4. after SWEEP_FULL_EVERY: a full reconcile, drift=0 ($(info))" || fail "4. reconcile: $(info) $(cat "$T/e4")"
SW_ENV=dev sweep spl_sweep_rows_cached "$T/r4" 2>"$T/e4" && [[ "$(info)" == *"rows=full"* && "$(info)" != *drift* ]] &&
  pass "4. a cache of another ENV is not merged into: full read ($(info))" || fail "4. env change: $(info) $(cat "$T/e4")"

# 5. the read's DB time is floored, never after the read: a rounded now
# (::bigint) stores the NEXT second for a read in the upper half of one, and
# a change committed just after that read is then older than the next
# delta's since and missed. Bracketed by the DB clock: t0 before the read,
# t1 after it, both in one second with t0 at >= .5 s; retried until it holds.
n5=""
for try in 1 2 3 4 5 6 7 8; do
  until [[ "$(psql_owner -c "SELECT extract(microseconds FROM clock_timestamp())::int % 1000000 BETWEEN 500000 AND 520000")" == t ]]; do sleep 0.005; done
  t0="$(psql_owner -c "SELECT extract(epoch FROM clock_timestamp())")"
  sweep _spl_sweep_rows_read "" "$T/now5" 2>"$T/e5" || { fail "5. read: $(cat "$T/e5")"; break; }
  t1="$(psql_owner -c "SELECT extract(epoch FROM clock_timestamp())")"
  [[ "${t0%.*}" == "${t1%.*}" ]] || continue
  n5="$(cat "$T/now5")"; break
done
if [[ -z "$n5" ]]; then
  fail "5. the timing never held in 8 tries (a read inside the upper half of one second)"
elif [[ "$n5" == "${t0%.*}" ]]; then
  pass "5. a read at $t0..$t1 stores $n5: floored, not past the read (try $try)"
else
  fail "5. a read at $t0..$t1 stores $n5, past the read: a change right after it would be missed"
fi

# 6. SPL-2705: the edited-lines arm starts from the few revisions edited since
# :since, never from every message. prd 2026-10-20 (1 665 revisions, 48 822
# messages): the planner walked messages_task_received and probed
# message_revisions_pkey once per message, 101 744 of the read's 101 919
# buffers, so an idle delta (127 ms) cost more than the full read (73 ms) and
# crossed statement_timeout first when the instance's storage slowed. Every
# message_revisions scan in the plan runs once (loops <= 1).
q6="$(sweep _spl_sweep_delta_sql 2>"$T/e6")" || fail "6. statement: $(cat "$T/e6")"
printf "BEGIN READ ONLY;\nSET LOCAL app.rls_scope = 'operator';\nEXPLAIN (ANALYZE, FORMAT JSON) %s;\nROLLBACK;\n" "$q6" >"$T/q6.sql"
PGPASSWORD=rt psql -X -q -At -v ON_ERROR_STOP=1 -v days=7 -v since="$now1" -v tns='{}' -v tks='{}' "$RT_DSN" -f "$T/q6.sql" \
  >"$T/p6.json" 2>"$T/e6" || fail "6. explain: $(cat "$T/e6")"
loops6="$(python3 -c '
import json, sys
def walk(n):
    if n.get("Relation Name") == "message_revisions":
        yield n.get("Node Type", "?"), n.get("Actual Loops", 0)
    for c in n.get("Plans", []):
        yield from walk(c)
txt = open(sys.argv[1]).read()
plan = json.loads(txt[txt.index("["):])[0]["Plan"]
print(" ".join("%s:%d" % x for x in walk(plan)) or "none")' "$T/p6.json" 2>&1)"
nm="$(psql_owner -c "SELECT count(*) FROM messages")"
if [[ "$loops6" == none || "$loops6" == *Traceback* ]]; then
  fail "6. no message_revisions scan found in the delta plan: $loops6"
elif [[ "$loops6" =~ :([2-9]|[1-9][0-9]+)( |$) ]]; then
  fail "6. message_revisions is probed per row ($loops6, $nm messages): the edited-lines arm is driven from messages"
else
  pass "6. message_revisions is scanned once ($loops6) over $nm messages"
fi

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
