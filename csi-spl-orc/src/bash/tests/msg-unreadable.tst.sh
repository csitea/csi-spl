#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_msg_unreadable (spec 117 1.3, incident t1 f87e6c9d): the rows
# only their writer can read, over fixture rows, a scratch spool root and a
# fake sender; then its SQL against a REAL throwaway Postgres carrying the real
# rdb migrations, as a NON-owner login so row-level security binds.
#   1. bad input is refused before any read
#   2. report only: the live rows listed per workspace with ids, times, seats;
#      test workspaces (e2e, a proof-* id, a test name) counted apart; a PLAN
#      line; nothing sent or written
#   3. DELIVER=1: ONE note to the orchestrator (LEASE_ORCH) on task
#      msg-unreadable with the NEW rows only, no test row; the state written;
#      a second run sends nothing
#   4. a new row: the next note carries that row only
#   5. a failed send records nothing: the rows stay NEW
#   6. the dispatch lease held on another machine: this one sends nothing
#   7. the SQL selects no body; on a real Postgres it returns exactly the
#      person -> ALL-0 channel-less rows of every workspace in the window
#      (CONTROL rows: a channel post, a DM to a person, an agent's ALL-0, an
#      old row, a GST- root)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PG_CTR=""
trap '[[ -n "$PG_CTR" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT

S="$T/spool"; mkdir -p "$S/dispatch"
printf 'LEASE_MASTER=c-002\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
echo "c-002 1790000000" >"$S/dispatch/lease"
# the fake sender: logs "TO <to> TASK <task> FROM <from>", the body, END; fails while $SEND_LOG.fail exists
cat >"$T/send.sh" <<'SH'
#!/usr/bin/env bash
to="" task="" from="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --task) task="$2"; shift 2 ;; --from) from="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift ;; esac; done
[ -e "$SEND_LOG.fail" ] && exit 11
{ echo "TO $to TASK $task FROM $from"; cat "$body"; echo "END"; } >>"$SEND_LOG"
SH
chmod +x "$T/send.sh"

# tenant name msg task epoch from kind in-topic
r() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
ROWS="$T/rows.tsv"
A=86abbd6a-1290-43bb-a5cf-5180de114e3b B=b7b1b5e7-26a5-4f11-9957-c644d1649e3d C=22f73584-a809-4d9f-a0fd-866cd18bc15d
D=d0000000-0000-4000-8000-00000000000d
{
  r t1 "" "$A" 483e9afc-0000-4000-8000-000000000001 1791561151 HUM-46 reply people
  r t1 "" "$B" 483e9afc-0000-4000-8000-000000000001 1791561158 HUM-46 reply people
  r t1 "" "$C" 1a7c634e-0000-4000-8000-000000000002 1791561227 HUM-46 root people
  r csitea "Csitea" "$D" 5a000000-0000-4000-8000-000000000003 1791561300 GST-2 root agent
  r e2e "" e2e00000-0000-4000-8000-000000000001 e2e00000-0000-4000-8000-0000000000aa 1791561000 HUM-1 root people
  r e2e "" e2e00000-0000-4000-8000-000000000002 e2e00000-0000-4000-8000-0000000000aa 1791561001 HUM-1 reply people
  r proof-x "" f0000000-0000-4000-8000-000000000001 f0000000-0000-4000-8000-0000000000aa 1791561002 HUM-1 root people
  r ws9 "Load test" f0000000-0000-4000-8000-000000000002 f0000000-0000-4000-8000-0000000000bb 1791561003 HUM-2 root people
} >"$ROWS"

un() { SNIPPET='do_spl_msg_unreadable' in_orc ENV=prd SPOOL_ROOT="$S" UNREADABLE_ROWS_FILE="$ROWS" SWEEP_SEND="$T/send.sh" \
  SEND_LOG="$T/sent" HOME="$T/home" "$@" 2>&1; }
sends() { grep -c '^TO ' "$T/sent" 2>/dev/null || echo 0; }

# 1 --------------------------------------------------------------------------
for bad in "ENV=qa|ENV must be dev or prd" "DELIVER=yes|DELIVER must be 0 or 1" "UNREADABLE_DAYS=0|UNREADABLE_DAYS must be" \
           "UNREADABLE_MAX_ITEMS=x|UNREADABLE_MAX_ITEMS must be" "UNREADABLE_TO=c-001;id|UNREADABLE_TO is not an agent id"; do
  out="$(un "${bad%%|*}")"; rc=$?
  [[ $rc -ne 0 ]] && grep -q "${bad#*|}" <<<"$out" && ! grep -q '^## ' <<<"$out" &&
    pass "1. ${bad%%|*} is refused before any read" || fail "1. ${bad%%|*}: rc=$rc $out"
done

# 2 --------------------------------------------------------------------------
out="$(un)"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(grep -c '^| NEW |' <<<"$out")" == 4 ]] &&
  grep -q "^| NEW | t1 | $A | 483e9afc-0000-4000-8000-000000000001 | 2026-10-09T15:52Z | HUM-46 | reply | people |$" <<<"$out" &&
  grep -q "^| NEW | t1 | $C | 1a7c634e-0000-4000-8000-000000000002 | .* | HUM-46 | root | people |$" <<<"$out" &&
  grep -q "^| NEW | csitea | $D | .* | GST-2 | root | agent |$" <<<"$out" &&
  pass "2. the 4 live rows are listed with ids, times, seats" || fail "2. rows: rc=$rc $out"
grep -q '^| e2e | 2 |$' <<<"$out" && grep -q '^| proof-x | 1 |$' <<<"$out" && grep -q '^| ws9 | 1 |$' <<<"$out" &&
  ! grep -q '^| NEW | \(e2e\|proof-x\|ws9\) ' <<<"$out" && grep -q '^SUM rows=4 new=4 test=4 people=3 agent=1$' <<<"$out" &&
  pass "2. test workspaces (e2e, proof-x, a 'Load test' name) are counted apart, never listed" || fail "2. test: $out"
grep -q '^PLAN send to c-001: \*\*Messages only their writer can read\*\* (prd, ' <<<"$out" &&
  [[ ! -e "$T/sent" && ! -e "$S/dispatch/unreadable-prd.state" ]] &&
  pass "2. report only: a PLAN line to the orchestrator, nothing sent or written" || fail "2. report only: $out $(ls "$S/dispatch")"

# 3 --------------------------------------------------------------------------
out="$(un DELIVER=1)"; rc=$?
[[ $rc -eq 0 && "$(sends)" == 1 ]] && grep -q '^TO c-001 TASK msg-unreadable FROM c-001$' "$T/sent" &&
  grep -q '4 new row(s), 4 in all (test workspaces left out: 4)' "$T/sent" &&
  [[ "$(grep -c '^| NEW |' "$T/sent")" == 4 ]] && ! grep -q 'e2e00000\|f0000000' "$T/sent" &&
  pass "3. DELIVER=1: one note to c-001 on msg-unreadable with the 4 NEW rows, no test row" || fail "3. deliver: rc=$rc $out $(cat "$T/sent" 2>/dev/null)"
[[ "$(LC_ALL=C sort "$S/dispatch/unreadable-prd.state")" == "$(printf '%s\n' "csitea|$D" "t1|$A" "t1|$B" "t1|$C" | LC_ALL=C sort)" ]] &&
  pass "3. the state holds the 4 live rows" || fail "3. state: $(cat "$S/dispatch/unreadable-prd.state")"
out="$(un DELIVER=1)"; rc=$?
[[ $rc -eq 0 && "$(sends)" == 1 ]] && [[ "$(grep -c '^| seen |' <<<"$out")" == 4 ]] && grep -q '^SUM rows=4 new=0 test=4 people=3 agent=1$' <<<"$out" &&
  pass "3. a second run sends nothing; the rows are 'seen'" || fail "3. second run: $(sends) $out"

# 4 --------------------------------------------------------------------------
E=e0000000-0000-4000-8000-00000000000e
r t1 "" "$E" 483e9afc-0000-4000-8000-000000000001 1791562000 HUM-46 reply >>"$ROWS"
out="$(un DELIVER=1)"; rc=$?
last="$(sed -n '/^TO /h; /^TO /!H; ${x;p}' "$T/sent")"
[[ $rc -eq 0 && "$(sends)" == 2 ]] && [[ "$(grep -c '^| NEW |' <<<"$last")" == 1 ]] && grep -q "^| NEW | t1 | $E |" <<<"$last" &&
  pass "4. a new row: the next note carries that row only" || fail "4. new row: rc=$rc $(cat "$T/sent")"

# 5 --------------------------------------------------------------------------
F=f1000000-0000-4000-8000-00000000000f
r t1 "" "$F" 483e9afc-0000-4000-8000-000000000001 1791563000 HUM-46 reply >>"$ROWS"
cp "$S/dispatch/unreadable-prd.state" "$T/state.before"; touch "$T/sent.fail"
out="$(un DELIVER=1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL the note was not delivered' <<<"$out" && cmp -s "$T/state.before" "$S/dispatch/unreadable-prd.state" &&
  pass "5. a failed send records nothing" || fail "5. failed send: rc=$rc $out"
rm -f "$T/sent.fail"
out="$(un DELIVER=1)"
grep -q "^| NEW | t1 | $F |" "$T/sent" && [[ "$(sends)" == 3 ]] && pass "5. ...and the row is sent on the next run" || fail "5. retry: $(cat "$T/sent")"

# 6 --------------------------------------------------------------------------
echo "c-002@box-b 1790000000" >"$S/dispatch/lease"; echo LEASE_MACHINE=box-a >>"$S/dispatch/lease.conf"
G=f2000000-0000-4000-8000-00000000000a
r t1 "" "$G" 483e9afc-0000-4000-8000-000000000001 1791564000 HUM-46 reply >>"$ROWS"
out="$(un DELIVER=1)"; rc=$?
[[ $rc -eq 0 && "$(sends)" == 3 ]] && grep -q 'held by c-002@box-b' <<<"$out" &&
  pass "6. the lease on another machine: this one sends nothing" || fail "6. remote lease: rc=$rc $out"
out="$(un DELIVER=1 UNREADABLE_TO=c-009)"; rc=$?
[[ $rc -eq 0 && "$(sends)" == 4 ]] && grep -q '^TO c-009 TASK msg-unreadable' "$T/sent" &&
  pass "6. CONTROL: an explicit UNREADABLE_TO sends from here" || fail "6. control: rc=$rc $out"

# 7 --------------------------------------------------------------------------
FUNC="$PROJ_ROOT/src/bash/run/spl-msg-unreadable.func.sh"
sql="$(sed -n '/^_spl_unreadable_rows_sql()/,/^}/p' "$FUNC")"
! grep -qi 'body' <<<"$sql" && grep -q 'BEGIN READ ONLY' "$FUNC" && pass "7. the SQL selects no body and runs READ ONLY" || fail "7. sql: $sql"
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the SQL part is not run"
  echo "msg-unreadable: ${fails} failure(s)"; [ "$fails" -eq 0 ]; exit
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool-bin"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-msg-unreadable-pg-$$"
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
psql_owner -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex')), ('csitea', decode(repeat('ac', 32), 'hex'))" >/dev/null
psql_owner -c "INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('t1', 'dev', 'dev', 'HUM-1')" >/dev/null
# m <tenant> <msg n> <channel|''> <from> <to> <days ago> <is_parent> <task n>
m() {
  local ch="NULL"; [[ -n "$3" ]] && ch="'$3'"
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at, is_parent)
    VALUES ('$1', '10000000-0000-4000-8000-00000000000$2', '00000000-0000-4000-8000-00000000000$8', $ch, now(), 'box-wui', '$4', 'box-wui', '$5', 'note', 'secret body $2',
            '{}'::jsonb, 'sig', '\\x00', now() - interval '$6 days', now() + interval '60 days', $7)" >/dev/null || fail "seed $1 msg $2"
}
m t1 1 "" HUM-46 ALL-0 1 0 1     # hit: a person's reply to nobody (people)
m t1 2 "" HUM-46 ALL-0 1 1 2     # hit: a channel-less root to nobody (people)
m csitea 3 "" GST-2 ALL-0 2 1 3  # hit: a guest, another workspace; an agent in the topic (agent)
m csitea 8 "" c-003 GST-2 2 0 3  #   the agent's post in that topic
m t1 4 dev HUM-46 ALL-0 1 0 4    # control: a channel post
m t1 5 "" HUM-46 HUM-10 1 0 1    # control: a DM to a person
m t1 6 "" c-003 ALL-0 1 0 6      # control: an agent's ALL-0
m t1 7 "" HUM-46 ALL-0 45 0 7    # control: older than the window
env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" OUT="$T/pgrows" UNREADABLE_DAYS=30 bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-msg-unreadable.func.sh"
  _spl_unreadable_rows_read "$OUT"' >"$T/o" 2>&1; rc=$?
got="$(cut -f1,3,6,7,8 "$T/pgrows" 2>/dev/null | sed 's/10000000-0000-4000-8000-00000000000//' | tr '\t\n' ', ')"
[[ $rc -eq 0 && "$got" == "csitea,3,GST-2,root,agent t1,1,HUM-46,reply,people t1,2,HUM-46,root,people " ]] &&
  pass "7. on Postgres as the runtime role: exactly the 3 writer-only rows of both workspaces" || fail "7. pg: rc=$rc got='$got' $(cat "$T/o")"
! grep -q 'secret body' "$T/pgrows" && pass "7. no body in the rows" || fail "7. a body leaked into the rows"

echo "msg-unreadable: ${fails} failure(s)"
[ "$fails" -eq 0 ]
