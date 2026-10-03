#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: print one workspace's agent vendor split (rdb 0109)
# @description as one line the orchestrator can read:
# @description   claude=40 grok=50 agy=10 qwen=0
# @description The four whole numbers are a guideline, not a quota. They sum
# @description to 100. The hub stores them and does not refuse a spawn that
# @description drifts; spawn routing reads this line. Through the Cloud SQL
# @description proxy as the env's project service account, one SELECT, values
# @description as psql variables. Prints no secret.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param SPL_SA_KEY (optional) - default the env project SA key; or set
# @param   GCP_SA_KEY_FILE, which do_gcp_pin_account reads
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_agent_split_show
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_agent_split_show
#------------------------------------------------------------------------------
do_spl_agent_split_show() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}"
  spl_require_tenant_slug "$tenant" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_agent_split_show_run "$tenant"
}

# _spl_agent_split_show_run <tenant> -> one "claude=N grok=N agy=N qwen=N" line.
# The tenant id travels as a psql variable. A row whose numbers are outside
# 0..100 or do not sum to 100 is a FATAL, not a line a router should trust.
_spl_agent_split_show_run() {
  local tenant="$1" out claude grok agy qwen sum
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT agent_split_claude::text || '|' || agent_split_grok::text || '|' ||
       agent_split_agy::text || '|' || agent_split_qwen::text
  FROM tenants WHERE tenant_id = :'tenant';
ROLLBACK;
SQL
)" || { do_log "FATAL agent split read of $tenant failed: ${out:-}"; return 1; }
  if [[ "$out" =~ ([0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+) ]]; then
    claude="${BASH_REMATCH[1]}"
    grok="${BASH_REMATCH[2]}"
    agy="${BASH_REMATCH[3]}"
    qwen="${BASH_REMATCH[4]}"
  else
    do_log "FATAL no agent split row for tenant $tenant"
    return 1
  fi
  if (( claude > 100 || grok > 100 || agy > 100 || qwen > 100 )); then
    do_log "FATAL agent split of $tenant is outside 0..100"
    return 1
  fi
  sum=$(( claude + grok + agy + qwen ))
  if (( sum != 100 )); then
    do_log "FATAL agent split of $tenant sums to $sum, not 100"
    return 1
  fi
  printf 'claude=%s grok=%s agy=%s qwen=%s\n' "$claude" "$grok" "$agy" "$qwen"
  do_log "OK agent split of $tenant on $SPL_SQL_CONN: claude=$claude grok=$grok agy=$agy qwen=$qwen (read-only, as $GCP_ACCOUNT)"
}
