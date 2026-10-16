#!/bin/bash
#------------------------------------------------------------------------------
# @description Roll the spool hub of one cloud env back (or forward) to a
# @description release it was built for before: the Cloud Run service is
# @description pointed at that release's image, already in the env's registry.
# @description Nothing is built, no tag is minted, no migration runs, and no
# @description workflow is touched (SPL-2131, robustness gap 4).
# @description   1. TO -> the release key (image tag) and its commit:
# @description      v<X.Y.Z>[-c<N>]  that v-tag
# @description      <sha>            a trunk commit; its newest v-tag
# @description      previous         the newest revision whose image differs
# @description                       from the serving one
# @description      <service>-NNNNN-xxx  that Cloud Run revision's image
# @description      a revision / previous maps back through the registry's tags
# @description      (digest -> release key -> v-tag -> commit). Anything else,
# @description      or a release whose image is not in this env's registry,
# @description      is refused (rc 3).
# @description   2. prd only when dev already serves that commit (rc 4):
# @description      dev equals or leads prd. ENV_ORDER_OVERRIDE=<owner msg id>
# @description   3. the schema: every migration the served code has and the
# @description      target lacks is listed; a non-additive one refuses (rc 5)
# @description      unless ROLLBACK_SCHEMA_OK=1
# @description   4. DRY_RUN=1 (default): print the plan, change nothing
# @description   5. DRY_RUN=0: gcloud run services update --image <ref>, then
# @description      do_check_hub_deploy and GET /version .commit == the target
# @description Identity: the env's project SA (do_gcp_pin_account), --account on
# @description every gcloud call; never the owner account.
# @param ENV - required: dev or prd
# @param TO - required: v<X.Y.Z>[-c<N>] | <trunk sha> | previous | <revision name>
# @param DRY_RUN (optional) - 1 (default): print the plan; 0: roll
# @param ROLLBACK_SCHEMA_OK (optional) - 1: roll back over a non-additive newer migration (after reading it)
# @param ENV_ORDER_OVERRIDE (optional) - <owner msg id>: prd without dev first (an emergency)
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (never the owner account)
# @example ENV=dev TO=previous ./run -a do_hub_rollback
# @example ENV=dev TO=v1.0.6-c3 DRY_RUN=0 ./run -a do_hub_rollback
# @example ENV=prd TO=v1.0.6-c3 DRY_RUN=0 ./run -a do_hub_rollback
#------------------------------------------------------------------------------
do_hub_rollback() {
  spl_require_cloud_env || return 2
  [[ -n "${TO:-}" ]] || { do_log "FATAL TO must be set: v<X.Y.Z>[-c<N>], a trunk sha, previous or a revision name (no default)"; return 2; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 2; dry=0; fi
  do_require_bin git yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  local svc api_fqdn
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }
  [[ -n "$api_fqdn" && "$api_fqdn" != null ]] || { do_log "FATAL cnf env.dns.api_fqdn is empty for $ENV"; return 1; }
  spl_rb_fetch || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local -a gsvc=(--project="$SPL_PROJECT" --region="$SPL_REGION")
  local repo="${SPL_IMAGE_CNF_REF%:*}" served live rc=0
  served="$(spl_ld_served "https://$api_fqdn/version" commit)"
  live="$(gcloud run services describe "$svc" "${gsvc[@]}" --account="$GCP_ACCOUNT" --format='value(spec.template.spec.containers[0].image)')" ||
    { do_log "FATAL cannot describe $svc in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT"; return 1; }

  _hub_rb_resolve "$TO" "$svc" "$repo" || return $?
  local ref="$repo:$HUB_RB_KEY" digest
  digest="$(gcloud artifacts docker images describe "$ref" --account="$GCP_ACCOUNT" --format='value(image_summary.digest)' 2>/dev/null)"
  [[ -n "$digest" ]] || { do_log "FATAL unknown target: $ref is not in the $ENV registry (v$HUB_RB_KEY was not a hub release here)"; return 3; }

  echo "hub-rollback PLAN $ENV TO=$TO"
  echo "  served    ${served:-unknown} (GET https://$api_fqdn/version)"
  echo "  live      $live"
  echo "  target    $ref ($digest) = commit $HUB_RB_SHA"
  spl_rb_prd_gate hub "$HUB_RB_SHA" || return $?
  spl_rb_schema_check "$HUB_RB_SHA" "$served" || return $?
  _hub_rb_wui_order "$HUB_RB_SHA"
  echo "  roll      gcloud run services update $svc --project=$SPL_PROJECT --region=$SPL_REGION --image $ref"
  echo "  verify    do_check_hub_deploy SPL_HUB_IMAGE_TAG=$HUB_RB_KEY; https://$api_fqdn/version .commit == ${HUB_RB_SHA:0:12}"
  if ((dry)); then
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to roll." >&2
    return 0
  fi

  if [[ "$live" == "$ref" ]]; then
    echo "hub-rollback $ENV $svc already runs $ref: nothing to roll"
  else
    gcloud run services update "$svc" "${gsvc[@]}" --account="$GCP_ACCOUNT" --image "$ref" --quiet ||
      { do_log "FATAL gcloud run services update $svc failed"; return 1; }
  fi
  local i got=""
  for i in 1 2 3 4 5 6; do
    rc=0
    (SPL_HUB_IMAGE_TAG="$HUB_RB_KEY" do_check_hub_deploy) || rc=$?
    [[ $rc -eq 4 && $i -lt 6 ]] || break
    echo "hub-rollback $ENV not Ready yet (attempt $i/6) -- waiting"; sleep "${HUB_RB_WAIT_S:-10}"
  done
  ((rc == 0)) || { do_log "FATAL do_check_hub_deploy rc $rc (3 = another image, 4 = not Ready)"; return 1; }
  for i in 1 2 3 4 5 6; do
    got="$(spl_ld_served "https://$api_fqdn/version?ts=$(date +%s)" commit)"
    [[ "$got" == "$HUB_RB_SHA" ]] && break
    sleep "${HUB_RB_WAIT_S:-10}"
  done
  [[ "$got" == "$HUB_RB_SHA" ]] || { do_log "FATAL https://$api_fqdn/version serves '${got:0:12}', not ${HUB_RB_SHA:0:12}"; return 1; }
  echo "hub-rollback $ENV OK https://$api_fqdn/version commit=$got image=$ref"
  spl_rb_hold_note hub
}

# _hub_rb_resolve <to> <svc> <repo> -> sets HUB_RB_KEY (the image tag) and
# HUB_RB_SHA (its commit); rc 2 a bad form, rc 3 an unknown target
_hub_rb_resolve() {
  local to="$1" svc="$2" repo="$3" sha digest rc=0
  HUB_RB_KEY="" HUB_RB_SHA=""
  sha="$(spl_rb_commit_of "$to")" || rc=$?
  if ((rc == 0)); then
    if [[ "$to" == v* ]]; then HUB_RB_KEY="${to#v}"
    else HUB_RB_KEY="$(spl_rb_key_of "$sha")" ||
      { do_log "FATAL unknown target: ${sha:0:12} carries no v-tag, so it was never deployed"; return 3; }
    fi
    HUB_RB_SHA="$sha"
    return 0
  fi
  ((rc == 2)) || return 3
  if [[ "$to" == previous ]]; then
    digest="$(_hub_rb_previous_digest "$svc")" || return 3
  elif [[ "$to" =~ ^$svc-[0-9]{5}-[a-z0-9]{3}$ ]]; then
    digest="$(gcloud run revisions describe "$to" --project="$SPL_PROJECT" --region="$SPL_REGION" --account="$GCP_ACCOUNT" \
      --format='value(status.imageDigest)' 2>/dev/null)"
    [[ "$digest" == *@sha256:* ]] || { do_log "FATAL unknown target: no revision $to of $svc"; return 3; }
  else
    do_log "FATAL TO='$to' is none of v<X.Y.Z>[-c<N>], a sha, previous or a $svc-NNNNN-xxx revision"
    return 2
  fi
  digest="${digest##*@}"
  HUB_RB_KEY="$(gcloud artifacts docker tags list "$repo" --account="$GCP_ACCOUNT" --filter="version~${digest#sha256:}" \
    --format='value(tag)' 2>/dev/null | while read -r t; do spl_release_key_valid "$t" && echo "$t"; done | spl_release_key_max)"
  [[ -n "$HUB_RB_KEY" ]] || { do_log "FATAL unknown target: image $digest carries no release tag in $repo"; return 3; }
  HUB_RB_SHA="$(spl_rb_sha_of_key "$HUB_RB_KEY")" ||
    { do_log "FATAL unknown target: release $HUB_RB_KEY has no v-tag v$HUB_RB_KEY in git"; return 3; }
  echo "hub-rollback $ENV TO=$to -> $digest -> release $HUB_RB_KEY -> ${HUB_RB_SHA:0:12}"
}

# _hub_rb_previous_digest <svc> -> image@digest of the newest revision older
# than the serving one whose image differs (a heal restart reuses an image)
_hub_rb_previous_digest() {
  local svc="$1" cur out
  cur="$(gcloud run services describe "$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" --account="$GCP_ACCOUNT" \
    --format='value(status.latestReadyRevisionName)')" || return 1
  out="$(gcloud run revisions list --service="$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" --account="$GCP_ACCOUNT" \
    --limit=50 --format=json | jq -r --arg cur "$cur" '
      sort_by(.metadata.creationTimestamp) | reverse
      | (map(.metadata.name) | index($cur)) as $i
      | if $i == null then empty else
          .[$i].status.imageDigest as $d
          | [.[$i + 1:][] | select(.status.imageDigest != $d)][0].status.imageDigest // empty
        end')"
  [[ -n "$out" ]] || { do_log "FATAL unknown target: no revision of $svc before $cur runs another image" >&2; return 1; }
  printf '%s' "$out"
}

# _hub_rb_wui_order <hub target sha> -> WARN when this env's WUI is newer than
# the hub target: a WUI waits for a hub at least as new (wf 30), so roll the
# WUI back first
_hub_rb_wui_order() {
  local site wui
  site="$(yq -r '.env.steps."019-firebase-static-site".site_id // ""' "$SPL_CNF")"
  [[ -n "$site" && "$site" != null ]] || return 0
  wui="$(spl_ld_served "https://$site.web.app/build.json?rb=$(date +%s)" commit)"
  if [[ -n "$wui" ]] && ! git -C "$APP_PATH" merge-base --is-ancestor "$wui" "$1" 2>/dev/null; then
    do_log "WARN the $ENV WUI serves ${wui:0:12}, newer than this hub target: it may call API the older hub lacks; roll the WUI back first (do_wui_rollback)"
  fi
}
