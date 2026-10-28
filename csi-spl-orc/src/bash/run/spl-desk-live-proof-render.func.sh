#!/bin/bash
#------------------------------------------------------------------------------
# @description Render the "**Live**" proof table of an owner post from git, the
# @description served builds and CI (spec 157 Rule 4, build row B2). A
# @description dispatcher typed this table by hand on every shift, and the desk
# @description post guard (spl_desk_live_proof, how-to-post.md rules 14 and 16)
# @description refused the ones that got it wrong. This action builds it from
# @description the same checks, so what it prints passes that guard.
# @description
# @description It composes the checks that already exist, it copies none:
# @description   landed - git-fetch-fresh.sh, then merge-base --is-ancestor
# @description            <sha> origin/master
# @description   served - _spl_served_components / _spl_served_env of
# @description            do_check_lane_served, i.e. do_check_deploy_lag per
# @description            env: the served commit CONTAINS <sha> (ancestry,
# @description            never string equality, rule 14)
# @description   CI     - gh run list --commit <sha>
# @description Rows: one per area the commit touched (git diff-tree): hub and
# @description wui are probed on every env when their build input changed; any
# @description other area (orc, iac, doc, ...) reads `no deploy`.
# @description Header: **Live** when every probed env serves it (or nothing
# @description needs a deploy); else **Landed, not live yet** and the envs that
# @description do not serve it, so the post guard never sees a false **Live**.
# @description The post goes to stdout, the probe lines to stderr.
# @description Exit: 0 rendered **Live**; 3 rendered **Landed, not live yet**;
# @description 1 refused (SHA, LIVE_CHECKED or LIVE_NOT_CHECKED missing, SHA
# @description not a commit, the fetch failed); 2 refused (not on origin/master).
# @description Reads only: one fetch, local git, the deploy-lag probes, gh.
# @param SHA - required: the landed commit
# @param LIVE_CHECKED - required: the measured cases (rule 16)
# @param LIVE_NOT_CHECKED - required: what was not measured; literal `none` when all was
# @param LANE_WT - optional: the git checkout to read (default: APP_PATH)
# @param LANE_REMOTE / LANE_BRANCH - optional: the trunk (default: origin / master)
# @param LANE_ENVS - optional: the envs to probe (default: "dev prd")
# @param LANE_FETCH_SCRIPT - optional: the fetch script (default: git-fetch-fresh.sh)
# @example SHA=<sha> LIVE_CHECKED="hub /version on dev and prd" LIVE_NOT_CHECKED=none ./run -a do_spl_desk_live_proof_render
#------------------------------------------------------------------------------
do_spl_desk_live_proof_render() {
  local -a miss=()
  [[ -n "${SHA//[[:space:]]/}" ]] || miss+=(SHA)
  [[ -n "${LIVE_CHECKED//[[:space:]]/}" ]] || miss+=(LIVE_CHECKED)
  [[ -n "${LIVE_NOT_CHECKED//[[:space:]]/}" ]] || miss+=(LIVE_NOT_CHECKED)
  if (( ${#miss[@]} )); then
    do_log "FATAL REFUSED: SHA, LIVE_CHECKED and LIVE_NOT_CHECKED are required by how-to-post.md rule 16 (pass literal 'none' to LIVE_NOT_CHECKED if all was checked); missing: ${miss[*]}" >&2
    return 1
  fi
  local wt="${LANE_WT:-$APP_PATH}" remote="${LANE_REMOTE:-origin}" branch="${LANE_BRANCH:-master}"
  local fetch="${LANE_FETCH_SCRIPT:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/git-fetch-fresh.sh}"
  local sha parent comps ci
  sha="$(git -C "$wt" rev-parse --verify -q "$SHA^{commit}" 2>/dev/null)" ||
    { do_log "FATAL REFUSED: SHA '$SHA' is not a commit in $wt" >&2; return 1; }
  bash "$fetch" -C "$wt" --remote "$remote" --branch "$branch" >&2 ||
    { do_log "FATAL REFUSED: the fetch of $remote/$branch failed: cannot prove ${sha:0:9} landed" >&2; return 1; }
  git -C "$wt" merge-base --is-ancestor "$sha" "$remote/$branch" 2>/dev/null ||
    { do_log "FATAL REFUSED: not on master: ${sha:0:9} is not an ancestor of $remote/$branch" >&2; return 2; }
  parent="$(git -C "$wt" rev-parse --verify -q "$sha^" 2>/dev/null)" || parent="$sha"
  comps="$(_spl_served_components "$wt" "$parent" "$sha" 2>/dev/null)"
  ci="$(_spl_live_render_ci "$wt" "$sha")"
  _spl_live_render_table "$wt" "$sha" "$comps" "$ci" "$remote/$branch"
}

# _spl_live_render_areas <wt> <sha> <components> -> one row name per line:
# the components first (a wui input outside csi-spl-wui/ is still probed),
# then each other area the commit touched: csi-spl-api = hub,
# csi-spl-<x> = x, anything else = repo.
_spl_live_render_areas() {
  local -a named
  read -r -a named <<<"$3"
  (( ${#named[@]} )) && printf '%s\n' "${named[@]}"
  git -C "$1" diff-tree --root --no-commit-id --name-only -r "$2" |
    awk -F/ -v skip=" $3 " '{ a = ($1 == "csi-spl-api") ? "hub" : ($1 ~ /^csi-spl-/) ? substr($1, 9) : "repo" }
      index(skip, " " a " ") == 0 && !seen[a]++ { print a }'
}

# _spl_live_render_ci <wt> <sha> -> green | red | running | no runs | unknown
# green = every run of the commit completed success, skipped or neutral.
_spl_live_render_ci() {
  local out st co n=0 red=0 run=0
  out="$(cd "$1" && gh run list --commit "$2" --limit 100 --json status,conclusion \
    --jq '.[] | "\(.status) \(.conclusion)"' 2>/dev/null)" || { echo unknown; return 0; }
  while read -r st co; do
    [[ -n "$st" ]] || continue
    n=$((n + 1))
    if [[ "$st" != completed ]]; then run=1
    else case "$co" in success|skipped|neutral) ;; *) red=1 ;; esac; fi
  done <<<"$out"
  if (( n == 0 )); then echo "no runs"
  elif (( red )); then echo red
  elif (( run )); then echo running
  else echo green; fi
}

# _spl_live_render_version <wt> <sha> -> the first v<X.Y.Z> release tag that
# contains the commit (do_release_version mints one per deploy), else "no tag".
_spl_live_render_version() {
  local t
  t="$(git -C "$1" tag --contains "$2" --list 'v*' --sort=v:refname 2>/dev/null | awk 'NR == 1')"
  echo "${t:-no tag}"
}

# _spl_live_render_table <wt> <sha> <components> <ci> <trunk>: the post on
# stdout; 0 when **Live**, 3 when an env does not serve a probed component.
_spl_live_render_table() {
  local wt="$1" sha="$2" comps="$3" ci="$4" trunk="$5" short="${2:0:9}" a e v ver row lagging="" rows=""
  local -a envs
  read -r -a envs <<<"${LANE_ENVS:-dev prd}"
  while read -r a; do
    [[ -n "$a" ]] || continue
    if [[ " $comps " == *" $a "* ]]; then
      ver="$(_spl_live_render_version "$wt" "$sha")"
      row="| $a | $short (\`$ver\`) |"
      for e in "${envs[@]}"; do
        v="$(_spl_served_env "$e" "$wt" "$sha" "$a")"
        [[ "$v" == served ]] || lagging+=" $e $a $v,"
        row+=" $v |"
      done
    else
      row="| $a | $short |"
      for e in "${envs[@]}"; do row+=" no deploy |"; done
    fi
    rows+="$row $ci |"$'\n'
  done < <(_spl_live_render_areas "$wt" "$sha" "$comps")
  if [[ -z "$lagging" ]]; then echo "**Live**: $short on $trunk, served wherever it deploys."
  else echo "**Landed, not live yet**: $short is on $trunk; not served:${lagging%,}."; fi
  echo
  printf '| target | commit / version |'; for e in "${envs[@]}"; do printf ' %s |' "$e"; done; echo ' CI |'
  printf '|---|---|'; for e in "${envs[@]}"; do printf -- '---|'; done; echo '---|'
  printf '%s' "$rows"
  echo
  echo "checked: $LIVE_CHECKED"
  echo "not checked: $LIVE_NOT_CHECKED"
  [[ -z "$lagging" ]] || return 3
}
