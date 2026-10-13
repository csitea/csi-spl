#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1643 live proof that closing an epic closes and archives
# @description its issues on a deployed hub (issues-v1 section 9): sign the
# @description probe member in, file a test epic with 2 open issues, check the
# @description unconfirmed close is refused (409 epic_close_confirm, count 2),
# @description close it with cascade, check all 3 are archived (hidden from
# @description reads), unarchive the epic and check all 3 come back done, then
# @description archive the test tree again so the tenant's list stays clean.
# @description
# @description It WRITES three issues, so point it at a TEST tenant (dev t1).
# @description Unarchive needs an admin, so the login must hold
# @description tenant.settings. The password is read from a file and never
# @description printed. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (dev: t1)
# @param PROBE_EMAIL (optional) - default the file <state>/m3-e2e/<tenant>/probe/human-email
# @param PROBE_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/probe/pw-human
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_issue_epic_close_probe
#------------------------------------------------------------------------------
do_spl_issue_epic_close_probe() {
  do_require_bin yq python3 || return 1
  local tenant="${TENANT_ID:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: file a test epic with 2 open issues in $tenant on $ENV as the probe member, close it (refused, then with cascade), check all 3 archived, unarchive the epic, check all 3 restored, archive the tree again"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to prove it."
    return 0
  fi
  do_spl_cloud_cnf || return 1
  local dir="$SPL_STATE_DIR/m3-e2e/$tenant/probe" api fqdn email out rc=0
  local pw="${PROBE_PW_FILE:-$dir/pw-human}"
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE)"; return 1; }
  email="${PROBE_EMAIL:-}"
  [[ -n "$email" || ! -r "$dir/human-email" ]] || email="$(tr -d '[:space:]' <"$dir/human-email")"
  [[ -n "$email" ]] || { do_log "FATAL no probe login: set PROBE_EMAIL or write $dir/human-email"; return 1; }
  spl_cnf_api_fqdn api || return 1
  fqdn="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
  out="$(PROBE_API="https://$api" PROBE_AUTH="https://${fqdn:-$api}" PROBE_TENANT="$tenant" \
    PROBE_EMAIL="$email" PROBE_PW_FILE="$pw" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/issue-epic-close-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL epic-close probe on $ENV/$tenant (exit $rc)"; return 1; }
  do_log "OK epic-close probe on $ENV/$tenant: confirm refused, close archived the epic and its 2 issues, unarchive restored all 3"
}
