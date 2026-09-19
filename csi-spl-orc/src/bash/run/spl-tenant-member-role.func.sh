#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one tenant member's role in a cloud env's hub DB (owner or
# @description member), through the Cloud SQL proxy as the env's project
# @description service account. Harvested from the 2026-09-19 hand UPDATE that
# @description demoted a test account the bootstrap had made owner of dev t1
# @description (t1-owner.sh, adhoc-harvest.md). Values travel as psql variables
# @description (:'var', quoted by psql), never spliced into the SQL. Exactly one
# @description row must change, or the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param HUMAN_ID - required: e.g. HUM-4
# @param MEMBER_ROLE - required: owner or member
# @param FROM_ROLE (optional) - only change the row while it holds this role
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 HUMAN_ID=HUM-4 MEMBER_ROLE=member FROM_ROLE=owner DRY_RUN=0 ./run -a do_spl_tenant_member_role
#------------------------------------------------------------------------------
do_spl_tenant_member_role() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" human="${HUMAN_ID:-}" role="${MEMBER_ROLE:-}" from="${FROM_ROLE:-}" dry=1
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$human" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  [[ "$role" == owner || "$role" == member ]] || { do_log "FATAL MEMBER_ROLE must be owner or member, got: '$role'"; return 1; }
  [[ -z "$from" || "$from" == owner || "$from" == member ]] || { do_log "FATAL FROM_ROLE must be owner or member, got: '$from'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set $human in $tenant to $role${from:+ (only while $from)} on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_member_role_run "$tenant" "$human" "$role" "$from"
}

_spl_tenant_member_role_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v human="$2" -v role="$3" -v from="$4" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE tenant_memberships SET role = :'role'
 WHERE tenant_id = :'tenant' AND human_id = :'human' AND (:'from' = '' OR role = :'from')
RETURNING format('%s | %s | %s | %s', tenant_id, human_id, role, admitted_by);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL role update of $2 in $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched $2 in $1${4:+ with role $4}: rolled back"; return 1; }
  do_log "OK $1 member $2 is now $3 ($GCP_ACCOUNT): $out"
}
