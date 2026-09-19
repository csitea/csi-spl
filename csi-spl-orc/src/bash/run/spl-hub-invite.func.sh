#!/bin/bash
#------------------------------------------------------------------------------
# @description Invite a human to a cloud tenant: `spool hub-invite` against the
# @description hub DB through the Cloud SQL proxy, as the env's project service
# @description account (do_gcp_pin_account: its key, never the owner account).
# @description The first
# @description OWNER of a tenant is seated this way, BEFORE anyone signs in:
# @description on a zero-member tenant a first sign-in becomes the bootstrap
# @description owner (010 OQ-A5). Harvested from the 2026-09-19 t1-owner.sh /
# @description prd-hub-invite.sh (adhoc-harvest.md). The DSN is never logged.
# @description DRY_RUN=1 (default): print the invite, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param INVITE_EMAIL - required: the human's email
# @param INVITE_ROLE (optional) - owner or member (default member)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=prd TENANT_ID=t1 INVITE_EMAIL=<owner-email> INVITE_ROLE=owner DRY_RUN=0 ./run -a do_spl_hub_invite
#------------------------------------------------------------------------------
do_spl_hub_invite() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" email="${INVITE_EMAIL:-}" role="${INVITE_ROLE:-member}" dry=1
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL INVITE_EMAIL is not an email: '$email'"; return 1; }
  [[ "$role" == owner || "$role" == member ]] || { do_log "FATAL INVITE_ROLE must be owner or member, got: '$role'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would invite $email to $tenant as $role on $SPL_SQL_CONN, as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_host_spool || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_hub_invite_run "$tenant" "$email" "$role"
}

_spl_hub_invite_run() {
  local out rc=0
  out="$(SPOOL_HUB_DB_DSN="$SPL_PROXY_DSN" "$SPL_SPOOL" hub-invite --tenant "$1" --email "$2" --role "$3" 2>&1)" || rc=$?
  (( rc == 0 )) || { do_log "FATAL hub-invite $2 to $1 as $3: $out"; return 1; }
  do_log "OK invited $2 to $1 as $3 ($GCP_ACCOUNT): $out"
}
