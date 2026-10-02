#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY network map of the first load on a cloud env's DEPLOYED
# @description WUI (CLE-77933, owner topic 87eaa57b: "investigate whether or not
# @description something else could be decreased as well"). Runs
# @description csi-spl-wui/tests/e2e/perf-first-load-net.timing.mjs as the env's
# @description m3-e2e test member in one headless Chrome: N fresh loads of / per
# @description profile (desktop 1440, phone 390) and cache (cold, warm), counting
# @description every request started before the left rail shows (count, KB on the
# @description wire, per kind: js css font img i18n api ws) and in the SETTLE ms
# @description after it, prefetches separately. Prints a median / p90 table with
# @description the build version and sha read from <host>/build.json; every
# @description request of every round lands in <out>/first-load-net.json. It loads
# @description and reads, it never posts. prd t1 is refused (the owner's tenant):
# @description measure prd in its test tenant e2e.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - default t1 on dev, e2e on prd
# @param PFL_N (optional) - rounds per profile and cache, 1..50, default 10
# @param PFL_PROFILES (optional) - d1440,m390 (default) or one of them
# @param PFL_CACHES (optional) - cold,warm (default) or one of them
# @param PFL_NET (optional) - none (default) or fast4g (150 ms RTT, 9 Mbit/s)
# @param PFL_SETTLE_MS (optional) - ms recorded after the rail shows, 0..30000, default 4000
# @param PFL_WUI_URL (optional) - the WUI origin, default the tenant's host
# @param PFL_EMAIL (optional) - default <state>/m3-e2e/<tenant>/human-email, else
# @param   m3-e2e-human@example.com
# @param PFL_OUT (optional) - default <state>/perf-first-load-net/<tenant>/<utc>
# @example ENV=prd ./run -a do_spl_wui_perf_first_load_net
# @example ENV=dev PFL_N=3 PFL_PROFILES=m390 PFL_CACHES=cold PFL_NET=fast4g ./run -a do_spl_wui_perf_first_load_net
#------------------------------------------------------------------------------
do_spl_wui_perf_first_load_net() {
  do_require_bin node || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" n="${PFL_N:-10}" profiles="${PFL_PROFILES:-d1440,m390}" caches="${PFL_CACHES:-cold,warm}"
  local net="${PFL_NET:-none}" settle="${PFL_SETTLE_MS:-4000}"
  [[ -n "$tenant" ]] || { [[ "$ENV" == prd ]] && tenant=e2e || tenant=t1; }
  spl_pf_validate "$tenant" "$n" "$profiles" 0 || return 1
  spl_pfl_validate "$caches" "$net" "$settle" || return 1

  local wui="${PFL_WUI_URL:-}"
  if [[ -z "$wui" ]]; then
    [[ "$tenant" == t1 ]] && wui="https://$SPL_FQDN" || wui="https://$tenant.$SPL_FQDN"
  fi
  local st="$SPL_STATE_DIR/m3-e2e/$tenant" email="${PFL_EMAIL:-}"
  [[ -n "$email" ]] || { [[ -s "$st/human-email" ]] && email="$(<"$st/human-email")"; }
  [[ -n "$email" ]] || email=m3-e2e-human@example.com
  local pwf="$st/pw-human"
  [[ -s "$pwf" ]] || { do_log "FATAL no password for $email at $pwf: run do_spl_m3_e2e once for $ENV/$tenant"; return 1; }
  local proof_js="$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/perf-first-load-net.timing.mjs"
  [[ -f "$proof_js" ]] || { do_log "FATAL no first-load e2e at $proof_js"; return 1; }
  local chrome="${CHROME_PATH:-/usr/bin/google-chrome}"
  [[ -x "$chrome" ]] || { do_log "FATAL no Chrome at $chrome (set CHROME_PATH)"; return 1; }

  local out="${PFL_OUT:-$SPL_STATE_DIR/perf-first-load-net/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"
  # the Flow timing's browser profile per env + tenant: one kept session for both
  # harnesses, so repeated runs stay under the native sign-in limit (10 / 15 min)
  local udd="$SPL_STATE_DIR/perf-flow-events/$tenant/chrome-profile"
  mkdir -p "$out" "$udd" && chmod 700 "$out" "$udd" || return 1
  local -a envv=(
    "BASE=$wui" "EMAIL=$email" "PW_FILE=$pwf" "OUT=$out" "TENANT=$tenant" "N=$n" "PROFILES=$profiles"
    "CACHES=$caches" "NET=$net" "SETTLE=$settle" "USER_DATA_DIR=$udd" "CHROME_PATH=$chrome"
  )
  [[ -n "${PUPPETEER_CORE:-}" ]] && envv+=("PUPPETEER_CORE=$PUPPETEER_CORE")
  do_log "INFO first-load network map on $ENV/$tenant at $wui as $email: n=$n per profile x cache ($profiles; $caches; net $net), evidence $out"
  local rc=0
  ( cd "$APP_PATH/$SPL_ORG_APP-wui" && env "${envv[@]}" node "$proof_js" ) || rc=$?
  (( rc == 0 )) && do_log "OK first-load map on $ENV/$tenant: $out/first-load-net.json" ||
    do_log "FATAL the first-load e2e failed on $ENV/$tenant (exit $rc): $out"
  return $rc
}

# spl_pfl_validate <caches> <net> <settle_ms> -> 0 when sane.
spl_pfl_validate() {
  [[ "$1" =~ ^(cold|warm)(,(cold|warm))?$ ]] || { do_log "FATAL PFL_CACHES must be cold and/or warm, got: '$1'"; return 1; }
  [[ "$2" == none || "$2" == fast4g ]] || { do_log "FATAL PFL_NET must be none or fast4g, got: '$2'"; return 1; }
  [[ "$3" =~ ^[0-9]+$ ]] && (( $3 <= 30000 )) || { do_log "FATAL PFL_SETTLE_MS must be 0..30000, got: '$3'"; return 1; }
}
