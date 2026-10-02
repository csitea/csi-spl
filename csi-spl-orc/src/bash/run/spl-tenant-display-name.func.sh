#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one tenant's display name in a cloud env's hub DB (the
# @description label the WUI tenant drop box shows). The tenant id is not
# @description changed. Through the Cloud SQL proxy as the env's project
# @description service account. Values travel as psql variables (:'var'),
# @description never spliced into the SQL. Exactly one row must change, or
# @description the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param DISPLAY_NAME - required: the name to show, 1..200 characters, one line
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DISPLAY_NAME=csitea DRY_RUN=0 ./run -a do_spl_tenant_display_name
#------------------------------------------------------------------------------
do_spl_tenant_display_name() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" name dry=1
  spl_require_tenant_slug "$tenant" || return 1
  name="$(printf '%s' "${DISPLAY_NAME-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$name" && ${#name} -le 200 && "$name" != *$'\n'* && "$name" != *$'\r'* ]] \
    || { do_log "FATAL DISPLAY_NAME must be one line of 1..200 characters, got: '${DISPLAY_NAME-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set the display name of $tenant to $name on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_display_name_run "$tenant" "$name"
}

_spl_tenant_display_name_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v name="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE tenants SET display_name = :'name'
 WHERE tenant_id = :'tenant'
RETURNING format('%s | %s', tenant_id, display_name);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL display name update of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched tenant $1: rolled back"; return 1; }
  do_log "OK $1 display name is now $2 ($GCP_ACCOUNT): $out"
}
