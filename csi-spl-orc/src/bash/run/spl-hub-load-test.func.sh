#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-2138: a bounded load / soak test of the DEPLOYED hub, dev
# @description only (prd and every other env are refused before anything is
# @description read). One sign-in as a test login, then an open-loop stream of
# @description read-only GETs at LOAD_RPS for LOAD_SECONDS with at most
# @description LOAD_CONCURRENCY in flight (scripts/hub-load-test.py). Prints
# @description p50 / p95 / p99 / max per path and in total, the error rate and
# @description the status counts, then the Cloud Run side of the same window
# @description (do_spl_hub_run_metrics: instances, requests in flight per
# @description instance, CPU, requests by class). FAILS when the error rate or
# @description the p95 crosses its threshold.
# @description Hard caps, any env: LOAD_RPS <= 50, LOAD_CONCURRENCY <= 50,
# @description LOAD_SECONDS <= 900. The dev hub serves every lane's e2e: run
# @description the default or the soak, nothing heavier.
# @description Default paths: the member reads prd's request log ranks highest
# @description (do_spl_hub_route_latency, 2026-10-20, n=50000), weighted by
# @description repetition. /v1/pins (the box route, first by count) needs a box
# @description token, so a member session reads 401 there: it is not in the set.
# @description The login, first match wins: LOAD_COOKIE_FILE; LOAD_EMAIL +
# @description LOAD_PW_FILE; SPL_PROBE_ADMIN_PW (the GitHub secret of wf 23) as
# @description cnf env.box.join_check_email in join_check_tenant; else the probe
# @description member files <state>/m3-e2e/<tenant>/probe/{human-email,pw-human}.
# @description Never a person's own login. The password is never printed.
# @param ENV - required: dev
# @param LOAD_RPS (optional) - requests a second, 1..50, default 20
# @param LOAD_CONCURRENCY (optional) - in flight at most, 1..50, default 10
# @param LOAD_SECONDS (optional) - 1..900, default 60
# @param LOAD_MAX_ERR_PCT (optional) - fail above this error rate, %, default 1
# @param LOAD_MAX_P95_MS (optional) - fail above this p95, ms, default 500 (10 x the 2026-10-20 dev baseline, 47.8 ms from sat; a hosted runner adds its RTT to europe-north1)
# @param LOAD_PATHS (optional) - comma-separated GET paths, default the set below
# @param LOAD_TENANT (optional) - the probe login's workspace, default t1
# @param LOAD_METRICS (optional) - 1 (default) reads Cloud Run after the run, 0 skips
# @param LOAD_METRICS_WAIT (optional) - s to wait first so the last minute is in, 0..300, default 150
# @example ENV=dev ./run -a do_spl_hub_load_test
# @example ENV=dev LOAD_RPS=10 LOAD_SECONDS=600 ./run -a do_spl_hub_load_test
#------------------------------------------------------------------------------
SPL_HUB_LOAD_PATHS_DEFAULT="/v1/wui/revision,/v1/health,/v1/view/channels,/v1/view/topics,/v1/view/flow,/v1/view/issues,/v1/view/roster,/api/v1/auth/session,/v1/me/reads,/version,/v1/wui/revision,/v1/health"

do_spl_hub_load_test() {
  spl_hub_load_test_check_args || return 1
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local api="" fqdn="" url auth start rc=0
  if [[ -n "${SPL_HUB_LOAD_URL:-}" ]]; then
    # the hermetic tests' stub hub; a loopback address only, never a real host
    [[ "$SPL_HUB_LOAD_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] ||
      { do_log "FATAL SPL_HUB_LOAD_URL is for the tests: http://127.0.0.1:<port> only, got '$SPL_HUB_LOAD_URL'"; return 1; }
    url="$SPL_HUB_LOAD_URL" auth="$SPL_HUB_LOAD_URL"
  else
    spl_cnf_api_fqdn api || return 1
    fqdn="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
    url="https://$api" auth="https://${fqdn:-$api}"
  fi
  local -a login=()
  spl_hub_load_test_login login || return 1
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '===== csi-spl hub load test: env=%s hub=%s start=%s\n' "$ENV" "$url" "$start"
  # export, never `env NAME=...`: a password on a command line is in ps
  ( export "${login[@]}" LOAD_URL="$url" LOAD_AUTH_URL="$auth" \
      LOAD_RPS="${LOAD_RPS:-20}" LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-10}" LOAD_SECONDS="${LOAD_SECONDS:-60}" \
      LOAD_MAX_ERR_PCT="${LOAD_MAX_ERR_PCT:-1}" LOAD_MAX_P95_MS="${LOAD_MAX_P95_MS:-500}" \
      LOAD_PATHS="${LOAD_PATHS:-$SPL_HUB_LOAD_PATHS_DEFAULT}"
    exec python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/hub-load-test.py" ) || rc=$?
  spl_hub_load_test_metrics "$start"
  (( rc == 0 )) && { do_log "OK hub load test on $ENV: under the thresholds"; return 0; }
  do_log "FATAL hub load test on $ENV failed (driver exit $rc)"
  return 1
}

# spl_hub_load_test_check_args -> 1 with a FATAL line unless ENV is dev and
# every knob is inside its cap. Runs before any file, cnf or network is read.
spl_hub_load_test_check_args() {
  [[ "${ENV:-}" == dev ]] ||
    { do_log "FATAL do_spl_hub_load_test runs on ENV=dev only (the shared dev hub), got ENV='${ENV:-}'; prd is never load-tested"; return 1; }
  local kv name val lo hi
  for kv in "LOAD_RPS 1 50" "LOAD_CONCURRENCY 1 50" "LOAD_SECONDS 1 900" "LOAD_METRICS 0 1" "LOAD_METRICS_WAIT 0 300"; do
    read -r name lo hi <<<"$kv"
    val="${!name:-}"
    [[ -z "$val" ]] && continue
    [[ "$val" =~ ^[0-9]+$ ]] && (( val >= lo && val <= hi )) ||
      { do_log "FATAL $name must be $lo..$hi, got '$val'"; return 1; }
  done
  for name in LOAD_MAX_ERR_PCT LOAD_MAX_P95_MS; do
    val="${!name:-}"
    [[ -z "$val" || "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { do_log "FATAL $name must be a number, got '$val'"; return 1; }
  done
}

# spl_hub_load_test_login <array name> -> the driver's login env (NAME=value
# words) into that array; 1 with a FATAL when no test login is found.
spl_hub_load_test_login() {
  local -n _out="$1"
  local tenant="${LOAD_TENANT:-t1}" dir email
  if [[ -n "${LOAD_COOKIE_FILE:-}" ]]; then
    _out=(LOAD_COOKIE_FILE="$LOAD_COOKIE_FILE"); return 0
  fi
  if [[ -n "${LOAD_EMAIL:-}" ]]; then
    [[ -r "${LOAD_PW_FILE:-}" ]] || { do_log "FATAL LOAD_EMAIL needs a readable LOAD_PW_FILE (0600)"; return 1; }
    _out=(LOAD_EMAIL="$LOAD_EMAIL" LOAD_PW_FILE="$LOAD_PW_FILE" LOAD_TENANT="$tenant"); return 0
  fi
  if [[ -n "${SPL_PROBE_ADMIN_PW:-}" ]]; then
    email="$(yq -r '.env.box.join_check_email // ""' "$SPL_CNF")"
    tenant="$(yq -r '.env.box.join_check_tenant // ""' "$SPL_CNF")"
    [[ -n "$email" && -n "$tenant" ]] ||
      { do_log "FATAL SPL_PROBE_ADMIN_PW is set but cnf env.box.join_check_email / join_check_tenant is not"; return 1; }
    _out=(LOAD_EMAIL="$email" LOAD_PW="$SPL_PROBE_ADMIN_PW" LOAD_TENANT="$tenant"); return 0
  fi
  dir="$SPL_STATE_DIR/m3-e2e/$tenant/probe"
  if [[ -r "$dir/human-email" && -r "$dir/pw-human" ]]; then
    email="$(tr -d '[:space:]' <"$dir/human-email")"
    _out=(LOAD_EMAIL="$email" LOAD_PW_FILE="$dir/pw-human" LOAD_TENANT="$tenant"); return 0
  fi
  do_log "FATAL no test login: set LOAD_COOKIE_FILE, LOAD_EMAIL + LOAD_PW_FILE or SPL_PROBE_ADMIN_PW, or create the probe member ($dir, do_spl_probe_member_seat)"
  return 1
}

# spl_hub_load_test_metrics <start> -> the Cloud Run side from 5 min before the
# run to now (instances before / during / after). Informational: a failed
# read is a WARN, never the verdict. LOAD_METRICS=0 skips it.
spl_hub_load_test_metrics() {
  [[ "${LOAD_METRICS:-1}" == 1 ]] || { do_log "INFO LOAD_METRICS=0: Cloud Run metrics not read"; return 0; }
  local wait="${LOAD_METRICS_WAIT:-150}" since minutes
  do_log "INFO waiting ${wait} s for Cloud Run monitoring to hold the last minute of the run"
  sleep "$wait"
  since="$(date -u -d "$1 - 5 minutes" +%Y-%m-%dT%H:%M:%SZ)" || return 0
  minutes=$(( ( $(date -u +%s) - $(date -u -d "$since" +%s) ) / 60 + 1 ))
  REQ_SINCE="$since" REQ_MINUTES="$minutes" do_spl_hub_run_metrics ||
    do_log "WARN Cloud Run metrics not read (do_spl_hub_run_metrics); the load verdict above stands"
  return 0
}
