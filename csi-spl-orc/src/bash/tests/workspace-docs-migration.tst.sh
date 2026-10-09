#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: rdb 0157_workspace_docs.sql (spec 113 T001, test 9c) against a REAL
#          throwaway Postgres with every rdb migration, written by the
#          RUNTIME login (non-owner, so FORCE RLS binds) in a tenant scope.
#          SKIP when no docker / psql / cached postgres image.
#   1. refused, each naming its constraint or trigger: a gap (insert, a
#      delete that leaves it under OLD.parent_id, a move), an overlap, a
#      cycle, a second root, a doc without a root, a root delete, a doc_id
#      change, a cross-tenant doc_id and parent_id, a gap written after an
#      IMMEDIATE check in the same transaction; the rev log refuses UPDATE
#      and DELETE to the runtime login
#   2. committed: deleting a last child, insert-first with a one-statement
#      shift, a move with its shifts, a subtree delete with its shift
#   3. the race (spec 3.2, seat 5): tx1 deletes ord 3 of 3 and runs the check
#      (holding the doc lock), tx2 skips the lock, appends at count(*)+1 and
#      commits while tx1 sleeps; tx1 commits. tx2 waits on the lock, then is
#      refused at commit (I4 gap), 3 of 3 runs
#   CONTROL: with the two triggers dropped, every trigger-refused write of 1
#      commits and the race commits the gap 1,2,4
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no docker / psql / cached $PG_IMAGE image"
  echo "ALL PASS"; exit 0
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-wsdoc-pg-$$"
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
for t in t1 t2; do
  q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null
done

uuid() { cat /proc/sys/kernel/random/uuid; }
# tx <tenant> <sql> [app name]: ONE transaction as the runtime login in the
# tenant's scope; prints psql's output, exits non-zero on any error (the
# deferred triggers fire at the COMMIT).
tx() {
  printf "BEGIN;\nSET LOCAL app.tenant_id = '%s';\n%s\nCOMMIT;\n" "$1" "$2" |
    PGAPPNAME="${3:-wsdoc-test}" PGPASSWORD=rt psql -X -q -v ON_ERROR_STOP=1 -At "$RT_DSN" -f - 2>&1
}
# mkdoc <tenant> [root-only]: a doc D with root R and children A(1) B(2) C(3),
# A with child A1(1); root-only: D and R alone.
mkdoc() {
  D=$(uuid) R=$(uuid) A=$(uuid) B=$(uuid) C=$(uuid) A1=$(uuid)
  local items="('$R','$1','$D',NULL,1,'root')"
  [[ "${2:-}" != root-only ]] &&
    items+=",('$A','$1','$D','$R',1,'A'),('$B','$1','$D','$R',2,'B'),('$C','$1','$D','$R',3,'C'),('$A1','$1','$D','$A',1,'A1')"
  tx "$1" "INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('$D', '$1', 'doc');
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES $items;" >/dev/null ||
    { fail "mkdoc $1"; exit 1; }
}
# children <doc> <parent>: the parent's children's ords, as the operator
children() {
  q "SET app.rls_scope = 'operator'; SELECT string_agg(ord::text, ',' ORDER BY ord) FROM workspace_doc_item WHERE doc_id = '$1' AND parent_id = '$2'" | tail -1
}
# refused <label> <name> <sql>: rc != 0 and the error names <name>
refused() {
  local out rc=0
  out="$(tx t1 "$3")" || rc=$?
  if [[ $rc -ne 0 ]] && grep -q "$2" <<<"$out"; then
    pass "$1 refused: $2"
    echo "    $(grep -m1 'ERROR' <<<"$out")"
  else
    fail "$1: want refused by $2, rc=$rc $out"
  fi
}
committed() {
  local out rc=0
  out="$(tx t1 "$2")" || rc=$?
  [[ $rc -eq 0 ]] && pass "$1 committed" || fail "$1: want commit, rc=$rc $out"
}

# The trigger-refused writes of section 1: each on a fresh doc. <mode> is
# refused (triggers in place) or committed (CONTROL, triggers dropped).
trigger_cases() {
  local mode="$1" D2 R2 Dn
  mkdoc t1
  if [[ $mode == refused ]]; then
    refused "gap (insert at ord 5)" workspace_doc_item_tree \
      "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', '$R', 5);"
  else committed "CONTROL gap (insert at ord 5)" \
      "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', '$R', 5);"; fi
  mkdoc t1
  if [[ $mode == refused ]]; then
    refused "gap under OLD.parent_id (delete ord 2 of 3)" workspace_doc_item_tree "DELETE FROM workspace_doc_item WHERE id = '$B';"
  else committed "CONTROL gap under OLD.parent_id (delete ord 2 of 3)" "DELETE FROM workspace_doc_item WHERE id = '$B';"; fi
  mkdoc t1
  if [[ $mode == refused ]]; then
    refused "gap under OLD.parent_id (move ord 2 under A)" workspace_doc_item_tree \
      "UPDATE workspace_doc_item SET parent_id = '$A', ord = 2 WHERE id = '$B';"
  else committed "CONTROL gap under OLD.parent_id (move ord 2 under A)" \
      "UPDATE workspace_doc_item SET parent_id = '$A', ord = 2 WHERE id = '$B';"; fi
  mkdoc t1
  local cyc="UPDATE workspace_doc_item SET parent_id = '$A1', ord = 1 WHERE id = '$A';
UPDATE workspace_doc_item SET ord = ord - 1 WHERE doc_id = '$D' AND parent_id = '$R';"
  if [[ $mode == refused ]]; then refused "cycle (A under its own child A1)" 'workspace_doc_item_tree: I3 cycle' "$cyc"
  else committed "CONTROL cycle (A under its own child A1)" "$cyc"; fi
  Dn=$(uuid)
  if [[ $mode == refused ]]; then
    refused "doc without a root" workspace_doc_root_required "INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('$Dn', 't1', 'no root');"
  else committed "CONTROL doc without a root" "INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('$Dn', 't1', 'no root');"; fi
  mkdoc t1 root-only
  if [[ $mode == refused ]]; then refused "root delete (doc kept)" 'workspace_doc_item_tree: I1' "DELETE FROM workspace_doc_item WHERE id = '$R';"
  else committed "CONTROL root delete (doc kept)" "DELETE FROM workspace_doc_item WHERE id = '$R';"; fi
  mkdoc t1; D2=$D R2=$R
  mkdoc t1
  local mv="UPDATE workspace_doc_item SET doc_id = '$D2', parent_id = '$R2', ord = 4 WHERE id = '$A1';"
  if [[ $mode == refused ]]; then refused "doc_id change" 'workspace_doc_item_tree: doc_id change refused' "$mv"
  else committed "CONTROL doc_id change" "$mv"; fi
  mkdoc t1
  local late="UPDATE workspace_doc_item SET ord = 4 WHERE id = '$C';
UPDATE workspace_doc_item SET ord = 3 WHERE id = '$C';
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
DELETE FROM workspace_doc_item WHERE id = '$B';"
  if [[ $mode == refused ]]; then refused "gap written after an IMMEDIATE check in the same tx" workspace_doc_item_tree "$late"
  else committed "CONTROL gap written after an IMMEDIATE check in the same tx" "$late"; fi
}

# race <mode> <run>: seat 5's tx1/tx2 repro. tx1 runs the check (taking the
# doc lock) and sleeps; tx2 never takes the lock and appends at count(*)+1.
race() {
  local mode="$1" n="$2" out2 rc2=0 waited=0
  mkdoc t1
  tx t1 "DELETE FROM workspace_doc_item WHERE id = '$C';
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_sleep(4);" wsdoc-tx1 >"$T/tx1" 2>&1 &
  local p1=$!
  for _ in $(seq 1 40); do
    [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'wsdoc-tx1' AND query LIKE '%pg_sleep%' AND state = 'active'")" == 1 ]] && break
    sleep 0.1
  done
  tx t1 "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord)
SELECT 't1', '$D', '$R', count(*) + 1 FROM workspace_doc_item WHERE doc_id = '$D' AND parent_id = '$R';" wsdoc-tx2 >"$T/tx2" 2>&1 &
  local p2=$!
  for _ in $(seq 1 30); do
    [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'wsdoc-tx2' AND wait_event_type = 'Lock'")" == 1 ]] && { waited=1; break; }
    sleep 0.1
  done
  wait "$p1"; local rc1=$?
  wait "$p2" || rc2=$?
  out2="$(cat "$T/tx2")"
  local final; final="$(children "$D" "$R")"
  echo "    race run $n: tx1 rc=$rc1, tx2 lock_wait=$waited rc=$rc2, children of root = $final"
  if [[ $mode == refused ]]; then
    [[ $rc1 -eq 0 && $waited -eq 1 && $rc2 -ne 0 && "$final" == 1,2 ]] && grep -q 'workspace_doc_item_tree: I4 gap' <<<"$out2" &&
      { pass "race $n: the lock-skipping writer is refused at commit: workspace_doc_item_tree"; echo "    $(grep -m1 ERROR <<<"$out2")"; } ||
      fail "race $n: rc1=$rc1 waited=$waited rc2=$rc2 final=$final $out2 $(cat "$T/tx1")"
  else
    [[ $rc1 -eq 0 && $rc2 -eq 0 && "$final" == 1,2,4 ]] &&
      pass "CONTROL race $n: with the trigger dropped both commit, children = 1,2,4" ||
      fail "CONTROL race $n: rc1=$rc1 rc2=$rc2 final=$final $out2"
  fi
}

echo "--- 1. refused"
trigger_cases refused
mkdoc t1
refused "overlap (a second ord 2)" workspace_doc_item_sibling_ord \
  "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', '$R', 2);"
refused "ord 0" workspace_doc_item_ord_min \
  "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', '$R', 0);"
refused "second root" workspace_doc_item_one_root \
  "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', NULL, 1);"
refused "root at ord 2" workspace_doc_item_root_ord \
  "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', NULL, 2);"
T1D=$D
mkdoc t2
refused "cross-tenant doc_id (t1 item in t2's doc)" workspace_doc_item_doc_fk \
  "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', '$R', 4);"
refused "cross-tenant parent_id (t1 doc, t2's item as parent)" workspace_doc_item_parent_fk \
  "INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$T1D', '$A', 1);"
seen="$(tx t1 "SELECT id FROM workspace_doc WHERE id = '$D' FOR UPDATE;" | grep -c '^[0-9a-f-]\{36\}$')"
[[ "$seen" == 0 ]] && pass "t1 scope: FOR UPDATE on t2's doc returns 0 rows" || fail "t1 FOR UPDATE on t2: $seen"
seen="$(tx t1 "SELECT id FROM workspace_doc WHERE id = '$T1D' FOR UPDATE;" | grep -c '^[0-9a-f-]\{36\}$')"
[[ "$seen" == 1 ]] && pass "CONTROL t1 scope: FOR UPDATE on its own doc returns 1 row" || fail "t1 FOR UPDATE own: $seen"
committed "rev log append" "INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor) VALUES ('t1', '$T1D', 1, '{\"kind\":\"add\"}', 'test');"
refused "rev log UPDATE by the runtime login" 'permission denied' "UPDATE workspace_doc_rev_log SET actor = 'x';"
refused "rev log DELETE by the runtime login" 'permission denied' "DELETE FROM workspace_doc_rev_log;"

echo "--- 2. committed"
mkdoc t1
committed "delete a last child (A1, A keeps 0 children)" "DELETE FROM workspace_doc_item WHERE id = '$A1';"
[[ "$(children "$D" "$A")" == "" && "$(children "$D" "$R")" == 1,2,3 ]] && pass "  tree after: A has none, root 1,2,3" || fail "  tree after last-child delete"
committed "insert first with a one-statement shift" "UPDATE workspace_doc_item SET ord = ord + 1 WHERE doc_id = '$D' AND parent_id = '$R';
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('t1', '$D', '$R', 1);"
[[ "$(children "$D" "$R")" == 1,2,3,4 ]] && pass "  root 1,2,3,4" || fail "  root after insert-first: $(children "$D" "$R")"
mkdoc t1
committed "move B under A at ord 2, C shifts up" "UPDATE workspace_doc_item SET parent_id = '$A', ord = 2 WHERE id = '$B';
UPDATE workspace_doc_item SET ord = ord - 1 WHERE doc_id = '$D' AND parent_id = '$R' AND ord > 2;"
[[ "$(children "$D" "$R")" == 1,2 && "$(children "$D" "$A")" == 1,2 ]] && pass "  root 1,2; A 1,2" || fail "  tree after move"
mkdoc t1
committed "delete subtree A (A1, A) and shift B, C" "DELETE FROM workspace_doc_item WHERE id IN ('$A1', '$A');
UPDATE workspace_doc_item SET ord = ord - 1 WHERE doc_id = '$D' AND parent_id = '$R';"
[[ "$(children "$D" "$R")" == 1,2 ]] && pass "  root 1,2" || fail "  tree after subtree delete"
mkdoc t1
committed "delete the doc (items and log cascade)" "DELETE FROM workspace_doc WHERE id = '$D';"

echo "--- 3. the race, 3 runs"
for i in 1 2 3; do race refused "$i"; done

echo "--- CONTROL: the two triggers dropped"
q "DROP TRIGGER workspace_doc_item_tree ON workspace_doc_item; DROP TRIGGER workspace_doc_root_required ON workspace_doc" >/dev/null
trigger_cases committed
race committed 1

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
