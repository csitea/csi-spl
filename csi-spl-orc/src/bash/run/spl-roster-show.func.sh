#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: print the LIVE GET /v1/view/roster JSON of a cloud
# @description tenant (view-v1 4.1) - the boxes, their pins, their announced
# @description agents and who is online - read through a real member session
# @description on the env's API host (env.dns.api_fqdn), so it is the same
# @description door and the same bytes the owner sees in the WUI. A viewer
# @description read touches nothing (view-v1 0), so this cannot change what
# @description it reports; it is the proof an owner asks for after a
# @description do_spl_box_purge, and the way to check a roster without psql.
# @description The JSON goes to stdout; the password and the session cookie
# @description are never printed.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_EMAIL (optional) - default m3-e2e-human@example.com (the M3 e2e member)
# @param PROBE_PW_FILE (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_API (optional) - overrides https://<env.dns.api_fqdn>
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_roster_show
# @example ENV=prd TENANT_ID=e2e ./run -a do_spl_roster_show
#------------------------------------------------------------------------------
do_spl_roster_show() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" api
  spl_require_tenant_slug "$tenant" || return 1
  api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  local pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}" out rc=0
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (run do_spl_m3_e2e first, or set PROBE_PW_FILE)"; return 1; }
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="${PROBE_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$pw" python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/roster-show.py")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL cannot read the $ENV/$tenant roster (exit $rc): $out"; return 1; }
  printf '%s\n' "$out"
  local n
  n="$(yq -p json -r '.boxes | length' <<<"$out" 2>/dev/null)"
  do_log "OK live GET /v1/view/roster on $ENV/$tenant: ${n:-?} box(es) (printed above)"
}
