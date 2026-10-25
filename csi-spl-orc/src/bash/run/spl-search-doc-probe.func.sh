#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-3337: does search find a Qto document, as a member sees it?
# @description Signs one tenant member in on the env's API host
# @description (env.dns.api_fqdn), makes ONE throwaway Qto document whose words
# @description are fresh random words, then: the plain search for its word,
# @description type:doc with it, an edit of its section to a new word (found)
# @description while the old word is gone, and deletes the document again.
# @description Exit 0 = every search found what it should; non-zero = a miss,
# @description printed per search with its status and hit counts (spec 100
# @description section 14). Writes only that one document, as the member, and
# @description deletes it; dry run unless DRY_RUN=0. The password is read from
# @description a file and never printed.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_EMAIL (optional) - default <pw dir>/human-email, else m3-e2e-human@example.com
# @param PROBE_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_NONCE (optional) - the random words' seed, default a fresh one
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_search_doc_probe
#------------------------------------------------------------------------------
do_spl_search_doc_probe() {
  do_require_bin yq python3 || return 1
  local tenant="${TENANT_ID:-}" api dry=1
  spl_search_doc_probe_check "$tenant" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_cnf_api_fqdn api || return 1
  local st="$SPL_STATE_DIR/m3-e2e/$tenant" out rc=0
  local pw="${PROBE_PW_FILE:-$st/pw-human}" email="${PROBE_EMAIL:-}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: sign a member of $tenant in on https://$api, make one Qto doc of random words, search it (plain, type:doc, after an edit) and delete it"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to probe."
    return 0
  fi
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE)"; return 1; }
  [[ -n "$email" ]] || email="$(cat "$(dirname "$pw")/human-email" 2>/dev/null)"
  [[ -n "$email" ]] || email="m3-e2e-human@example.com"
  printf '===== search doc probe: env=%s tenant=%s\n' "$ENV" "$tenant"
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="$email" PROBE_PW_FILE="$pw" \
    PROBE_NONCE="${PROBE_NONCE:-}" python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/search-doc-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL search doc probe on $ENV/$tenant (exit $rc): search does not find the Qto document"; return 1; }
  do_log "OK search doc probe on $ENV/$tenant: the doc is found by its words, by type:doc and after an edit"
}

# spl_search_doc_probe_check <tenant> -> 0 when well formed; refuses before
# any cnf or network call.
spl_search_doc_probe_check() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got '${ENV:-}'"; return 1; }
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got '$1'"; return 1; }
}
