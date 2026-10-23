#!/bin/bash
#------------------------------------------------------------------------------
# @description Daily backup of each workspace's Qto docs into THAT workspace's
# @description own docs bucket (step 052, <bucket_prefix><tenant>), under
# @description backup/<yyyy-mm-dd>/: spec 114 section 9.5, tasks R6. Run by
# @description wf 45 after its whole-database dump; the 052 lifecycle rule
# @description deletes backup/ after cnf backup_retention_days.
# @description One workspace at a time: per workspace one READ ONLY,
# @description REPEATABLE READ transaction in the operator row-level-security
# @description scope (rdb 0157) reads its rows of workspace_doc,
# @description workspace_doc_item and workspace_doc_node (every WHERE names
# @description that tenant) plus their counts from the same snapshot. Tenant
# @description `system` (the repo docs) is skipped: it has no 052 bucket.
# @description Files per workspace, as JSON lines (row_to_json, lossless, an
# @description SQL copy restores them): docs.jsonl, items.jsonl, nodes.jsonl,
# @description assets.tsv (doc id, path, sha256 of every root's attrs.assets)
# @description and manifest.json (tenant, date, counts, sha256 per file),
# @description uploaded last.
# @description Refused, per workspace: a bucket other than <bucket_prefix> +
# @description that tenant (wrong-bucket), a missing bucket (no-bucket), and
# @description an exported row of another tenant (foreign-row).
# @description Restore-read check after the upload: the objects are downloaded
# @description again from that bucket only; the docs, items and nodes counted
# @description there must equal the database counts (count-docs, count-items,
# @description count-nodes) and each file's sha256 its manifest's.
# @description One line per workspace, then a summary; exit 1 on any FAIL.
# @description Prints slugs and counts only, never a doc's text; the rows sit
# @description in a private temp dir removed on return. gcloud runs as the
# @description env's project service account (do_gcp_pin_account), --account
# @description on every call.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) export and check locally, upload nothing; 0 upload
# @param TENANT_ID (optional) - this workspace only; default every workspace with a doc
# @param WSDOC_BACKUP_DATE (optional) - the yyyy-mm-dd prefix; default today (UTC)
# @example ENV=dev ./run -a do_spl_wsdoc_backup
# @example ENV=dev DRY_RUN=0 TENANT_ID=t1 ./run -a do_spl_wsdoc_backup
#------------------------------------------------------------------------------
do_spl_wsdoc_backup() {
  local dry=1 day="${WSDOC_BACKUP_DATE:-$(date -u +%F)}" only="${TENANT_ID:-}"
  spl_require_cloud_env || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { do_log "FATAL WSDOC_BACKUP_DATE must be yyyy-mm-dd, got: $day"; return 1; }
  [[ -z "$only" ]] || _spl_wsdoc_backup_slug_ok "$only" || { do_log "FATAL TENANT_ID is not a workspace slug (system has no 052 bucket): $only"; return 1; }
  do_require_bin gcloud yq jq psql sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local bprefix
  bprefix="$(yq -r '.env.steps."052-gcs-workspace-docs".bucket_prefix // ""' "$SPL_CNF")"
  [[ -n "$bprefix" && "$bprefix" != null ]] || { do_log "FATAL cnf steps.052-gcs-workspace-docs.bucket_prefix is empty for $ENV: no workspace docs buckets"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local work
  work="$(mktemp -d)" || return 1
  chmod 700 "$work"
  trap 'rm -rf "$work"; trap - RETURN' RETURN
  do_log "INFO ENV=$ENV bucket_prefix=$bprefix date=$day GCP_ACCOUNT=$GCP_ACCOUNT tenant=${only:-all} dry_run=$dry"
  WSDOC_BPREFIX="$bprefix" WSDOC_DAY="$day" WSDOC_ONLY="$only" WSDOC_DRY="$dry" \
    spl_via_proxy _spl_wsdoc_backup_all "$work"
}

# _spl_wsdoc_backup_slug_ok <slug>: a workspace slug, and not `system`.
_spl_wsdoc_backup_slug_ok() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$1" != system ]]
}

# _spl_wsdoc_backup_all <work> -> one verdict line per workspace and the
# summary; 1 on any FAIL. Inside spl_via_proxy (SPL_PROXY_DSN set).
_spl_wsdoc_backup_all() {
  local work="$1" tenants t v ok=0 would=0 failed=0
  if [[ -n "$WSDOC_ONLY" ]]; then
    tenants="$WSDOC_ONLY"
  else
    _spl_wsdoc_backup_psql "" "\\o '$work/tenants'
SELECT tenant_id FROM workspace_doc WHERE tenant_id <> 'system' GROUP BY 1 ORDER BY 1;" ||
      { do_log "FATAL ENV=$ENV: the hub DB read failed (workspace list)"; return 1; }
    tenants="$(cat "$work/tenants" 2>/dev/null)"
  fi
  while read -r t; do
    [[ -n "$t" ]] || continue
    if _spl_wsdoc_backup_slug_ok "$t"; then
      mkdir -m 700 "$work/w-$t" || return 1
      v="$(_spl_wsdoc_backup_one "$t" "$WSDOC_BPREFIX$t" "$work/w-$t")"
      rm -rf "${work:?}/w-$t"
    else
      v="FAIL bad-slug"
    fi
    do_log "${v%% *} $ENV $t gs://$WSDOC_BPREFIX$t/backup/$WSDOC_DAY/${v#"${v%% *}"}"
    case "$v" in
      ok*) ok=$((ok + 1)) ;;
      would-write*) would=$((would + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done <<<"$tenants"
  local sum="workspaces=$((ok + would + failed)) ok=$ok would_write=$would failed=$failed"
  ((failed == 0)) || { do_log "FATAL ENV=$ENV wsdoc backup $WSDOC_DAY: $sum"; return 1; }
  ((WSDOC_DRY == 0)) || { do_log "OK DRY RUN ENV=$ENV wsdoc backup $WSDOC_DAY: $sum; nothing uploaded, DRY_RUN=0 to upload"; return 0; }
  do_log "OK ENV=$ENV wsdoc backup $WSDOC_DAY: $sum"
}

# _spl_wsdoc_backup_one <tenant> <bucket> <dir> -> one verdict:
# ok <counts> | would-write <counts> | FAIL <why>.
_spl_wsdoc_backup_one() {
  local t="$1" b="$2" d="$3" counts why
  _spl_wsdoc_backup_bucket_is "$t" "$b" || { echo "FAIL wrong-bucket gs://$b"; return 0; }
  gcloud storage buckets describe "gs://$b" --account="$GCP_ACCOUNT" --format='value(name)' >/dev/null 2>&1 ||
    { echo "FAIL no-bucket"; return 0; }
  _spl_wsdoc_backup_export "$t" "$d" || { echo "FAIL export"; return 0; }
  _spl_wsdoc_backup_own "$t" "$d" || { echo "FAIL foreign-row"; return 0; }
  _spl_wsdoc_backup_manifest "$t" "$d" || { echo "FAIL manifest"; return 0; }
  counts="$(jq -r '"docs=\(.docs) items=\(.items) nodes=\(.nodes) assets=\(.assets)"' "$d/manifest.json")"
  ((WSDOC_DRY == 0)) || { echo "would-write $counts"; return 0; }
  _spl_wsdoc_backup_put "$t" "$b" "$d" || { echo "FAIL put"; return 0; }
  why="$(_spl_wsdoc_backup_check "$t" "$b" "$d")" || { echo "FAIL $why"; return 0; }
  echo "ok $counts"
}

# _spl_wsdoc_backup_bucket_is <tenant> <bucket>: the bucket is THAT
# workspace's own 052 bucket, nothing else.
_spl_wsdoc_backup_bucket_is() {
  [[ -n "${WSDOC_BPREFIX:-}" && "$2" == "$WSDOC_BPREFIX$1" ]]
}

# _spl_wsdoc_backup_psql <tenant> <script> -> runs the script (its psql \o
# lines write the files) in one READ ONLY, REPEATABLE READ transaction in the
# operator scope, the tenant as the psql variable :'t'.
_spl_wsdoc_backup_psql() {
  printf '%s\n' "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;" \
    "SET LOCAL app.rls_scope = 'operator';" "$2" '\o' 'ROLLBACK;' |
    PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
      psql -X -q -At -v ON_ERROR_STOP=1 -v t="$1" -f - >/dev/null 2>&1
}

# _spl_wsdoc_backup_export <tenant> <dir> -> docs.jsonl, items.jsonl,
# nodes.jsonl and counts ("<docs> <items> <nodes>") from one snapshot.
_spl_wsdoc_backup_export() {
  local d="$2" f
  _spl_wsdoc_backup_psql "$1" "\\o '$d/docs.jsonl'
SELECT row_to_json(x) FROM workspace_doc x WHERE x.tenant_id = :'t' ORDER BY x.id;
\\o '$d/items.jsonl'
SELECT row_to_json(x) FROM workspace_doc_item x WHERE x.tenant_id = :'t' ORDER BY x.doc_id, x.id;
\\o '$d/nodes.jsonl'
SELECT row_to_json(x) FROM workspace_doc_node x WHERE x.tenant_id = :'t' ORDER BY x.lft;
\\o '$d/counts'
SELECT (SELECT count(*) FROM workspace_doc WHERE tenant_id = :'t') || ' ' || (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = :'t') || ' ' || (SELECT count(*) FROM workspace_doc_node WHERE tenant_id = :'t');" || return 1
  for f in docs.jsonl items.jsonl nodes.jsonl; do touch "$d/$f"; done
  [[ "$(cat "$d/counts" 2>/dev/null)" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]
}

# _spl_wsdoc_backup_own <tenant> <dir>: every row of every file is that
# tenant's (an empty file passes).
_spl_wsdoc_backup_own() {
  local f other
  for f in docs.jsonl items.jsonl nodes.jsonl; do
    other="$(jq -r --arg t "$1" 'select(.tenant_id != $t) | "x"' "$2/$f" 2>/dev/null)" || return 1
    [[ -z "$other" ]] || return 1
  done
}

# _spl_wsdoc_backup_manifest <tenant> <dir> -> assets.tsv and manifest.json.
_spl_wsdoc_backup_manifest() {
  local t="$1" d="$2" docs items nodes f sums="{}"
  jq -r 'select(.parent_id == null) | .doc_id as $doc
    | (if (.attrs.assets | type) == "object" then .attrs.assets else {} end)
    | to_entries[] | [$doc, .key, (.value | tostring)] | @tsv' "$d/items.jsonl" >"$d/assets.tsv" || return 1
  read -r docs items nodes <"$d/counts"
  for f in docs.jsonl items.jsonl nodes.jsonl assets.tsv; do
    sums="$(jq -c --arg f "$f" --arg s "$(sha256sum "$d/$f" | awk '{ print $1 }')" '. + {($f): $s}' <<<"$sums")" || return 1
  done
  jq -n --arg t "$t" --arg e "$ENV" --arg day "$WSDOC_DAY" --argjson docs "$docs" --argjson items "$items" \
    --argjson nodes "$nodes" --argjson assets "$(grep -c . "$d/assets.tsv")" --argjson sha256 "$sums" \
    '{tenant: $t, env: $e, date: $day, docs: $docs, items: $items, nodes: $nodes, assets: $assets, sha256: $sha256}' \
    >"$d/manifest.json"
}

# _spl_wsdoc_backup_put <tenant> <bucket> <dir>: uploads the files, the
# manifest last; refuses any bucket but the tenant's own before any call.
_spl_wsdoc_backup_put() {
  local t="$1" b="$2" d="$3" f
  _spl_wsdoc_backup_bucket_is "$t" "$b" ||
    { do_log "FATAL refused: the backup of $t goes to gs://${WSDOC_BPREFIX:-}$t only, not gs://$b" >&2; return 1; }
  [[ "$(jq -r .tenant "$d/manifest.json" 2>/dev/null)" == "$t" ]] || { do_log "FATAL refused: the manifest is not $t's" >&2; return 1; }
  for f in docs.jsonl items.jsonl nodes.jsonl assets.tsv manifest.json; do
    gcloud storage cp "$d/$f" "gs://$b/backup/$WSDOC_DAY/$f" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 || return 1
  done
}

# _spl_wsdoc_backup_check <tenant> <bucket> <dir> -> reads the backup back
# from that bucket only; prints the first failure and returns 1.
_spl_wsdoc_backup_check() {
  local t="$1" b="$2" back="$3/back" f docs items nodes n
  mkdir -m 700 "$back" || { echo "check-tmp"; return 1; }
  for f in manifest.json docs.jsonl items.jsonl nodes.jsonl assets.tsv; do
    gcloud storage cp "gs://$b/backup/$WSDOC_DAY/$f" "$back/$f" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      { echo "check-unreadable $f"; return 1; }
  done
  [[ "$(jq -r .tenant "$back/manifest.json" 2>/dev/null)" == "$t" ]] || { echo "check-manifest"; return 1; }
  read -r docs items nodes <"$3/counts"
  for f in docs:"$docs" items:"$items" nodes:"$nodes"; do
    n="$(grep -c . "$back/${f%%:*}.jsonl")"
    [[ "$n" == "${f#*:}" ]] || { echo "count-${f%%:*} restored=$n db=${f#*:}"; return 1; }
  done
  _spl_wsdoc_backup_own "$t" "$back" || { echo "check-foreign-row"; return 1; }
  for f in docs.jsonl items.jsonl nodes.jsonl assets.tsv; do
    [[ "$(sha256sum "$back/$f" | awk '{ print $1 }')" == "$(jq -r --arg f "$f" '.sha256[$f]' "$back/manifest.json")" ]] ||
      { echo "check-sha256 $f"; return 1; }
  done
}
