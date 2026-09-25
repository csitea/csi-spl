#!/bin/bash
#------------------------------------------------------------------------------
# @description Drop a box-operator binding (rdb 0040, the inverse of
# @description do_spl_box_operator_grant). From then on the hub refuses that
# @description human's typed_by on that box (typed_by_not_bound) and the mirror
# @description posts the line as the agent. Revoking an absent binding is a
# @description no-op that says so. Values travel as psql variables.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param BOX_ID - required: the box id
# @param HUMAN_ID - required: e.g. HUM-4
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 BOX_ID=box-a HUMAN_ID=HUM-4 DRY_RUN=0 ./run -a do_spl_box_operator_revoke
#------------------------------------------------------------------------------
do_spl_box_operator_revoke() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  spl_box_operator_args revoke || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would unbind $SPL_BOP_HUMAN as operator of box $SPL_BOP_BOX in $SPL_BOP_TENANT on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_box_operator_revoke_run "$SPL_BOP_TENANT" "$SPL_BOP_BOX" "$SPL_BOP_HUMAN"
}

_spl_box_operator_revoke_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v box="$2" -v human="$3" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
DELETE FROM box_operators WHERE tenant_id = :'tenant' AND box_id = :'box' AND human_id = :'human'
RETURNING format('%s | %s | %s', tenant_id, box_id, human_id);
COMMIT;
SQL
)" || { do_log "FATAL operator revoke of $3 on $2 in $1 failed: $out"; return 1; }
  if grep -q ' | ' <<<"$out"; then
    do_log "OK $1 box $2 operator $3 revoked ($GCP_ACCOUNT)"
  else
    do_log "OK $1 box $2 had no operator $3: nothing to revoke ($GCP_ACCOUNT)"
  fi
}
