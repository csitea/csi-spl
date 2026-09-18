#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only deployed-state check for the spool hub in one cloud
# @description env: does the live Cloud Run service run exactly the image cnf
# @description names (env.hub.image.ref, the one 030 and the 20_hub-build-deploy
# @description workflow deploy), and is that revision the ready one?
# @description
# @description Prints ONE verdict line, `<env> <verdict> ...`, and exits:
# @description   0 current   - template image == cnf ref, Ready, latest revision ready
# @description   3 lagging   - the service runs a different image than cnf names
# @description   4 unhealthy - the image matches but the service / revision is not ready
# @description   1           - cannot tell (no service, no access, bad cnf)
# @description A green workflow run is not proof of a deploy (a skipped deploy
# @description job is green too); this is. It only DESCRIBES: no update, no
# @description create, no IAM. Spec 008 FR-P09.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT - required: the identity that reads (run.viewer is enough)
# @example ENV=dev GCP_ACCOUNT=<OPERATOR>@example.com ./run -a do_check_hub_deploy
#------------------------------------------------------------------------------
do_check_hub_deploy() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  do_require_var GCP_ACCOUNT "${GCP_ACCOUNT:-}" || return 1
  command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  if declare -f do_gcp_require_live_account >/dev/null; then
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi

  local svc json image ready created latest
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }

  json="$(gcloud run services describe "$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" \
            --account="$GCP_ACCOUNT" --format=json 2>&1)" || {
    do_log "FATAL cannot describe $svc in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT: $(tail -1 <<<"$json")"
    return 1; }

  image="$(yq -p json -r '.spec.template.spec.containers[0].image // ""' <<<"$json")"
  # the Ready condition by type, not by position
  ready="$(yq -p json -r '[.status.conditions[] | select(.type == "Ready") | .status][0] // ""' <<<"$json")"
  created="$(yq -p json -r '.status.latestCreatedRevisionName // ""' <<<"$json")"
  latest="$(yq -p json -r '.status.latestReadyRevisionName // ""' <<<"$json")"

  if [[ "$image" != "$SPL_IMAGE_REF" ]]; then
    echo "$ENV lagging service=$svc live=$image cnf=$SPL_IMAGE_REF"
    return 3
  fi
  if [[ "$ready" != True || -z "$created" || "$created" != "$latest" ]]; then
    echo "$ENV unhealthy service=$svc image=$image ready=${ready:-unknown} latest_created=$created latest_ready=$latest"
    return 4
  fi
  echo "$ENV current service=$svc image=$image revision=$latest"
}
