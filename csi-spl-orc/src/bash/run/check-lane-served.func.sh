#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only LANE-level "landed and served" verdict: is a lane's
# @description commit on origin/master, made by the right identity, free of AI
# @description trailers, and served by dev and prd? One line answers what a
# @description dispatcher otherwise checks by hand before it accepts a lane
# @description (SDLC round 1 row 09, SPL-2091; 18 owner posts a week asked
# @description "is it deployed / live").
# @description
# @description It composes the checks that already exist, it copies none:
# @description   landed   - git-fetch-fresh.sh --landed (always fetches); for a
# @description              SHA other than the worktree's HEAD the same script
# @description              fetches (--force) and merge-base --is-ancestor asks
# @description   identity - the `%ae %ce` rule of do_spl_push_master: author AND
# @description              committer of every commit in BASE..SHA are LANE_EMAIL
# @description   trailers - anchored: no body line STARTS with Co-Authored-By: or
# @description              Claude-Session: (a commit that only mentions them passes)
# @description   served   - do_check_deploy_lag per env (dev, prd)
# @description The n/a arm: when BASE..SHA changed no hub and no wui build input,
# @description no deploy ever comes (developer guide 1.4), so the env verdict is
# @description n/a and nothing waits on it. That question is asked of
# @description do_check_deploy_lag itself, with its probe pointed at a local
# @description file that says "BASE is served": n=0 for every component = n/a.
# @description So the input lists stay the ones the deploy check owns.
# @description
# @description Prints one line per check on stderr, then the verdict line:
# @description   PASS dev=served prd=served     PASS dev=n/a prd=n/a
# @description   FAIL dev=served prd=lag landed=yes identity=ok trailers=none
# @description Exit: 0 PASS; 3 FAIL only because an env still lags (poll again);
# @description 1 any other FAIL (not landed, identity, trailer, cannot tell).
# @description Reads only: a git fetch, local git, one HTTPS GET per component
# @description and env. No GCP call, no credential, nothing mutated.
# @param SHA - optional: the lane's landing commit (default: HEAD of LANE_WT)
# @param BASE - optional: the commit before the lane's first one (default: SHA^)
# @param LANE_WT - optional: the git checkout to read (default: APP_PATH)
# @param LANE_EMAIL - optional: the one allowed author+committer address (default: git config user.email)
# @param LANE_ENVS - optional: the envs to check (default: "dev prd")
# @param LANE_REMOTE / LANE_BRANCH - optional: the trunk (default: origin / master)
# @param LAG_HUB_URL_<ENV> / LAG_WUI_URL_<ENV> - optional: per-env probe URL override (tests)
# @example ./run -a do_check_lane_served
# @example SHA=<40-hex> BASE=<40-hex> ./run -a do_check_lane_served
#------------------------------------------------------------------------------
do_check_lane_served() {
  do_require_bin git || return 1
  local wt="${LANE_WT:-$APP_PATH}" remote="${LANE_REMOTE:-origin}" branch="${LANE_BRANCH:-master}"
  local sha base email
  sha="$(git -C "$wt" rev-parse --verify "${SHA:-HEAD}^{commit}" 2>/dev/null)" ||
    { do_log "FATAL SHA '${SHA:-HEAD}' is not a commit in $wt"; return 1; }
  base="$(git -C "$wt" rev-parse --verify "${BASE:-$sha^}^{commit}" 2>/dev/null)" ||
    { do_log "FATAL BASE '${BASE:-$sha^}' is not a commit in $wt"; return 1; }
  if [[ "$base" == "$sha" ]] || ! git -C "$wt" merge-base --is-ancestor "$base" "$sha"; then
    do_log "FATAL BASE ${base:0:8} is not a proper ancestor of SHA ${sha:0:8}"; return 1
  fi
  email="${LANE_EMAIL:-$(git -C "$wt" config user.email 2>/dev/null)}"
  [[ -n "$email" ]] || { do_log "FATAL LANE_EMAIL is empty and git config user.email is unset in $wt"; return 1; }

  local landed identity trailers needs verdict="" hard=0 lag=0 e v
  landed="$(_spl_served_landed "$wt" "$sha" "$remote" "$branch")"
  identity="$(_spl_served_identity "$wt" "$base" "$sha" "$email")"
  trailers="$(_spl_served_trailers "$wt" "$base" "$sha")"
  [[ "$landed" == yes && "$identity" == ok && "$trailers" == none ]] || hard=1
  needs="$(_spl_served_needs_deploy "$wt" "$base" "$sha")"
  for e in ${LANE_ENVS:-dev prd}; do
    if [[ "$needs" == no ]]; then
      v=n/a; echo "$e served=n/a (no hub or wui build input in ${base:0:8}..${sha:0:8})" >&2
    else v="$(_spl_served_env "$e" "$wt" "$sha")"; fi
    case "$v" in served|n/a) ;; lag) lag=1 ;; *) hard=1 ;; esac
    verdict+=" $e=$v"
  done
  if (( hard == 0 && lag == 0 )); then
    echo "PASS$verdict sha=${sha:0:8}"; return 0
  fi
  echo "FAIL$verdict landed=$landed identity=$identity trailers=$trailers sha=${sha:0:8}"
  (( hard )) && return 1
  return 3
}

# _spl_served_landed <wt> <sha> <remote> <branch> -> yes | no | unknown
_spl_served_landed() {
  local wt="$1" sha="$2" remote="$3" branch="$4" rc=0
  local fetch="${LANE_FETCH_SCRIPT:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/git-fetch-fresh.sh}"
  if [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" == "$sha" ]]; then
    bash "$fetch" -C "$wt" --remote "$remote" --branch "$branch" --landed >&2 || rc=$?
  elif bash "$fetch" -C "$wt" --remote "$remote" --branch "$branch" --force >&2; then
    git -C "$wt" merge-base --is-ancestor "$sha" "$remote/$branch" || rc=1
  else
    rc=2
  fi
  case "$rc" in 0) echo yes ;; 1) echo no ;; *) echo unknown ;; esac
  echo "landed rc=$rc: ${sha:0:8} on $remote/$branch (0 yes, 1 no, 2 the fetch failed)" >&2
}

# _spl_served_identity <wt> <base> <sha> <email> -> ok | bad
# The `%ae %ce` rule of _spl_push_master_worker, on the lane's range.
_spl_served_identity() {
  local wt="$1" base="$2" sha="$3" email="$4" bad
  bad="$(git -C "$wt" log --no-mailmap --format='%h %ae %ce' "$base..$sha" | awk -v e="$email" '$2 != e || $3 != e')"
  if [[ -z "$bad" ]]; then echo ok; echo "identity=ok author+committer $email" >&2
  else echo bad; printf 'identity=bad (want %s as author and committer):\n%s\n' "$email" "$bad" >&2; fi
}

# _spl_served_trailers <wt> <base> <sha> -> none | found
# Anchored: a line that STARTS with the trailer, not a commit that mentions it.
_spl_served_trailers() {
  local wt="$1" base="$2" sha="$3" h body found=""
  while read -r h; do
    body="$(git -C "$wt" log -1 --format=%B "$h")"
    grep -qiE '^(Co-Authored-By:|Claude-Session:)' <<<"$body" && found+=" ${h:0:8}"
  done < <(git -C "$wt" rev-list "$base..$sha")
  if [[ -z "$found" ]]; then echo none; echo "trailers=none" >&2
  else echo found; echo "trailers=found in$found" >&2; fi
}

# _spl_served_needs_deploy <wt> <base> <sha> -> yes | no
# Asks do_check_deploy_lag "if BASE were served, would SHA be behind?" with
# the probes pointed at a local file naming BASE and a grace nobody reaches:
# every component current n=0 = no build input changed = no. Anything else,
# "cannot tell" included, is yes: the real envs are then asked.
_spl_served_needs_deploy() {
  local wt="$1" base="$2" sha="$3" fx out
  fx="$(mktemp)" || { echo yes; return 0; }
  printf '{"commit":"%s"}' "$base" >"$fx"
  out="$(ENV=dev APP_PATH="$wt" SHA="$sha" COMPONENT=all GRACE_MINUTES=99999999 \
    LAG_HUB_URL="file://$fx" LAG_WUI_URL="file://$fx" do_check_deploy_lag 2>&1)"
  rm -f "$fx"
  if [[ "$(grep -cE '^dev (hub|wui) current .* n=0 ' <<<"$out")" == 2 ]]; then echo no
  else echo yes; fi
}

# _spl_served_env <env> <wt> <sha> -> served | lag | unknown
# do_check_deploy_lag's lines: current = served, pending/lagging = lag.
_spl_served_env() {
  local env="$1" wt="$2" sha="$3" up hv wv out
  up="$(tr '[:lower:]' '[:upper:]' <<<"$env")"; hv="LAG_HUB_URL_$up"; wv="LAG_WUI_URL_$up"
  out="$(ENV="$env" APP_PATH="$wt" SHA="$sha" COMPONENT=all \
    LAG_HUB_URL="${!hv:-}" LAG_WUI_URL="${!wv:-}" do_check_deploy_lag 2>&1)"
  printf '%s\n' "$out" >&2
  if [[ "$(grep -cE "^$env (hub|wui) " <<<"$out")" != 2 ]] || grep -qE "^$env (hub|wui) unknown " <<<"$out"; then
    echo unknown
  elif grep -qE "^$env (hub|wui) (pending|lagging) " <<<"$out"; then echo lag
  else echo served; fi
}
