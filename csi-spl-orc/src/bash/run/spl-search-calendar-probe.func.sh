#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-6251: does the search box find a calendar entry, as a member
# @description sees it? Signs one tenant member in on the env's API host
# @description (env.dns.api_fqdn), makes ONE throwaway calendar entry (audience
# @description workspace, tomorrow) whose title holds a fresh random word, then:
# @description type:calendar with it, type:cal with it (both find it), and
# @description type:event with it (the event log: no calendar section), and
# @description deletes the entry again. Exit 0 = every search showed what it
# @description should; non-zero = a miss, printed per search with its status
# @description and hit counts (spec 100 section 16). Writes only that one
# @description entry, as the member, and deletes it; dry run unless DRY_RUN=0.
# @description The password is read from a file and never printed.
# @param ENV (required) - dev or prd
# @param TENANT_ID (required) - the tenant slug
# @param PROBE_EMAIL (optional) - default <pw dir>/human-email, else m3-e2e-human@example.com
# @param PROBE_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_NONCE (optional) - the random word's seed, default a fresh one
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_search_calendar_probe
#------------------------------------------------------------------------------
do_spl_search_calendar_probe() {
  do_require_bin yq python3 || return 1
  local tenant="${TENANT_ID:-}" api dry=1
  declare -F spl_search_doc_probe_check >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-search-doc-probe.func.sh"
  spl_search_doc_probe_check "$tenant" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_cnf_api_fqdn api || return 1
  local st="$SPL_STATE_DIR/m3-e2e/$tenant" out rc=0
  local pw="${PROBE_PW_FILE:-$st/pw-human}" email="${PROBE_EMAIL:-}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: sign a member of $tenant in on https://$api, make one calendar entry with a random word, search it (type:calendar, type:cal, type:event) and delete it"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to probe."
    return 0
  fi
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE)"; return 1; }
  [[ -n "$email" ]] || email="$(cat "$(dirname "$pw")/human-email" 2>/dev/null)"
  [[ -n "$email" ]] || email="m3-e2e-human@example.com"
  printf '===== search calendar probe: env=%s tenant=%s\n' "$ENV" "$tenant"
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="$email" PROBE_PW_FILE="$pw" \
    PROBE_NONCE="${PROBE_NONCE:-}" python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/search-calendar-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL search calendar probe on $ENV/$tenant (exit $rc): the search box does not find the calendar entry as it should"; return 1; }
  do_log "OK search calendar probe on $ENV/$tenant: type:calendar and type:cal find the entry, type:event does not"
}
