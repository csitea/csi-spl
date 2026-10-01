#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY timing e2e of the Flow and the Event log on a cloud
# @description env's DEPLOYED WUI (CLE-77914, owner topic 73c9704c: "some kind of
# @description optimization e2e must be performed with empiric evidence for the
# @description performed changes"). Runs csi-spl-wui/tests/e2e/perf-flow-events.timing.mjs
# @description as the env's m3-e2e test member in one headless Chrome: N rounds
# @description per profile (desktop 1440, phone 390) of Flow click -> list painted,
# @description entry click -> message shown + marked, Flow again, Event log tab ->
# @description link -> page painted -> rows painted, and the Event log again.
# @description Prints a median / p90 ms table per step with the build version
# @description and sha read from <host>/build.json, plus the API reads each step
# @description fired; every sample lands in <out>/timing.json. It clicks and
# @description reads, it never posts. prd t1 is refused (the owner's tenant):
# @description measure prd in its test tenant e2e.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - default t1 on dev, e2e on prd
# @param PF_N (optional) - rounds per profile, 1..50, default 10
# @param PF_PROFILES (optional) - d1440,m390 (default) or one of them
# @param PF_COLD_CACHE (optional) - 1 clears the HTTP cache before each round, default 0
# @param PF_WUI_URL (optional) - the WUI origin, default the tenant's host
# @param   (https://<fqdn> for the env's default tenant, else https://<tenant>.<fqdn>)
# @param PF_EMAIL (optional) - default <state>/m3-e2e/<tenant>/human-email, else
# @param   m3-e2e-human@example.com
# @param PF_OUT (optional) - default <state>/perf-flow-events/<tenant>/<utc>
# @example ENV=prd ./run -a do_spl_wui_perf_flow_events
# @example ENV=dev PF_N=3 PF_PROFILES=d1440 ./run -a do_spl_wui_perf_flow_events
#------------------------------------------------------------------------------
do_spl_wui_perf_flow_events() {
  do_require_bin node || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" n="${PF_N:-10}" profiles="${PF_PROFILES:-d1440,m390}" cold="${PF_COLD_CACHE:-0}"
  [[ -n "$tenant" ]] || { [[ "$ENV" == prd ]] && tenant=e2e || tenant=t1; }
  spl_pf_validate "$tenant" "$n" "$profiles" "$cold" || return 1

  local wui="${PF_WUI_URL:-}"
  if [[ -z "$wui" ]]; then
    [[ "$tenant" == t1 ]] && wui="https://$SPL_FQDN" || wui="https://$tenant.$SPL_FQDN"
  fi
  local st="$SPL_STATE_DIR/m3-e2e/$tenant" email="${PF_EMAIL:-}"
  [[ -n "$email" ]] || { [[ -s "$st/human-email" ]] && email="$(<"$st/human-email")"; }
  [[ -n "$email" ]] || email=m3-e2e-human@example.com
  local pwf="$st/pw-human"
  [[ -s "$pwf" ]] || { do_log "FATAL no password for $email at $pwf: run do_spl_m3_e2e once for $ENV/$tenant"; return 1; }
  local proof_js="$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/perf-flow-events.timing.mjs"
  [[ -f "$proof_js" ]] || { do_log "FATAL no timing e2e at $proof_js"; return 1; }
  local chrome="${CHROME_PATH:-/usr/bin/google-chrome}"
  [[ -x "$chrome" ]] || { do_log "FATAL no Chrome at $chrome (set CHROME_PATH)"; return 1; }

  local out="${PF_OUT:-$SPL_STATE_DIR/perf-flow-events/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"
  # one browser profile per env + tenant: the session is kept between runs, so
  # repeated before/after runs stay under the native sign-in limit (10 / 15 min)
  local udd="$SPL_STATE_DIR/perf-flow-events/$tenant/chrome-profile"
  mkdir -p "$out" "$udd" && chmod 700 "$out" "$udd" || return 1
  local -a envv=(
    "BASE=$wui" "EMAIL=$email" "PW_FILE=$pwf" "OUT=$out" "TENANT=$tenant" "N=$n"
    "PROFILES=$profiles" "COLD_CACHE=$cold" "USER_DATA_DIR=$udd" "CHROME_PATH=$chrome"
  )
  [[ -n "${PUPPETEER_CORE:-}" ]] && envv+=("PUPPETEER_CORE=$PUPPETEER_CORE")
  do_log "INFO Flow + Event log timing on $ENV/$tenant at $wui as $email: n=$n per profile ($profiles), evidence $out"
  local rc=0
  ( cd "$APP_PATH/$SPL_ORG_APP-wui" && env "${envv[@]}" node "$proof_js" ) || rc=$?
  (( rc == 0 )) && do_log "OK timing on $ENV/$tenant: $out/timing.json" ||
    do_log "FATAL the timing e2e failed on $ENV/$tenant (exit $rc): $out"
  return $rc
}

# spl_pf_validate <tenant> <n> <profiles> <cold> -> 0 when sane; prd t1 refused.
spl_pf_validate() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$1'"; return 1; }
  [[ "$ENV" == prd && "$1" == t1 ]] &&
    { do_log "FATAL prd t1 is the owner's tenant: measure prd in its test tenant (TENANT_ID=e2e)"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 50 )) || { do_log "FATAL PF_N must be 1..50, got: '$2'"; return 1; }
  [[ "$3" =~ ^(d1440|m390)(,(d1440|m390))?$ ]] || { do_log "FATAL PF_PROFILES must be d1440 and/or m390, got: '$3'"; return 1; }
  [[ "$4" == 0 || "$4" == 1 ]] || { do_log "FATAL PF_COLD_CACHE must be 0 or 1, got: '$4'"; return 1; }
}
