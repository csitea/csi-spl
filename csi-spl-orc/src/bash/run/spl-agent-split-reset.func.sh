#!/bin/bash
#------------------------------------------------------------------------------
# @description Drop one workspace's saved per-kind vendor split (rdb 0163), so
# @description the kind falls back to the cnf env.box.agent_split_by_kind row.
# @description The same effect as PATCH /v1/agent-split {kinds:{<k>:null}}
# @description (store SetSplitKinds: DELETE ... WHERE tenant_id AND kind).
# @description DRY_RUN=1 (default) prints the rows it would delete, read-only.
# @description DRY_RUN=0 deletes them in one transaction and prints each
# @description kind's do_spl_agent_split_show line before and after (after:
# @description source=cnf). Through the Cloud SQL proxy as the env's project
# @description service account; tenant and kinds travel as psql variables.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param --kind <k> - required, repeatable: specs_and_docs, tests,
# @param   simple_coding, complex_coding, i18n, secret or orchestration (the
# @param   picker's aliases spec, hard and default are read as in the show)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_agent_split_reset --kind simple_coding --kind tests
# @example ENV=prd TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_agent_split_reset --kind simple_coding --kind tests
#------------------------------------------------------------------------------
do_spl_agent_split_reset() {
  local -a kinds=()
  local k
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) k="${2:-}"; shift 2 || { do_log "FATAL --kind needs a value"; return 1; } ;;
      --kind=*) k="${1#--kind=}"; shift ;;
      *) shift; continue ;;
    esac
    [[ -n "$k" ]] || { do_log "FATAL --kind needs a value"; return 1; }
    _spl_agent_split_kind "$k" || return 1
    [[ " ${kinds[*]} " == *" $SPL_SPLIT_KIND "* ]] || kinds+=("$SPL_SPLIT_KIND")
  done
  (( ${#kinds[@]} )) || { do_log "FATAL name at least one --kind to reset"; return 1; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}"
  spl_require_tenant_slug "$tenant" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( dry )); then
    spl_via_proxy _spl_agent_split_reset_dry "$tenant" "${kinds[@]}"
  else
    spl_via_proxy _spl_agent_split_reset_run "$tenant" "${kinds[@]}"
  fi
}

# _spl_agent_split_reset_dry <tenant> <kind>... -> one line per stored row
# that DRY_RUN=0 would delete, "tenant|kind|vendor|weight|is_backup", read-only.
_spl_agent_split_reset_dry() {
  local tenant="$1" out csv; shift
  csv="$(IFS=,; echo "$*")"
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" -v kinds="$csv" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT tenant_id || '|' || kind || '|' || vendor || '|' || weight::text || '|' || is_backup::text
  FROM tenant_agent_split_kind
 WHERE tenant_id = :'tenant' AND kind = ANY(string_to_array(:'kinds', ','))
 ORDER BY kind, vendor;
ROLLBACK;
SQL
)" || { do_log "FATAL agent split reset read of $tenant failed: ${out:-}"; return 1; }
  if [[ -z "$out" ]]; then
    do_log "OK DRY_RUN $tenant has no saved split for $csv: nothing to delete (as $GCP_ACCOUNT)"
    return 0
  fi
  sed 's/^/would delete /' <<<"$out"
  do_log "OK DRY_RUN would delete $(wc -l <<<"$out") row(s) of $tenant kinds $csv on $SPL_SQL_CONN. Re-run with DRY_RUN=0. (as $GCP_ACCOUNT)"
}

# _spl_agent_split_reset_run <tenant> <kind>... -> each kind's show line
# before, the DELETE in one transaction, each kind's show line after; the
# show's log line names the source (after the reset: source=cnf).
_spl_agent_split_reset_run() {
  local tenant="$1" out csv k; shift
  csv="$(IFS=,; echo "$*")"
  for k in "$@"; do
    echo "before $k:"
    _spl_agent_split_kind_run "$tenant" "$k" || return 1
  done
  out="$(spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" -v kinds="$csv" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
DELETE FROM tenant_agent_split_kind
 WHERE tenant_id = :'tenant' AND kind = ANY(string_to_array(:'kinds', ','))
RETURNING tenant_id || '|' || kind || '|' || vendor || '|' || weight::text || '|' || is_backup::text;
COMMIT;
SQL
)" || { do_log "FATAL agent split reset of $tenant kinds $csv failed: ${out:-}"; return 1; }
  [[ -n "$out" ]] && sed 's/^/deleted /' <<<"$out"
  do_log "OK deleted $(grep -c '|' <<<"$out") row(s) of $tenant kinds $csv on $SPL_SQL_CONN (as $GCP_ACCOUNT)"
  for k in "$@"; do
    echo "after $k:"
    _spl_agent_split_kind_run "$tenant" "$k" || return 1
  done
}
