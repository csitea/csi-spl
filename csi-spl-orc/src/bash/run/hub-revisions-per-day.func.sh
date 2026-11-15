#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only proof count of SPL-5641 (spec 175 task 5.10): how many
# @description hub Cloud Run revisions one env created per day. Every revision
# @description drops every box's socket; workflow 20 holds a push deploy so an
# @description env rolls at most once per HUB_DEPLOY_COALESCE_MIN minutes
# @description (csi-spl-orc/src/bash/scripts/hub-deploy-coalesce.sh).
# @description Prints "<YYYY-MM-DD> <count>" lines, oldest day first, for the
# @description newest LIMIT revisions. It only lists: no update, no IAM.
# @param ENV (required) - dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account)
# @param LIMIT (optional) - how many newest revisions to read (default 200)
# @example ENV=prd ./run -a do_hub_revisions_per_day
#------------------------------------------------------------------------------
do_hub_revisions_per_day() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  local svc limit="${LIMIT:-200}" out
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL LIMIT must be a positive number, got: '$limit'"; return 1; }
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }
  out="$(gcloud run revisions list --service="$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" \
           --account="$GCP_ACCOUNT" --limit="$limit" --format='value(metadata.creationTimestamp)' 2>&1)" || {
    do_log "FATAL cannot list the revisions of $svc in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT: $(tail -1 <<<"$out")"
    return 1; }
  bash "$PROJ_PATH/src/bash/scripts/hub-deploy-coalesce.sh" per-day <<<"$out"
}
