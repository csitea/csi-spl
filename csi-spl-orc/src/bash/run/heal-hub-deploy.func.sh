#!/bin/bash
#------------------------------------------------------------------------------
# @description Post-roll auto-heal of the hub Cloud Run service (owner go
# @description 2026-10-04, option A of the prd 429 incident, task aa35699c).
# @description Under hub.cloud_run max_instances 1 a rollout can leave the
# @description service answering Cloud Run 429 "no available instance" for
# @description minutes (prd 2026-10-02 05:12Z, 2026-10-04 17:30Z) until a NEW
# @description revision starts a fresh instance. This watches GET
# @description <service url>/v1/health for HEAL_WINDOW_S; on HEAL_STREAK
# @description consecutive 429s it forces ONE fresh revision with the same
# @description update csi-spl-iac do_gcp_hub_restart makes
# @description (--update-env-vars=SPOOL_HUB_RESTART_AT=<UTC ts>, same image),
# @description then watches once more. Never a second restart.
# @description Exit 0 healthy (with or without the one restart), 1 still bad
# @description (429 streak after the restart, the window ending on a non-200,
# @description or cannot read the service). SPOOL_HUB_RESTART_AT is terraform
# @description drift until the next 030 apply; harmless.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): watch only, print the restart it would make; 0: make it
# @param GCP_ACCOUNT (optional) - the identity (the deploy job passes its deploy SA)
# @param HEAL_WINDOW_S (optional) - seconds watched per pass (default 60)
# @param HEAL_INTERVAL_S (optional) - seconds between probes (default 5)
# @param HEAL_STREAK (optional) - consecutive 429s that trigger the restart (default 3)
# @example ENV=dev ./run -a do_heal_hub_deploy
# @example ENV=prd DRY_RUN=0 GCP_ACCOUNT=<deploy-sa> ./run -a do_heal_hub_deploy
#------------------------------------------------------------------------------
do_heal_hub_deploy() {
  local dry="${DRY_RUN:-1}" window="${HEAL_WINDOW_S:-60}" every="${HEAL_INTERVAL_S:-5}" streak="${HEAL_STREAK:-3}" v
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 1; }
  for v in "$window" "$every" "$streak"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL HEAL_WINDOW_S / HEAL_INTERVAL_S / HEAL_STREAK must be positive integers, got: $v"; return 1; }
  done
  spl_require_cloud_env || return 1
  do_require_bin yq curl || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1

  local svc url
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }
  local -a gsvc=(--project="$SPL_PROJECT" --region="$SPL_REGION")
  url="$(gcloud run services describe "$svc" "${gsvc[@]}" --account="$GCP_ACCOUNT" --format='value(status.url)' 2>/dev/null)"
  [[ -n "$url" ]] || { do_log "FATAL cannot read the url of $svc in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT"; return 1; }

  local probes=$(( (window + every - 1) / every ))
  _hhd_watch "$url" "$probes" "$every" "$streak"
  case $? in
    0) echo "heal: $ENV $svc healthy: /v1/health 200, no 429 streak in ${window}s ($probes probes) -- no extra revision"; return 0 ;;
    2) ;;
    *) echo "heal: $ENV $svc unhealthy without a 429 streak (last /v1/health $_HHD_LAST) -- not a stuck rollout, no restart"; return 1 ;;
  esac

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  echo "heal: $ENV $svc $streak consecutive 429s on /v1/health -- stuck rollout under max_instances 1"
  if [[ "$dry" == 1 ]]; then
    echo "heal: DRY_RUN would run: gcloud run services update $svc ${gsvc[*]} --account=$GCP_ACCOUNT --update-env-vars=SPOOL_HUB_RESTART_AT=$ts --quiet"
    return 1
  fi
  echo "heal: forcing ONE fresh revision of $svc (SPOOL_HUB_RESTART_AT=$ts)"
  gcloud run services update "$svc" "${gsvc[@]}" --account="$GCP_ACCOUNT" --update-env-vars="SPOOL_HUB_RESTART_AT=$ts" --quiet ||
    { do_log "FATAL gcloud run services update $svc failed"; return 1; }

  _hhd_watch "$url" "$probes" "$every" "$streak"
  case $? in
    0) echo "heal: $ENV $svc healed by one fresh revision: /v1/health 200 over ${window}s"; return 0 ;;
    2) echo "heal: $ENV $svc STILL 429 after the one fresh revision -- not retrying"; return 1 ;;
    *) echo "heal: $ENV $svc unhealthy after the fresh revision (last /v1/health $_HHD_LAST)"; return 1 ;;
  esac
}

# _hhd_watch <url> <probes> <interval> <streak> -> 0 the last probe is 200 and
# no 429 streak, 2 <streak> consecutive 429s (returns at once), 1 otherwise.
# Leaves the last code in _HHD_LAST.
_hhd_watch() {
  local url="$1" probes="$2" every="$3" streak="$4" i run=0 code
  _HHD_LAST=000
  for ((i = 1; i <= probes; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/v1/health")" || code=000
    _HHD_LAST="$code"
    if [[ "$code" == 429 ]]; then run=$((run + 1)); else run=0; fi
    ((run >= streak)) && return 2
    ((i < probes)) && sleep "$every"
  done
  [[ "$_HHD_LAST" == 200 ]]
}
