#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one tenant's place in the WUI tenant drop box (rdb 0051,
# @description SPL-71) in a cloud env's hub DB: 1 is first; tenants with no
# @description place follow, by tenant id. SORT_ORDER=none clears it. Through
# @description the Cloud SQL proxy as the env's project service account.
# @description Values travel as psql variables (:'var'), never spliced into
# @description the SQL. Exactly one row must change, or the transaction is
# @description rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param SORT_ORDER - required: 1..100000, or none
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 SORT_ORDER=1 DRY_RUN=0 ./run -a do_spl_tenant_sort_order
#------------------------------------------------------------------------------
do_spl_tenant_sort_order() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" order="${SORT_ORDER:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  if [[ "$order" == none ]]; then order=''
  elif [[ "$order" =~ ^[1-9][0-9]{0,5}$ ]] && (( order <= 100000 )); then :
  else do_log "FATAL SORT_ORDER must be 1..100000 or none, got: '${SORT_ORDER:-}'"; return 1; fi
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set the sort order of $tenant to ${order:-none} on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_sort_order_run "$tenant" "$order"
}

_spl_tenant_sort_order_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v ord="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE tenants SET sort_order = NULLIF(:'ord', '')::integer
 WHERE tenant_id = :'tenant'
RETURNING format('%s | %s', tenant_id, coalesce(sort_order::text, 'none'));
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL sort order update of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched tenant $1: rolled back"; return 1; }
  do_log "OK $1 sort order is now ${2:-none} ($GCP_ACCOUNT): $out"
}
