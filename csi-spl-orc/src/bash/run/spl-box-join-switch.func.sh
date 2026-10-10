#!/bin/bash
#------------------------------------------------------------------------------
# @description Turn spec 108 box joining (join tokens, spec 073) on or off for
# @description ONE workspace in a cloud env's hub DB: tenants.box_join_enabled
# @description (rdb 0170, spec 108 section 3.8, owner msg 9bdc5980). OFF, the
# @description default for every workspace: the hub refuses to mint and to
# @description redeem a join token; boxes already seated keep working. ON: the
# @description workspace is restricted, it takes dedicated boxes only. The
# @description operator's switch: no workspace admin can flip it. Through the
# @description Cloud SQL proxy as the env's project service account; values
# @description travel as psql variables. Exactly one row must change, or the
# @description transaction is rolled back. The hub route for the same switch
# @description is PATCH /v1/operator/workspaces/{id} {"box_join_enabled": ...}.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param BOX_JOIN - required: on or off
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=acme BOX_JOIN=on DRY_RUN=0 ./run -a do_spl_box_join_switch
#------------------------------------------------------------------------------
do_spl_box_join_switch() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" on dry=1
  spl_require_tenant_slug "$tenant" || return 1
  case "${BOX_JOIN:-}" in
    on) on=true ;;
    off) on=false ;;
    *) do_log "FATAL BOX_JOIN must be on or off, got: '${BOX_JOIN:-}'"; return 1 ;;
  esac
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would turn box joining ${BOX_JOIN} for $tenant on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_box_join_switch_run "$tenant" "$on"
}

_spl_box_join_switch_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v on="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE tenants SET box_join_enabled = :'on'::boolean
 WHERE tenant_id = :'tenant'
RETURNING format('%s | %s', tenant_id, box_join_enabled);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL box join switch of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched workspace $1: rolled back"; return 1; }
  do_log "OK $1 box joining is now $([[ "$2" == true ]] && echo on || echo off) ($GCP_ACCOUNT): $out"
}
