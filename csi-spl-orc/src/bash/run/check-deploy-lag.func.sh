#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only COMMIT-level deploy-lag check for one cloud env: is the
# @description commit under test actually SERVED by that env's hub and WUI?
# @description
# @description The gap it closes. do_check_hub_deploy asks "does the live
# @description service run the image cnf NAMES?" -- image vs cnf. That stays
# @description green when a lane lands hub source and does not bump
# @description env.hub.image.tag: cnf still names the old tag, the service still
# @description runs it, 20 runs the tests and (as its own header says) "deploys
# @description nothing new", and every gate is green while trunk's code is not
# @description live. Measured: the hourly 00 watch concluded success on 8
# @description consecutive runs (35463951071 2026-09-19T19:18Z .. 35484293822
# @description 2026-09-20T02:33Z) while dev and prd both served af8c6db and
# @description trunk 13e70d0 carried hub source a228c92 and f2c024a.
# @description This action asks the other question -- commit vs trunk -- by
# @description reading what the env PUBLISHES about itself:
# @description   hub  GET https://<env.dns.api_fqdn>/version   -> .commit
# @description   wui  GET https://<env.dns.fqdn>/build.json    -> .commit
# @description
# @description A commit only counts as lag when it changed an INPUT of that
# @description component, so a docs-only or iac-only trunk head is never red:
# @description   hub -- what the image is built from, as do_build_push_hub_image
# @description          itself defines it: the Go module, the DDL dir cnf
# @description          names (env.hub.image.sql_src) + spool-hub-roles, the
# @description          hub Dockerfile, its entrypoint and .version.
# @description   wui -- the allow-list workflow 30 deploys on, read from its
# @description          `on.push.paths` (_spl_wui_input_paths). The two
# @description          lists differ ON PURPOSE: 30 deploys on every path it
# @description          triggers on, 20 does not (only a tag bump ships).
# @description
# @description GRACE_MINUTES keeps a just-pushed commit out of the verdict: the
# @description age of the OLDEST unserved input commit must exceed it before the
# @description verdict turns to lagging, so a normal pipeline (build, deploy,
# @description propagate) is never reported as lag.
# @description The age runs from when TRUNK got that commit, not from its commit
# @description time (%ct): a reviewed sha landed as-is keeps its review-branch
# @description %ct, so its review time read as lag (SPL-3653: ac97393dc, GAP
# @description age=73m four minutes after it landed). The landing time is the
# @description push to master that brought it, from GitHub's repo activity API
# @description (`gh api .../activity`, the newest 100 pushes): the one record
# @description that exists both on a box and in CI's fresh clone. It is read
# @description only when the %ct age is already past the grace (a landing is
# @description never older than its commit). Unreadable (no gh, no token, the
# @description push older than the page) -> the %ct age, and the line says so:
# @description age_from=landed | commit | commit:<why the landing was unread>.
# @description
# @description Prints one verdict line per component, `<env> <component>
# @description <verdict> ...`, and exits with the WORST of them:
# @description   0 current  - served, or ahead, or no input of it changed since
# @description   0 pending  - it did change, but within the grace period
# @description   3 lagging  - it changed, the grace has passed, and it is not live
# @description   1          - cannot tell (no endpoint, junk body, commit not in
# @description                this checkout -- a shallow clone, so fetch-depth 0)
# @description Reads only: one HTTPS GET per component and local git. No GCP
# @description call, no credential, nothing mutated.
# @param ENV - required: dev or prd
# @param SHA - optional: the commit that must be live (default: HEAD)
# @param COMPONENT - optional: hub | wui | all (default all)
# @param GRACE_MINUTES - optional: minutes of grace for a fresh commit (default 45)
# @param LAG_HTTP_TIMEOUT - optional: per-probe curl --max-time seconds (default 15)
# @param LAG_HUB_URL / LAG_WUI_URL - optional: override the cnf-derived probe URL (tests)
# @param LAG_TRUNK - optional: the branch whose pushes date a landing (default master)
# @example ENV=dev ./run -a do_check_deploy_lag
# @example ENV=prd SHA=$(git rev-parse origin/master) GRACE_MINUTES=60 ./run -a do_check_deploy_lag
#------------------------------------------------------------------------------
do_check_deploy_lag() {
  do_require_bin yq jq curl git || return 1
  do_spl_cloud_cnf || return 1

  local component="${COMPONENT:-all}"
  case "$component" in hub|wui|all) ;; *) do_log "FATAL COMPONENT must be hub, wui or all, got: '$component'"; return 1 ;; esac
  local grace="${GRACE_MINUTES:-45}"
  [[ "$grace" =~ ^[0-9]+$ ]] || { do_log "FATAL GRACE_MINUTES must be a whole number of minutes, got: '$grace'"; return 1; }
  local timeout="${LAG_HTTP_TIMEOUT:-15}"

  local sha
  sha="$(git -C "$APP_PATH" rev-parse --verify "${SHA:-HEAD}^{commit}" 2>/dev/null)" ||
    { do_log "FATAL SHA '${SHA:-HEAD}' is not a commit in $APP_PATH"; return 1; }

  local api_fqdn site_fqdn sql_src
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  site_fqdn="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
  sql_src="$(yq -r '.env.hub.image.sql_src // ""' "$SPL_CNF")"
  [[ -n "$api_fqdn" && "$api_fqdn" != null ]] || { do_log "FATAL cnf env.dns.api_fqdn is empty for $ENV"; return 1; }
  [[ -n "$site_fqdn" && "$site_fqdn" != null ]] || { do_log "FATAL cnf env.dns.fqdn is empty for $ENV"; return 1; }
  [[ -n "$sql_src" && "$sql_src" != null ]] || { do_log "FATAL cnf env.hub.image.sql_src is empty for $ENV"; return 1; }

  # What the hub IMAGE is built from -- the ONE list, shared with workflow
  # 20's forward guard (hub-deploy-guard.sh `paths`, CLE-77918): THE hub
  # image's inputs (specs/072 A21). NOT the api test scripts: they are not
  # copied into the image.
  local -a hub_paths=()
  mapfile -t hub_paths < <(APP_PATH="$APP_PATH" HUB_SQL_SRC="$sql_src" bash "$PROJ_PATH/src/bash/scripts/hub-deploy-guard.sh" paths)
  (( ${#hub_paths[@]} )) || { do_log "FATAL hub-deploy-guard.sh paths printed no hub input"; return 1; }
  # Workflow 30's push allow-list, read from the workflow itself: every one of
  # these DOES roll the site. A hand-kept copy here drifted (SPL-2272: it had no
  # csi-spl-doc/blog/posts/**, so a blog post commit read as "no deploy").
  local -a wui_paths=()
  mapfile -t wui_paths < <(_spl_wui_input_paths "$APP_PATH")
  (( ${#wui_paths[@]} )) || { do_log "FATAL workflow 30 names no push paths: $APP_PATH/.github/workflows/30_wui-build-deploy.yml"; return 1; }

  local worst=0 rc
  if [[ "$component" == hub || "$component" == all ]]; then
    _spl_lag_one hub "${LAG_HUB_URL:-https://$api_fqdn/version}" "$sha" "$grace" "$timeout" "${hub_paths[@]}"
    rc=$?; (( rc > worst )) && worst=$rc
  fi
  if [[ "$component" == wui || "$component" == all ]]; then
    _spl_lag_one wui "${LAG_WUI_URL:-https://$site_fqdn/build.json}" "$sha" "$grace" "$timeout" "${wui_paths[@]}"
    rc=$?; (( rc > worst )) && worst=$rc
  fi
  # 3 (lagging) is the verdict worth acting on; 1 (cannot tell) must not mask it
  (( worst == 1 )) && return 1
  return "$worst"
}

# _spl_wui_input_paths <app path> -> workflow 30's `on.push.paths`, one git
# pathspec a line. `:(glob)` gives git GitHub's reading of `*` (one path
# level) and `**` (any depth); a leading `!` becomes an exclude.
_spl_wui_input_paths() {
  local wf="$1/.github/workflows/30_wui-build-deploy.yml" p
  [[ -f "$wf" ]] || return 1
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != null ]] || continue
    if [[ "$p" == '!'* ]]; then echo ":(glob,exclude)${p#!}"; else echo ":(glob)$p"; fi
  done < <(yq -r '.on.push.paths[]' "$wf" 2>/dev/null)
}

# _spl_lag_one <component> <url> <sha> <grace min> <timeout s> <path...>
# -> prints one verdict line; 0 current/pending, 3 lagging, 1 cannot tell
_spl_lag_one() {
  local comp="$1" url="$2" sha="$3" grace="$4" timeout="$5"; shift 5
  local -a paths=("$@")

  local body served
  body="$(curl -sS --max-time "$timeout" -H 'Cache-Control: no-cache' "$url" 2>/dev/null)" || {
    echo "$ENV $comp unknown url=$url reason=unreachable"; return 1; }
  served="$(jq -r 'if type == "object" and (.commit | type) == "string" then .commit else "" end' <<<"$body" 2>/dev/null)"
  [[ "$served" =~ ^[0-9a-f]{40}$ ]] || {
    echo "$ENV $comp unknown url=$url reason=no 40-hex .commit in the body"; return 1; }

  git -C "$APP_PATH" cat-file -e "$served^{commit}" 2>/dev/null || {
    echo "$ENV $comp unknown url=$url served=${served:0:8} reason=that commit is not in this checkout (shallow clone? use fetch-depth 0)"
    return 1; }

  if [[ "$served" == "$sha" ]] || git -C "$APP_PATH" merge-base --is-ancestor "$sha" "$served" 2>/dev/null; then
    echo "$ENV $comp current served=${served:0:8} sha=${sha:0:8} (the env serves this commit or a later one)"
    return 0
  fi
  git -C "$APP_PATH" merge-base --is-ancestor "$served" "$sha" 2>/dev/null || {
    echo "$ENV $comp unknown served=${served:0:8} sha=${sha:0:8} reason=the served commit is not an ancestor of the one under test"
    return 1; }

  # One history walk, not two: the count (--count) and the oldest unserved
  # input commit (--reverse | head -1) walked the same `served..sha` range with
  # the same pathspec. Walk it once (--reverse) and read both off the list -- n
  # is its length, oldest is its first line. ~15 ms -> ~7 ms per component.
  local revs
  revs="$(git -C "$APP_PATH" rev-list --reverse "$served..$sha" -- "${paths[@]}")" || {
    echo "$ENV $comp unknown served=${served:0:8} sha=${sha:0:8} reason=git rev-list failed"; return 1; }
  if [[ -z "$revs" ]]; then
    echo "$ENV $comp current served=${served:0:8} sha=${sha:0:8} n=0 (no $comp build input changed since the served commit)"
    return 0
  fi
  local -a changed=()
  mapfile -t changed <<<"$revs"
  local n=${#changed[@]}

  # the OLDEST unserved input commit decides the age: that is how long the env
  # has been behind, not how long ago the newest push was
  local oldest age_min from
  oldest="${changed[0]}"
  read -r age_min from < <(_spl_lag_age "$oldest" "$grace" "$timeout")
  if [[ "$age_min" -lt "$grace" ]]; then
    echo "$ENV $comp pending served=${served:0:8} sha=${sha:0:8} n=$n oldest=${oldest:0:8} age=${age_min}m grace=${grace}m age_from=$from (a roll is still within its grace period)"
    return 0
  fi
  echo "$ENV $comp lagging served=${served:0:8} sha=${sha:0:8} n=$n oldest=${oldest:0:8} age=${age_min}m grace=${grace}m age_from=$from url=$url"
  return 3
}

# _spl_lag_age <commit> <grace min> <timeout s> -> "<age in minutes> <from>":
# minutes since trunk got <commit> (from=landed), or since its commit time
# when that is already inside the grace (from=commit: a landing is never
# older) or the landing cannot be read (from=commit:<why>).
_spl_lag_age() {
  local c="$1" grace="$2" timeout="$3" now first landed
  now="$(date -u +%s)"
  first="$(git -C "$APP_PATH" show -s --format=%ct "$c")"
  if (( grace == 0 || (now - first) / 60 < grace )); then
    echo "$(( (now - first) / 60 )) commit"; return 0
  fi
  if landed="$(_spl_lag_landed_at "$c" "$timeout")"; then
    echo "$(( (now - landed) / 60 )) landed"
  else
    # one WARN on stderr (stdout is the age line): a CI step with no GH_TOKEN
    # must not fall back to the commit time silently (SPL-4127)
    do_log "WARN the landing of ${c:0:8} is unread ($landed): its age runs from the commit time; in CI set GH_TOKEN on the step" >&2
    echo "$(( (now - first) / 60 )) commit:$landed"
  fi
}

# _spl_lag_landed_at <commit> <timeout s> -> the epoch second of the push to
# trunk that brought <commit>: the newest-first push whose `after` holds it and
# whose `before` does not. rc 1 with a one-word reason when it cannot be read.
_spl_lag_landed_at() {
  local c="$1" timeout="$2" json after before ts
  json="$(cd "$APP_PATH" && timeout "$timeout" gh api \
    "repos/{owner}/{repo}/activity?ref=refs/heads/${LAG_TRUNK:-master}&activity_type=push&per_page=100" 2>/dev/null)" ||
    { echo gh-api-failed; return 1; }
  while read -r after before ts; do
    git -C "$APP_PATH" merge-base --is-ancestor "$c" "$after" 2>/dev/null || continue
    if [[ ! "$before" =~ ^0+$ ]] && git -C "$APP_PATH" merge-base --is-ancestor "$c" "$before" 2>/dev/null; then continue; fi
    date -u -d "$ts" +%s 2>/dev/null && return 0
    echo bad-push-timestamp; return 1
  done < <(jq -r '.[]? | "\(.after) \(.before) \(.timestamp)"' <<<"$json" 2>/dev/null)
  echo not-in-last-100-pushes; return 1
}
