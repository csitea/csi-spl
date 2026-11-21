#!/bin/bash
#------------------------------------------------------------------------------
# @description End the native (email + password) sign-in lockout of one
# @description address: the 429 "too many attempts" of spec 015 FR-006b
# @description (SPL-6182 defect 5). The hub counts wrong sign-ins in its
# @description database (rdb 0308 native_login_failures), so the clear works
# @description on every hub instance at once and needs no redeploy: it runs
# @description `spool hub-clear-lockout` against the env's hub DB through a
# @description Cloud SQL proxy, as the env's project SA. It clears the count
# @description only; a forgotten password is do_spl_tenant_member_add or
# @description `spool hub-reset-password`. The email is never logged: the
# @description verdict carries the number of failures cleared.
# @description Dry run unless DRY_RUN=0; ENV=prd DRY_RUN=0 also needs OWNER_GO.
# @param ENV (required) - dev or prd
# @param LOCKOUT_EMAIL (required) - the locked address (lower-cased here)
# @param OWNER_GO (optional) - the owner's go message id; needed with ENV=prd DRY_RUN=0
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev LOCKOUT_EMAIL=person@example.com DRY_RUN=0 ./run -a do_spl_native_lockout_clear
# @example ENV=prd LOCKOUT_EMAIL=<email> OWNER_GO=<msg id> DRY_RUN=0 ./run -a do_spl_native_lockout_clear
#------------------------------------------------------------------------------
do_spl_native_lockout_clear() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local email="${LOCKOUT_EMAIL:-}" dry=1
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL LOCKOUT_EMAIL is not an email"; return 1; }
  email="${email,,}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )) && [[ "$ENV" == prd ]]; then
    [[ "${OWNER_GO:-}" =~ ^[0-9a-f]{8}([0-9a-f-]{28})?$ ]] ||
      { do_log "FATAL ENV=prd DRY_RUN=0 needs OWNER_GO, the owner's go message id"; return 1; }
  fi
  do_spl_cloud_cnf || return 1
  if (( dry )); then
    do_log "OK DRY_RUN would clear the counted wrong sign-ins of the given address on the $ENV hub DB ($SPL_SQL_CONN) via spool hub-clear-lockout. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_host_spool || return 1
  spl_via_proxy _spl_native_lockout_clear_run "$email"
}

# _spl_native_lockout_clear_run <email>: SPL_PROXY_DSN is the hub DB through
# the proxy (spl_via_proxy); SPL_SPOOL is the host binary spl_host_spool built.
_spl_native_lockout_clear_run() {
  local out rc=0
  out="$("$SPL_SPOOL" hub-clear-lockout --db "$SPL_PROXY_DSN" --email "$1" </dev/null 2>&1)" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL lockout clear on $ENV failed ($GCP_ACCOUNT): ${out//$1/<email>}"
    return 1
  fi
  do_log "OK lockout cleared on $ENV${OWNER_GO:+, owner go $OWNER_GO} ($GCP_ACCOUNT): $out"
}
