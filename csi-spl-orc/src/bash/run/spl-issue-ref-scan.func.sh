#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: find the old-prefix issue keys (e.g. SPL-44) left in
# @description a workspace after its issue prefix changed (csitea SPL -> CSI,
# @description owner HUM-10, csitea topic 26a21b5a, SPL-3570). Reads, inside
# @description one READ ONLY transaction as the env's project service account,
# @description the workspace's message bodies, its issues' titles and
# @description descriptions, and its workspace docs (doc tree titles and
# @description descriptions, doc item titles and bodies), then sorts each key
# @description into rewrite / keep / ambiguous / archived
# @description (src/bash/scripts/issue-ref-scan.py says how). Another workspace
# @description (t1) uses the same old prefix with its own numbers: its keys are
# @description never in the rewrite class. An archived or deleted issue's keys
# @description are archived: the hub cannot update that issue.
# @description Prints counts per source and class, SCAN_SAMPLES samples per
# @description class and every ambiguous and archived hit; writes the rewrite plan (ids and
# @description offsets, no text) to SCAN_PLAN. Writes nothing to the hub: a
# @description DRY_RUN other than 1 is refused (the writer is its own action).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug (e.g. csitea)
# @param OLD_PREFIX (optional) - the prefix the keys used before, default SPL
# @param SCAN_SAMPLES (optional) - samples per class, 1..100, default 10
# @param SCAN_PLAN (optional) - the plan file, default a new file under ${TMPDIR:-/tmp}
# @param DRY_RUN (optional) - only 1 (the default) is accepted
# @example ENV=prd TENANT_ID=csitea ./run -a do_spl_issue_ref_scan
# @example ENV=prd TENANT_ID=csitea OLD_PREFIX=SPL SCAN_SAMPLES=20 SCAN_PLAN=/var/tmp/csitea-refs.json ./run -a do_spl_issue_ref_scan
#------------------------------------------------------------------------------
do_spl_issue_ref_scan() {
  spl_issue_ref_scan_args || return 1
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local rows rc=0
  rows="$(mktemp)" || return 1
  spl_via_proxy _spl_issue_ref_scan_rows "$rows" || rc=$?
  if [[ $rc == 0 ]]; then
    spl_issue_ref_scan_classify <"$rows" || rc=$?
  fi
  rm -f "$rows"
  return $rc
}

# spl_issue_ref_scan_args -> checks TENANT_ID, OLD_PREFIX, SCAN_SAMPLES and
# DRY_RUN, and sets SCAN_PLAN. Every value interpolated into the SQL is
# matched against a strict pattern here first.
spl_issue_ref_scan_args() {
  [[ "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL do_spl_issue_ref_scan is read-only: DRY_RUN must be 1, got: '$DRY_RUN'"; return 1; }
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '${TENANT_ID:-}'"; return 1; }
  OLD_PREFIX="${OLD_PREFIX:-SPL}"
  [[ "$OLD_PREFIX" =~ ^[A-Z][A-Z0-9]{0,9}$ ]] || { do_log "FATAL OLD_PREFIX must be an issue prefix (A-Z then A-Z0-9, up to 10), got: '$OLD_PREFIX'"; return 1; }
  SCAN_SAMPLES="${SCAN_SAMPLES:-10}"
  [[ "$SCAN_SAMPLES" =~ ^[0-9]+$ ]] && (( SCAN_SAMPLES >= 1 && SCAN_SAMPLES <= 100 )) || { do_log "FATAL SCAN_SAMPLES must be 1..100, got: '$SCAN_SAMPLES'"; return 1; }
  if [[ -z "${SCAN_PLAN:-}" ]]; then
    SCAN_PLAN="$(mktemp "${TMPDIR:-/tmp}/issue-ref-scan.$TENANT_ID.XXXXXX.json")" || return 1
  fi
}

# _spl_issue_ref_scan_rows <file> -> the JSON lines the classifier reads, into
# <file>: one meta row (prefix, counter, live numbers), then one row per text
# field that holds an old-prefix key.
_spl_issue_ref_scan_rows() {
  local out
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -c 'BEGIN TRANSACTION READ ONLY' \
      -c "SET LOCAL app.rls_scope = 'operator'" \
      -c "$(spl_issue_ref_scan_sql "$TENANT_ID" "$OLD_PREFIX")" -c 'ROLLBACK' </dev/null 2>&1)" \
    || { do_log "FATAL the read-only scan of $TENANT_ID in $ENV failed: $out"; return 1; }
  printf '%s\n' "$out" >"$1"
}

# spl_issue_ref_scan_sql <tenant> <old> -> the one SELECT (both checked by
# spl_issue_ref_scan_args).
spl_issue_ref_scan_sql() {
  local t="$1" rx="$2-[0-9]"
  cat <<EOF_SQL
SELECT json_build_object('src', 'meta', 'tenant', '$t',
  'prefix', (SELECT prefix FROM issue_counters WHERE tenant_id = '$t'),
  'last_number', (SELECT last_number FROM issue_counters WHERE tenant_id = '$t'),
  'numbers', (SELECT coalesce(json_agg(number ORDER BY number), '[]'::json) FROM issues WHERE tenant_id = '$t'))
UNION ALL SELECT json_build_object('src', 'msg', 'id', msg_id, 'field', 'body', 'text', body)
  FROM messages WHERE tenant_id = '$t' AND body ~ '$rx'
UNION ALL SELECT json_build_object('src', 'issue', 'id', number, 'field', 'title', 'text', title,
    'archived', archived_at IS NOT NULL OR deleted_at IS NOT NULL)
  FROM issues WHERE tenant_id = '$t' AND title ~ '$rx'
UNION ALL SELECT json_build_object('src', 'issue', 'id', number, 'field', 'description', 'text', description,
    'archived', archived_at IS NOT NULL OR deleted_at IS NOT NULL)
  FROM issues WHERE tenant_id = '$t' AND description ~ '$rx'
UNION ALL SELECT json_build_object('src', 'doc_item', 'id', id, 'field', 'title', 'text', title)
  FROM workspace_doc_item WHERE tenant_id = '$t' AND title ~ '$rx'
UNION ALL SELECT json_build_object('src', 'doc_item', 'id', id, 'field', 'body', 'text', body)
  FROM workspace_doc_item WHERE tenant_id = '$t' AND body ~ '$rx'
UNION ALL SELECT json_build_object('src', 'doc_node', 'id', id, 'field', 'title', 'text', title)
  FROM workspace_doc_node WHERE tenant_id = '$t' AND title ~ '$rx'
UNION ALL SELECT json_build_object('src', 'doc_node', 'id', id, 'field', 'description', 'text', description)
  FROM workspace_doc_node WHERE tenant_id = '$t' AND description ~ '$rx'
EOF_SQL
}

# spl_issue_ref_scan_classify - the JSON lines on stdin -> the report; the plan
# goes to SCAN_PLAN.
spl_issue_ref_scan_classify() {
  local rc=0
  python3 "$PROJ_PATH/src/bash/scripts/issue-ref-scan.py" --old "$OLD_PREFIX" \
    --samples "$SCAN_SAMPLES" --plan "$SCAN_PLAN" || rc=$?
  [[ $rc == 0 ]] || { do_log "FATAL the classifier refused the scan of $TENANT_ID (exit $rc)"; return 1; }
  do_log "OK read-only scan of $TENANT_ID in ${ENV:-}: nothing written; rewrite plan $SCAN_PLAN"
}
