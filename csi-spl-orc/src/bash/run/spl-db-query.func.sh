#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY query of a cloud env's hub DB: one SQL statement (or
# @description one psql \d describe) through the Cloud SQL proxy, as the env's
# @description project service account, inside a READ ONLY transaction that is
# @description rolled back: Postgres itself refuses any write. Harvested from
# @description the 2026-09-19 d-tenants.sh, the membership reads of
# @description t1-owner.sh and a raw proxied psql (adhoc-harvest.md).
# @description ONE statement only: a ';' before the end is refused (so is one
# @description inside a string literal), so the statement cannot COMMIT out of
# @description the read-only transaction. The DSN is never printed.
# @param ENV - required: dev or prd
# @param SQL - required: a single SELECT / \d statement
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev SQL="select tenant_id, human_id, role, admitted_by from tenant_memberships where tenant_id='t1'" ./run -a do_spl_db_query
# @example ENV=prd SQL='\d tenants' ./run -a do_spl_db_query
#------------------------------------------------------------------------------
do_spl_db_query() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local sql="${SQL:-}"
  sql="${sql%"${sql##*[![:space:]]}"}"; sql="${sql%;}"
  [[ -n "$sql" ]] || { do_log "FATAL SQL is required"; return 1; }
  [[ "$sql" != *";"* ]] || { do_log "FATAL SQL must be ONE statement (no ';' before the end)"; return 1; }
  if [[ "$sql" == \\* ]]; then
    [[ "$sql" =~ ^\\d[a-zA-Z+]*([[:space:]]+[A-Za-z0-9_.*\"]+)?$ ]] || { do_log "FATAL only a \\d describe is allowed as a psql meta-command"; return 1; }
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_db_query_run "$sql"
}

_spl_db_query_run() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off -c 'BEGIN TRANSACTION READ ONLY' -c "$1" -c 'ROLLBACK'
}
