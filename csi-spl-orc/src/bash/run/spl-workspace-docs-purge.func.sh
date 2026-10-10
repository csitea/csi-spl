#!/bin/bash
#------------------------------------------------------------------------------
# @description Export, then delete, every workspace document (spec 113, the
# @description Qto outline/grid docs: workspace_doc + workspace_doc_item +
# @description workspace_doc_rev_log) of ONE workspace (tenant), as the per-env
# @description SA through the Cloud SQL proxy, under the operator RLS scope.
# @description Owner HUM-10 (t1 topic 91289b0a, msg f5bc3948): "remove all of
# @description the existing documents for now".
# @description   1. ALWAYS (dry run too): export docs.json, items.json,
# @description      rev_log.json and manifest.json (counts + doc ids) to
# @description      PURGE_EXPORT_DIR, read in ONE READ ONLY transaction, and
# @description      print the counts. A file that does not parse, or whose
# @description      length differs from the counted rows, fails the action.
# @description   2. DRY_RUN=0 only: in ONE transaction, the tenant's docs FOR
# @description      UPDATE (the doc lock the store's ops take), the live counts
# @description      must equal the manifest's, then one DELETE per exported doc
# @description      (exactly 1 row each); items and rev log go by the FK
# @description      cascade (the owner runs it, rdb runtime-grants.sql). Then
# @description      the deferred triggers, 0 left for the tenant, COMMIT.
# @description      Before/after counts are printed.
# @description Why SQL and not the hub: the hub has no document delete route
# @description (wsdoc_tree.go deletes item subtrees and refuses the root, so
# @description a document cannot be emptied through it); the doc row delete
# @description is the one path the schema designed for (0157 I1/I3 triggers
# @description skip a doc deleted in the transaction).
# @description NOT touched: the image bytes in the workspace bucket
# @description (.doctree/<doc>/, wsdoc_media.go), unreachable once the doc is gone.
# @description DRY_RUN=0 on prd is an owner go (repo rule).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: exactly ONE workspace slug ("all" or a list is refused)
# @param DRY_RUN (optional) - 1 (default): export only, nothing deleted
# @param PURGE_EXPORT_DIR (optional) - default /var/csi/csi-spl/workspace-docs-purge/<env>/<tenant>/<utc ts>
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_workspace_docs_purge
# @example ENV=prd TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_workspace_docs_purge
#------------------------------------------------------------------------------
do_spl_workspace_docs_purge() {
  do_require_bin psql python3 yq || return 1
  local tenant="${TENANT_ID:-}" dry=1 dir
  [[ -n "$tenant" ]] || { do_log "FATAL TENANT_ID is required: the purge works on exactly one workspace"; return 1; }
  [[ "${tenant,,}" != all && "$tenant" != '*' ]] || { do_log "FATAL TENANT_ID=$tenant refused: one workspace per run, never all"; return 1; }
  spl_require_tenant_slug "$tenant" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  dir="${PURGE_EXPORT_DIR:-/var/csi/csi-spl/workspace-docs-purge/$ENV/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  do_log "INFO workspace docs purge: env=$ENV tenant=$tenant dry_run=$dry export=$dir as $GCP_ACCOUNT"
  SPL_WSDOC_PURGE_TENANT="$tenant" SPL_WSDOC_PURGE_DIR="$dir" SPL_WSDOC_PURGE_DRY="$dry" \
    spl_via_proxy _spl_wsdoc_purge_run
}

# _spl_wsdoc_purge_run: the SQL half, SPL_PROXY_DSN in the env.
_spl_wsdoc_purge_run() {
  spl_wsdoc_purge_exec "$SPL_PROXY_DSN" "$SPL_WSDOC_PURGE_TENANT" "$SPL_WSDOC_PURGE_DIR" "$SPL_WSDOC_PURGE_DRY"
}

# spl_wsdoc_purge_exec <dsn> <tenant> <dir> <dry 0|1>: step 1, then step 2
# when dry is 0 and the export verified.
spl_wsdoc_purge_exec() {
  local dsn="$1" tenant="$2" dir="$3" dry="$4" counts
  spl_wsdoc_purge_export "$dsn" "$tenant" "$dir" ||
    { do_log "FATAL the export of $tenant's documents failed: nothing is deleted"; return 1; }
  counts="$(spl_wsdoc_purge_manifest_counts "$dir")" ||
    { do_log "FATAL the export in $dir does not verify: nothing is deleted"; return 1; }
  do_log "OK exported $tenant: $counts to $dir"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN nothing was deleted. Re-run with DRY_RUN=0 to delete these documents."
    return 0
  fi
  [[ "$counts" != docs=0\ * ]] || { do_log "OK $tenant has no documents: nothing to delete"; return 0; }
  spl_wsdoc_purge_delete "$dsn" "$tenant" "$dir" || return 1
  do_log "OK before: $counts after: $(spl_wsdoc_purge_count "$dsn" "$tenant")"
}

# spl_wsdoc_purge_count <dsn> <tenant> -> "docs=<n> items=<n> rev_log=<n>",
# read only, operator scope.
spl_wsdoc_purge_count() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$1" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$2" -f - <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT format('docs=%s items=%s rev_log=%s',
  (SELECT count(*) FROM workspace_doc WHERE tenant_id = :'tenant'),
  (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = :'tenant'),
  (SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = :'tenant'));
ROLLBACK;
SQL
}

# spl_wsdoc_purge_export <dsn> <tenant> <dir>: the three tables of <tenant>
# as JSON arrays plus their counts, in ONE read-only transaction (one
# snapshot), then manifest.json. Fails on any psql or parse error.
spl_wsdoc_purge_export() {
  local dsn="$1" tenant="$2" dir="$3" out
  (umask 077 && mkdir -p "$dir") || { do_log "FATAL cannot create the export dir $dir"; return 1; }
  [[ -z "$(ls -A "$dir")" ]] || { do_log "FATAL the export dir $dir is not empty"; return 1; }
  out="$(cd "$dir" && PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$dsn" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" -f - 2>&1 <<'SQL'
BEGIN TRANSACTION READ ONLY ISOLATION LEVEL REPEATABLE READ;
SET LOCAL app.rls_scope = 'operator';
\o docs.json
SELECT coalesce(json_agg(d ORDER BY d.created_at, d.id), '[]') FROM workspace_doc d WHERE d.tenant_id = :'tenant';
\o items.json
SELECT coalesce(json_agg(i ORDER BY i.doc_id, i.parent_id NULLS FIRST, i.ord, i.id), '[]') FROM workspace_doc_item i WHERE i.tenant_id = :'tenant';
\o rev_log.json
SELECT coalesce(json_agg(l ORDER BY l.doc_id, l.rev), '[]') FROM workspace_doc_rev_log l WHERE l.tenant_id = :'tenant';
\o counts.tsv
SELECT (SELECT count(*) FROM workspace_doc WHERE tenant_id = :'tenant'),
       (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = :'tenant'),
       (SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = :'tenant');
\o
ROLLBACK;
SQL
  )" || { do_log "FATAL export query: $out"; return 1; }
  python3 - "$dir" "$tenant" "${ENV:-}" <<'PY'
import json, re, sys, os
d, tenant, env = sys.argv[1:4]
docs, items, revs = (json.load(open(os.path.join(d, f))) for f in ("docs.json", "items.json", "rev_log.json"))
want = [int(x) for x in open(os.path.join(d, "counts.tsv")).read().split("|")]
got = [len(docs), len(items), len(revs)]
if got != want:
    sys.exit(f"export rows {got} != counted {want}")
uuid = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ids = [x["id"] for x in docs]
if any(not uuid.match(i) for i in ids) or any(r["tenant_id"] != tenant for r in docs + items + revs):
    sys.exit("export carries a malformed doc id or another tenant's row")
json.dump({"tenant": tenant, "env": env, "docs": got[0], "items": got[1], "rev_log": got[2], "doc_ids": ids},
          open(os.path.join(d, "manifest.json"), "w"), indent=1)
PY
}

# spl_wsdoc_purge_manifest_counts <dir> -> "docs=<n> items=<n> rev_log=<n>"
# from manifest.json, after re-reading the three files against it. Fails when
# any file is missing, does not parse, or disagrees with the manifest.
spl_wsdoc_purge_manifest_counts() {
  python3 - "$1" <<'PY'
import json, os, sys
d = sys.argv[1]
try:
    m = json.load(open(os.path.join(d, "manifest.json")))
    n = [len(json.load(open(os.path.join(d, f)))) for f in ("docs.json", "items.json", "rev_log.json")]
except (OSError, ValueError) as e:
    sys.exit(f"export unreadable: {e}")
if n != [m["docs"], m["items"], m["rev_log"]] or len(m["doc_ids"]) != m["docs"]:
    sys.exit(f"export files {n} disagree with manifest.json")
print(f"docs={m['docs']} items={m['items']} rev_log={m['rev_log']}")
PY
}

# spl_wsdoc_purge_delete <dsn> <tenant> <dir>: the one delete transaction
# (see the header, step 2). Refuses, committing nothing, when the live counts
# differ from the manifest or a doc delete hits other than 1 row.
spl_wsdoc_purge_delete() {
  local dsn="$1" tenant="$2" dir="$3" sql out
  sql="$(spl_wsdoc_purge_delete_sql "$dir")" || { do_log "FATAL cannot build the delete from $dir/manifest.json"; return 1; }
  out="$(spl_pg_env "$dsn" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" -f - 2>&1 <<<"$sql")" ||
    { do_log "FATAL the delete failed, nothing was committed: $out"; return 1; }
  grep -qx 'MATCH' <<<"$out" ||
    { do_log "FATAL live counts of $tenant differ from the export in $dir ($(grep '^LIVE' <<<"$out")): nothing deleted, export again"; return 1; }
  grep -qx 'COMMITTED' <<<"$out" ||
    { do_log "FATAL the delete did not commit: $(grep -E '^(BAD|LEFT)' <<<"$out" | tr '\n' ' ')"; return 1; }
  do_log "OK deleted $(grep -c '^DEL ' <<<"$out") documents of $tenant"
}

# spl_wsdoc_purge_delete_sql <dir>: the psql script of the delete
# transaction, one DELETE per doc id of manifest.json. psql variable :tenant.
spl_wsdoc_purge_delete_sql() {
  python3 - "$1" <<'PY'
import json, os, re, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
uuid = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
if any(not uuid.match(i) for i in m["doc_ids"]):
    sys.exit("malformed doc id in manifest.json")
print(r"""BEGIN;
SET LOCAL app.rls_scope = 'operator';
SELECT count(*) AS live_docs FROM (SELECT 1 FROM workspace_doc WHERE tenant_id = :'tenant' FOR UPDATE) l \gset
SELECT count(*) AS live_items FROM workspace_doc_item WHERE tenant_id = :'tenant' \gset
SELECT count(*) AS live_revs FROM workspace_doc_rev_log WHERE tenant_id = :'tenant' \gset
SELECT 'LIVE docs=' || :live_docs || ' items=' || :live_items || ' rev_log=' || :live_revs;
SELECT :live_docs = %d AND :live_items = %d AND :live_revs = %d AS match \gset
\if :match
SELECT 'MATCH';
\else
ROLLBACK;
\q
\endif""" % (m["docs"], m["items"], m["rev_log"]))
for i in m["doc_ids"]:
    print(f"""WITH d AS (DELETE FROM workspace_doc WHERE tenant_id = :'tenant' AND id = '{i}' RETURNING id)
SELECT count(*) = 1 AS one FROM d \\gset
\\if :one
SELECT 'DEL {i}';
\\else
SELECT 'BAD {i}';
ROLLBACK;
\\q
\\endif""")
print(r"""SET CONSTRAINTS ALL IMMEDIATE;
SELECT (SELECT count(*) FROM workspace_doc WHERE tenant_id = :'tenant')
     + (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = :'tenant')
     + (SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = :'tenant') = 0 AS empty \gset
\if :empty
COMMIT;
SELECT 'COMMITTED';
\else
SELECT 'LEFT rows remain for the tenant';
ROLLBACK;
\endif""")
PY
}
