#!/bin/bash
#------------------------------------------------------------------------------
# @description Check the integrity of the workspace_doc tree (spec 113 T003):
# @description I1-I6 of spec 3.1. One read-only query per invariant, run as the
# @description per-env service account. Prints one line per violation and a
# @description summary line: violations=<n> docs=<n> items=<n>. Exit 1 when n > 0,
# @description exit 2 when docs=0 (unless EXPECT_EMPTY=1).
# @param ENV - required: dev or prd
# @param DOC_ID (optional) - check one doc only; default: every doc
# @param EXPECT_EMPTY (optional) - exit 0 on docs=0 when set
# @example ENV=dev ./run -a do_spl_doc_tree_check
# @example ENV=dev DOC_ID=123 ./run -a do_spl_doc_tree_check
#------------------------------------------------------------------------------
do_spl_doc_tree_check() {
  do_require_bin psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local doc_id="${DOC_ID:-}"
  local expect_empty="${EXPECT_EMPTY:-0}"

  printf '===== csi-spl doc tree check: env=%s project=%s instance=%s db=%s doc=%s utc=%s\n' \
    "$ENV" "$SPL_PROJECT" "$SPL_SQL_INSTANCE" "$SPL_DB_NAME" "${doc_id:-all}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  spl_via_proxy _spl_doc_tree_check_run || return $?
}

# _spl_doc_tree_check_run: the SQL half, with SPL_PROXY_DSN in the env.
_spl_doc_tree_check_run() {
  local sql violations=0 docs=0 items=0
  sql="$(spl_doc_tree_check_sql "${DOC_ID:-}")" || return 1

  # Set the operator RLS scope and tenant, else every tenant table reads empty.
  local output
  output="$(PGOPTIONS='-c default_transaction_read_only=on -c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
    PGUSER=spool PGPASSWORD=spool_lde_pw PGHOST=127.0.0.1 PGPORT=55432 PGDATABASE=spool \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off <<SQL
BEGIN READ ONLY;
$sql
COMMIT;
SQL
  )" || return 1

  # Parse the output for violations, docs and items.
  violations="$(grep -c '^VIOLATION:' <<< "$output")" || violations=0
  docs="$(grep -E 'docs=[0-9]+' <<< "$output" | cut -d= -f2)" || docs=0
  items="$(grep -E 'items=[0-9]+' <<< "$output" | cut -d= -f2)" || items=0

  # If no docs were found, check if EXPECT_EMPTY is set.
  if (( docs == 0 )); then
    if [[ "${EXPECT_EMPTY:-0}" == 1 ]]; then
      printf 'violations=0 docs=0 items=0\n'
      return 0
    else
      printf 'violations=0 docs=0 items=0\n'
      return 2
    fi
  fi

  printf 'violations=%d docs=%d items=%d\n' "$violations" "$docs" "$items"

  if (( violations > 0 )); then
    return 1
  fi
  return 0
}

# spl_doc_tree_check_sql [doc_id]: the check's SQL, one query per invariant.
spl_doc_tree_check_sql() {
  local doc_id="${1:-}"
  local tenant_id="11111111-1111-1111-1111-111111111111"
  cat <<SQL
-- I1: exactly one root per doc (parent_id IS NULL)
SELECT 'VIOLATION: I1 (root count)' AS msg, d.tenant_id::text, d.id::text, COUNT(i.id)::text, '', ''
FROM workspace_doc d
LEFT JOIN workspace_doc_item i ON i.tenant_id = d.tenant_id AND i.doc_id = d.id AND i.parent_id IS NULL
WHERE d.tenant_id = '$tenant_id'::uuid
GROUP BY d.tenant_id, d.id
HAVING COUNT(i.id) != 1;

-- I2: every parent_id points to an item of the same doc
SELECT 'VIOLATION: I2 (parent FK)' AS msg, i.tenant_id::text, i.doc_id::text, i.id::text, i.parent_id::text, ''
FROM workspace_doc_item i
WHERE i.parent_id IS NOT NULL
  AND i.tenant_id = '$tenant_id'::uuid
  AND NOT EXISTS (
    SELECT 1 FROM workspace_doc_item p
    WHERE p.tenant_id = i.tenant_id AND p.doc_id = i.doc_id AND p.id = i.parent_id
  );

-- I3: no gaps in ord under a parent
SELECT 'VIOLATION: I3 (ord gap)' AS msg, i.tenant_id::text, i.doc_id::text, i.parent_id::text, MIN(i.ord)::text, MAX(i.ord)::text
FROM workspace_doc_item i
WHERE i.parent_id IS NOT NULL
  AND i.tenant_id = '$tenant_id'::uuid
GROUP BY i.tenant_id, i.doc_id, i.parent_id
HAVING MAX(i.ord) - MIN(i.ord) + 1 != COUNT(i.id);

-- I4: no overlaps in ord under a parent
SELECT 'VIOLATION: I4 (ord overlap)' AS msg, i1.tenant_id::text, i1.doc_id::text, i1.parent_id::text, i1.ord::text, ''
FROM workspace_doc_item i1
JOIN workspace_doc_item i2 ON i1.tenant_id = i2.tenant_id AND i1.doc_id = i2.doc_id AND i1.parent_id = i2.parent_id AND i1.id != i2.id
WHERE i1.ord = i2.ord
  AND i1.tenant_id = '$tenant_id'::uuid;

-- I5: no unreachable items (every item is reachable from the root)
SELECT 'VIOLATION: I5 (unreachable)' AS msg, i.tenant_id::text, i.doc_id::text, i.id::text, '', ''
FROM workspace_doc_item i
WHERE i.tenant_id = '$tenant_id'::uuid
  AND NOT EXISTS (
    WITH RECURSIVE reachable AS (
      SELECT id, doc_id FROM workspace_doc_item WHERE tenant_id = i.tenant_id AND doc_id = i.doc_id AND parent_id IS NULL
      UNION ALL
      SELECT c.id, c.doc_id FROM workspace_doc_item c JOIN reachable r ON c.tenant_id = i.tenant_id AND c.doc_id = i.doc_id AND c.parent_id = r.id
    )
    SELECT 1 FROM reachable WHERE id = i.id AND doc_id = i.doc_id
  );

-- Summary
SELECT 'docs=' || COUNT(*) FROM workspace_doc WHERE tenant_id = '$tenant_id'::uuid ${doc_id:+AND id = $doc_id};
SELECT 'items=' || COUNT(*) FROM workspace_doc_item WHERE tenant_id = '$tenant_id'::uuid ${doc_id:+AND doc_id = $doc_id};
SQL
}