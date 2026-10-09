#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_doc_tree_repair (spec 113 section 3.4, T003).
#   A. the action, stubbed (no cloud call): DOC_ID missing or malformed and a
#      bad DRY_RUN are refused before any gcloud call
#   B. against a REAL throwaway Postgres with every rdb migration, run by the
#      RUNTIME login (non-owner: FORCE RLS binds, its grants suffice), on a doc
#      with one planted gap and one unreachable cycle (written by the owner
#      with the triggers off):
#      1. dry run (the default): renumbered=1 reattached=1 ids=<cut>, the
#         check inside the rolled-back transaction is violations=0; nothing
#         committed (the check still finds 2, rev unchanged)
#      2. DRY_RUN=0: the same line, the check after the commit violations=0,
#         exit 0; the cut item is the last child of the root; rev + 1 and one
#         "repair" log entry naming it
#      3. again on the clean doc: renumbered=0 reattached=0, no rev bump
#      4. the doc lock: a repair waits on another session holding the doc
#         row FOR UPDATE (pg_stat_activity wait_event_type = Lock), and then
#         completes
#      5. an orphan (parent not in the doc) is re-attached too
#      6. an unknown doc is refused, nothing written
#      7. CONTROL the renumber step neutered: the check after the commit
#         still finds the gap and exits 1, so case 2 can fail
#   SKIP part B when no docker / psql / cached postgres image.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# A ---------------------------------------------------------------------------
orc_stub 1 gcloud docker
for bad in "DOC_ID=" "DOC_ID=not-a-uuid" "DOC_ID=00000000-0000-0000-0000-000000000000 DRY_RUN=2"; do
  : >"$T/calls.log"
  # shellcheck disable=SC2086 # the case is VAR=value words
  out=$(SNIPPET=do_spl_doc_tree_repair in_orc $bad 2>&1); rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q FATAL <<<"$out" &&
    pass "A. '$bad' refused before any cloud call" || fail "A. '$bad' rc=$rc calls=$(cat "$T/calls.log") $out"
done

# B ---------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: part B, no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-doc-repair-pg-$$"
trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex'))" >/dev/null

# The functions under test, with the orc libs (spl_pg_env) and a plain do_log.
do_log() { echo "$*"; }
for f in "$PROJ_ROOT"/lib/bash/funcs/spl-cloud-cnf.func.sh "$PROJ_ROOT"/src/bash/run/spl-doc-tree-check.func.sh \
  "$PROJ_ROOT"/src/bash/run/spl-doc-tree-repair.func.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

uuid() { cat /proc/sys/kernel/random/uuid; }
# mkdoc: doc D in t1, root R, children A(1) B(2) C(3), A with child A1(1),
# committed through the triggers by the owner.
mkdoc() {
  D=$(uuid) R=$(uuid) A=$(uuid) B=$(uuid) C=$(uuid) A1=$(uuid)
  q "BEGIN; INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('$D', 't1', 'doc');
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES
 ('$R','t1','$D',NULL,1,'root'),('$A','t1','$D','$R',1,'A'),('$B','t1','$D','$R',2,'B'),
 ('$C','t1','$D','$R',3,'C'),('$A1','t1','$D','$A',1,'A1'); COMMIT;" >/dev/null || { fail "mkdoc"; exit 1; }
}
# plant <sql>: as the owner with the triggers and FKs off (replica role).
plant() { q "BEGIN; SET LOCAL session_replication_role = replica; $1 COMMIT;" >/dev/null; }
# mkbroken: mkdoc + a gap under A (A1 at ord 2) + the unreachable cycle
# C -> X -> C; CUT is its smallest id.
mkbroken() {
  mkdoc
  X=$(uuid)
  plant "UPDATE workspace_doc_item SET ord = 2 WHERE id = '$A1';
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES ('$X','t1','$D','$C',1,'X');
UPDATE workspace_doc_item SET parent_id = '$X', ord = 1 WHERE id = '$C';"
  CUT=$(printf '%s\n%s\n' "$C" "$X" | sort | sed -n 1p)
}
rev() { q "SELECT rev FROM workspace_doc WHERE id = '$1'"; }
repair() { spl_doc_tree_repair_exec "$RT_DSN" "$1" "$2" test-repair 2>&1; }

# --- 1. dry run ----------------------------------------------------------------------
mkbroken
rev0=$(rev "$D")
out=$(repair "$D" 1); rc=$?
after=$(spl_doc_tree_check_exec "$RT_DSN" operator "$D" 2>&1)
[[ $rc -eq 0 ]] && grep -qx "renumbered=1 reattached=1 ids=$CUT" <<<"$out" && grep -qx 'violations=0 docs=1 items=6' <<<"$out" &&
  grep -qx 'violations=2 docs=1 items=6' <<<"$after" && [[ "$(rev "$D")" == "$rev0" ]] &&
  pass "1. dry run: renumbered=1 reattached=1 ids=<cut>, in-tx check clean, nothing committed" || fail "1. rc=$rc $out // after: $after"

# --- 2. DRY_RUN=0 ----------------------------------------------------------------------
case2() {
  local out rc=0 last log
  out=$(repair "$D" 0) || rc=$?
  last=$(q "SET app.rls_scope = 'operator'; SELECT id FROM workspace_doc_item WHERE doc_id = '$D' AND parent_id = '$R' ORDER BY ord DESC LIMIT 1" | tail -1)
  log=$(q "SELECT op->>'kind', op->>'renumbered', op->'reattached'->>0, actor FROM workspace_doc_rev_log WHERE doc_id = '$D' AND rev = $((rev0 + 1))")
  [[ $rc -eq 0 ]] && grep -qx "renumbered=1 reattached=1 ids=$CUT" <<<"$out" && grep -qx 'violations=0 docs=1 items=6' <<<"$out" &&
    [[ "$last" == "$CUT" && "$(rev "$D")" == "$((rev0 + 1))" && "$log" == "repair|1|$CUT|test-repair" ]] ||
    { echo "rc=$rc last=$last rev=$(rev "$D") log=$log $out"; return 1; }
  echo "$out"
}
if out=$(case2); then pass "2. DRY_RUN=0: renumbered=1 reattached=1 ids=$CUT, check after: violations=0; rev+1, repair log entry"
  grep -E '^(renumbered|violations)=' <<<"$out" | sed 's/^/    /'
else fail "2. $out"; fi

# --- 3. again, clean -------------------------------------------------------------------
rev1=$(rev "$D")
out=$(repair "$D" 0); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'renumbered=0 reattached=0 ids=-' <<<"$out" && [[ "$(rev "$D")" == "$rev1" ]] &&
  pass "3. clean doc: renumbered=0 reattached=0, no rev bump" || fail "3. rc=$rc rev=$(rev "$D") $out"

# --- 4. the doc lock ---------------------------------------------------------------------
mkbroken
PGAPPNAME=doc-holder PGPASSWORD=spool psql -X -q -At "$OWNER_DSN" \
  -c "BEGIN; SELECT 1 FROM workspace_doc WHERE id = '$D' FOR UPDATE; SELECT pg_sleep(4); COMMIT;" >/dev/null 2>&1 &
holder=$!
for _ in $(seq 1 40); do
  [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'doc-holder' AND wait_event = 'PgSleep'")" == 1 ]] && break; sleep 0.1
done
PGAPPNAME=doc-repair spl_doc_tree_repair_exec "$RT_DSN" "$D" 0 test-repair >"$T/lock.out" 2>&1 &
rep=$!
waited=0
for _ in $(seq 1 30); do
  [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'doc-repair' AND wait_event_type = 'Lock'")" == 1 ]] && { waited=1; break; }
  sleep 0.1
done
wait "$holder"; wait "$rep"; rc=$?
[[ $waited == 1 && $rc -eq 0 ]] && grep -qx "renumbered=1 reattached=1 ids=$CUT" "$T/lock.out" &&
  pass "4. the repair waits on the doc lock held elsewhere, then completes" || fail "4. waited=$waited rc=$rc $(cat "$T/lock.out")"

# --- 5. an orphan ------------------------------------------------------------------------
mkdoc
plant "UPDATE workspace_doc_item SET parent_id = '$(uuid)' WHERE id = '$A1';"
out=$(repair "$D" 0); rc=$?
[[ $rc -eq 0 ]] && grep -qx "renumbered=0 reattached=1 ids=$A1" <<<"$out" && grep -qx 'violations=0 docs=1 items=5' <<<"$out" &&
  pass "5. an orphan is re-attached at the end of the root" || fail "5. rc=$rc $out"

# --- 6. unknown doc --------------------------------------------------------------------
n0=$(q "SELECT count(*) FROM workspace_doc_rev_log")
out=$(repair "$(uuid)" 0); rc=$?
[[ $rc -ne 0 ]] && grep -q 'not found under the operator scope' <<<"$out" && [[ "$(q "SELECT count(*) FROM workspace_doc_rev_log")" == "$n0" ]] &&
  pass "6. an unknown doc is refused, nothing written" || fail "6. rc=$rc $out"

# --- 7. CONTROL the renumber step neutered ---------------------------------------------
eval "$(declare -f spl_doc_tree_repair_sql | sed '1s/spl_doc_tree_repair_sql/_repair_sql_real/')"
neuter='s/AND i.ord <> n.k$/AND false/'
# shellcheck disable=SC2329 # called by spl_doc_tree_repair_exec
spl_doc_tree_repair_sql() { _repair_sql_real | sed "$neuter"; }
[[ "$(spl_doc_tree_repair_sql)" != "$(_repair_sql_real)" ]] || fail "7. CONTROL: the neuter matched nothing"
mkbroken
rev0=$(rev "$D")
if out=$(case2); then fail "7. CONTROL renumber neutered and case 2 still passes: $out"
else pass "7. CONTROL renumber neutered: case 2 fails ($(grep -oE 'violations=[0-9]+' <<<"$out" | tail -1))"; fi

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
