#!/usr/bin/env bash
# do_spl_unanswered_sweep's hub query (_spl_sweep_rows_read) against a REAL
# throwaway Postgres carrying the real rdb migrations, as a NON-owner login so
# rdb 0014 row-level security binds and the operator scope is what lets it read
# every workspace. The fixture test (unanswered-sweep.tst.sh) proves the rules
# on hand-written rows; this one proves the SQL runs on the real schema and
# hands the classifier the rows it expects. Written after the first prd run
# failed on "column t.disabled_at does not exist" (2026-10-01): a column the
# fixtures assumed and no migration has.
#   1. the query runs on the migrated schema, one row per topic, two workspaces
#   2. the last message decides: human-last -> human, agent-last -> agent
#   3. an archived card -> archived; an archived channel -> archived channel
#   4. a DM carries no channel and its to_id; a body's tab/newline collapse
#   2b. a terminal-typed line (typed_by) is 'terminal', not a human post
#   5. CONTROL: the classifier lists exactly the open topic of each workspace
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

grep -q 'disabled_at' "$PROJ_ROOT/src/bash/run/spl-unanswered-sweep.func.sh" &&
  fail "the sweep SQL names disabled_at, which no tenants migration has" || pass "no disabled_at in the sweep SQL"

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the SQL part is not run"
  (( fails == 0 )) && exit 0; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-unanswered-pg-$$"
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

# m <tenant> <task n> <msg n> <channel|''> <from> <to> <minutes ago> <body>
m() {
  local ch="NULL"; [[ -n "$4" ]] && ch="'$4'"
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', '10000000-0000-4000-8000-00000000000$3', '00000000-0000-4000-8000-00000000000$2', $ch, now(),
            CASE WHEN '$5' LIKE 'HUM-%' THEN 'box-wui' ELSE 'box-desk' END, '$5', 'box-desk', '$6', 'note', \$b\$$8\$b\$,
            '{}'::jsonb, 'sig', '\\x00', now() - interval '$7 minutes', now() + interval '30 days')" >/dev/null ||
    fail "seed $1 task $2 msg $3"
}
psql_owner <<'PSQL' >/dev/null || fail "seed tenants/channels"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex')), ('csi-rel', decode(repeat('ac', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('t1', 'dev', 'dev', 'HUM-1'), ('t1', 'old', 'old', 'HUM-1'), ('csi-rel', 'development', 'development', 'HUM-27');
UPDATE channels SET archived_at = now(), archived_by = 'HUM-1' WHERE tenant_id = 't1' AND channel_id = 'old';
PSQL
m t1 1 1 dev HUM-2 box-desk 120 "agent first?"
m t1 1 2 dev CLE-5 HUM-2 110 "agent reply"
m t1 1 3 dev HUM-2 box-desk 100 "still broken"             # topic 1: human last
m t1 2 4 dev HUM-2 box-desk 100 "question"
m t1 2 5 dev CLE-5 HUM-2 90 "answer"                        # topic 2: agent last
m t1 3 6 dev HUM-2 box-desk 100 "archived card"             # topic 3: archived
m t1 4 7 old HUM-2 box-desk 100 "in an archived channel"    # topic 4: archived channel
m csi-rel 5 8 development HUM-27 box-desk 4000 "bug one"    # topic 5: the csi-rel shape, 3 days old
m csi-rel 6 9 "" HUM-27 CLE-7 60 "dm with	a tab
and a newline"                                              # topic 6: a DM to an agent
psql_owner -c "UPDATE messages SET archived_at = now(), archived_by = 'HUM-1' WHERE msg_id = '10000000-0000-4000-8000-000000000006'" >/dev/null
m t1 7 a dev CLE-5 box-desk 80 "typed in the terminal"     # topic 7: a terminal-typed line (specs/036)
psql_owner -c "UPDATE messages SET typed_by = 'HUM-2' WHERE msg_id = '10000000-0000-4000-8000-00000000000a'" >/dev/null || fail "seed typed_by"

env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" OUT="$T/rows" bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
  _spl_sweep_rows_read "$OUT"' >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$T/rows")" == 7 ]] && [[ "$(cut -f1 "$T/rows" | sort -u | tr '\n' ' ')" == "csi-rel t1 " ]] &&
  pass "1. the query runs on the migrated schema as the runtime role: 7 topics, both workspaces" ||
  fail "1. rc=$rc rows=$(wc -l <"$T/rows" 2>/dev/null) $(cat "$T/o") $(cat "$T/rows" 2>/dev/null)"
col() { awk -F'\t' -v t="$1" -v c="$2" '$4 == "00000000-0000-4000-8000-00000000000" t { print $c }' "$T/rows"; }
[[ "$(col 1 9) $(col 1 5) $(col 1 13)" == "human 10000000-0000-4000-8000-000000000003 still broken" && "$(col 2 9)" == agent && -z "$(col 2 13)" ]] &&
  pass "2. the last message decides; an agent's body is not read"
[[ "$(col 7 9) $(col 7 7)" == "terminal HUM-2" && -z "$(col 7 13)" ]] && pass "2. a typed_by line is 'terminal', shown as its human" || fail "2. typed_by: $(col 7 9) $(col 7 7) $(col 7 13)" || fail "2. $(col 1 9) $(col 1 5) $(col 1 13) / $(col 2 9) $(col 2 13)"
[[ "$(col 3 10)" == archived && "$(col 4 11)" == archived && "$(col 1 10) $(col 1 11)" == "open live" ]] &&
  pass "3. archived card and archived channel are flagged; a live topic is open/live" || fail "3. $(col 3 10) $(col 4 11) $(col 1 10) $(col 1 11)"
[[ -z "$(col 6 3)" && "$(col 6 8)" == CLE-7 && "$(col 6 11)" == dm && "$(col 6 13)" == "dm with a tab and a newline" ]] &&
  pass "4. a DM: no channel, its to_id, whitespace collapsed to one line" || fail "4. '$(col 6 3)' $(col 6 8) $(col 6 11) '$(col 6 13)'"

env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" ENV=prd SWEEP_ROWS_FILE="$T/rows" SWEEP_TO=CLE-002 HOME="$T/home" bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
  do_spl_unanswered_sweep' >"$T/o" 2>&1
[[ "$(grep -c '^| open |' "$T/o")" == 3 ]] && grep -q '^| open | t1 | #dev | 00000000-0000-4000-8000-000000000001 |' "$T/o" &&
  grep -q '^| open | csi-rel | #development | 00000000-0000-4000-8000-000000000005 | .* | 2d18h | HUM-27 | bug one |' "$T/o" &&
  grep -q '^| open | csi-rel | dm CLE-7 |' "$T/o" &&
  pass "5. CONTROL: the classifier lists the open topics of every workspace, nothing closed or answered" || fail "5. $(cat "$T/o")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
