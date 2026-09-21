#!/bin/bash
#------------------------------------------------------------------------------
# @description Pre-apply precondition for step 030-cloud-run-hub: would an
# @description apply from THIS tree move the live hub image BACKWARDS?
# @description
# @description The tf-runner renders tfvars from the tree it mounts. A stale
# @description checkout still names the previous hub.image.tag, so
# @description `make do-provision STEP=030-cloud-run-hub` proposes
# @description `~ image = <live> -> <older>` and un-ships every commit in
# @description between. That happened on 2026-09-21: the main checkout was
# @description stuck on an unpushed doc commit, 18 behind trunk, and both 030
# @description plans proposed 0.1.17 -> 0.1.16, dev AND prd (ORC freeze 08:0xZ).
# @description
# @description Direction matters, so this is NOT do_check_hub_deploy with a
# @description non-zero exit: cnf NEWER than live is the documented roll path
# @description (a tag bump applied through 030 instead of the 20 pipeline) and
# @description stays allowed. Only cnf OLDER than live is refused.
# @description
# @description Prints ONE verdict line, `<env> <verdict> ...`, and exits:
# @description   0 current  - cnf names exactly the live image
# @description   0 forward  - cnf names a NEWER tag: a roll, allowed
# @description   3 regress  - cnf names an OLDER tag: refused (stale tree)
# @description   3 diverged - tags do not compare (repository change): refused
# @description   1          - cannot tell (no service, no access, bad cnf)
# @description Read-only: describe only, no update, no create, no IAM.
# @param ENV - required: dev or prd
# @param ALLOW_IMAGE_REGRESS (optional) - 1 permits a deliberate rollback; the
# @param   verdict is still printed, so the intent stays visible in the log
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key
# @param   (do_gcp_account; never the owner account)
# @example ENV=dev ./run -a do_check_hub_image_regress
#------------------------------------------------------------------------------
do_check_hub_image_regress() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  if declare -f do_gcp_require_live_account >/dev/null; then
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi

  local svc json live cnf_tag live_tag newest
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }

  json="$(gcloud run services describe "$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" \
            --account="$GCP_ACCOUNT" --format=json 2>&1)" || {
    do_log "FATAL cannot describe $svc in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT: $(tail -1 <<<"$json")"
    return 1; }

  live="$(yq -p json -r '.spec.template.spec.containers[0].image // ""' <<<"$json")"
  [[ -n "$live" ]] || { do_log "FATAL $svc reports no container image"; return 1; }

  if [[ "$live" == "$SPL_IMAGE_REF" ]]; then
    echo "$ENV current service=$svc image=$live"
    return 0
  fi

  cnf_tag="${SPL_IMAGE_REF##*:}"; live_tag="${live##*:}"
  if [[ "${SPL_IMAGE_REF%:*}" != "${live%:*}" ]]; then
    echo "$ENV diverged service=$svc live=$live cnf=$SPL_IMAGE_REF reason=different-repository"
    [[ "${ALLOW_IMAGE_REGRESS:-}" == 1 ]] && return 0
    return 3
  fi

  newest="$(printf '%s\n%s\n' "$live_tag" "$cnf_tag" | sort -V | tail -1)"
  if [[ "$newest" == "$cnf_tag" && "$newest" != "$live_tag" ]]; then
    echo "$ENV forward service=$svc live=$live_tag cnf=$cnf_tag (an apply rolls the hub forward)"
    return 0
  fi

  echo "$ENV regress service=$svc live=$live_tag cnf=$cnf_tag (an apply would roll the hub BACK: this tree is behind the one that deployed $live_tag)"
  [[ "${ALLOW_IMAGE_REGRESS:-}" == 1 ]] && return 0
  return 3
}
