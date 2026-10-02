#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY runtime timing e2e of the WUI's FIRST LOAD on a cloud
# @description env's DEPLOYED WUI (CLE-77934, owner topic 87eaa57b: investigate
# @description what else could be decreased; method of 73c9704c: empiric before
# @description / after). Runs csi-spl-wui/tests/e2e/perf-first-load.timing.mjs as
# @description the env's m3-e2e test member in one headless Chrome: N fresh tabs
# @description per profile (desktop 1440, phone 390 at CPU 4x) of navigation ->
# @description rail -> Flow list painted, with the long tasks / total blocking
# @description time, CDP script + layout ms, the hub socket's open time, DOM
# @description nodes and heap. Prints a median / p90 table with the build version
# @description and sha read from <host>/build.json; every sample lands in
# @description <out>/first-load.json. FL_CPU_PROFILE=1 adds one profiled round per
# @description profile: self ms per script and the top functions (<out>/*.cpuprofile).
# @description It clicks and reads, it never posts. prd t1 is refused (the
# @description owner's tenant): measure prd in its test tenant e2e.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - default t1 on dev, e2e on prd
# @param PF_N (optional) - rounds per profile, 1..50, default 10
# @param PF_PROFILES (optional) - d1440,m390 (default) or one of them
# @param PF_COLD_CACHE (optional) - 1 clears the HTTP cache before each round, default 0
# @param FL_CPU_PROFILE (optional) - 1 adds one V8-profiled round per profile, default 0
# @param PF_WUI_URL (optional) - the WUI origin, default the tenant's host
# @param PF_EMAIL (optional) - default <state>/m3-e2e/<tenant>/human-email, else
# @param   m3-e2e-human@example.com
# @param PF_OUT (optional) - default <state>/perf-first-load/<tenant>/<utc>
# @example ENV=dev ./run -a do_spl_wui_perf_first_load
# @example ENV=prd PF_N=10 FL_CPU_PROFILE=1 ./run -a do_spl_wui_perf_first_load
#------------------------------------------------------------------------------
do_spl_wui_perf_first_load() {
  do_require_bin node || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" n="${PF_N:-10}" profiles="${PF_PROFILES:-d1440,m390}" cold="${PF_COLD_CACHE:-0}" cpu="${FL_CPU_PROFILE:-0}"
  [[ -n "$tenant" ]] || { [[ "$ENV" == prd ]] && tenant=e2e || tenant=t1; }
  spl_pf_validate "$tenant" "$n" "$profiles" "$cold" || return 1
  [[ "$cpu" == 0 || "$cpu" == 1 ]] || { do_log "FATAL FL_CPU_PROFILE must be 0 or 1, got: '$cpu'"; return 1; }

  local wui="${PF_WUI_URL:-}"
  if [[ -z "$wui" ]]; then
    [[ "$tenant" == t1 ]] && wui="https://$SPL_FQDN" || wui="https://$tenant.$SPL_FQDN"
  fi
  local st="$SPL_STATE_DIR/m3-e2e/$tenant" email="${PF_EMAIL:-}"
  [[ -n "$email" ]] || { [[ -s "$st/human-email" ]] && email="$(<"$st/human-email")"; }
  [[ -n "$email" ]] || email=m3-e2e-human@example.com
  local pwf="$st/pw-human"
  [[ -s "$pwf" ]] || { do_log "FATAL no password for $email at $pwf: run do_spl_m3_e2e once for $ENV/$tenant"; return 1; }
  local proof_js="$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/perf-first-load.timing.mjs"
  [[ -f "$proof_js" ]] || { do_log "FATAL no timing e2e at $proof_js"; return 1; }
  local chrome="${CHROME_PATH:-/usr/bin/google-chrome}"
  [[ -x "$chrome" ]] || { do_log "FATAL no Chrome at $chrome (set CHROME_PATH)"; return 1; }

  local out="${PF_OUT:-$SPL_STATE_DIR/perf-first-load/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"
  # one browser profile per env + tenant: repeated before/after runs keep the
  # session and stay under the native sign-in limit (10 / 15 min)
  local udd="$SPL_STATE_DIR/perf-first-load/$tenant/chrome-profile"
  mkdir -p "$out" "$udd" && chmod 700 "$out" "$udd" || return 1
  local -a envv=(
    "BASE=$wui" "EMAIL=$email" "PW_FILE=$pwf" "OUT=$out" "TENANT=$tenant" "N=$n"
    "PROFILES=$profiles" "COLD_CACHE=$cold" "CPU_PROFILE=$cpu" "USER_DATA_DIR=$udd" "CHROME_PATH=$chrome"
  )
  [[ -n "${PUPPETEER_CORE:-}" ]] && envv+=("PUPPETEER_CORE=$PUPPETEER_CORE")
  do_log "INFO first-load runtime timing on $ENV/$tenant at $wui as $email: n=$n per profile ($profiles), evidence $out"
  local rc=0
  ( cd "$APP_PATH/$SPL_ORG_APP-wui" && env "${envv[@]}" node "$proof_js" ) || rc=$?
  (( rc == 0 )) && do_log "OK first-load timing on $ENV/$tenant: $out/first-load.json" ||
    do_log "FATAL the first-load timing e2e failed on $ENV/$tenant (exit $rc): $out"
  return $rc
}
