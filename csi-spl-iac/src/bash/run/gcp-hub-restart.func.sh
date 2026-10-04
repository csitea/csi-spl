#!/bin/bash
#------------------------------------------------------------------------------
# @description Force a fresh revision of the env's hub Cloud Run service (030,
# @description hub.service_name), harvested from the 2026-10-04 17:41Z prd
# @description recovery: under hub.cloud_run max_instances 1 a rollout can leave
# @description every revision answering 429 "no available instance" (two prd
# @description deploys did, 2026-10-02 05:12Z and 2026-10-04 17:30Z) until a
# @description NEW revision starts a fresh instance; a traffic rollback to an
# @description older revision does not. The new revision differs only by the
# @description env var SPOOL_HUB_RESTART_AT=<UTC ts>, same image, same template.
# @description Runs as the env's project SA (do_gcp_pin_account) in a private
# @description gcloud config. DRY_RUN=1 (default) reads the service and prints
# @description the update it would make; DRY_RUN=0 makes it, then prints the
# @description new ready revision and GET <service url>/v1/health.
# @description Terraform drift: SPOOL_HUB_RESTART_AT is not in the 030 tf, so
# @description the next 030 apply (and any CI deploy) drops it again. Harmless.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param HEALTH_TRIES (optional) - /v1/health attempts, 2 s apart (default 15)
# @example ENV=dev ./run -a do_gcp_hub_restart
# @example ENV=prd DRY_RUN=0 ./run -a do_gcp_hub_restart
#------------------------------------------------------------------------------
do_gcp_hub_restart() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}" tries="${HEALTH_TRIES:-15}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$tries" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL HEALTH_TRIES must be a positive integer, got: $tries"; return 2; }
  do_require_bin yq curl || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml"
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  local svc region
  svc="$(yq -r '.env.hub.service_name // ""' "$cnf")"
  region="$(yq -r '.env.gcp.gcp_region // ""' "$cnf")"
  [[ -n "$svc" && -n "$region" ]] || { do_log "FATAL the $ENV cnf has no env.hub.service_name or env.gcp.gcp_region"; return 1; }

  do_gcp_pin_account || return 1
  local sa="$GCP_ACCOUNT" before
  before="$(gcloud run services describe "$svc" --region="$region" --project="$p" --account="$sa" \
    --format='value(status.latestReadyRevisionName)' 2>/dev/null)" ||
    { do_log "FATAL cannot read Cloud Run service $svc in $p/$region as $sa"; return 1; }
  do_log "INFO $p/$region $svc: ready revision ${before:-<none>}"

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would run: gcloud run services update $svc --region=$region --project=$p --account=$sa --update-env-vars=SPOOL_HUB_RESTART_AT=$ts"
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0 to force a fresh revision."
    return 0
  fi

  do_log "INFO forcing a fresh revision (SPOOL_HUB_RESTART_AT=$ts; terraform drift until the next 030 apply)"
  gcloud run services update "$svc" --region="$region" --project="$p" --account="$sa" \
    --update-env-vars="SPOOL_HUB_RESTART_AT=$ts" --quiet ||
    { do_log "FATAL gcloud run services update $svc failed"; return 1; }

  local after url
  read -r after url < <(gcloud run services describe "$svc" --region="$region" --project="$p" --account="$sa" \
    --format='value(status.latestReadyRevisionName,status.url)' 2>/dev/null)
  if [[ -z "${after:-}" || "$after" == "$before" ]]; then
    do_log "ERROR no new ready revision: before=${before:-<none>} after=${after:-<none>}"
    return 1
  fi
  do_log "OK new revision $after (was ${before:-<none>})"
  [[ -n "${url:-}" ]] || { do_log "ERROR the service reports no url; /v1/health not checked"; return 1; }

  local i code=000
  for ((i = 1; i <= tries; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/v1/health")" || code=000
    [[ "$code" == 200 ]] && break
    ((i < tries)) && sleep 2
  done
  if [[ "$code" == 200 ]]; then
    do_log "OK $url/v1/health 200 on revision $after (attempt $i)"
    return 0
  fi
  do_log "ERROR $url/v1/health answered $code after $tries attempts on revision $after"
  return 1
}
