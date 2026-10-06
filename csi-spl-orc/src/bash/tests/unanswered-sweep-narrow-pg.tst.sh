#!/usr/bin/env bash
# Perf edition 20261004 E17: do_spl_unanswered_sweep picks each topic's last
# message on its KEY (tenant_id, msg_id) in a MATERIALIZED CTE and reads only
# those rows whole. The old shape (DISTINCT ON over m.*) sorted every 7-day row
# at full width and spilled to disk on prd each run. This pins both halves
# against a REAL throwaway Postgres with the real migrations, as the runtime
# role so row-level security binds:
#   1. same answers: the old statement (kept here verbatim) and the new one
#      return the same rows on a seeded fixture with the edge cases a narrow
#      key could get wrong - ties on received_at (msg_id decides), an expired
#      last message, a message older than the window, DMs, archived cards
#   2. narrow: the scan of messages m outputs <= 4 columns and runs once
#   3. CONTROL: the old statement fails check 2 (it reads m.* at full width)
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
PG_CTR="spl-unanswered-narrow-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

# 3 workspaces x 40 topics x 1..9 messages, deterministic (setseed). Every 5th
# topic's last two messages share one received_at (msg_id breaks the tie);
# every 7th topic's newest message is expired; every 11th topic has a message
# older than the 7-day window; a third are DMs; agents and humans alternate.
psql_owner <<'PSQL' >/dev/null || fail "seed"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES
  ('t1', decode(repeat('ab', 32), 'hex')), ('w2', decode(repeat('ac', 32), 'hex')), ('w3', decode(repeat('ad', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by)
  SELECT t, c, c, 'HUM-1' FROM unnest(ARRAY['t1', 'w2', 'w3']) t, unnest(ARRAY['dev', 'old']) c;
UPDATE channels SET archived_at = now(), archived_by = 'HUM-1' WHERE channel_id = 'old';
SELECT setseed(0.17);
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
SELECT s.tenant, md5(s.tenant || s.topic || '-' || s.n)::uuid, md5(s.tenant || s.topic)::uuid,
       CASE WHEN s.topic % 3 = 0 THEN NULL WHEN s.topic % 13 = 0 THEN 'old' ELSE 'dev' END, now(),
       'box-x', CASE WHEN (s.n + s.topic) % 2 = 0 THEN 'HUM-2' ELSE 'c-005' END, 'box-x', 'c-005', 'note',
       'body ' || s.n || repeat(' padding', 200), '{}'::jsonb, 'sig', '\x00',
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
-- Pin both null-channel shapes independent of the random seed: an agent post
-- then a human ALL-0 (thread), and a lone human ALL-0 (dm).
INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
VALUES
  ('t1', '10000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a1', NULL, now(),
   'box-x', 'c-003', 'box-x', 'HUM-10', 'note', 'agent outage', '{}'::jsonb, 'sig', '\x00', now() - interval '50 minutes', now() + interval '30 days'),
  ('t1', '10000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a1', NULL, now(),
   'box-x', 'HUM-10', 'box-x', 'ALL-0', 'note', 'human follow-up', '{}'::jsonb, 'sig', '\x00', now() - interval '40 minutes', now() + interval '30 days'),
  ('t1', '10000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a3', NULL, now(),
   'box-x', 'HUM-3', 'box-x', 'ALL-0', 'note', 'humans only', '{}'::jsonb, 'sig', '\x00', now() - interval '40 minutes', now() + interval '30 days');
ANALYZE messages;
PSQL

# The pre-E17 FROM shape (DISTINCT ON over m.*), with the current SELECT
# list, as the reference. The null-channel cstate split (thread vs dm) is in
# both, so a row difference is the scan shape, not the rule.
old_sql() {
  cat <<'SQL'
SELECT l.tenant_id, coalesce(t.display_name, ''), coalesce(l.channel, ''), l.task_id, l.msg_id,
       extract(epoch FROM l.received_at)::bigint, coalesce(l.typed_by, l.from_id), l.to_id,
       CASE WHEN l.typed_by IS NOT NULL THEN 'terminal'
            WHEN l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%' THEN 'human' ELSE 'agent' END,
       CASE WHEN EXISTS (SELECT 1 FROM messages a WHERE a.tenant_id = l.tenant_id
                          AND a.task_id = l.task_id AND a.archived_at IS NOT NULL)
            THEN 'archived' ELSE 'open' END,
       CASE WHEN l.channel IS NOT NULL AND c.deleted_at IS NOT NULL THEN 'deleted'
            WHEN l.channel IS NOT NULL AND c.archived_at IS NOT NULL THEN 'archived'
            WHEN l.channel IS NOT NULL THEN 'live'
            WHEN EXISTS (SELECT 1 FROM messages g
                          WHERE g.tenant_id = l.tenant_id AND g.task_id = l.task_id
                            AND g.typed_by IS NULL
                            AND g.from_id NOT LIKE 'HUM-%' AND g.from_id NOT LIKE 'GST-%')
            THEN 'thread' ELSE 'dm' END,
       CASE WHEN coalesce(l.has_files, false) THEN 'files' ELSE '-' END,
       CASE WHEN l.typed_by IS NULL AND (l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%')
            THEN regexp_replace(left(l.body, 400), '[[:space:]]+', ' ', 'g') ELSE '' END
  FROM (SELECT DISTINCT ON (m.tenant_id, m.task_id) m.*
          FROM messages m
         WHERE m.expires_at > now() AND m.received_at > now() - make_interval(days => :days)
         ORDER BY m.tenant_id, m.task_id, m.received_at DESC, m.msg_id DESC) l
  JOIN tenants t ON t.tenant_id = l.tenant_id
  LEFT JOIN channels c ON c.tenant_id = l.tenant_id AND c.channel_id = l.channel
 ORDER BY 1, 6
SQL
}
new_sql() {
  env PROJ_PATH="$PROJ_ROOT" bash -c 'do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"; _spl_sweep_rows_sql'
}
# rt_run <sql> <prefix>: run <prefix><sql> as the runtime role in the sweep's
# read-only operator transaction (the action's own frame).
rt_run() {
  PGOPTIONS='-c default_transaction_read_only=on' psql "$RT_DSN" -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v days=7 <<SQL
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
$2$1;
COMMIT;
SQL
}
new_sql >"$T/new.sql" && grep -q 'AS MATERIALIZED' "$T/new.sql" || fail "could not read _spl_sweep_rows_sql"
old_sql >"$T/old.sql"

# 1. same answers (row order inside one tenant and second is unspecified in
# both, so compare sorted)
rt_run "$(cat "$T/old.sql")" "" | sort >"$T/old.rows"
rt_run "$(cat "$T/new.sql")" "" | sort >"$T/new.rows"
n="$(wc -l <"$T/new.rows")"
if (( n >= 100 )) && cmp -s "$T/old.rows" "$T/new.rows"; then
  pass "1. old and new statements return the same $n rows (ties, expired last, out-of-window, DMs, archived)"
else
  fail "1. rows differ (old $(wc -l <"$T/old.rows"), new $n): $(diff "$T/old.rows" "$T/new.rows" >"$T/diff"; sed -n 1,6p "$T/diff")"
fi
[[ "$(awk -F'\t' '$10 == "archived"' "$T/new.rows" | wc -l)" -ge 1 && "$(awk -F'\t' '$11 == "dm"' "$T/new.rows" | wc -l)" -ge 1 &&
   "$(awk -F'\t' '$11 == "archived"' "$T/new.rows" | wc -l)" -ge 1 && "$(awk -F'\t' '$11 == "thread"' "$T/new.rows" | wc -l)" -ge 1 ]] &&
  pass "1. the fixture carries archived cards, DMs, threads and archived channels" || fail "1. fixture lacks a case: $(cut -f10,11 "$T/new.rows" | sort | uniq -c)"
if awk -F'\t' '$4 == "00000000-0000-4000-8000-0000000000a1" && $11 == "thread" && $8 == "ALL-0" && $9 == "human" { found=1 } END { exit found ? 0 : 1 }' "$T/new.rows"; then
  pass "1. a null channel after an agent post is thread"
else
  fail "1. thread pin: $(awk -F'\t' '$4 ~ /0a1$/ { print }' "$T/new.rows")"
fi
if awk -F'\t' '$4 == "00000000-0000-4000-8000-0000000000a3" && $11 == "dm" && $8 == "ALL-0" { found=1 } END { exit found ? 0 : 1 }' "$T/new.rows"; then
  pass "1. a null channel with no agent stays dm"
else
  fail "1. dm pin: $(awk -F'\t' '$4 ~ /0a3$/ { print }' "$T/new.rows")"
fi

# narrow_scan <sql file> -> "<max output columns> <max loops>" of every scan of
# messages m in the EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) plan
narrow_scan() {
  rt_run "$(cat "$1")" "EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) " | python3 -c '
import json, sys
txt = sys.stdin.read(); plan = json.loads(txt[txt.index("["):])
cols, loops = 0, 0
def walk(n):
    global cols, loops
    if n.get("Relation Name") == "messages" and n.get("Alias") == "m":
        cols = max(cols, len(n.get("Output", []))); loops = max(loops, n.get("Actual Loops", 0))
    for c in n.get("Plans", []): walk(c)
walk(plan[0]["Plan"]); print(cols, loops)'
}
read -r nc nl <<<"$(narrow_scan "$T/new.sql")"
[[ "$nc" =~ ^[0-9]+$ ]] && (( nc >= 1 && nc <= 4 && nl == 1 )) &&
  pass "2. the new scan of messages reads $nc columns, once" || fail "2. new scan: columns=$nc loops=$nl (want <= 4, 1)"
read -r oc ol <<<"$(narrow_scan "$T/old.sql")"
[[ "$oc" =~ ^[0-9]+$ ]] && (( oc > 4 )) &&
  pass "3. CONTROL: the old statement reads $oc columns per row and fails check 2" || fail "3. CONTROL: old scan columns=$oc loops=$ol - check 2 cannot tell old from new"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
