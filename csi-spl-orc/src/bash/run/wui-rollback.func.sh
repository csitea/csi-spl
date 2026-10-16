#!/bin/bash
#------------------------------------------------------------------------------
# @description Roll the web UI of one cloud env back (or forward) to a Firebase
# @description Hosting version that env served before: a new release of that
# @description stored version on the live channel. Nothing is built and no
# @description workflow is touched (SPL-2131, robustness gap 4).
# @description   1. TO -> the Firebase version and, where it can be told, its commit:
# @description      v<X.Y.Z>[-c<N>] / <sha>  the version wf 30 released for
# @description                  that commit in this env (its "firebase deploy"
# @description                  step window, read with gh, holds the release)
# @description      previous    the newest live release before the current one
# @description                  with another version
# @description      <16-hex>    that Firebase version id (a box deploy,
# @description                  do_deploy_wui, has no wf 30 run: name it so)
# @description      Anything else, or a version not in the live history, is
# @description      refused (rc 3).
# @description   2. prd only when dev already serves that commit (rc 4):
# @description      dev equals or leads prd. ENV_ORDER_OVERRIDE=<owner msg id>
# @description   3. DRY_RUN=1 (default): print the plan, change nothing
# @description   4. DRY_RUN=0: create the release, then <site>.web.app/build.json
# @description      .commit must be the target; when it is not, the version that
# @description      was live is released again and the action fails
# @description A release carries the whole hosting config of its time (headers,
# @description CSP connect-src, rewrites): a tenant host added since is missing
# @description from an older version's CSP.
# @description Identity: the env's project SA (do_gcp_pin_account), its token
# @description on stdin of curl (never argv); never the owner account.
# @param ENV - required: dev or prd
# @param TO - required: v<X.Y.Z>[-c<N>] | <trunk sha> | previous | <Firebase version id>
# @param DRY_RUN (optional) - 1 (default): print the plan; 0: release
# @param ENV_ORDER_OVERRIDE (optional) - <owner msg id>: prd without dev first (an emergency)
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (never the owner account)
# @param GH_TOKEN (optional) - for gh: resolving a v-tag / sha needs the wf 30 runs
# @example ENV=dev TO=previous ./run -a do_wui_rollback
# @example ENV=dev TO=v1.1.0 DRY_RUN=0 ./run -a do_wui_rollback
#------------------------------------------------------------------------------
do_wui_rollback() {
  spl_require_cloud_env || return 2
  [[ -n "${TO:-}" ]] || { do_log "FATAL TO must be set: v<X.Y.Z>[-c<N>], a trunk sha, previous or a Firebase version id (no default)"; return 2; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 2; dry=0; fi
  do_require_bin git yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  local site
  site="$(yq -r '.env.steps."019-firebase-static-site".site_id // ""' "$SPL_CNF")"
  [[ -n "$site" && "$site" != null ]] || { do_log "FATAL cnf steps.019-firebase-static-site.site_id is empty for $ENV"; return 1; }
  spl_rb_fetch || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local rel served
  rel="$(_wui_rb_api GET "sites/$site/channels/live/releases?pageSize=100")" || rel=""
  jq -e '.releases | length > 0' >/dev/null 2>&1 <<<"$rel" ||
    { do_log "FATAL cannot list the live releases of $site as $GCP_ACCOUNT: $(jq -c '.error? // empty' <<<"$rel" 2>/dev/null)"; return 1; }
  # one row per release, newest first: <epoch> <version id> <releaseTime>
  local rows live_v
  rows="$(jq -r '.releases[] | "\(.releaseTime) \(.version.name | split("/")[-1])"' <<<"$rel" |
    while read -r t v; do echo "$(date -d "$t" +%s) $v $t"; done)"
  live_v="$(awk 'NR == 1 {print $2}' <<<"$rows")"
  served="$(spl_ld_served "https://$site.web.app/build.json?rb=$(date +%s)" commit)"

  _wui_rb_resolve "$TO" "$rows" "$live_v" || return $?
  echo "wui-rollback PLAN $ENV TO=$TO"
  echo "  served    ${served:-unknown} (https://$site.web.app/build.json), version $live_v"
  echo "  target    version $WUI_RB_VERSION (released $WUI_RB_TIME) = commit ${WUI_RB_SHA:-unknown until it is live}"
  spl_rb_prd_gate wui "$WUI_RB_SHA" || return $?
  echo "  release   POST sites/$site/channels/live/releases?versionName=sites/$site/versions/$WUI_RB_VERSION"
  echo "  verify    https://$site.web.app/build.json .commit == ${WUI_RB_SHA:-<printed>}; else release $live_v again"
  if ((dry)); then
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to release." >&2
    return 0
  fi

  if [[ "$WUI_RB_VERSION" == "$live_v" ]]; then
    echo "wui-rollback $ENV $site already serves version $live_v: nothing to release"
  else
    _wui_rb_release "$site" "$WUI_RB_VERSION" "rollback to ${WUI_RB_SHA:-version $WUI_RB_VERSION} (do_wui_rollback, was $live_v)" || return 1
  fi
  local got=""
  for _ in 1 2 3 4 5 6; do
    got="$(spl_ld_served "https://$site.web.app/build.json?rb=$(date +%s)" commit)"
    [[ -z "$WUI_RB_SHA" && -n "$got" && "$got" != "$served" ]] && break
    [[ -n "$WUI_RB_SHA" && "$got" == "$WUI_RB_SHA" ]] && break
    sleep "${WUI_RB_WAIT_S:-10}"
  done
  if [[ -n "$WUI_RB_SHA" && "$got" != "$WUI_RB_SHA" ]]; then
    do_log "FATAL https://$site.web.app/build.json serves '${got:0:12}', not ${WUI_RB_SHA:0:12}: releasing $live_v again"
    _wui_rb_release "$site" "$live_v" "restore after a failed do_wui_rollback" || true
    return 1
  fi
  echo "wui-rollback $ENV OK https://$site.web.app/build.json commit=${got:-unknown} version=$WUI_RB_VERSION"
  spl_rb_hold_note wui
}

# _wui_rb_api <GET|POST> <path> [json body] -> the Firebase Hosting REST answer
_wui_rb_api() {
  local tok
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)" ||
    { do_log "FATAL no access token for $GCP_ACCOUNT" >&2; return 1; }
  # The bearer rides on stdin (-K -), never on curl's argv where ps shows it.
  curl -sS --max-time 30 -X "$1" -K - -H "x-goog-user-project: $SPL_PROJECT" -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "https://firebasehosting.googleapis.com/v1beta1/$2" <<<"header = \"Authorization: Bearer $tok\""
}

# _wui_rb_release <site> <version id> <message> -> a live release of the version
_wui_rb_release() {
  local out body
  body="$(jq -nc --arg m "$3" '{message: $m}')"
  out="$(_wui_rb_api POST "sites/$1/channels/live/releases?versionName=sites/$1/versions/$2" "$body")"
  if jq -e '.name' >/dev/null 2>&1 <<<"$out"; then
    echo "wui-rollback $ENV released version $2: $(jq -r '.name' <<<"$out")"
    return 0
  fi
  out="$(jq -c '.error? // .' <<<"$out" 2>/dev/null)"
  do_log "FATAL the release of version $2 on $1 failed: ${out:0:400}"
  return 1
}

# _wui_rb_resolve <to> <rows> <live version> -> sets WUI_RB_VERSION,
# WUI_RB_TIME and WUI_RB_SHA ("" when no wf 30 run tells it); rc 2 a bad
# form, rc 3 an unknown target
_wui_rb_resolve() {
  local to="$1" rows="$2" live="$3" sha="" row="" w s e rc=0
  WUI_RB_VERSION="" WUI_RB_TIME="" WUI_RB_SHA=""
  # a Firebase version id is 16 hex, which also reads as a short sha: the live
  # history decides first
  [[ "$to" =~ ^[0-9a-f]{16}$ ]] && row="$(awk -v v="$to" '$2 == v {print; exit}' <<<"$rows")"
  if [[ -z "$row" && "$to" == previous ]]; then
    row="$(awk -v live="$live" '$2 != live {print; exit}' <<<"$rows")"
    [[ -n "$row" ]] || { do_log "FATAL unknown target: no live release before $live with another version"; return 3; }
  elif [[ -z "$row" ]]; then
    sha="$(spl_rb_commit_of "$to")" || rc=$?
    if ((rc == 2)); then
      do_log "FATAL TO='$to' is none of v<X.Y.Z>[-c<N>], a sha, previous or a 16-hex Firebase version id"
      return 2
    fi
    ((rc == 0)) || return 3
    while read -r s e _; do
      row="$(awk -v s="$s" -v e="$e" '$1 >= s - 2 && $1 <= e + 2 {print; exit}' <<<"$rows")"
      [[ -n "$row" ]] && break
    done < <(_wui_rb_windows "head_sha=$sha")
    [[ -n "$row" ]] || { do_log "FATAL unknown target: no wf 30 release of ${sha:0:12} in the $ENV live history (a WUI deploy runs only on WUI inputs; a box deploy has no run: name the Firebase version id)"; return 3; }
    WUI_RB_SHA="$sha"
  fi
  read -r w WUI_RB_VERSION WUI_RB_TIME <<<"$row"
  [[ -n "$WUI_RB_SHA" ]] || WUI_RB_SHA="$(_wui_rb_sha_at "$w")"
}

# _wui_rb_sha_at <epoch> -> the commit whose wf 30 "firebase deploy" step for
# ENV ran when that release was made; "" when gh cannot tell
_wui_rb_sha_at() {
  local t="$1" from to s e sha
  from="$(date -u -d "@$((t - 10800))" +%FT%TZ)"; to="$(date -u -d "@$((t + 60))" +%FT%TZ)"
  while read -r s e sha; do
    ((t >= s - 2 && t <= e + 2)) && { printf '%s' "$sha"; return 0; }
  done < <(_wui_rb_windows "created=$from..$to")
  return 0
}

# _wui_rb_windows <runs query> -> "<start epoch> <end epoch> <head sha>" per
# successful "firebase deploy" step of the "Deploy WUI to <ENV>" job of the wf
# 30 runs the query selects (gh, the repo of APP_PATH's remote)
_wui_rb_windows() {
  command -v gh >/dev/null || { do_log "WARN no gh: a wf 30 run cannot tell a WUI release's commit" >&2; return 0; }
  local id sha s e
  (cd "$APP_PATH" && gh api "repos/{owner}/{repo}/actions/workflows/30_wui-build-deploy.yml/runs?$1&per_page=30" \
    --jq '.workflow_runs[] | "\(.id) \(.head_sha)"' 2>/dev/null) |
    while read -r id sha; do
      (cd "$APP_PATH" && gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" --jq \
        '.jobs[] | select(.name == "Deploy WUI to '"$ENV"'") | .steps[] | select((.name | startswith("firebase deploy")) and .conclusion == "success") | "\(.started_at) \(.completed_at)"' 2>/dev/null) |
        while read -r s e; do echo "$(date -d "$s" +%s) $(date -d "$e" +%s) $sha"; done
    done
}
