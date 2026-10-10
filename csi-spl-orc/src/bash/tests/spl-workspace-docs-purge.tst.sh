#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_workspace_docs_purge (owner HUM-10, t1 topic 91289b0a).
#   A. stubbed, no DB, no cloud call:
#      1. TENANT_ID empty / all / ALL / a list, and a bad DRY_RUN, are refused
#         before any gcloud call; CONTROL TENANT_ID=t1 passes the guards and
#         reaches the cloud (the stub), so the refusals can fail
#      2. dry run: the export is written, no delete statement is sent
#      3. a failed export blocks the delete; CONTROL the same run with a good
#         export does send it
#      4. an export file that does not parse blocks the delete
#      5. DRY_RUN=0: one DELETE per exported doc (4 docs -> 4), each its id
#      6. live counts differ from the export: refused, nothing committed
#   B. against a REAL throwaway Postgres with every rdb migration, run by the
#      RUNTIME login (FORCE RLS binds, its grants suffice): tenants t1 (2 docs)
#      and t2 (1 doc)
#      1. dry run: exported counts match, nothing deleted; the export is
#         owner-only (dir 700, files 600)
#      2. a doc added after the export: DRY_RUN=0 refused, nothing deleted
#      3. DRY_RUN=0: t1 has 0 docs/items/rev_log left (the cascade ran under
#         the runtime login), t2 untouched
#      With rdb 0165 (workspace_doc_node) in the migrations, t1's first two
#      docs also get nodes (root (1,6), (2,3), (4,5)), as its data step lays
#      them out: 3 must also leave t1's root at (1,2) through the commit
#      check, and 4. CONTROL the gap close neutered: the same purge is
#      refused by workspace_doc_node_ns, nothing deleted. SPOOL_TEST_SQL_DIR
#      overrides the migrations dir (to run against a tree with 0165).
#   SKIP part B when no docker / psql / cached postgres image.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# A.1 -------------------------------------------------------------------------
orc_stub 1 gcloud docker
# A case is its VAR=value words, '|'-separated.
for bad in "TENANT_ID=" "TENANT_ID=all" "TENANT_ID=ALL" "TENANT_ID=t1,t2" "TENANT_ID=t1 t2" "TENANT_ID=t1|DRY_RUN=2"; do
  : >"$T/calls.log"
  IFS='|' read -ra vars <<<"$bad"
  out=$(SNIPPET=do_spl_workspace_docs_purge in_orc "${vars[@]}" 2>&1); rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q FATAL <<<"$out" &&
    pass "A.1 '$bad' refused before any cloud call" || fail "A.1 '$bad' rc=$rc calls=$(cat "$T/calls.log") $out"
done
: >"$T/calls.log"
out=$(SNIPPET=do_spl_workspace_docs_purge in_orc TENANT_ID=t1 SPL_DSN_SECRET=x 2>&1); rc=$?
[[ $rc -ne 0 && -s "$T/calls.log" ]] && ! grep -q 'TENANT_ID' <<<"$out" &&
  pass "A.1 CONTROL TENANT_ID=t1 passes the guards and reaches the cloud stub" || fail "A.1 CONTROL rc=$rc calls=$(cat "$T/calls.log") $out"

# The functions under test with a plain do_log; spl_pg_env and the export are
# stubbed per case.
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$PROJ_ROOT/src/bash/run/spl-workspace-docs-purge.func.sh"
eval "$(declare -f spl_wsdoc_purge_export | sed '1s/spl_wsdoc_purge_export/_exp_real/')"
D1=11111111-1111-4111-8111-111111111111 D2=22222222-2222-4222-8222-222222222222
D3=33333333-3333-4333-8333-333333333333 D4=44444444-4444-4444-8444-444444444444
# fixture <dir>: the export of 4 docs, 7 items, 9 rev log entries.
fixture() {
  mkdir -p "$1"
  python3 - "$1" "$D1" "$D2" "$D3" "$D4" <<'PY'
import json, os, sys
d, ids = sys.argv[1], sys.argv[2:]
docs = [{"id": i, "tenant_id": "t1"} for i in ids]
items = [{"id": str(k), "tenant_id": "t1", "doc_id": ids[k % 4]} for k in range(7)]
revs = [{"tenant_id": "t1", "doc_id": ids[k % 4], "rev": k + 1} for k in range(9)]
for f, v in (("docs.json", docs), ("items.json", items), ("rev_log.json", revs)):
    json.dump(v, open(os.path.join(d, f), "w"))
json.dump({"tenant": "t1", "env": "dev", "docs": 4, "items": 7, "rev_log": 9, "doc_ids": ids},
          open(os.path.join(d, "manifest.json"), "w"))
PY
}
# spl_pg_env stub: logs the SQL it got; answers the delete script as the DB
# would (MATCH unless PG_LIVE_DIFF, a DEL per DELETE, COMMITTED), the count
# query with zeros.
spl_pg_env() {
  local sql; sql="$(cat)"
  printf '%s\n----\n' "$sql" >>"$T/sql.log"
  if grep -q 'DELETE FROM workspace_doc' <<<"$sql"; then
    echo "LIVE docs=4 items=7 rev_log=9"
    [[ -n "${PG_LIVE_DIFF:-}" ]] && return 0
    echo MATCH
    grep -oE "AND id = '[0-9a-f-]+'" <<<"$sql" | sed -E "s/AND id = '(.*)'/DEL \1/"
    echo COMMITTED
  else echo "docs=0 items=0 rev_log=0"; fi
}
ndel() { grep -c '^WITH d AS (DELETE FROM workspace_doc ' "$T/sql.log" 2>/dev/null || true; }
run() { : >"$T/sql.log"; rm -rf "$T/exp"; spl_wsdoc_purge_exec stub-dsn t1 "$T/exp" "$1" 2>&1; }

# A.2 dry run -----------------------------------------------------------------
spl_wsdoc_purge_export() { fixture "$3"; }
out=$(run 1); rc=$?
[[ $rc -eq 0 && "$(ndel)" == 0 && -s "$T/exp/manifest.json" ]] && grep -q 'exported t1: docs=4 items=7 rev_log=9' <<<"$out" &&
  pass "A.2 dry run: export docs=4 items=7 rev_log=9 written, 0 DELETE sent" || fail "A.2 rc=$rc ndel=$(ndel) $out"

# A.3 a failed export blocks the delete -----------------------------------------
spl_wsdoc_purge_export() { return 1; }
out=$(run 0); rc=$?
[[ $rc -ne 0 && "$(ndel)" == 0 ]] && grep -q 'export of t1.*failed: nothing is deleted' <<<"$out" &&
  pass "A.3 a failed export blocks the delete (0 DELETE sent)" || fail "A.3 rc=$rc ndel=$(ndel) $out"
spl_wsdoc_purge_export() { fixture "$3"; }
out=$(run 0); rc=$?
[[ $rc -eq 0 && "$(ndel)" -gt 0 ]] && pass "A.3 CONTROL the same run with a good export sends the delete" ||
  fail "A.3 CONTROL rc=$rc ndel=$(ndel) $out"

# A.4 an export file that does not parse ---------------------------------------
spl_wsdoc_purge_export() { fixture "$3"; head -c 20 "$3/items.json" >"$3/x" && mv "$3/x" "$3/items.json"; }
out=$(run 0); rc=$?
[[ $rc -ne 0 && "$(ndel)" == 0 ]] && grep -q 'does not verify: nothing is deleted' <<<"$out" &&
  pass "A.4 a broken items.json blocks the delete" || fail "A.4 rc=$rc ndel=$(ndel) $out"

# A.5 DRY_RUN=0: one DELETE per doc ----------------------------------------------
spl_wsdoc_purge_export() { fixture "$3"; }
out=$(run 0); rc=$?
ids=$(grep -oE "AND id = '[0-9a-f-]+'" "$T/sql.log" | sed -E "s/AND id = '(.*)'/\1/" | sort | tr '\n' ' ')
[[ $rc -eq 0 && "$(ndel)" == 4 && "$ids" == "$D1 $D2 $D3 $D4 " ]] && grep -q 'deleted 4 documents of t1' <<<"$out" &&
  grep -q 'before: docs=4 items=7 rev_log=9 after: docs=0 items=0 rev_log=0' <<<"$out" &&
  pass "A.5 DRY_RUN=0: 4 docs -> 4 DELETEs, one per id; before/after printed" || fail "A.5 rc=$rc ndel=$(ndel) ids=$ids $out"

# A.6 live counts differ ---------------------------------------------------------
out=$(PG_LIVE_DIFF=1 run 0); rc=$?
[[ $rc -ne 0 ]] && grep -q 'differ from the export' <<<"$out" && ! grep -q 'deleted 4' <<<"$out" &&
  pass "A.6 live counts differ from the export: refused" || fail "A.6 rc=$rc $out"
unset -f spl_pg_env
spl_wsdoc_purge_export() { _exp_real "$@"; }

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
PG_CTR="spl-wsdoc-purge-pg-$$"
trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
SQL_DIR="${SPOOL_TEST_SQL_DIR:-$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub}"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$SQL_DIR" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex')), ('t2', decode(repeat('cd', 32), 'hex'))" >/dev/null
# shellcheck source=/dev/null
source "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
do_log() { echo "$*"; }

uuid() { cat /proc/sys/kernel/random/uuid; }
# mkdoc <tenant>: a doc with root R, children A(1) B(2), A with child A1(1),
# and 2 rev log entries, committed through the triggers by the owner.
mkdoc() {
  local D R A B A1; D=$(uuid) R=$(uuid) A=$(uuid) B=$(uuid) A1=$(uuid)
  q "BEGIN; INSERT INTO workspace_doc (id, tenant_id, title, rev) VALUES ('$D', '$1', 'doc', 2);
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES
 ('$R','$1','$D',NULL,1,'root'),('$A','$1','$D','$R',1,'A'),('$B','$1','$D','$R',2,'B'),('$A1','$1','$D','$A',1,'A1');
INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor) VALUES
 ('$1','$D',1,'{\"kind\":\"add\"}','test'),('$1','$D',2,'{\"kind\":\"add\"}','test'); COMMIT;" >/dev/null || { fail "mkdoc"; exit 1; }
}
cnt() { q "SELECT (SELECT count(*) FROM workspace_doc WHERE tenant_id='$1')||' '||(SELECT count(*) FROM workspace_doc_item WHERE tenant_id='$1')||' '||(SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id='$1')"; }
# nodes <tenant>: when 0165 is migrated, a root and a node per doc of the
# tenant, in (created_at, id) order as its data step lays them out; prints
# the node count (0 without 0165).
nodes() {
  [[ "$(q "SELECT to_regclass('workspace_doc_node') IS NOT NULL")" == t ]] || { echo 0; return; }
  q "BEGIN; SET LOCAL app.rls_scope = 'operator';
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, kind)
SELECT '$1', 1, 2 * count(*)::int + 2, 'root' FROM workspace_doc WHERE tenant_id = '$1';
INSERT INTO workspace_doc_node (tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id)
SELECT '$1', 2 * d.i, 2 * d.i + 1, (SELECT id FROM workspace_doc_node WHERE tenant_id = '$1' AND kind = 'root'), 'root', 'doc', d.id
FROM (SELECT id, row_number() OVER (ORDER BY created_at, id)::int AS i FROM workspace_doc WHERE tenant_id = '$1') d;
COMMIT;" >/dev/null || { fail "nodes $1"; exit 1; }
  q "SET app.rls_scope = 'operator'; SELECT count(*) FROM workspace_doc_node WHERE tenant_id = '$1'" | tail -1
}
root_bounds() { q "SET app.rls_scope = 'operator'; SELECT lft || ' ' || rgt FROM workspace_doc_node WHERE tenant_id = '$1' AND kind = 'root'" | tail -1; }
mkdoc t1; mkdoc t1; mkdoc t2
NODES=$(nodes t1)
[[ "$NODES" == 0 ]] && echo "INFO: no workspace_doc_node (rdb 0165) in $SQL_DIR: the gap-close cases run as plain deletes"

# --- B.1 dry run --------------------------------------------------------------------
out=$(spl_wsdoc_purge_exec "$RT_DSN" t1 "$T/b1" 1 2>&1); rc=$?
[[ $rc -eq 0 && "$(cnt t1)" == "2 8 4" ]] && grep -q 'exported t1: docs=2 items=8 rev_log=4' <<<"$out" &&
  [[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/b1/items.json")" == 8 ]] &&
  pass "B.1 dry run: export docs=2 items=8 rev_log=4, nothing deleted" || fail "B.1 rc=$rc cnt=$(cnt t1) $out"
modes=$(stat -c '%a' "$T/b1" "$T/b1"/* | sort -u | tr '\n' ' ')
[[ "$modes" == "600 700 " ]] && pass "B.1 the export is owner-only (dir 700, files 600)" || fail "B.1 export modes: $modes"

# --- B.2 a doc added after the export: refused ----------------------------------------
spl_wsdoc_purge_export() { _exp_real "$@" && mkdoc t1; }
out=$(spl_wsdoc_purge_exec "$RT_DSN" t1 "$T/b2" 0 2>&1); rc=$?
[[ $rc -ne 0 && "$(cnt t1)" == "3 12 6" ]] && grep -q 'differ from the export' <<<"$out" &&
  pass "B.2 a doc added after the export: DRY_RUN=0 refused, nothing deleted" || fail "B.2 rc=$rc cnt=$(cnt t1) $out"
spl_wsdoc_purge_export() { _exp_real "$@"; }

# --- B.4 CONTROL the gap close neutered (0165 only) -------------------------------------
if [[ "$NODES" != 0 ]]; then
  eval "$(declare -f spl_wsdoc_purge_delete_sql | sed '1s/spl_wsdoc_purge_delete_sql/_delete_sql_real/')"
  # shellcheck disable=SC2329 # called by spl_wsdoc_purge_delete
  spl_wsdoc_purge_delete_sql() { _delete_sql_real "$@" | sed 's/AND :rgt0 > 0;$/AND false;/'; }
  [[ "$(spl_wsdoc_purge_delete_sql "$T/b1")" != "$(_delete_sql_real "$T/b1")" ]] || fail "B.4 CONTROL: the neuter matched nothing"
  out=$(spl_wsdoc_purge_exec "$RT_DSN" t1 "$T/b4" 0 2>&1); rc=$?
  [[ $rc -ne 0 && "$(cnt t1)" == "3 12 6" ]] && grep -q 'workspace_doc_node_ns' <<<"$out" &&
    pass "B.4 CONTROL gap close neutered: refused by workspace_doc_node_ns, nothing deleted" || fail "B.4 CONTROL rc=$rc cnt=$(cnt t1) $out"
  eval "$(declare -f _delete_sql_real | sed '1s/_delete_sql_real/spl_wsdoc_purge_delete_sql/')"
fi

# --- B.3 DRY_RUN=0 ----------------------------------------------------------------------
out=$(spl_wsdoc_purge_exec "$RT_DSN" t1 "$T/b3" 0 2>&1); rc=$?
[[ $rc -eq 0 && "$(cnt t1)" == "0 0 0" && "$(cnt t2)" == "1 4 2" ]] && grep -q 'deleted 3 documents of t1' <<<"$out" &&
  grep -q 'before: docs=3 items=12 rev_log=6 after: docs=0 items=0 rev_log=0' <<<"$out" &&
  pass "B.3 DRY_RUN=0 as the runtime login: t1 0 0 0 left, t2 untouched (1 4 2)" || fail "B.3 rc=$rc t1=$(cnt t1) t2=$(cnt t2) $out"
if [[ "$NODES" != 0 ]]; then
  [[ "$(root_bounds t1)" == "1 2" ]] && pass "B.3 0165: $((NODES - 1)) doc nodes deleted, the gaps closed, t1's root back at (1,2)" ||
    fail "B.3 0165: t1 root = $(root_bounds t1), want 1 2"
fi

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
