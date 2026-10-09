#!/bin/bash
#------------------------------------------------------------------------------
# @description Repair ONE workspace doc's tree (spec 113 section 3.4, T003):
# @description rebuild the derived fields from the parent links, in ONE
# @description transaction under the doc lock (the doc row FOR UPDATE, exactly
# @description 1 row, as the store's ops take it), so it serializes with live
# @description ops and passes the deferred triggers, as the per-env SA through
# @description the Cloud SQL proxy, under the operator RLS scope:
# @description   1. each unreachable cycle is cut at its smallest id, and that
# @description      item re-attached at the end of the root; any other
# @description      unreachable item (an orphan) is re-attached there too
# @description   2. each item's children are renumbered 1..k in their current
# @description      (ord, id) order
# @description   3. when 1 or 2 changed a row: workspace_doc.rev + 1 and a
# @description      "repair" entry in workspace_doc_rev_log (spec 2.3)
# @description   4. SET CONSTRAINTS ALL IMMEDIATE: the deferred triggers run
# @description      before the commit (and in a dry run before the rollback)
# @description Prints renumbered=<n> reattached=<n> ids=<cut and re-attached
# @description ids>, then the check of the doc (do_spl_doc_tree_check's line):
# @description in a dry run inside the rolled-back transaction, with DRY_RUN=0
# @description a fresh check after the commit. Dry run unless DRY_RUN=0;
# @description DRY_RUN=0 on prd is an owner go (repo rule).
# @param ENV - required: dev or prd
# @param DOC_ID - required: the doc (uuid)
# @param DRY_RUN (optional) - 1 (default): the same statements, rolled back
# @example ENV=dev DOC_ID=<doc uuid> ./run -a do_spl_doc_tree_repair
# @example ENV=dev DOC_ID=<doc uuid> DRY_RUN=0 ./run -a do_spl_doc_tree_repair
#------------------------------------------------------------------------------
do_spl_doc_tree_repair() {
  do_require_bin psql python3 || return 1
  [[ -n "${DOC_ID:-}" ]] || { do_log "FATAL DOC_ID is required: the repair works on one doc"; return 1; }
  spl_doc_tree_doc_id_ok "$DOC_ID" || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  do_log "INFO doc tree repair: env=$ENV doc=$DOC_ID dry_run=$dry as $GCP_ACCOUNT"
  SPL_DOC_REPAIR_DRY="$dry" spl_via_proxy _spl_doc_tree_repair_run
}

# _spl_doc_tree_repair_run: the SQL half, SPL_PROXY_DSN in the env.
_spl_doc_tree_repair_run() {
  spl_doc_tree_repair_exec "$SPL_PROXY_DSN" "$DOC_ID" "$SPL_DOC_REPAIR_DRY" "do_spl_doc_tree_repair:$GCP_ACCOUNT"
}

# spl_doc_tree_repair_exec <dsn> <doc> <dry 0|1> <actor>: the one transaction,
# then the check. Returns the check's code (0 = the doc is clean after it).
spl_doc_tree_repair_exec() {
  local dsn="$1" doc="$2" dry="$3" actor="$4" out rc
  out="$({ spl_doc_tree_repair_sql
    if [[ "$dry" == 1 ]]; then spl_doc_tree_check_sql; fi
    printf '%s\n' '\if :dry' 'ROLLBACK;' '\else' 'COMMIT;' '\endif'
  } | spl_pg_env "$dsn" psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 \
    -v doc="$doc" -v dry="$dry" -v actor="${actor:0:200}" -f - 2>&1)" ||
    { do_log "FATAL the repair of doc $doc failed, nothing was committed: $out"; return 1; }
  grep -q $'^LOCKED\t1$' <<<"$out" ||
    { do_log "FATAL doc $doc: not found under the operator scope, or it has no root (I1): nothing to repair"; return 1; }
  awk -F'\t' '$1 == "R" { printf "renumbered=%s reattached=%s ids=%s\n", $2, $3, ($4 == "" ? "-" : $4) }' <<<"$out"
  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN rolled back; the check inside that transaction (the doc as the repair would leave it):"
    spl_doc_tree_check_report "$(grep -v -e $'^LOCKED\t' -e $'^R\t' <<<"$out")"; rc=$?
    do_log "OK DRY_RUN nothing was committed. Re-run with DRY_RUN=0 to repair doc $doc."
    return $rc
  fi
  do_log "OK doc $doc repaired and committed; the check after the commit:"
  spl_doc_tree_check_exec "$dsn" operator "$doc"
}

# spl_doc_tree_repair_sql: BEGIN, the lock, the two fixes, the log entry, the
# deferred triggers. Leaves the transaction open (the caller ends it). psql
# variables :doc, :actor. Output rows: LOCKED <0|1>, R <renumbered>
# <reattached> <ids>.
spl_doc_tree_repair_sql() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
-- The doc lock (spec 3.3), exactly 1 row, and the doc's root (no root = I1,
-- nothing to attach to: refuse).
SELECT count(*) = 1 AND EXISTS (
         SELECT 1 FROM workspace_doc_item WHERE doc_id = :'doc'::uuid AND parent_id IS NULL) AS locked
FROM (SELECT 1 FROM workspace_doc WHERE id = :'doc'::uuid FOR UPDATE) l \gset
SELECT 'LOCKED', CASE WHEN :'locked' THEN 1 ELSE 0 END;
\if :locked
\else
ROLLBACK;
\q
\endif

-- 1. Re-attach. reach and u as in the check (I3); cut = the smallest id of
-- each cycle; orphan = an unreachable item whose parent is not in the doc.
-- Both go to the end of the root, in id order.
WITH RECURSIVE reach AS (
  SELECT id FROM workspace_doc_item WHERE doc_id = :'doc'::uuid AND parent_id IS NULL
  UNION ALL
  SELECT c.id FROM workspace_doc_item c JOIN reach ON c.parent_id = reach.id
), u AS (
  SELECT i.id, i.parent_id FROM workspace_doc_item i
  WHERE i.doc_id = :'doc'::uuid AND NOT EXISTS (SELECT 1 FROM reach WHERE reach.id = i.id)
), up (start, cur) AS (
  SELECT id, parent_id FROM u
  UNION ALL
  SELECT up.start, i.parent_id FROM up JOIN workspace_doc_item i ON i.id = up.cur
) CYCLE cur SET looped USING path,
fix AS (
  SELECT DISTINCT (array_agg(cur ORDER BY cur))[1] AS id
  FROM up WHERE cur IS NOT NULL AND start IN (SELECT start FROM up WHERE cur = start)
  GROUP BY start
  UNION
  SELECT u.id FROM u WHERE NOT EXISTS (
    SELECT 1 FROM workspace_doc_item p WHERE p.doc_id = :'doc'::uuid AND p.id = u.parent_id)
), root AS (
  SELECT r.id, (SELECT coalesce(max(c.ord), 0) FROM workspace_doc_item c
                WHERE c.doc_id = :'doc'::uuid AND c.parent_id = r.id) AS top
  FROM workspace_doc_item r WHERE r.doc_id = :'doc'::uuid AND r.parent_id IS NULL
), moved AS (
  UPDATE workspace_doc_item i
  SET parent_id = root.id, ord = root.top + f.k, updated_at = now()
  FROM (SELECT id, row_number() OVER (ORDER BY id) AS k FROM fix) f, root
  WHERE i.doc_id = :'doc'::uuid AND i.id = f.id
  RETURNING i.id
)
SELECT count(*) AS reattached, coalesce(string_agg(id::text, ',' ORDER BY id), '') AS reattached_ids
FROM moved \gset

-- 2. Renumber every sibling list 1..k in (ord, id) order, ONE statement (the
-- deferrable UNIQUE is checked at its end). The root keeps ord 1.
WITH n AS (
  SELECT id, row_number() OVER (PARTITION BY parent_id ORDER BY ord, id) AS k
  FROM workspace_doc_item WHERE doc_id = :'doc'::uuid AND parent_id IS NOT NULL
), renum AS (
  UPDATE workspace_doc_item i SET ord = n.k, updated_at = now()
  FROM n WHERE i.doc_id = :'doc'::uuid AND i.id = n.id AND i.ord <> n.k
  RETURNING i.id
)
SELECT count(*) AS renumbered FROM renum \gset

-- 3. The rev bump and its "repair" log entry, in one statement (the store's
-- bump), only when something changed.
SELECT :reattached + :renumbered > 0 AS changed \gset
\if :changed
WITH b AS (
  UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = :'doc'::uuid
  RETURNING tenant_id, id, rev
)
INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
SELECT tenant_id, id, rev,
       jsonb_build_object('kind', 'repair', 'renumbered', :renumbered,
                          'reattached', to_jsonb(string_to_array(NULLIF(:'reattached_ids', ''), ','))),
       :'actor'
FROM b;
\endif

-- 4. The deferred triggers (I3 cycle, I4 gap) now, so a dry run proves them.
SET CONSTRAINTS ALL IMMEDIATE;
SELECT 'R', :renumbered, :reattached, :'reattached_ids';
SQL
}
