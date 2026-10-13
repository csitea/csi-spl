#!/usr/bin/env bash
# do_spl_msg_purge / do_spl_msg_purge_undo (SPL-1641): the list guards
# (hermetic, refused before any cloud call), then purge.sql and undo.sql
# against a REAL throwaway Postgres carrying the real rdb migrations,
# connected as a NON-owner login so rdb 0014/0021 row-level security binds.
#
# The controls are the point:
#   - DRY_RUN=1 prints the counts and changes nothing
#   - a missing id, an id in the wrong task: refused, nothing changed
#   - DRY_RUN=0 deletes exactly the listed rows and their children; an
#     unlisted row in the same topic stays and becomes the archived card
#   - the journal is written before the delete; the undo puts back every
#     row byte for byte and clears only the stamps the purge set
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

SQL="$PROJ_ROOT/src/sql/msg-purge"
grep -q "SET LOCAL app.tenant_id = :'tenant'" "$SQL/purge.sql" && grep -q "SET LOCAL app.tenant_id = :'tenant'" "$SQL/undo.sql" \
  && pass "both scripts run under the tenant's RLS context" || fail "no app.tenant_id"
grep -qE '\$SPL_MP_|\$\{?[a-z]+\}?' "$SQL/purge.sql" "$SQL/undo.sql" \
  && fail "a shell value is spliced into the SQL" || pass "values travel as psql variables only"
awk '/^\\o :journal$/{j=NR} /^DELETE FROM messages/{d=NR} END{exit !(j && d && j < d)}' "$SQL/purge.sql" \
  && pass "the journal is written before the DELETE" || fail "journal not before the DELETE"

# --- the guards, sourced like the other orc tests (no ./run) ------------------
U=(aaaaaaaa-0000-4000-8000-00000000000 bbbbbbbb-0000-4000-8000-00000000000)
TA=a0000000-0000-4000-8000-000000000001
printf 't1 %s1 %s\nt1 %s2 %s\n# a comment\n\ncsi-rel %s1 %s\n' "${U[0]}" "$TA" "${U[0]}" "$TA" "${U[1]}" "$TA" >"$T/ok.tsv"
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u LIST_FILE -u EXPECT_N -u ARCHIVED_BY -u DRY_RUN \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { echo "REACHED-CLOUD"; return 1; }
    do_spl_msg_purge' >"$T/out" 2>&1 </dev/null
}
OK_ARGS=(LIST_FILE="$T/ok.tsv" EXPECT_N=3 ARCHIVED_BY=HUM-10)
guard() { # <label> <needle> <list content or ''> <env assignments...>
  local label="$1" needle="$2" body="$3"; shift 3
  [[ -n "$body" ]] && printf '%b' "$body" >"$T/bad.tsv"
  act "${OK_ARGS[@]}" "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$needle" "$T/out" && ! grep -q REACHED-CLOUD "$T/out" \
    && pass "$label (refused before any cloud call)" || fail "$label: rc=$rc $(cat "$T/out")"
}
guard "no LIST_FILE"          "LIST_FILE must be a readable"  "" LIST_FILE="$T/nope.tsv"
guard "EXPECT_N missing"      "EXPECT_N must be"              "" EXPECT_N=
guard "EXPECT_N wrong"        "holds 3 row(s), EXPECT_N=76"   "" EXPECT_N=76
guard "a bad ARCHIVED_BY"     "ARCHIVED_BY must look like"    "" "ARCHIVED_BY=HUM-10'--"
guard "a bad DRY_RUN"         "DRY_RUN must be 0 or 1"        "" DRY_RUN=yes
guard "a short msg id"        "line 1 is not"  "t1 aaaaaaaa $TA\n" LIST_FILE="$T/bad.tsv" EXPECT_N=1
guard "SQL in the tenant"     "line 1 is not"  "t1'-- ${U[0]}1 $TA\n" LIST_FILE="$T/bad.tsv" EXPECT_N=1
guard "a fourth field"        "line 1 is not"  "t1 ${U[0]}1 $TA x\n" LIST_FILE="$T/bad.tsv" EXPECT_N=1
guard "a msg listed twice"    "listed twice"   "t1 ${U[0]}1 $TA\nt1 ${U[0]}1 $TA\n" LIST_FILE="$T/bad.tsv" EXPECT_N=2
guard "the lobby task"        "lobby task"     "t1 ${U[0]}1 00000000-0000-4000-8000-000000000001\n" LIST_FILE="$T/bad.tsv" EXPECT_N=1
act "${OK_ARGS[@]}" DRY_RUN=0
grep -q REACHED-CLOUD "$T/out" && pass "CONTROL: a good list passes the guards and reaches the cloud step" \
  || fail "a good list was refused: $(cat "$T/out")"

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
PG_CTR="spl-msg-purge-pg-$$"
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

seed() { # <tenant> <msg_id> <task_id> <is_parent> <minute> [mirror_of]
  psql_owner <<PSQL >/dev/null
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$1', decode(repeat('ab', 32), 'hex')) ON CONFLICT DO NOTHING;
INSERT INTO messages (tenant_id, msg_id, task_id, ts, received_at, from_box, from_id, to_box, to_id, kind, body, msg,
                      env_sig, env, expires_at, is_parent, mirror_of)
VALUES ('$1', '$2', '$3', now(), '2026-09-26 10:00:00+00'::timestamptz + interval '$5 minutes', 'box-a', 'CLE-1', 'box-a',
        'HUM-10', 'note', E'| a | table |\\\\n|---|---|', jsonb_build_object('to', 'HUM-10', 'body', 'x\\\\y'),
        'sig', '\\x00ab', now() + interval '30 days', $4, NULLIF('${6:-}', '')::uuid);
PSQL
}
id() { printf '%s-0000-4000-8000-%012d' "$1" "$2"; }
TA=$(id a0000000 1); TB=$(id b0000000 1); TC=$(id c0000000 1); TX=$(id d0000000 1); TM=$(id e0000000 1)
A0=$(id aaaaaaaa 0); A1=$(id aaaaaaaa 1); A2=$(id aaaaaaaa 2); AM=$(id aaaaaaaa 3)
B0=$(id bbbbbbbb 0); B1=$(id bbbbbbbb 1); C0=$(id cccccccc 0); X0=$(id dddddddd 0); X1=$(id dddddddd 1)
seed t2 "$A0" "$TA" 1 0; seed t2 "$A1" "$TA" 0 1; seed t2 "$A2" "$TA" 1 2; seed t2 "$AM" "$TM" 1 3 "$A2"
seed t2 "$B0" "$TB" 1 0; seed t2 "$B1" "$TB" 0 1; seed t2 "$C0" "$TC" 1 0
seed t3 "$X0" "$TX" 1 0; seed t3 "$X1" "$TX" 0 1
psql_owner >/dev/null <<PSQL
INSERT INTO message_revisions VALUES ('t2', '$A0', 1, 'old body', 'CLE-1', now()), ('t2', '$A0', 2, 'new body', 'CLE-1', now());
INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji) VALUES ('t2', '$A0', 'HUM-10', 'x'), ('t2', '$B0', 'HUM-10', 'y');
PSQL
snap() { psql_owner -c "SELECT md5(string_agg(to_jsonb(m)::text, ',' ORDER BY msg_id)) FROM messages m"; }
snapc() { psql_owner -c "SELECT (SELECT count(*) FROM message_revisions) || '/' || (SELECT count(*) FROM message_reactions)"; }
BEFORE="$(snap)"; BEFOREC="$(snapc)"

run() { # <dry> <plan>: _spl_msg_purge_all against the throwaway db
  env PROJ_PATH="$PROJ_ROOT" ENV=dev GCP_ACCOUNT=test@example.com SPL_PROXY_DSN="$RT_DSN" \
    SPL_MP_PLAN="$2" SPL_MP_BY=HUM-10 SPL_MP_DRY="$1" SPL_MP_JDIR="$T/journal" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-msg-purge.func.sh"; source "$PROJ_PATH/src/bash/run/spl-msg-purge-undo.func.sh"
    _spl_msg_purge_all' >"$T/out" 2>&1
}
mkdir -p "$T/journal"
PLAN="t2 $A0:$TA,$A1:$TA,$B1:$TB,$C0:$TC
t3 $X1:$TX"

run 1 "$PLAN"; rc=$?
[[ $rc -eq 0 ]] && grep -q "dev/t2: n=4 of 4 listed, topics=3: STAMP=2 ARCHIVED=0 GONE=1" "$T/out" \
  && grep -q "dev/t3: n=1 of 1 listed, topics=1: STAMP=1" "$T/out" && grep -q "message_reactions=1 message_revisions=2" "$T/out" \
  && grep -q "DRY_RUN rolled back" "$T/out" && [[ "$(snap)" == "$BEFORE" ]] \
  && pass "DRY_RUN=1: t2 n=4 in 3 topics (2 to stamp, 1 gone), t3 n=1, children counted; nothing changed" \
  || fail "dry: rc=$rc $(cat "$T/out")"
grep -q 'table' "$T/out" && fail "the output carries a message body" || pass "the output carries ids and counts only"

refused() { # <label> <plan> <needle>
  run 0 "$2"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "$3" "$T/out" && [[ "$(snap)" == "$BEFORE" ]] && [[ -z "$(ls -A "$T/journal")" ]] \
    && pass "$1: refused, nothing changed, no journal" || fail "$1: rc=$rc $(cat "$T/out")"
}
refused "a missing id"             "t2 $A0:$TA,$(id ffffffff 9):$TA" "MISSING msg=$(id ffffffff 9)"
refused "an id in the wrong task"  "t2 $A0:$TB"                      "MISSING msg=$A0 task=$TB"
refused "t3's id asked as t2 (RLS + tenant)" "t2 $X1:$TX"            "n=0 of 1"
refused "t3 bad: t2 is not touched either" "t2 $A0:$TA
t3 $(id ffffffff 8):$TX" "n=0 of 1"

run 0 "$PLAN"; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK dev/t2: DELETE 4, STAMP 3" "$T/out" && grep -q "OK dev/t3: DELETE 1, STAMP 1" "$T/out" \
  && pass "DRY_RUN=0: t2 DELETE 4 + 3 stamps (card + its mirror + B0), t3 DELETE 1 + 1 stamp" || fail "real: rc=$rc $(cat "$T/out")"
left="$(psql_owner -c "SELECT string_agg(msg_id::text, ' ' ORDER BY msg_id) FROM messages")"
[[ "$left" == "$A2 $AM $B0 $X0" ]] && pass "only the listed rows are gone; the unlisted rows of the same topics stay" \
  || fail "left: $left"
arch="$(psql_owner -c "SELECT string_agg(msg_id::text || '=' || archived_by, ' ' ORDER BY msg_id) FROM messages WHERE archived_at IS NOT NULL")"
[[ "$arch" == "$A2=HUM-10 $AM=HUM-10 $B0=HUM-10 $X0=HUM-10" ]] \
  && pass "the new cards (A2 after its card went, B0) and A2's DM mirror read archived by HUM-10" || fail "archived: $arch"
[[ "$(snapc)" == "0/1" ]] && pass "A0's revisions and reaction went with it; B0's reaction stays" || fail "children: $(snapc)"
mapfile -t J < <(ls "$T/journal")
[[ ${#J[@]} == 2 ]] && [[ "$(grep -c '^messages	' "$T/journal/${J[0]}")" == 4 ]] \
  && [[ "$(grep -c '^message_revisions	' "$T/journal/${J[0]}")" == 2 ]] \
  && [[ "$(grep -c '^=archive	' "$T/journal/${J[0]}")" == 3 ]] \
  && pass "one journal per tenant; t2's holds 4 messages, 2 revisions and 3 stamps" || fail "journal: ${J[*]} $(cat "$T/journal/"* 2>/dev/null | cut -c1-80)"

undo() { # <dry> <journal>
  env PROJ_PATH="$PROJ_ROOT" ENV=dev GCP_ACCOUNT=test@example.com SPL_PROXY_DSN="$RT_DSN" \
    SPL_MP_J="$2" SPL_MP_TENANT="$(sed -n 's/^=meta\t.*"tenant": "\([a-z0-9-]*\)".*/\1/p' "$2")" SPL_MP_DRY="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-msg-purge.func.sh"; source "$PROJ_PATH/src/bash/run/spl-msg-purge-undo.func.sh"
    _spl_msg_purge_undo_run' >"$T/out" 2>&1
}
AFTER="$(snap)"
sed 's/"tenant": "t2"/"tenant": "t3"/' "$T/journal/${J[0]}" >"$T/forged.tsv"
undo 0 "$T/forged.tsv"; rc=$?
[[ $rc -ne 0 ]] && grep -q "refused" "$T/out" && pass "a journal whose rows are another tenant's is refused" \
  && [[ "$(snap)" == "$AFTER" ]] || fail "forged: $(cat "$T/out")"
undo 1 "$T/journal/${J[0]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q "RESTORED 4" "$T/out" && [[ "$(snap)" == "$AFTER" ]] \
  && pass "undo DRY_RUN=1: restores 4 inside the transaction, rolls back" || fail "undo dry: rc=$rc $(cat "$T/out")"
for j in "${J[@]}"; do undo 0 "$T/journal/$j" || fail "undo $j: $(cat "$T/out")"; done
[[ "$(snap)" == "$BEFORE" ]] && pass "undo DRY_RUN=0: every message row is back byte for byte, the stamps are cleared" \
  || fail "undo: $(psql_owner -c "SELECT msg_id, archived_at FROM messages ORDER BY msg_id")"
[[ "$(snapc)" == "$BEFOREC" ]] && pass "the revisions and reactions are back" || fail "children after undo: $(snapc)"
undo 0 "$T/journal/${J[0]}"; rc=$?
[[ $rc -ne 0 ]] && grep -q "refused" "$T/out" && [[ "$(snap)" == "$BEFORE" ]] \
  && pass "a second undo is refused (the messages exist)" || fail "re-undo: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
