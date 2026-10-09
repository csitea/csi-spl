#!/bin/bash
#------------------------------------------------------------------------------
# @description The full check of the workspace doc tree invariants I1-I6 (spec
# @description 113 section 3.1 and 3.4, T003), read-only, as the per-env SA
# @description through the Cloud SQL proxy, under the OPERATOR RLS scope: an
# @description RLS-scoped run sees 0 docs and would print a false violations=0.
# @description Prints one line per violation, then
# @description   violations=<n> docs=<n> items=<n>
# @description   I1 doc has exactly one root (ord 1)
# @description   I2 every other item's parent is in the same doc and tenant
# @description   I3 every item is reachable from the root: one line per cycle
# @description      (named by its smallest id, where the repair cuts it), one
# @description      per doc for the items hanging below a cycle or an orphan
# @description   I4 the children of each item are numbered 1..k (gap, overlap)
# @description   I5 follows from I4; I6 is derived at read, nothing stored.
# @description Exit 0 clean, 1 on any violation, 2 on docs=0 (the scope or the
# @description DOC_ID found nothing) unless EXPECT_EMPTY=1.
# @param ENV - required: dev or prd
# @param DOC_ID (optional) - one doc (uuid); default: every doc
# @param EXPECT_EMPTY (optional) - 1: docs=0 exits 0
# @example ENV=dev ./run -a do_spl_doc_tree_check
# @example ENV=dev DOC_ID=<doc uuid> ./run -a do_spl_doc_tree_check
#------------------------------------------------------------------------------
do_spl_doc_tree_check() {
  do_require_bin psql python3 || return 1
  spl_doc_tree_doc_id_ok "${DOC_ID:-}" || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  do_log "INFO doc tree check: env=$ENV doc=${DOC_ID:-all} as $GCP_ACCOUNT (read-only, operator scope)"
  spl_via_proxy _spl_doc_tree_check_run
}

# _spl_doc_tree_check_run: the SQL half, SPL_PROXY_DSN in the env.
_spl_doc_tree_check_run() {
  spl_doc_tree_check_exec "$SPL_PROXY_DSN" operator "${DOC_ID:-}"
}

# spl_doc_tree_doc_id_ok <doc>: empty or a uuid, else refused (it is a psql
# variable, quoted by psql, but a malformed one is a typo to stop early).
spl_doc_tree_doc_id_ok() {
  [[ -z "$1" || "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && return 0
  do_log "FATAL DOC_ID must be a lowercase uuid or empty, got: '$1'"
  return 1
}

# spl_doc_tree_check_exec <dsn> <rls scope> [doc]: one READ ONLY transaction
# under app.rls_scope = <scope> (the action passes operator; the test passes
# '' for the no-scope control), prints the violations and the summary line,
# returns 0 / 1 / 2 as the action does.
spl_doc_tree_check_exec() {
  local dsn="$1" scope="$2" doc="${3:-}" out
  # shellcheck disable=SC2016 # :'scope' is a psql variable, not a shell one
  out="$({ printf '%s\n' 'BEGIN READ ONLY;' "SET LOCAL app.rls_scope = :'scope';"
    spl_doc_tree_check_sql
    printf '%s\n' 'COMMIT;'
  } | spl_pg_env "$dsn" psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v scope="$scope" -v doc="$doc" -f - 2>&1)" ||
    { do_log "FATAL the doc tree check query failed: $out"; return 1; }
  spl_doc_tree_check_report "$out"
}

# spl_doc_tree_check_report <psql output>: V<TAB><inv><TAB><text> rows become
# "violation <inv> <text>"; the S row is the summary. Returns the exit code.
spl_doc_tree_check_report() {
  local out="$1" n docs items
  awk -F'\t' '$1 == "V" { printf "violation %s %s\n", $2, $3 }' <<<"$out"
  n="$(grep -c $'^V\t' <<<"$out")"
  docs="$(awk -F'\t' '$1 == "S" { print $2 }' <<<"$out")"
  items="$(awk -F'\t' '$1 == "S" { print $3 }' <<<"$out")"
  [[ "$docs" =~ ^[0-9]+$ && "$items" =~ ^[0-9]+$ ]] || { do_log "FATAL no summary row in the check output: $out"; return 1; }
  printf 'violations=%d docs=%d items=%d\n' "$n" "$docs" "$items"
  if (( docs == 0 )); then
    [[ "${EXPECT_EMPTY:-0}" == 1 ]] && return 0
    do_log "FAIL docs=0: the run saw no document (no operator scope, an empty env, or DOC_ID not found); EXPECT_EMPTY=1 if that is expected"
    return 2
  fi
  (( n == 0 ))
}

# spl_doc_tree_check_sql: the check's statements (psql variable :doc, '' =
# every doc). Every statement scopes to the docs of d, so a DOC_ID run reads
# that doc's items only. Output rows: V <inv> <text>, and one S <docs> <items>.
spl_doc_tree_check_sql() {
  cat <<'SQL'
-- I1: exactly one root (parent_id NULL), and its ord is 1.
WITH d AS (SELECT id FROM workspace_doc WHERE :'doc' = '' OR id = NULLIF(:'doc', '')::uuid)
SELECT 'V', 'I1', format('doc=%s roots=%s', d.id, count(r.id))
FROM d LEFT JOIN workspace_doc_item r ON r.doc_id = d.id AND r.parent_id IS NULL
GROUP BY d.id
HAVING count(r.id) <> 1 OR bool_or(r.ord <> 1)
ORDER BY d.id;

-- I2: the parent of every non-root item is an item of the same doc and tenant,
-- and the item's tenant is its doc's (the composite FKs, checked again).
WITH d AS (SELECT id FROM workspace_doc WHERE :'doc' = '' OR id = NULLIF(:'doc', '')::uuid)
SELECT 'V', 'I2', format('doc=%s item=%s parent=%s', i.doc_id, i.id, coalesce(i.parent_id::text, '-'))
FROM workspace_doc_item i JOIN d ON d.id = i.doc_id
WHERE NOT EXISTS (SELECT 1 FROM workspace_doc w WHERE w.id = i.doc_id AND w.tenant_id = i.tenant_id)
   OR (i.parent_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM workspace_doc_item p
         WHERE p.tenant_id = i.tenant_id AND p.doc_id = i.doc_id AND p.id = i.parent_id))
ORDER BY i.doc_id, i.id;

-- I3: reachable from the root. reach walks down from each root (a node
-- reachable from a root has one parent chain, so the walk ends). u is the
-- rest; up walks each u item's parent chain, the CYCLE clause stops it at the
-- first repeat. An item met again on its own chain is on a cycle; its cycle
-- is named by the smallest id met on that chain (all of them cycle members).
WITH RECURSIVE d AS (
  SELECT id FROM workspace_doc WHERE :'doc' = '' OR id = NULLIF(:'doc', '')::uuid
), reach AS (
  SELECT r.id FROM workspace_doc_item r JOIN d ON d.id = r.doc_id WHERE r.parent_id IS NULL
  UNION ALL
  SELECT c.id FROM workspace_doc_item c JOIN reach ON c.parent_id = reach.id
), u AS (
  SELECT i.id, i.doc_id, i.parent_id FROM workspace_doc_item i JOIN d ON d.id = i.doc_id
  WHERE NOT EXISTS (SELECT 1 FROM reach WHERE reach.id = i.id)
), up (start, cur) AS (
  SELECT id, parent_id FROM u
  UNION ALL
  SELECT up.start, i.parent_id FROM up JOIN workspace_doc_item i ON i.id = up.cur
) CYCLE cur SET looped USING path,
k AS (
  SELECT start AS id, (array_agg(cur ORDER BY cur))[1] AS cut
  FROM up WHERE cur IS NOT NULL AND start IN (SELECT start FROM up WHERE cur = start)
  GROUP BY start
)
SELECT 'V', 'I3', format('cycle doc=%s cut=%s size=%s', u.doc_id, k.cut, count(*))
FROM k JOIN u ON u.id = k.id GROUP BY u.doc_id, k.cut
UNION ALL
SELECT 'V', 'I3', format('unreachable doc=%s items=%s first=%s', u.doc_id, count(*), (array_agg(u.id ORDER BY u.id))[1])
FROM u WHERE NOT EXISTS (SELECT 1 FROM k WHERE k.id = u.id) GROUP BY u.doc_id
ORDER BY 3;

-- I4 (and I5): the children of each parent are numbered 1..k.
WITH d AS (SELECT id FROM workspace_doc WHERE :'doc' = '' OR id = NULLIF(:'doc', '')::uuid)
SELECT 'V', 'I4', format('%s doc=%s parent=%s count=%s ord=%s..%s',
         CASE WHEN count(DISTINCT i.ord) <> count(*) THEN 'overlap' ELSE 'gap' END,
         i.doc_id, i.parent_id, count(*), min(i.ord), max(i.ord))
FROM workspace_doc_item i JOIN d ON d.id = i.doc_id
WHERE i.parent_id IS NOT NULL
GROUP BY i.doc_id, i.parent_id
HAVING min(i.ord) <> 1 OR max(i.ord) <> count(*) OR count(DISTINCT i.ord) <> count(*)
ORDER BY i.doc_id, i.parent_id;

-- The summary row.
WITH d AS (SELECT id FROM workspace_doc WHERE :'doc' = '' OR id = NULLIF(:'doc', '')::uuid)
SELECT 'S', (SELECT count(*) FROM d),
       (SELECT count(*) FROM workspace_doc_item i JOIN d ON d.id = i.doc_id);
SQL
}
