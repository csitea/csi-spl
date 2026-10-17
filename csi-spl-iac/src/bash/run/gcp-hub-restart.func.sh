#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
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
# @description Fresh guard (SPL-2294): before any change it reads the ready
# @description revision's SPOOL_HUB_RESTART_AT and REFUSES (FATAL, also under
# @description DRY_RUN=1) while it is younger than HUB_RESTART_MIN_AGE_S: on
# @description 2026-10-16 two seats acting on one owner go restarted prd twice,
# @description 2 min apart. HUB_RESTART_FORCE=1 restarts anyway.
# @description Terraform drift: SPOOL_HUB_RESTART_AT is not in the 030 tf, so
# @description the next 030 apply (and any CI deploy) drops it again. Harmless.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param HEALTH_TRIES (optional) - /v1/health attempts, 2 s apart (default 15)
# @param HUB_RESTART_MIN_AGE_S (optional) - refuse while the ready revision's
# @param   SPOOL_HUB_RESTART_AT is younger than this many seconds (default 600)
# @param HUB_RESTART_FORCE (optional) - 1 restarts a fresh revision anyway (default 0)
# @example ENV=dev ./run -a do_gcp_hub_restart
# @example ENV=prd DRY_RUN=0 ./run -a do_gcp_hub_restart
#------------------------------------------------------------------------------
do_gcp_hub_restart() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}" tries="${HEALTH_TRIES:-15}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$tries" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL HEALTH_TRIES must be a positive integer, got: $tries"; return 2; }
  [[ "${HUB_RESTART_MIN_AGE_S:-600}" =~ ^[0-9]+$ ]] || { do_log "FATAL HUB_RESTART_MIN_AGE_S must be a non-negative integer, got: $HUB_RESTART_MIN_AGE_S"; return 2; }
  [[ "${HUB_RESTART_FORCE:-0}" =~ ^[01]$ ]] || { do_log "FATAL HUB_RESTART_FORCE must be 0 or 1, got: $HUB_RESTART_FORCE"; return 2; }
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
  _spl_hub_restart_fresh_guard "$before" "$region" "$p" "$sa" || return 1

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

#------------------------------------------------------------------------------
# @description The fresh guard of do_gcp_hub_restart (SPL-2294): reads the
# @description SPOOL_HUB_RESTART_AT of revision $1 and fails while it is younger
# @description than HUB_RESTART_MIN_AGE_S (default 600 s), unless
# @description HUB_RESTART_FORCE=1. A value it cannot read or parse also fails.
# @description No revision ($1 empty) or no SPOOL_HUB_RESTART_AT passes.
# @param $1 revision, $2 region, $3 project, $4 account
#------------------------------------------------------------------------------
_spl_hub_restart_fresh_guard() {
  local rev="$1" region="$2" p="$3" sa="$4" min_age="${HUB_RESTART_MIN_AGE_S:-600}"
  local force_hint="pass HUB_RESTART_FORCE=1 to restart anyway"
  if [[ "${HUB_RESTART_FORCE:-0}" == 1 ]]; then
    do_log "WARN HUB_RESTART_FORCE=1: the fresh guard is skipped"
    return 0
  fi
  [[ -n "$rev" ]] || return 0
  local json at
  json="$(gcloud run revisions describe "$rev" --region="$region" --project="$p" --account="$sa" --format=json 2>/dev/null)" ||
    { do_log "FATAL cannot read revision $rev to check its SPOOL_HUB_RESTART_AT; $force_hint"; return 1; }
  [[ -n "$json" ]] || json='{}'
  at="$(yq -p=json -r '[.spec.containers[]?.env[]? | select(.name == "SPOOL_HUB_RESTART_AT") | .value][0] // ""' <<<"$json" 2>/dev/null)" ||
    { do_log "FATAL cannot parse revision $rev to check its SPOOL_HUB_RESTART_AT; $force_hint"; return 1; }
  if [[ -z "$at" ]]; then
    do_log "INFO revision $rev has no SPOOL_HUB_RESTART_AT: no recent restart"
    return 0
  fi
  [[ "$at" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] ||
    { do_log "FATAL revision $rev has SPOOL_HUB_RESTART_AT=$at, not <YYYYmmddTHHMMSSZ>; $force_hint"; return 1; }
  local at_s age
  at_s="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]} UTC" +%s 2>/dev/null)" ||
    { do_log "FATAL revision $rev has SPOOL_HUB_RESTART_AT=$at, not a date; $force_hint"; return 1; }
  age=$(($(date -u +%s) - at_s))
  if ((age < min_age)); then
    do_log "FATAL revision $rev was restarted $age s ago (SPOOL_HUB_RESTART_AT=$at, younger than HUB_RESTART_MIN_AGE_S=$min_age): refusing a second restart; $force_hint"
    return 1
  fi
  do_log "INFO revision $rev SPOOL_HUB_RESTART_AT=$at is $age s old (>= $min_age s): restart allowed"
}
