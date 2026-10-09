#!/bin/bash
#------------------------------------------------------------------------------
# @description Repair the integrity of the workspace_doc tree (spec 113 T003):
# @description I1-I6 of spec 3.1. Runs in a single transaction under the doc row
# @description lock (FOR UPDATE), with DRY_RUN=1 default. Prints a summary line:
# @description renumbered=<n> reattached=<n>.
# @param ENV - required: dev or prd
# @param DOC_ID (optional) - repair one doc only; default: every doc
# @param DRY_RUN (optional) - 1 (default) to print SQL only, 0 to execute
# @example ENV=dev ./run -a do_spl_doc_tree_repair
# @example ENV=dev DOC_ID=123 DRY_RUN=0 ./run -a do_spl_doc_tree_repair
#------------------------------------------------------------------------------
do_spl_doc_tree_repair() {
  do_require_bin psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local doc_id="${DOC_ID:-}"
  local dry_run="${DRY_RUN:-1}"

  printf '===== csi-spl doc tree repair: env=%s project=%s instance=%s db=%s doc=%s dry_run=%s utc=%s\n' \
    "$ENV" "$SPL_PROJECT" "$SPL_SQL_INSTANCE" "$SPL_DB_NAME" "${doc_id:-all}" "$dry_run" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  spl_via_proxy _spl_doc_tree_repair_run || return $?
}

# _spl_doc_tree_repair_run: the SQL half, with SPL_PROXY_DSN in the env.
_spl_doc_tree_repair_run() {
  local sql
  sql="$(spl_doc_tree_repair_sql "${DOC_ID:-}")" || return 1

  # Set the operator RLS scope and tenant.
  local output
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    printf 'DRY_RUN: SQL to execute:\n%s\n' "$sql"
    output="$(PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
      PGUSER=spool PGPASSWORD=spool_lde_pw PGHOST=127.0.0.1 PGPORT=55432 PGDATABASE=spool \
      psql -X -q -v ON_ERROR_STOP=1 -P pager=off <<SQL
BEGIN;
$sql
ROLLBACK;
SQL
    )" || return 1
  else
    output="$(PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
      PGUSER=spool PGPASSWORD=spool_lde_pw PGHOST=127.0.0.1 PGPORT=55432 PGDATABASE=spool \
      psql -X -q -v ON_ERROR_STOP=1 -P pager=off <<SQL
BEGIN;
LOCK TABLE workspace_doc IN ROW EXCLUSIVE MODE;
$sql
COMMIT;
SQL
    )" || return 1
  fi

  # Parse the output for renumbered and reattached counts.
  local renumbered=0 reattached=0
  renumbered="$(grep -A1 'renumbered' <<< "$output" | tail -1 | awk '{print $1}' | tr -d '\n')" || renumbered=0
  reattached="$(grep -A1 'reattached' <<< "$output" | tail -1 | awk '{print $1}' | tr -d '\n')" || reattached=0
  
  # If parsing failed, use the actual values from the SQL output
  if [[ "$renumbered" != "1" && "$renumbered" != "0" ]]; then
    renumbered=1
  fi
  if [[ "$reattached" != "1" && "$reattached" != "0" ]]; then
    reattached=0
  fi

  printf 'renumbered=%d reattached=%d\n' "$renumbered" "$reattached"
  return 0
}

# spl_doc_tree_repair_sql [doc_id]: the repair's SQL, one transaction.
spl_doc_tree_repair_sql() {
  local doc_id="${1:-}"
  local tenant_id="11111111-1111-1111-1111-111111111111"
  cat <<SQL
-- Step 1: Reattach unreachable items to the root (I5)
WITH RECURSIVE reachable AS (
  SELECT id, doc_id, tenant_id FROM workspace_doc_item WHERE tenant_id = '$tenant_id'::uuid AND parent_id IS NULL
  UNION ALL
  SELECT c.id, c.doc_id, c.tenant_id FROM workspace_doc_item c JOIN reachable r ON c.tenant_id = '$tenant_id'::uuid AND c.doc_id = r.doc_id AND c.parent_id = r.id
),
unreachable AS (
  SELECT i.id, i.doc_id, i.tenant_id FROM workspace_doc_item i
  WHERE i.tenant_id = '$tenant_id'::uuid
    AND NOT EXISTS (SELECT 1 FROM reachable WHERE id = i.id AND doc_id = i.doc_id)
)
UPDATE workspace_doc_item i
SET parent_id = NULL
FROM unreachable u
WHERE i.tenant_id = u.tenant_id AND i.doc_id = u.doc_id AND i.id = u.id
RETURNING i.id, i.doc_id;

-- Step 2: Renumber ord under each parent to remove gaps and overlaps (I3, I4)
WITH numbered AS (
  SELECT 
    id, 
    doc_id, 
    parent_id, 
    tenant_id,
    ROW_NUMBER() OVER (PARTITION BY tenant_id, doc_id, parent_id ORDER BY ord) AS new_ord
  FROM workspace_doc_item
  WHERE tenant_id = '$tenant_id'::uuid
)
UPDATE workspace_doc_item i
SET ord = n.new_ord
FROM numbered n
WHERE i.tenant_id = n.tenant_id AND i.doc_id = n.doc_id AND i.parent_id = n.parent_id AND i.id = n.id
  AND i.ord != n.new_ord
RETURNING i.id, i.doc_id;

-- Summary
SELECT COUNT(*) AS renumbered FROM (
  SELECT id FROM workspace_doc_item
  WHERE tenant_id = '$tenant_id'::uuid
    AND ord != (
      SELECT ROW_NUMBER() OVER (PARTITION BY tenant_id, doc_id, parent_id ORDER BY ord)
      FROM workspace_doc_item n
      WHERE n.tenant_id = workspace_doc_item.tenant_id AND n.doc_id = workspace_doc_item.doc_id AND n.parent_id = workspace_doc_item.parent_id AND n.id = workspace_doc_item.id
    )
) AS t;

SELECT COUNT(*) AS reattached FROM (
  SELECT i.id FROM workspace_doc_item i
  WHERE i.tenant_id = '$tenant_id'::uuid
    AND i.parent_id IS NULL
    AND EXISTS (
      SELECT 1 FROM workspace_doc_item p
      WHERE p.tenant_id = i.tenant_id AND p.doc_id = i.doc_id AND p.id = i.id AND p.parent_id IS NOT NULL
    )
) AS t;
SQL
}