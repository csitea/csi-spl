#!/usr/bin/env bash
# Spec 144 T006, control C3 (spec section 12.2): do_spl_unanswered_sweep never
# lists a private scope (rdb 0219), so no dispatcher is handed a private
# discussion. Against a REAL throwaway Postgres with the real migrations, as
# the runtime role so row-level security binds:
#   1. the full read keeps a public human-last topic and leaves out a topic in
#      a private channel, a private topic, a topic with a dedicated agent and
#      a topic in a channel with a dedicated agent
#   2. the classifier report lists the public topic and 0 private items
#   3. CONTROL: the same reads with the private filter off (the statement
#      before T006) carry and list all four private topics
#   4. the delta read: cache + delta == the full read after a public post, a
#      post in a private channel, a public topic going private (a flagged
#      line), a dedicated agent bound to a cached topic and a cached topic's
#      channel made private; the merge drops the three cached rows
#   5. CONTROL: with the filter off the merge keeps all four private topics
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
PG_CTR="spl-unanswered-private-pg-$$"
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
[[ "$(psql_owner -c "SELECT count(*) FROM information_schema.columns WHERE table_name = 'messages' AND column_name = 'is_private_scope'")" == 1 ]] ||
  { fail "rdb 0219 is not applied: no messages.is_private_scope"; exit 1; }

tk() { printf '00000000-0000-4000-8000-0000000000%02d' "$1"; }
# m <task n> <channel> <from> <minutes ago> <private> <body>: a line in t1
m() {
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at, is_private_scope)
    VALUES ('t1', gen_random_uuid(), '$(tk "$1")', '$2', now(), 'box-wui', '$3', 'box-desk', 'ALL-0', 'note', \$b\$$6\$b\$,
            '{}'::jsonb, 'sig', '\\x00', now() - interval '$4 minutes', now() + interval '30 days', $5)" >/dev/null || fail "seed task $1"
}
psql_owner <<PSQL >/dev/null || fail "seed tenants/channels/bindings"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('t1', 'dev', 'dev', 'HUM-1'), ('t1', 'bound', 'bound', 'HUM-1'), ('t1', 'ops', 'ops', 'HUM-1');
INSERT INTO channels (tenant_id, channel_id, name, created_by, is_private_scope, private_scope_at) VALUES ('t1', 'sec', 'sec', 'HUM-1', true, now());
INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES
  ('t1', 'c-901', 'box-a', 'topic', '$(tk 4)', 'HUM-1'), ('t1', 'c-902', 'box-a', 'channel', 'bound', 'HUM-1');
PSQL
m 1 dev HUM-2 100 false "public question"          # topic 1: public, human last
m 2 sec HUM-2 100 false "question in a private channel"
m 3 dev HUM-2 100 true "question in a private topic"
m 4 dev HUM-2 100 false "question in a dedicated topic"
m 5 bound HUM-2 100 false "question in a dedicated channel"
m 6 dev HUM-2 100 false "public now, private later"
m 9 dev HUM-2 100 false "public now, dedicated later"
m 10 ops HUM-2 100 false "public now, its channel private later"

# sweep <fn> <args...>: a sweep function as the runtime role; SW_NOPRIV=1
# turns the private filter off (the statement before T006, for the controls)
sweep() {
  env PROJ_PATH="$PROJ_ROOT" RT_DSN="$RT_DSN" SPL_PROXY_DSN="$RT_DSN" SW_NOPRIV="${SW_NOPRIV:-0}" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    [[ "$SW_NOPRIV" == 1 ]] && _spl_sweep_private_sql() { printf false; }
    "$@"' _ "$@"
}
# report <rows>: the classifier's report over a row file
report() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" ENV=prd SWEEP_ROWS_FILE="$1" SWEEP_TO=c-002 HOME="$T/home" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    do_spl_unanswered_sweep'
}
has() { awk -F'\t' -v t="$(tk "$2")" '$4 == t && $5 != "" { f = 1 } END { exit !f }' "$1"; }
srt() { LC_ALL=C sort "$1"; }

# 1. + 2. the full read and its report
sleep 1.1
sweep _spl_sweep_rows_read "$T/f0" "$T/now0" 2>"$T/e0" || fail "1. read: $(cat "$T/e0")"
has "$T/f0" 1 && has "$T/f0" 6 && has "$T/f0" 9 && has "$T/f0" 10 && ! has "$T/f0" 2 && ! has "$T/f0" 3 && ! has "$T/f0" 4 && ! has "$T/f0" 5 &&
  pass "1. the full read keeps the public topics and leaves out the private channel, private topic, dedicated topic and dedicated channel" ||
  fail "1. rows: $(cut -f3,4,9 "$T/f0" | tr '\n' ' ') $(cat "$T/e0")"
report "$T/f0" >"$T/r0" 2>&1
grep -q "^| open | t1 | #dev | $(tk 1) |" "$T/r0" && grep -q "^| open | t1 | #dev | $(tk 6) |" "$T/r0" &&
  [[ "$(grep -c '^| open |' "$T/r0")" == 4 ]] && ! grep -q 'question in a' "$T/r0" &&
  pass "2. C3: the report lists the public topic and 0 private items" || fail "2. report: $(grep '^| open' "$T/r0")"

# 3. CONTROL: the filter off
SW_NOPRIV=1 sweep _spl_sweep_rows_read "$T/c0" 2>"$T/ec" || fail "3. read: $(cat "$T/ec")"
report "$T/c0" >"$T/rc" 2>&1
has "$T/c0" 2 && has "$T/c0" 3 && has "$T/c0" 4 && has "$T/c0" 5 &&
  [[ "$(grep -c '^| open | t1 | .*| \(question in a \(private\|dedicated\)\)' "$T/rc")" == 4 ]] &&
  pass "3. CONTROL: with the filter off the 4 private topics are read and listed" || fail "3. CONTROL: $(grep '^| open' "$T/rc")"

# 4. the delta read: a public post, a post in the private channel, topic 6
# going private (its new line flagged, spec 3.2)
now0="$(cat "$T/now0")"
sleep 1.1
m 7 dev HUM-2 0 false "a new public question"
m 8 sec HUM-2 0 false "a new question in the private channel"
m 6 dev HUM-2 0 true "topic 6 is private now"
psql_owner -c "INSERT INTO dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id, bound_by) VALUES ('t1', 'c-903', 'box-a', 'topic', '$(tk 9)', 'HUM-1')" >/dev/null || fail "bind topic 9"
psql_owner -c "UPDATE channels SET is_private_scope = true, private_scope_at = now() WHERE tenant_id = 't1' AND channel_id = 'ops'" >/dev/null || fail "ops private"
sleep 1.1
delta() { # <rows prefix>: full + delta in one snapshot, then the merge of f0
  # shellcheck disable=SC2046 # two words: the arrays
  sweep _spl_sweep_rows_read "$T/$1.f" "$T/$1.now" "$now0" "$T/$1.d" $(sweep spl_sweep_keep "$T/f0") 2>"$T/$1.e" &&
    sweep spl_sweep_merge "$T/f0" "$T/$1.d" "$(cat "$T/$1.now")" 7 >"$T/$1.m" 2>>"$T/$1.e"
}
delta d1 || fail "4. read: $(cat "$T/d1.e")"
cmp -s <(srt "$T/d1.m") <(srt "$T/d1.f") && has "$T/d1.m" 7 && has "$T/d1.m" 1 && ! has "$T/d1.m" 6 && ! has "$T/d1.m" 8 &&
  ! has "$T/d1.m" 9 && ! has "$T/d1.m" 10 &&
  pass "4. cache + delta == the full read: the new public post is in; the private channel's post, the topic gone private, the topic bound later and the channel made private later are not" ||
  fail "4. merged: $(cut -f4,13 "$T/d1.m" | tr '\n' ' ') / full: $(cut -f4 "$T/d1.f" | tr '\n' ' ') $(cat "$T/d1.e")"

# 5. CONTROL: the filter off, the merge keeps them
SW_NOPRIV=1 delta d0 || fail "5. read: $(cat "$T/d0.e")"
has "$T/d0.m" 6 && has "$T/d0.m" 8 && has "$T/d0.m" 9 && has "$T/d0.m" 10 &&
  pass "5. CONTROL: with the filter off the merge carries all four" ||
  fail "5. CONTROL: $(cut -f4 "$T/d0.m" | tr '\n' ' ')"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
