#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: rdb 0165_workspace_doc_node.sql (spec 120 v1.0, section 9) against
#          a REAL throwaway Postgres with every rdb migration, written by the
#          RUNTIME login (non-owner, so FORCE RLS binds) in a tenant scope.
#          SKIP when no docker / psql / cached postgres image.
#   T1/T2b every section 5 op (create, edit, move right, move left, move a
#          folder with children both ways, no-op move, delete a document,
#          delete an empty folder, recursive delete) with nodes on both
#          sides, exact bounds asserted after each; a document delete with
#          no gap close is refused at commit; the recursive delete
#          removes the documents, their items and rev log; a workspace
#          delete cascades. CONTROL: the two-statement create fails _leaf,
#          the negate-step move fails _bounds
#   T2     planted breaks refused at commit by workspace_doc_node_ns: a gap,
#          an off-by-one shift, crossing intervals, a parent_id that
#          disagrees, depth 33 (32 commits). CONTROL: with _ns dropped each
#          commits
#   T3     a document of width 4 (_leaf), a node under a document (parent
#          kind CHECK, parent FK), a kind change (_fixed)
#   T4     10,000 documents then the 10,001st: workspace_doc_node_cap;
#          delete one and the next create commits; the same for 1,000 folders
#   T5     cap race at 9,999: two concurrent creates (store lock, and one
#          that skips it), exactly one commits, counter = count(*) = 10,000.
#          CONTROL: with the cap CHECK dropped both commit (10,001)
#   T6     two concurrent moves, the second skipping the store lock: it waits
#          at the commit check's root lock and the tree is the two moves.
#          CONTROL: with _ns dropped it never waits
#   T7     RLS as the runtime login: 0 of b's nodes; b's parent or doc id
#          refused by the FKs; b's folder not found; an unfiltered shift in a
#          leaves b's bounds (md5); unscoped 0 rows. CONTROL: an FK without
#          the tenant column lets the cross-tenant row through
#   T9     the migration on existing rows: bounds 1..2n in created_at order,
#          one node per document, doc_count; a workspace at 10,001 refused
#          by id with nothing left behind. CONTROL: at 10,000 it migrates
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
SQL_DIR="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub"
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
PG_CTR="spl-wsnode-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
dsn() { echo "postgres://$1@127.0.0.1:$PGPORT/${2:-spool_hub}?sslmode=disable"; }
OWNER_DSN="$(dsn spool:spool)"
RT_DSN="$(dsn spool_rt:rt)"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$SQL_DIR" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "${2:-$OWNER_DSN}" -c "$1"; }
qop() { q "SET app.rls_scope = 'operator'; $1" "${2:-$OWNER_DSN}" | tail -n +1; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$SQL_DIR/../spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
mktenant() { q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$1', decode(repeat('ab', 32), 'hex'))" "${2:-$OWNER_DSN}" >/dev/null; }

uuid() { cat /proc/sys/kernel/random/uuid; }
# tx <tenant> <sql> [app name] [-v k=v ...]: ONE transaction as the runtime
# login in the tenant's scope; psql variable :tenant is set. Prints psql's
# output, exits non-zero on any error (the deferred checks fire at COMMIT).
tx() {
  local ten="$1" sql="$2" app="${3:-wsnode-test}"; shift 3 2>/dev/null || shift $#
  printf "BEGIN;\nSET LOCAL app.tenant_id = '%s';\n%s\nCOMMIT;\n" "$ten" "$sql" |
    PGAPPNAME="$app" PGPASSWORD=rt psql -X -q -v ON_ERROR_STOP=1 -At "$RT_DSN" -v tenant="$ten" "$@" -f - 2>&1
}

# --- The section 5 ops, as the store will run them (pgx binds there, psql
# variables here). Each is one transaction: lock the root, read the bounds,
# then ONE UPDATE per shift.
SQL_LOCK="SELECT id AS root FROM workspace_doc_node WHERE tenant_id = :'tenant' AND kind = 'root' FOR UPDATE \\gset"
SQL_ROOT="INSERT INTO workspace_doc_node (tenant_id, lft, rgt, kind) VALUES (:'tenant', 1, 2, 'root')
  ON CONFLICT (tenant_id) WHERE kind = 'root' DO NOTHING;"
# create, append as P's last child: shift, then insert at (r, r + 1).
SQL_CREATE_SHIFT="SELECT rgt AS r, kind AS pk FROM workspace_doc_node WHERE tenant_id = :'tenant' AND id = :'p' \\gset
UPDATE workspace_doc_node SET lft = lft + CASE WHEN lft > :r THEN 2 ELSE 0 END, rgt = rgt + 2
 WHERE tenant_id = :'tenant' AND rgt >= :r;"
sql_create_folder() {
  echo "$SQL_ROOT
$SQL_LOCK
$SQL_CREATE_SHIFT
INSERT INTO workspace_doc_node (id, tenant_id, lft, rgt, parent_id, parent_kind, kind, name, title, description)
VALUES (:'x', :'tenant', :r, :r + 1, :'p', :'pk', 'folder', :'name', 'title of ' || :'name', 'about ' || :'name');"
}
sql_create_doc() {
  echo "$SQL_ROOT
$SQL_LOCK
INSERT INTO workspace_doc (id, tenant_id, title) VALUES (:'d', :'tenant', :'name');
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES (:'tenant', :'d', NULL, 1);
$SQL_CREATE_SHIFT
INSERT INTO workspace_doc_node (id, tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id)
VALUES (:'x', :'tenant', :r, :r + 1, :'p', :'pk', 'doc', :'d');"
}
# move X under P as last child: refuse into its own subtree, no-op when P is
# already the parent, else ONE UPDATE, right (r > X.rgt) or left (r < X.lft).
# <lock> = 0 skips the store lock (T6's lock-skipping writer).
sql_move() {
  local lock="${1:-1}"
  [[ $lock == 1 ]] && echo "$SQL_LOCK"
  echo "SELECT lft AS xl, rgt AS xr, rgt - lft + 1 AS w, parent_id AS xp FROM workspace_doc_node WHERE tenant_id = :'tenant' AND id = :'x' \\gset
SELECT lft AS pl, rgt AS r, kind AS pk FROM workspace_doc_node WHERE tenant_id = :'tenant' AND id = :'p' \\gset
SELECT (:pl BETWEEN :xl AND :xr) AS own, (:'xp' = :'p') AS noop, (:r > :xr) AS right_move \\gset
\\if :own
DO \$\$ BEGIN RAISE EXCEPTION 'move_into_own_subtree'; END \$\$;
\\elif :noop
SELECT 'noop';
\\elif :right_move
UPDATE workspace_doc_node SET
  lft = CASE WHEN lft BETWEEN :xl AND :xr THEN lft + (:r - :xr - 1) WHEN lft > :xr AND lft < :r THEN lft - :w ELSE lft END,
  rgt = CASE WHEN rgt BETWEEN :xl AND :xr THEN rgt + (:r - :xr - 1) WHEN rgt > :xr AND rgt < :r THEN rgt - :w ELSE rgt END,
  parent_id = CASE WHEN id = :'x' THEN :'p'::uuid ELSE parent_id END,
  parent_kind = CASE WHEN id = :'x' THEN :'pk' ELSE parent_kind END
 WHERE tenant_id = :'tenant' AND (lft BETWEEN :xl AND :r - 1 OR rgt BETWEEN :xl AND :r - 1);
\\else
UPDATE workspace_doc_node SET
  lft = CASE WHEN lft BETWEEN :xl AND :xr THEN lft - (:xl - :r) WHEN lft >= :r AND lft < :xl THEN lft + :w ELSE lft END,
  rgt = CASE WHEN rgt BETWEEN :xl AND :xr THEN rgt - (:xl - :r) WHEN rgt >= :r AND rgt < :xl THEN rgt + :w ELSE rgt END,
  parent_id = CASE WHEN id = :'x' THEN :'p'::uuid ELSE parent_id END,
  parent_kind = CASE WHEN id = :'x' THEN :'pk' ELSE parent_kind END
 WHERE tenant_id = :'tenant' AND (lft BETWEEN :r AND :xr OR rgt BETWEEN :r AND :xr);
\\endif"
}
# delete document D: the workspace_doc row (items, rev log and node
# cascade), then close the gap of 2.
SQL_DELETE_DOC="$SQL_LOCK
SELECT rgt AS xr FROM workspace_doc_node WHERE tenant_id = :'tenant' AND doc_id = :'d' \\gset
DELETE FROM workspace_doc WHERE tenant_id = :'tenant' AND id = :'d';
UPDATE workspace_doc_node SET lft = lft - CASE WHEN lft > :xr THEN 2 ELSE 0 END, rgt = rgt - 2
 WHERE tenant_id = :'tenant' AND rgt > :xr;"
# delete folder X (empty, or ?recursive=1): its documents' workspace_doc
# rows, then the subtree's nodes in ONE statement, then the gap of w.
SQL_DELETE_FOLDER="$SQL_LOCK
SELECT lft AS xl, rgt AS xr, rgt - lft + 1 AS w FROM workspace_doc_node WHERE tenant_id = :'tenant' AND id = :'x' AND kind = 'folder' \\gset
DELETE FROM workspace_doc WHERE tenant_id = :'tenant' AND id IN (
  SELECT doc_id FROM workspace_doc_node WHERE tenant_id = :'tenant' AND kind = 'doc' AND lft BETWEEN :xl AND :xr);
DELETE FROM workspace_doc_node WHERE tenant_id = :'tenant' AND lft BETWEEN :xl AND :xr;
UPDATE workspace_doc_node SET lft = lft - CASE WHEN lft > :xr THEN :w ELSE 0 END, rgt = rgt - :w
 WHERE tenant_id = :'tenant' AND rgt > :xr;"
SQL_EDIT_FOLDER="UPDATE workspace_doc_node SET name = :'name', title = :'title', description = :'descr', updated_at = now()
 WHERE tenant_id = :'tenant' AND id = :'x' AND kind = 'folder';"

declare -A ID DOC
# Node handles: ID[<tenant>/<label>] is the node id, DOC[...] the doc id.
mkroot() { tx "$1" "$SQL_ROOT" >/dev/null || { fail "mkroot $1"; exit 1; }
  ID[$1/R]="$(qop "SELECT id FROM workspace_doc_node WHERE tenant_id = '$1' AND kind = 'root'" | tail -1)"; }
parent_of() { echo "${ID[$1/${2:-R}]}"; }
# op <tenant> folder|doc <label> [parent label]; op_* print psql's output.
mk() {
  local ten="$1" kind="$2" lab="$3" par="${4:-R}" x
  x=$(uuid); ID[$ten/$lab]=$x
  if [[ $kind == folder ]]; then
    tx "$ten" "$(sql_create_folder)" t -v x="$x" -v p="$(parent_of "$ten" "$par")" -v name="$lab"
  else
    DOC[$ten/$lab]=$(uuid)
    tx "$ten" "$(sql_create_doc)" t -v x="$x" -v d="${DOC[$ten/$lab]}" -v p="$(parent_of "$ten" "$par")" -v name="$lab"
  fi
}
mv_() { tx "$1" "$(sql_move "${4:-1}")" "${5:-t}" -v x="${ID[$1/$2]}" -v p="${ID[$1/$3]}"; }
rm_doc() { tx "$1" "$SQL_DELETE_DOC" t -v d="${DOC[$1/$2]}"; }
rm_folder() { tx "$1" "$SQL_DELETE_FOLDER" t -v x="${ID[$1/$2]}"; }
# tree <tenant>: label:lft,rgt in lft order (R = the root, a folder its name,
# a document its title), read as the operator.
tree() {
  qop "SELECT string_agg(CASE n.kind WHEN 'root' THEN 'R' WHEN 'folder' THEN n.name ELSE d.title END
         || ':' || n.lft || ',' || n.rgt, ' ' ORDER BY n.lft)
         FROM workspace_doc_node n LEFT JOIN workspace_doc d ON d.id = n.doc_id WHERE n.tenant_id = '$1'" | tail -1
}
counters() { qop "SELECT doc_count || '/' || folder_count FROM workspace_doc_node WHERE tenant_id = '$1' AND kind = 'root'" | tail -1; }
want_tree() { local got; got="$(tree "$1")"; [[ "$got" == "$2" ]] && pass "  $3: $got" || fail "  $3: want '$2' got '$got'"; }
# ok / refused / committed run the command in THIS shell (mk records ids).
ok() { local out rc=0; "${@:2}" >"$T/out" 2>&1 || rc=$?; out="$(cat "$T/out")"; [[ $rc -eq 0 ]] && pass "$1 committed" || fail "$1: want commit, rc=$rc $out"; }
refused() {
  local lab="$1" name="$2" out rc=0; shift 2
  "$@" >"$T/out" 2>&1 || rc=$?; out="$(cat "$T/out")"
  if [[ $rc -ne 0 ]] && grep -qE "$name" <<<"$out"; then
    pass "$lab refused: $name"; echo "    $(grep -m1 'ERROR' <<<"$out")"
  else
    fail "$lab: want refused by $name, rc=$rc $out"
  fi
}
committed() { local lab="$1" out rc=0; shift; "$@" >"$T/out" 2>&1 || rc=$?; out="$(cat "$T/out")"
  [[ $rc -eq 0 ]] && pass "$lab committed" || fail "$lab: want commit, rc=$rc $out"; }

echo "--- T1/T2b. every section 5 op on the real DDL"
W=w1; mktenant $W; mkroot $W
ok "create folder A" mk $W folder A
ok "create folder B" mk $W folder B
ok "create doc d1 under A (B to its right)" mk $W doc d1 A
ok "create doc d2 under B" mk $W doc d2 B
ok "create doc d3 under the root" mk $W doc d3
want_tree $W "R:1,12 A:2,5 d1:3,4 B:6,9 d2:7,8 d3:10,11" "after the creates"
[[ "$(counters $W)" == 3/2 ]] && pass "  counters 3 docs / 2 folders" || fail "  counters: $(counters $W)"
ok "edit folder A (name, title, description)" tx $W "$SQL_EDIT_FOLDER" t -v x="${ID[$W/A]}" -v name=A -v title="A heading" -v descr="plain text"
want_tree $W "R:1,12 A:2,5 d1:3,4 B:6,9 d2:7,8 d3:10,11" "edit moves no bound"
ok "move right: d1 under B" mv_ $W d1 B
want_tree $W "R:1,12 A:2,3 B:4,9 d2:5,6 d1:7,8 d3:10,11" "after move right"
ok "move left: d3 under A" mv_ $W d3 A
want_tree $W "R:1,12 A:2,5 d3:3,4 B:6,11 d2:7,8 d1:9,10" "after move left"
ok "move a folder with children left: B under A" mv_ $W B A
want_tree $W "R:1,12 A:2,11 d3:3,4 B:5,10 d2:6,7 d1:8,9" "after folder move left"
ok "create folder C under the root" mk $W folder C
ok "move a folder with children right: B under C" mv_ $W B C
want_tree $W "R:1,14 A:2,5 d3:3,4 C:6,13 B:7,12 d2:8,9 d1:10,11" "after folder move right"
ok "no-op move: B under C again" mv_ $W B C
want_tree $W "R:1,14 A:2,5 d3:3,4 C:6,13 B:7,12 d2:8,9 d1:10,11" "no-op leaves the tree"
refused "move C into its own subtree (under B)" move_into_own_subtree mv_ $W C B
ok "delete doc d2" rm_doc $W d2
want_tree $W "R:1,12 A:2,5 d3:3,4 C:6,11 B:7,10 d1:8,9" "after doc delete"
ok "create folder E under A" mk $W folder E A
ok "delete the empty folder E" rm_folder $W E
want_tree $W "R:1,12 A:2,5 d3:3,4 C:6,11 B:7,10 d1:8,9" "after empty-folder delete"
q "SET app.rls_scope = 'operator'; INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor) VALUES ('$W', '${DOC[$W/d1]}', 1, '{\"kind\":\"add\"}', 'test')" >/dev/null
sub_counts() { qop "SELECT (SELECT count(*) FROM workspace_doc WHERE tenant_id = '$W') || '/' ||
  (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = '$W') || '/' ||
  (SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = '$W')" | tail -1; }
before="$(sub_counts)"
ok "recursive delete of C (B, d1 inside)" rm_folder $W C
after="$(sub_counts)"
want_tree $W "R:1,6 A:2,5 d3:3,4" "after recursive delete"
[[ "$before" == 2/2/1 && "$after" == 1/1/0 ]] && pass "  docs/items/rev log $before -> $after" || fail "  docs/items/rev log $before -> $after"
[[ "$(counters $W)" == 1/1 ]] && pass "  counters 1 doc / 1 folder" || fail "  counters: $(counters $W)"
ok "a workspace delete cascades its tree" q "SET app.rls_scope = 'operator'; DELETE FROM tenants WHERE tenant_id = '$W'"
[[ "$(qop "SELECT count(*) FROM workspace_doc_node WHERE tenant_id = '$W'" | tail -1)" == 0 ]] && pass "  0 nodes left" || fail "  nodes left"

echo "--- T2b CONTROL: the textbook forms against the immediate CHECKs"
W=w2; mktenant $W; mkroot $W; mk $W folder A >/dev/null; mk $W doc d A >/dev/null; mk $W doc e >/dev/null
want_tree $W "R:1,8 A:2,5 d:3,4 e:6,7" "control tree"
refused "a document delete without the gap close (today's DocDelete / purge)" workspace_doc_node_ns \
  tx $W "$SQL_LOCK
DELETE FROM workspace_doc WHERE tenant_id = :'tenant' AND id = '${DOC[$W/d]}';"
refused "two-statement create under A (rgt + 2 first)" workspace_doc_node_leaf tx $W "$SQL_LOCK
UPDATE workspace_doc_node SET rgt = rgt + 2 WHERE tenant_id = :'tenant' AND rgt >= 5;
UPDATE workspace_doc_node SET lft = lft + 2 WHERE tenant_id = :'tenant' AND lft > 5;"
refused "negate-step move of A" workspace_doc_node_bounds tx $W "$SQL_LOCK
UPDATE workspace_doc_node SET lft = -lft, rgt = -rgt WHERE tenant_id = :'tenant' AND lft BETWEEN 2 AND 5;"

echo "--- T2. planted breaks, refused at commit"
# t2tree <tenant>: R(1,8) A(2,5) d1(3,4) B(6,7), B a folder.
t2tree() { mktenant "$1"; mkroot "$1"; mk "$1" folder A >/dev/null; mk "$1" doc d1 A >/dev/null; mk "$1" folder B >/dev/null; }
crosstree() { mktenant "$1"; mkroot "$1"; mk "$1" folder P >/dev/null; mk "$1" folder Q >/dev/null; mk "$1" folder S >/dev/null; }
# chain <tenant> <n>: n folders nested under the root in one statement.
chain() {
  mktenant "$1"; mkroot "$1"
  tx "$1" "INSERT INTO workspace_doc_node (id, tenant_id, lft, rgt, parent_id, parent_kind, kind, name)
SELECT md5('$1/' || g)::uuid, :'tenant', g + 1, 2 * ($2 + 1) - g, CASE WHEN g = 1 THEN :'root'::uuid ELSE md5('$1/' || (g - 1))::uuid END,
       CASE WHEN g = 1 THEN 'root' ELSE 'folder' END, 'folder', 'f' || g FROM generate_series(1, $2) g;
UPDATE workspace_doc_node SET rgt = 2 * ($2 + 1) WHERE id = :'root';" t -v root="${ID[$1/R]}"
}
declare -A PLANT
PLANT[GAP]="UPDATE workspace_doc_node SET rgt = rgt + 2 WHERE tenant_id = :'tenant' AND kind = 'root';"
PLANT[OFF1]="UPDATE workspace_doc_node SET rgt = rgt + 2 WHERE tenant_id = :'tenant' AND kind = 'root';
UPDATE workspace_doc_node SET lft = lft + 1, rgt = rgt + 1 WHERE tenant_id = :'tenant' AND name = 'B';"
# crossing on R(1,8) P(2,3) Q(4,5) S(6,7): P(2,5) Q(3,6) S(4,7), every
# width odd and every bound once, so only the ordered pass can see it.
PLANT[CROSS]="UPDATE workspace_doc_node SET lft = CASE name WHEN 'Q' THEN 3 WHEN 'S' THEN 4 ELSE lft END,
  rgt = CASE name WHEN 'P' THEN 5 WHEN 'Q' THEN 6 ELSE rgt END
 WHERE tenant_id = :'tenant' AND name IN ('P', 'Q', 'S');"
PLANT[PARENT]="UPDATE workspace_doc_node SET parent_id = :'root', parent_kind = 'root' WHERE tenant_id = :'tenant' AND kind = 'doc';"
planted() {
  local mode="$1" n=0 c
  for c in GAP OFF1 CROSS PARENT; do
    n=$((n + 1))
    if [[ $c == CROSS ]]; then crosstree "p$mode$n"; else t2tree "p$mode$n"; fi
    local sql="$SQL_LOCK
${PLANT[$c]}"
    if [[ $mode == r ]]; then refused "planted $c" workspace_doc_node_ns tx "p$mode$n" "$sql"
    else committed "CONTROL planted $c" tx "p$mode$n" "$sql"; fi
  done
  if [[ $mode == r ]]; then
    refused "planted depth 33" 'workspace_doc_node_ns: .* deeper than 32' chain "p${mode}d33" 33
    committed "depth 32 (the cap)" chain "p${mode}d32" 32
  else committed "CONTROL planted depth 33" chain "p${mode}d33" 33; fi
}
planted r
refused "planted rgt - 1 (even width)" workspace_doc_node_bounds tx pr1 "UPDATE workspace_doc_node SET rgt = rgt - 1 WHERE tenant_id = :'tenant' AND name = 'A';"

echo "--- T3. leaf, width, kind"
W=w3; mktenant $W; mkroot $W; mk $W folder A >/dev/null; mk $W doc d A >/dev/null
DX=$(uuid)
leaf_sql="$SQL_LOCK
INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('$DX', :'tenant', 'wide');
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES (:'tenant', '$DX', NULL, 1);
UPDATE workspace_doc_node SET rgt = rgt + 4 WHERE tenant_id = :'tenant' AND kind = 'root';"
refused "a document of width 4 (D2)" workspace_doc_node_leaf tx $W "$leaf_sql
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id) VALUES (:'tenant', 6, 9, :'root', 'root', 'doc', '$DX');"
refused "a node under a document (parent_kind doc)" workspace_doc_node_parent_kind tx $W "$SQL_LOCK
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, name) VALUES (:'tenant', 4, 5, '${ID[$W/d]}', 'doc', 'folder', 'x');"
refused "a node under a document (claimed folder)" workspace_doc_node_parent_fk tx $W "$SQL_LOCK
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, name) VALUES (:'tenant', 4, 5, '${ID[$W/d]}', 'folder', 'folder', 'x');"
refused "a kind change" workspace_doc_node_fixed tx $W "UPDATE workspace_doc_node SET kind = 'doc', doc_id = '${DOC[$W/d]}', name = '', title = '', description = '' WHERE id = '${ID[$W/A]}';"
refused "a second root" workspace_doc_node_one_root tx $W "INSERT INTO workspace_doc_node (tenant_id, lft, rgt, kind) VALUES (:'tenant', 1, 100, 'root');"
refused "a folder name twice under one parent (case-insensitive)" workspace_doc_node_folder_name mk $W folder a

echo "--- T4. caps"
# seed_flat <tenant> <docs> <folders> [dsn]: a root with that many documents
# then folders flat under it, written by the owner under operator scope.
seed_flat() {
  q "BEGIN; SET LOCAL app.rls_scope = 'operator';
INSERT INTO workspace_doc (tenant_id, title, created_at) SELECT '$1', 'doc ' || g, now() + g * interval '1 ms' FROM generate_series(1, $2) g;
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) SELECT '$1', id, NULL, 1 FROM workspace_doc WHERE tenant_id = '$1';
$( [[ -n "${4:-}" ]] || echo "WITH k AS (SELECT id, row_number() OVER (ORDER BY created_at, id)::int AS i FROM workspace_doc WHERE tenant_id = '$1'),
r AS (INSERT INTO workspace_doc_node (tenant_id, lft, rgt, kind) VALUES ('$1', 1, 2 * ($2 + $3) + 2, 'root') RETURNING id)
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id, name)
SELECT '$1', 2 * i, 2 * i + 1, r.id, 'root', 'doc', k.id, '' FROM k, r
UNION ALL SELECT '$1', 2 * ($2 + g), 2 * ($2 + g) + 1, r.id, 'root', 'folder', NULL, 'f' || g FROM generate_series(1, $3) g, r;")
COMMIT;" "${4:-$OWNER_DSN}" >/dev/null
}
W=w4; mktenant $W; seed_flat $W 10000 0; ID[$W/R]="$(qop "SELECT id FROM workspace_doc_node WHERE tenant_id = '$W' AND kind = 'root'" | tail -1)"
[[ "$(counters $W)" == 10000/0 ]] && pass "  10,000 documents seeded, counter 10000" || fail "  seed: $(counters $W)"
refused "the 10,001st document" workspace_doc_node_cap mk $W doc over
DOC[$W/first]="$(qop "SELECT id FROM workspace_doc WHERE tenant_id = '$W' ORDER BY created_at LIMIT 1" | tail -1)"
ok "delete one document" rm_doc $W first
ok "the next create" mk $W doc again
[[ "$(counters $W)" == 10000/0 ]] && pass "  counter back at 10000" || fail "  counter: $(counters $W)"
W=w4f; mktenant $W; seed_flat $W 0 1000; ID[$W/R]="$(qop "SELECT id FROM workspace_doc_node WHERE tenant_id = '$W' AND kind = 'root'" | tail -1)"
[[ "$(counters $W)" == 0/1000 ]] && pass "  1,000 folders seeded" || fail "  seed: $(counters $W)"
refused "the 1,001st folder" workspace_doc_node_folder_cap mk $W folder over
ID[$W/f1]="$(qop "SELECT id FROM workspace_doc_node WHERE tenant_id = '$W' AND name = 'f1'" | tail -1)"
ok "delete one folder" rm_folder $W f1
ok "the next folder" mk $W folder again

echo "--- T5. the cap race at 9,999"
# race5 <tenant> <lock of tx2>: tx1 creates and sleeps before COMMIT; tx2
# creates meanwhile. Prints "rc1 rc2 counter count".
race5() {
  local ten="$1" x1 x2 d1 d2 p1 p2 rc1=0 rc2=0
  x1=$(uuid) x2=$(uuid) d1=$(uuid) d2=$(uuid)
  tx "$ten" "$(sql_create_doc)
SELECT pg_sleep(2);" race-tx1 -v x="$x1" -v d="$d1" -v p="${ID[$ten/R]}" -v name=r1 >"$T/r1" 2>&1 &
  p1=$!
  for _ in $(seq 1 40); do
    [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'race-tx1' AND query LIKE '%pg_sleep%'")" == 1 ]] && break
    sleep 0.1
  done
  local sql; sql="$(sql_create_doc)"; [[ $2 == 0 ]] && sql="${sql/"$SQL_LOCK"/}"
  tx "$ten" "$sql" race-tx2 -v x="$x2" -v d="$d2" -v p="${ID[$ten/R]}" -v name=r2 >"$T/r2" 2>&1 &
  p2=$!
  wait "$p1" || rc1=$?; wait "$p2" || rc2=$?
  echo "$rc1 $rc2 $(counters "$ten" | cut -d/ -f1) $(qop "SELECT count(*) FROM workspace_doc_node WHERE tenant_id = '$ten' AND kind = 'doc'" | tail -1)"
}
for v in 1 0; do
  W=w5l$v; mktenant $W; seed_flat $W 9999 0; ID[$W/R]="$(qop "SELECT id FROM workspace_doc_node WHERE tenant_id = '$W' AND kind = 'root'" | tail -1)"
  read -r rc1 rc2 cnt real <<<"$(race5 $W $v)"
  echo "    race (tx2 lock=$v): tx1 rc=$rc1 tx2 rc=$rc2 counter=$cnt count=$real"
  [[ $rc1 -eq 0 && $rc2 -ne 0 && $cnt == 10000 && $real == 10000 ]] && grep -q workspace_doc_node_cap "$T/r2" &&
    pass "T5 race (tx2 lock=$v): one commits, the other refused by workspace_doc_node_cap" ||
    fail "T5 race (tx2 lock=$v): $(cat "$T/r1" "$T/r2")"
done

echo "--- T6. the lock: a lock-skipping move waits at the commit check"
# t6tree: R A(a1) B C(c1) D; tx1 moves a1 under B, tx2 c1 under D: disjoint rows.
t6tree() { mktenant "$1"; mkroot "$1"; mk "$1" folder A >/dev/null; mk "$1" doc a1 A >/dev/null; mk "$1" folder B >/dev/null
  mk "$1" folder C >/dev/null; mk "$1" doc c1 C >/dev/null; mk "$1" folder D >/dev/null; }
race6() {
  local ten="$1" p1 p2 rc1=0 rc2=0 waited=0
  t6tree "$ten"
  tx "$ten" "$(sql_move 1)
SELECT pg_sleep(3);" lock-tx1 -v x="${ID[$ten/a1]}" -v p="${ID[$ten/B]}" >"$T/m1" 2>&1 &
  p1=$!
  for _ in $(seq 1 40); do
    [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'lock-tx1' AND query LIKE '%pg_sleep%'")" == 1 ]] && break
    sleep 0.1
  done
  tx "$ten" "$(sql_move 0)" lock-tx2 -v x="${ID[$ten/c1]}" -v p="${ID[$ten/D]}" >"$T/m2" 2>&1 &
  p2=$!
  for _ in $(seq 1 20); do
    [[ "$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'lock-tx2' AND wait_event_type = 'Lock'")" == 1 ]] && { waited=1; break; }
    sleep 0.1
  done
  wait "$p1" || rc1=$?; wait "$p2" || rc2=$?
  echo "$rc1 $rc2 $waited"
}
read -r rc1 rc2 waited <<<"$(race6 w6)"
echo "    tx1 rc=$rc1 tx2 rc=$rc2 tx2 lock_wait=$waited"
[[ $rc1 -eq 0 && $rc2 -eq 0 && $waited -eq 1 ]] && pass "T6 the lock-skipping move waited at the commit check" || fail "T6: $(cat "$T/m1" "$T/m2")"
want_tree w6 "R:1,14 A:2,3 B:4,7 a1:5,6 C:8,9 D:10,13 c1:11,12" "T6 both moves, a valid tree"

echo "--- T7. RLS and the tenant FKs, as the runtime login"
for t in ra rb; do mktenant $t; mkroot $t; mk $t folder F >/dev/null; mk $t doc d F >/dev/null; done
DOC[rb/bare]=$(uuid)
tx rb "INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('${DOC[rb/bare]}', 'rb', 'no node yet');
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ('rb', '${DOC[rb/bare]}', NULL, 1);" >/dev/null
seen="$(tx ra "SELECT count(*) FILTER (WHERE tenant_id = 'rb') || '/' || count(*) FROM workspace_doc_node;" | tail -1)"
[[ "$seen" == 0/3 ]] && pass "ra sees 0 of rb's nodes, 3 of its own" || fail "ra sees $seen"
refused "ra node under rb's folder" workspace_doc_node_parent_fk tx ra "$SQL_LOCK
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, name) VALUES ('ra', 6, 7, '${ID[rb/F]}', 'folder', 'folder', 'x');"
refused "ra node for rb's document" workspace_doc_node_doc_fk tx ra "$SQL_LOCK
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id) VALUES ('ra', 6, 7, :'root', 'root', 'doc', '${DOC[rb/bare]}');"
seen="$(tx ra "SELECT count(*) FROM workspace_doc_node WHERE id = '${ID[rb/F]}';" | tail -1)"
[[ "$seen" == 0 ]] && pass "ra's move into rb's folder finds no parent (404)" || fail "ra finds rb's folder: $seen"
bmd5() { qop "SELECT md5(string_agg(id::text || ':' || lft || ',' || rgt, ';' ORDER BY lft)) FROM workspace_doc_node WHERE tenant_id = 'rb'" | tail -1; }
b0="$(bmd5)"
ok "ra: a shift with no tenant predicate" tx ra "SELECT 1 FROM workspace_doc_node WHERE kind = 'root' FOR UPDATE;
UPDATE workspace_doc_node SET lft = lft + CASE WHEN lft > 6 THEN 2 ELSE 0 END, rgt = rgt + 2 WHERE rgt >= 6;
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, name) VALUES ('ra', 6, 7, '${ID[ra/R]}', 'root', 'folder', 'G');"
[[ -n "$b0" && "$(bmd5)" == "$b0" ]] && pass "  rb's bounds unchanged (md5 $b0)" || fail "  rb's bounds changed"
want_tree ra "R:1,8 F:2,5 d:3,4 G:6,7" "  ra's own tree shifted"
seen="$(printf "SELECT count(*) FROM workspace_doc_node;\n" | PGPASSWORD=rt psql -X -q -At "$RT_DSN" -f - 2>&1 | tail -1)"
[[ "$seen" == 0 ]] && pass "an unscoped session sees 0 nodes" || fail "unscoped sees $seen"
q "CREATE TABLE ctl_node_ref (tenant_id text NOT NULL, node_id uuid REFERENCES workspace_doc_node (id));
ALTER TABLE ctl_node_ref ENABLE ROW LEVEL SECURITY; ALTER TABLE ctl_node_ref FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ctl_node_ref USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
  WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
GRANT SELECT, INSERT ON ctl_node_ref TO spool_rt;" >/dev/null
committed "CONTROL an FK without the tenant column: ra row pointing at rb's folder" tx ra "INSERT INTO ctl_node_ref VALUES ('ra', '${ID[rb/F]}');"
q "DROP TABLE ctl_node_ref" >/dev/null

echo "--- T9. the migration on existing rows"
mkdir -p "$T/sql"
for f in "$SQL_DIR"/*.sql; do [[ "$(basename "$f")" == 0165_workspace_doc_node.sql ]] || cp "$f" "$T/sql/"; done
migrate_to() { "$BIN" migrate --db "$(dsn spool:spool "$1")" --sql-dir "$T/sql" 2>&1; }
for db in spool_mig spool_cap; do q "CREATE DATABASE $db" >/dev/null; migrate_to $db >/dev/null || fail "migrate $db to 0164"; done
MIG="$(dsn spool:spool spool_mig)" CAP="$(dsn spool:spool spool_cap)"
for t in m1 m2 m3; do mktenant $t "$MIG"; done
q "BEGIN; SET LOCAL app.rls_scope = 'operator';
INSERT INTO workspace_doc (id, tenant_id, title, created_at) VALUES
  ('00000000-0000-4000-8000-000000000003', 'm1', 'first', '2026-01-01'),
  ('00000000-0000-4000-8000-000000000001', 'm1', 'second', '2026-01-02'),
  ('00000000-0000-4000-8000-000000000002', 'm1', 'third', '2026-01-03'),
  ('00000000-0000-4000-8000-000000000004', 'm3', 'only', '2026-01-01');
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) SELECT tenant_id, id, NULL, 1 FROM workspace_doc;
COMMIT;" "$MIG" >/dev/null
cp "$SQL_DIR/0165_workspace_doc_node.sql" "$T/sql/"
out="$(migrate_to spool_mig)" && pass "T9 migrate existing rows" || fail "T9 migrate: $out"
treem() { qop "SELECT string_agg(CASE n.kind WHEN 'root' THEN 'R' ELSE d.title END || ':' || n.lft || ',' || n.rgt, ' ' ORDER BY n.lft)
  FROM workspace_doc_node n LEFT JOIN workspace_doc d ON d.id = n.doc_id WHERE n.tenant_id = '$1'" "$MIG" | tail -1; }
[[ "$(treem m1)" == "R:1,8 first:2,3 second:4,5 third:6,7" ]] && pass "  m1: created_at order, bounds 1..8" || fail "  m1: $(treem m1)"
[[ "$(treem m3)" == "R:1,4 only:2,3" ]] && pass "  m3: R:1,4 only:2,3" || fail "  m3: $(treem m3)"
[[ "$(treem m2)" == "" ]] && pass "  m2 (no documents): no root" || fail "  m2: $(treem m2)"
got="$(qop "SELECT (SELECT count(*) FROM workspace_doc) || '/' || (SELECT count(DISTINCT doc_id) FROM workspace_doc_node WHERE kind = 'doc')
  || '/' || (SELECT string_agg(tenant_id || '=' || doc_count, ',' ORDER BY tenant_id) FROM workspace_doc_node WHERE kind = 'root')" "$MIG" | tail -1)"
[[ "$got" == "4/4/m1=3,m3=1" ]] && pass "  every document one node, doc_count m1=3 m3=1" || fail "  counts: $got"
rm "$T/sql/0165_workspace_doc_node.sql"
mktenant big "$CAP"; seed_flat big 10001 0 "$CAP"
cp "$SQL_DIR/0165_workspace_doc_node.sql" "$T/sql/"
rc=0; out="$(migrate_to spool_cap)" || rc=$?
reg="$(q "SELECT to_regclass('workspace_doc_node') IS NULL" "$CAP")"
[[ $rc -ne 0 && "$reg" == t ]] && grep -q 'big (10001)' <<<"$out" &&
  { pass "T9 a workspace at 10,001 is refused by id, nothing left behind"; echo "    $(grep -m1 -o 'workspace_doc_node: refused[^"]*' <<<"$out")"; } ||
  fail "T9 refusal: rc=$rc table_absent=$reg $out"
q "SET app.rls_scope = 'operator'; DELETE FROM workspace_doc WHERE id = (SELECT id FROM workspace_doc ORDER BY created_at DESC LIMIT 1)" "$CAP" >/dev/null
out="$(migrate_to spool_cap)" && [[ "$(qop "SELECT doc_count FROM workspace_doc_node WHERE kind = 'root'" "$CAP" | tail -1)" == 10000 ]] &&
  pass "CONTROL T9 at 10,000 the migration runs, doc_count 10000" || fail "CONTROL T9 at 10,000: $out"

echo "--- CONTROL: the commit check and the cap CHECK dropped"
q "DROP TRIGGER workspace_doc_node_ns ON workspace_doc_node" >/dev/null
planted c
read -r rc1 rc2 waited <<<"$(race6 w6c)"
[[ $rc1 -eq 0 && $waited -eq 0 ]] && pass "CONTROL T6 with _ns dropped the lock-skipping move never waits (rc2=$rc2)" || fail "CONTROL T6: waited=$waited rc1=$rc1"
q "ALTER TABLE workspace_doc_node DROP CONSTRAINT workspace_doc_node_cap" >/dev/null
W=w5c; mktenant $W; seed_flat $W 9999 0; ID[$W/R]="$(qop "SELECT id FROM workspace_doc_node WHERE tenant_id = '$W' AND kind = 'root'" | tail -1)"
read -r rc1 rc2 cnt real <<<"$(race5 $W 1)"
[[ $rc1 -eq 0 && $rc2 -eq 0 && $real == 10001 ]] && pass "CONTROL T5 with the cap CHECK dropped both commit (count $real)" ||
  fail "CONTROL T5: rc1=$rc1 rc2=$rc2 count=$real"

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
