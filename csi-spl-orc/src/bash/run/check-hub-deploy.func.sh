#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only deployed-state check for the spool hub in one cloud
# @description env: does the live Cloud Run service run exactly the image cnf
# @description names (env.hub.image.ref, the one 030 and the 20_hub-build-deploy
# @description workflow deploy), and is that revision the ready one?
# @description
# @description Prints ONE verdict line, `<env> <verdict> ...`, and exits:
# @description   0 current   - template image == the expected image, Ready, latest revision ready
# @description   3 lagging   - the service runs a different image than expected
# @description The expected image: with SPL_HUB_IMAGE_TAG (the deploy job, which
# @description knows the release version it minted) exactly that tag. Without
# @description it (the 00 watch, an operator) the version is minted per deploy
# @description and cnf hub.image.tag is only the FLOOR, so any tag in the cnf
# @description repository at or above the floor is current; commit-level lag is
# @description do_check_deploy_lag's question, not this one.
# @description   4 unhealthy - the image matches but the service / revision is not ready
# @description   1           - cannot tell (no service, no access, bad cnf)
# @description A green workflow run is not proof of a deploy (a skipped deploy
# @description job is green too); this is. It only DESCRIBES: no update, no
# @description create, no IAM. Spec 008 FR-P09.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account): the identity that reads (run.viewer is enough)
# @param SPL_HUB_IMAGE_TAG (optional) - require exactly this release key (do_release_version `key`; 1.0.1-c2 past 9.9.9, while /version shows 1.0.1)
# @example ENV=dev ./run -a do_check_hub_deploy
#------------------------------------------------------------------------------
do_check_hub_deploy() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
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

  # One yq over the describe JSON, not four: image, the Ready condition by type
  # (not position), and the two revision names, tab-joined. ~33 ms of four
  # spawns -> ~5 ms of one; in the deploy-verify retry loop that is 24 yq -> 6.
  # None of these values can contain a tab (image ref, revision names, a
  # condition status), so @tsv round-trips exactly.
  IFS=$'\t' read -r image ready created latest < <(yq -p json -r '[
      .spec.template.spec.containers[0].image // "",
      ([.status.conditions[] | select(.type == "Ready") | .status][0] // ""),
      .status.latestCreatedRevisionName // "",
      .status.latestReadyRevisionName // ""
    ] | @tsv' <<<"$json")

  local live_tag="${image##*:}" floor="${SPL_IMAGE_CNF_REF##*:}" ok=0
  if [[ -n "${SPL_HUB_IMAGE_TAG:-}" ]]; then
    [[ "$image" == "$SPL_IMAGE_REF" ]] && ok=1
  # The image tag is the release KEY: past 9.9.9 it carries its cycle
  # (1.0.1-c2, spl-release-version CYCLES) and is later than the cycle-1
  # floor although its X.Y.Z -- what /version shows -- reads lower.
  elif [[ "${image%:*}" == "${SPL_IMAGE_CNF_REF%:*}" ]] && spl_release_key_valid "$live_tag" &&
       ! spl_release_key_gt "$floor" "$live_tag"; then
    ok=1
  fi
  if ((!ok)); then
    if [[ -n "${SPL_HUB_IMAGE_TAG:-}" ]]; then echo "$ENV lagging service=$svc live=$image expected=$SPL_IMAGE_REF (minted)"
    else echo "$ENV lagging service=$svc live=$image expected=$SPL_IMAGE_CNF_REF (the floor) or a later minted tag"; fi
    return 3
  fi
  if [[ "$ready" != True || -z "$created" || "$created" != "$latest" ]]; then
    echo "$ENV unhealthy service=$svc image=$image ready=${ready:-unknown} latest_created=$created latest_ready=$latest"
    return 4
  fi
  echo "$ENV current service=$svc image=$image revision=$latest"
}
