#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: list a tenant's box-operator bindings (rdb 0040), one
# @description line each: tenant | box | human | granted_by | granted_at. Runs
# @description in BEGIN READ ONLY .. ROLLBACK in the tenant's RLS scope, as the
# @description env's project SA. Exit 2 when there is none.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param BOX_ID (optional) - only this box
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_box_operator_list
#------------------------------------------------------------------------------
do_spl_box_operator_list() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  spl_box_operator_args list || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_box_operator_list_run "$SPL_BOP_TENANT" "$SPL_BOP_BOX"
}

_spl_box_operator_list_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v box="$2" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT format('%s | %s | %s | %s | %s', tenant_id, box_id, human_id, granted_by, granted_at)
  FROM box_operators WHERE tenant_id = :'tenant' AND (:'box' = '' OR box_id = :'box')
 ORDER BY box_id, human_id;
ROLLBACK;
SQL
)" || { do_log "FATAL operator list for $1 failed: $out"; return 1; }
  local n
  n="$(grep -c ' | ' <<<"$out")"
  (( n > 0 )) || { do_log "FAIL no box operator in $1${2:+ on box $2}"; return 2; }
  printf '%s\n' "$out"
  do_log "OK $n box operator binding(s) in $1${2:+ on box $2} (read-only, as $GCP_ACCOUNT)"
}
