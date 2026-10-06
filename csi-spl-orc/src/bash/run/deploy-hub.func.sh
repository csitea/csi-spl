#!/bin/bash
#------------------------------------------------------------------------------
# @description Deploy the spool hub to a cloud env FROM THIS BOX, no GitHub in
# @description the path: what the deploy job of workflow 20 does, step for
# @description step, calling the same actions (owner order 2026-10-06, t1
# @description 916c8696: "Deploy either from the SAT or from the Think box").
# @description   1. the commit: SHA, default origin/master head; refused unless
# @description      it is on origin/master. Built from a clean detached
# @description      checkout of it, never from the caller's working tree.
# @description   2. a flock per env (one hub deploy per env on this box)
# @description   3. the forward-only guard (hub-deploy-guard.sh decide against
# @description      the served /version): an env that already serves it, or
# @description      serves a later hub, stands down (exit 0). DEPLOY_GUARD=0
# @description      skips it, as a workflow_dispatch run does.
# @description   4. do_release_version (mint: push the v-tag, or re-read it)
# @description   5. the image: already in the registry -> reused, else
# @description      do_build_push_hub_image with the minted tag
# @description   6. do_spl_db_bootstrap (migrations before the roll)
# @description   7. gcloud run services update <svc> --image <minted ref>
# @description   8. do_heal_hub_deploy (only when it rolled)
# @description   9. do_check_hub_deploy (retried while not Ready)
# @description  10. do_release_note_ingest (a failure only WARNs, as in 20)
# @description  11. GET https://<api_fqdn>/version: .commit must be the sha
# @description Identity: the env's project SA from its key (do_gcp_pin_account)
# @description in a throwaway CLOUDSDK_CONFIG, --account on every call; never
# @description the owner account. DRY_RUN=1 (default) prints the plan and
# @description touches nothing: no tag, no image, no roll.
# @param ENV - required: dev or prd
# @param SHA (optional) - the commit to deploy, default origin/master head; must be on origin/master
# @param DRY_RUN (optional) - 1 (default): print the plan; 0: deploy
# @param DEPLOY_GUARD (optional) - 1 (default): forward-only guard; 0: deploy even when the env serves it or a later hub
# @param DEPLOY_LOCK_WAIT_S (optional) - seconds to wait for another deploy's lock, default 0 (refuse)
# @param DEPLOY_LOCK_DIR / DEPLOY_WORK_DIR (optional) - lock dir / parent of the checkout, default under $TMPDIR
# @param KEEP_WORKTREE (optional) - 1 keeps the deploy checkout for a post-mortem
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (never the owner account)
# @example ENV=dev ./run -a do_deploy_hub
# @example ENV=dev DRY_RUN=0 ./run -a do_deploy_hub
# @example ENV=prd DRY_RUN=0 SHA=3ce48b5d5 ./run -a do_deploy_hub
#------------------------------------------------------------------------------
do_deploy_hub() {
  spl_require_cloud_env || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_ld_user_bins
  do_require_bin git yq jq curl flock || return 1
  do_spl_cloud_cnf || return 1
  local sha svc api_fqdn served
  sha="$(spl_ld_resolve_sha)" || return 1
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }
  [[ -n "$api_fqdn" && "$api_fqdn" != null ]] || { do_log "FATAL cnf env.dns.api_fqdn is empty for $ENV"; return 1; }
  served="$(spl_ld_served "https://$api_fqdn/version" commit)"

  if ((dry)); then
    local v
    v="$(spl_ld_run "$APP_PATH" do_release_version DRY_RUN=1 RELEASE_SHA="$sha" 2>/dev/null | grep -xE '[0-9]\.[0-9]\.[0-9]' | tail -1)"
    echo "deploy-hub PLAN $ENV ${sha:0:12} (served ${served:0:12}${served:+ }${served:-unknown})"
    echo "  0 lock    $SPL_ORG_APP hub-$ENV (flock), clean checkout of ${sha:0:12}"
    echo "  1 guard   hub-deploy-guard.sh decide (DEPLOY_GUARD=${DEPLOY_GUARD:-1})"
    echo "  2 mint    do_release_version -> v${v:-?} (predicted; the tag is pushed at DRY_RUN=0)"
    echo "  3 image   ${SPL_IMAGE_REF%:*}:${v:-<key>} (reused when in the registry, else do_build_push_hub_image)"
    echo "  4 db      do_spl_db_bootstrap ($SPL_SQL_CONN / $SPL_DB_NAME)"
    echo "  5 roll    gcloud run services update $svc --project=$SPL_PROJECT --region=$SPL_REGION --image <minted ref>"
    echo "  6 heal    do_heal_hub_deploy, 7 verify do_check_hub_deploy, 8 notes do_release_note_ingest"
    echo "  9 probe   https://$api_fqdn/version .commit == ${sha:0:12}"
    do_log "OK DRY_RUN nothing was deployed. Re-run with DRY_RUN=0 to deploy." >&2
    return 0
  fi

  spl_ld_lock hub || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_ld_go_on_path || return 1
  spl_ld_checkout "$sha" || return 1
  local rc=0
  _deploy_hub_steps "$SPL_LD_WT" "$sha" "$svc" "$api_fqdn" "$served" || rc=$?
  spl_ld_cleanup
  return "$rc"
}

# _deploy_hub_steps <wt> <sha> <svc> <api_fqdn> <served> - steps 1..11 above
_deploy_hub_steps() {
  local wt="$1" sha="$2" svc="$3" api_fqdn="$4" served="$5" verdict rc=0
  if [[ "${DEPLOY_GUARD:-1}" != 0 ]]; then
    verdict="$(cd "$wt" && SHA="$sha" TIP="$(git -C "$APP_PATH" rev-parse "${RELEASE_REMOTE:-origin}/$(spl_ld_trunk)")" SERVED="$served" \
      bash csi-spl-orc/src/bash/scripts/hub-deploy-guard.sh decide)" || rc=$?
    echo "$verdict"
    case "$rc" in
      0) ;;
      10) echo "deploy-hub $ENV ${sha:0:12} STAND-DOWN (forward-only guard; DEPLOY_GUARD=0 deploys anyway)"; return 0 ;;
      *) do_log "FATAL the forward guard could not decide (rc $rc)"; return 1 ;;
    esac
  fi

  spl_ld_mint "$wt" "$sha" || return $?
  local ref="${SPL_IMAGE_CNF_REF%:*}:$SPL_LD_KEY" out
  echo "deploy-hub $ENV release $SPL_LD_VERSION (key $SPL_LD_KEY) -> $ref"
  local -a acct=(GCP_ACCOUNT="$GCP_ACCOUNT" CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-}" ENV="$ENV")

  if out="$(gcloud artifacts docker images describe "$ref" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
              --format='value(image_summary.digest)' 2>&1)"; then
    echo "deploy-hub $ENV image $ref is already in the registry ($out): not rebuilt"
  elif grep -qiE 'not.?found|NOT_FOUND' <<<"$out"; then
    spl_ld_run "$wt" do_build_push_hub_image "${acct[@]}" DRY_RUN=0 SPL_HUB_IMAGE_TAG="$SPL_LD_KEY" ||
      { do_log "FATAL do_build_push_hub_image failed"; return 1; }
  else
    do_log "FATAL cannot read $ref from the registry as $GCP_ACCOUNT: $(tail -1 <<<"$out")"; return 1
  fi

  spl_ld_run "$wt" do_spl_db_bootstrap "${acct[@]}" DRY_RUN=0 || { do_log "FATAL do_spl_db_bootstrap failed: not rolling"; return 1; }

  local -a gsvc=(--project="$SPL_PROJECT" --region="$SPL_REGION")
  local live rolled=0
  live="$(gcloud run services describe "$svc" "${gsvc[@]}" --account="$GCP_ACCOUNT" --format='value(spec.template.spec.containers[0].image)')" ||
    { do_log "FATAL Cloud Run service $svc does not exist in $SPL_PROJECT/$SPL_REGION (apply 030 first; this never creates it)"; return 1; }
  if [[ "$live" == "$ref" ]]; then
    echo "deploy-hub $ENV $svc already runs $ref: nothing to roll"
  else
    echo "deploy-hub $ENV rolling $svc: $live -> $ref"
    gcloud run services update "$svc" "${gsvc[@]}" --account="$GCP_ACCOUNT" --image "$ref" --quiet || { do_log "FATAL gcloud run services update $svc failed"; return 1; }
    rolled=1
  fi
  ((rolled)) && { spl_ld_run "$wt" do_heal_hub_deploy "${acct[@]}" DRY_RUN=0 || return 1; }

  local i
  for i in 1 2 3 4 5 6; do
    rc=0
    spl_ld_run "$wt" do_check_hub_deploy "${acct[@]}" SPL_HUB_IMAGE_TAG="$SPL_LD_KEY" || rc=$?
    [[ $rc -eq 4 && $i -lt 6 ]] || break
    echo "deploy-hub $ENV not Ready yet (attempt $i/6) -- waiting"; sleep 10
  done
  ((rc == 0)) || { do_log "FATAL do_check_hub_deploy rc $rc (3 = another image, 4 = not Ready)"; return 1; }

  spl_ld_run "$wt" do_release_note_ingest "${acct[@]}" DRY_RUN=0 RELEASE_SHA="$sha" ||
    do_log "WARN do_release_note_ingest failed: the release notes miss this deploy (as in 20, not fatal)"

  local got=""
  for i in 1 2 3 4 5 6; do
    got="$(spl_ld_served "https://$api_fqdn/version?ts=$(date +%s)" commit)"
    [[ "$got" == "$sha" ]] && break
    sleep 10
  done
  [[ "$got" == "$sha" ]] || { do_log "FATAL https://$api_fqdn/version serves '${got:0:12}', not ${sha:0:12}"; return 1; }
  echo "deploy-hub $ENV OK https://$api_fqdn/version commit=$sha version=$SPL_LD_VERSION"
}
