#!/bin/bash
#------------------------------------------------------------------------------
# @description CLE-77918: the deploy-lag rows of the dispatch check. Per env
# @description (dev and prd) and component (hub, wui), is trunk head SERVED?
# @description A hub or WUI input that has been on trunk longer than
# @description DISPATCH_LAG_GRACE minutes (30) and is still not live is a GAP
# @description row, so do_spl_dispatch_tick notes it ONCE to the lease holder
# @description (the row's key is "deploy lag <env> <component>"; the served /
# @description oldest commits are the value, not the identity) and escalates
# @description it to the orchestrator when it stays open. Built for the
# @description 2026-10-01 case: both hubs served one commit for ~50 min while
# @description every 20 run stood down, and nobody was told.
# @description The verdicts come from do_check_deploy_lag (GET /version and
# @description /build.json, local git, no credential). "cannot tell" is a
# @description plain row, never a GAP: a flapping endpoint must not flap the
# @description feed (00 and 22 report endpoints). Read-only.
# @param ENV - not used for the envs (both are asked); kept for do_spl_dispatch_check
# @param DISPATCH_DEPLOY_LAG (optional) - 0 skips these rows
# @param DISPATCH_LAG_ENVS (optional) - default "dev prd"
# @param DISPATCH_LAG_GRACE (optional) - minutes, default 30
# @param DISPATCH_LAG_SHA (optional) - the commit that must be live; default
# @param   origin/master of the checkout, else its HEAD
# @param DISPATCH_LAG_CMD (optional, tests) - replaces do_check_deploy_lag; gets
# @param   ENV, SHA and GRACE_MINUTES, prints '<env> <component> <verdict> ...'
# @example ./run -a do_spl_dispatch_deploy_lag
#------------------------------------------------------------------------------
do_spl_dispatch_deploy_lag() {
  local gaps=0
  echo "| what | value | verdict |"
  echo "|---|---|---|"
  row() { echo "| $1 | $2 | $3 |"; [[ "$3" == GAP* ]] && gaps=$((gaps + 1)); return 0; }
  DISPATCH_DEPLOY_LAG=1 spl_dispatch_deploy_lag_rows
  (( gaps )) && return 1
  return 0
}

# Appends one row per env+component through the caller's row().
spl_dispatch_deploy_lag_rows() {
  [[ "${DISPATCH_DEPLOY_LAG:-1}" != 0 ]] || return 0
  local grace="${DISPATCH_LAG_GRACE:-30}" sha e out line comp verdict rest app state_root
  # r4-B2: do_spl_cloud_cnf renders the cnf into SPL_STATE_DIR, so each env
  # gets a fresh dir under one root that the RETURN trap removes on every
  # return path (2,046 leaked /tmp/tmp.*/cnf dirs before).
  state_root="$(mktemp -d)"
  trap 'rm -rf "$state_root"; trap - RETURN' RETURN
  app="${APP_PATH:-$(cd "${PROJ_PATH:-.}/.." && pwd)}"
  sha="${DISPATCH_LAG_SHA:-$(git -C "$app" rev-parse -q --verify origin/master 2>/dev/null || git -C "$app" rev-parse HEAD 2>/dev/null)}"
  for e in ${DISPATCH_LAG_ENVS:-dev prd}; do
    if [[ -n "${DISPATCH_LAG_CMD:-}" ]]; then
      out="$(ENV="$e" SHA="$sha" GRACE_MINUTES="$grace" bash -c "$DISPATCH_LAG_CMD" 2>/dev/null)"
    elif declare -F do_check_deploy_lag >/dev/null; then
      out="$( (ENV="$e" SHA="$sha" GRACE_MINUTES="$grace" SPL_STATE_DIR="$(mktemp -d -p "$state_root")" do_check_deploy_lag) 2>/dev/null)"
    else
      row "deploy lag $e" "do_check_deploy_lag is not loaded" "cannot tell"; continue
    fi
    [[ -n "$out" ]] || { row "deploy lag $e" "no verdict" "cannot tell"; continue; }
    while IFS= read -r line; do
      [[ "$line" =~ ^"$e"[[:space:]]+(hub|wui)[[:space:]]+([a-z]+)[[:space:]]*(.*)$ ]] || continue
      comp="${BASH_REMATCH[1]}"; verdict="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
      rest="$(sed -E 's/(^| )url=[^ ]*//; s/[|]/\//g; s/^ +//; s/ +$//' <<<"$rest")"
      case "$verdict" in
        lagging) row "deploy lag $e $comp" "$rest" "GAP trunk input not served after ${grace} min: 21_hub-deploy-catchup dispatches it; if it stays, the deploy is broken: gh run list --workflow $([[ $comp == hub ]] && echo 20_hub-build-deploy.yml || echo 30_wui-build-deploy.yml)" ;;
        current|pending) row "deploy lag $e $comp" "$verdict${rest:+ ${rest%% (*}}" ok ;;
        *) row "deploy lag $e $comp" "$verdict${rest:+ ${rest%% (*}}" "cannot tell" ;;
      esac
    done <<<"$out"
  done
}
