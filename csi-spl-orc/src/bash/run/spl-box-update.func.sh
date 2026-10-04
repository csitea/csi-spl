#!/bin/bash
#------------------------------------------------------------------------------
# @description Bring this box and the two cloud envs to trunk (owner,
# @description 2026-10-04: "All boxes and tenants should run the latest
# @description version ... at least once in 12h"). Run twice a day by the
# @description `# <org>-<app>:box-update` cron (do_spl_box_update_install_cron).
# @description Re-implements nothing; each step is the existing action:
# @description   1. fetch    git fetch origin master, then --ff-only the main
# @description               checkout (on master); when HEAD moved, the
# @description               updated ./run runs steps 2..4 (BOX_UPDATE_FETCHED=1)
# @description   2. refresh  do_spl_spool_refresh (the installed spool binary
# @description               only, never the agent config)
# @description   3. deploy   BOX_DEPLOY_CMD=install do_spl_box_deploy in
# @description               UPDATE mode: BOX_DEPLOY_MISSING=skip (an
# @description               installed cron line is kept verbatim, a missing
# @description               one only named) and BOX_DEPLOY_POOL=status (no
# @description               desk is started); the desk binary is refreshed
# @description   4. lag      do_check_deploy_lag for dev AND prd at trunk; a
# @description               LAGGING hub or WUI gets its existing deploy
# @description               workflow (20 / 30) dispatched with environment=all
# @description               - only when the CI gate (10) on that trunk sha
# @description               concluded success, no run of that workflow is in
# @description               flight and its last one did not fail (as 21).
# @description               A dispatch runs at the master tip, so a red tip is
# @description               NEVER dispatched: the newest green sha is named
# @description               and the next run decides. The version is minted by
# @description               the workflow (do_release_version), never here.
# @description Every step runs; the exit code is non-zero when any failed.
# @description Dry run unless DRY_RUN=0 (every step prints its plan).
# @param ENV - required: dev or prd (the box's desk env, for step 3)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param BOX_UPDATE_LAG_ENVS (optional) - default "dev prd"
# @param BOX_UPDATE_GRACE (optional) - minutes, default 45 (do_check_deploy_lag)
# @param BOX_UPDATE_GH_TOKEN_FILE (optional) - read into GH_TOKEN when gh is
# @param   not logged in; default $HOME/.github/token
# @param BOX_UPDATE_FETCHED (optional) - 1 skips step 1 (set by the re-exec)
# @param BOX_UPDATE_REPO (optional) - owner/name, default read from the origin remote
# @param BOX_UPDATE_LAG_CMD / BOX_UPDATE_GH (optional, tests) - replace
# @param   do_check_deploy_lag (gets ENV, SHA, GRACE_MINUTES) and gh
# @example ENV=dev ./run -a do_spl_box_update
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_box_update
#------------------------------------------------------------------------------
do_spl_box_update() {
  local dry="${DRY_RUN:-1}" rc=0 head0 head1 trunk
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -n "${ENV:-}" ]] || { do_log "FATAL ENV must be set (no default): dev or prd"; return 1; }
  echo "BOX update: ENV=$ENV user=$USER APP_PATH=$APP_PATH DRY_RUN=$dry at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "${BOX_UPDATE_FETCHED:-0}" != 1 ]]; then
    head0="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)"
    box_update_fetch "$dry" || return 1
    head1="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)"
    if [[ "$head0" != "$head1" && "${BOX_UPDATE_REEXEC:-1}" == 1 ]]; then
      echo "STEP fetch: HEAD moved ${head0:0:12} -> ${head1:0:12}; the updated ./run does the rest"
      BOX_UPDATE_FETCHED=1 DRY_RUN="$dry" ENV="$ENV" "$PROJ_PATH/run" -a do_spl_box_update
      return $?
    fi
  fi
  trunk="$(git -C "$APP_PATH" rev-parse -q --verify origin/master 2>/dev/null)"

  echo "STEP refresh: do_spl_spool_refresh"
  ( DRY_RUN="$dry" do_spl_spool_refresh ) || { rc=1; echo "FAIL step refresh"; }
  echo "STEP deploy: BOX_DEPLOY_CMD=install BOX_DEPLOY_MISSING=skip BOX_DEPLOY_POOL=status do_spl_box_deploy"
  ( BOX_DEPLOY_CMD=install BOX_DEPLOY_MISSING=skip BOX_DEPLOY_POOL=status DRY_RUN="$dry" do_spl_box_deploy ) ||
    { rc=1; echo "FAIL step deploy"; }
  echo "STEP lag: dev and prd at ${trunk:-<no origin/master>}"
  box_update_lag "$dry" "$trunk" || { rc=1; echo "FAIL step lag"; }

  [[ "$rc" == 0 ]] && do_log "OK box update done (DRY_RUN=$dry)" || do_log "FAIL box update: a step failed (named above)"
  return "$rc"
}

# box_update_fetch <dry>: fetch trunk; fast-forward the main checkout on master
box_update_fetch() {
  local dry="$1" branch
  git -C "$APP_PATH" fetch -q origin master || { do_log "FATAL git fetch origin master failed in $APP_PATH"; return 1; }
  branch="$(git -C "$APP_PATH" symbolic-ref -q --short HEAD 2>/dev/null)"
  if [[ "$(git -C "$APP_PATH" rev-parse HEAD)" == "$(git -C "$APP_PATH" rev-parse origin/master)" ]]; then
    echo "OK fetch: $APP_PATH is at trunk"; return 0
  fi
  [[ "$branch" == master ]] || { do_log "FATAL $APP_PATH is on '${branch:-a detached HEAD}', not master: not fast-forwarded"; return 1; }
  if [[ "$dry" == 1 ]]; then echo "PLAN fetch: git merge --ff-only origin/master in $APP_PATH"; return 0; fi
  git -C "$APP_PATH" merge -q --ff-only origin/master ||
    { do_log "FATAL git merge --ff-only origin/master refused in $APP_PATH (local changes or a diverged master)"; return 1; }
  echo "DO fetch: $APP_PATH fast-forwarded to $(git -C "$APP_PATH" rev-parse --short HEAD)"
}

# box_update_lag <dry> <trunk>: do_check_deploy_lag per env; dispatch each
# lagging component once (environment=all covers both envs)
box_update_lag() {
  local dry="$1" trunk="$2" e out line hub=0 wui=0 rc=0
  [[ -n "$trunk" ]] || { do_log "FAIL no origin/master in $APP_PATH"; return 1; }
  for e in ${BOX_UPDATE_LAG_ENVS:-dev prd}; do
    if [[ -n "${BOX_UPDATE_LAG_CMD:-}" ]]; then
      out="$(ENV="$e" SHA="$trunk" GRACE_MINUTES="${BOX_UPDATE_GRACE:-45}" bash -c "$BOX_UPDATE_LAG_CMD" 2>&1)"
    else
      # each env its own state dir and cnf: unset, do_spl_cloud_cnf derives them
      out="$( (unset SPL_STATE_DIR SPL_CNF; ENV="$e" SHA="$trunk" GRACE_MINUTES="${BOX_UPDATE_GRACE:-45}" do_check_deploy_lag) 2>&1)"
    fi
    while IFS= read -r line; do
      [[ "$line" =~ ^"$e"[[:space:]]+(hub|wui)[[:space:]]+([a-z]+) ]] || continue
      echo "  $line"
      [[ "${BASH_REMATCH[2]}" == lagging ]] || continue
      [[ "${BASH_REMATCH[1]}" == hub ]] && hub=1 || wui=1
    done <<<"$out"
    grep -qE "^$e (hub|wui) " <<<"$out" || { echo "WARN lag $e: no verdict (cannot tell)"; rc=1; }
  done
  (( hub || wui )) || { echo "OK lag: nothing lags trunk"; return "$rc"; }
  box_update_gh_auth
  (( hub )) && { box_update_dispatch "$dry" "$trunk" 20_hub-build-deploy.yml hub || rc=1; }
  (( wui )) && { box_update_dispatch "$dry" "$trunk" 30_wui-build-deploy.yml wui || rc=1; }
  return "$rc"
}

# box_update_gh: gh, or the test stub
box_update_gh() { "${BOX_UPDATE_GH:-gh}" "$@"; }

# box_update_gh_auth: a cron job has no gh login of its own; the token file
# on disk is read into GH_TOKEN (never printed)
box_update_gh_auth() {
  local f="${BOX_UPDATE_GH_TOKEN_FILE:-$HOME/.github/token}"
  [[ -n "${GH_TOKEN:-}" ]] && return 0
  box_update_gh auth status >/dev/null 2>&1 && return 0
  [[ -r "$f" ]] && { GH_TOKEN="$(cat "$f")"; export GH_TOKEN; }
  return 0
}

# box_update_dispatch <dry> <trunk> <workflow> <component>: the existing
# deploy workflow at the master tip, only when that tip is <trunk>, its CI
# gate is green, nothing is in flight and the last run did not fail
box_update_dispatch() {
  local dry="$1" trunk="$2" wf="$3" comp="$4" repo gate green tip inflight last
  repo="${BOX_UPDATE_REPO:-$(git -C "$APP_PATH" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"
  [[ "$repo" == */* ]] || { do_log "FAIL $comp: cannot read owner/name from the origin remote"; return 1; }
  gate="$(box_update_gh run list --repo "$repo" --workflow 10_ci-quality.yml --commit "$trunk" --limit 5 \
    --json status,conclusion --jq '[.[] | select(.status == "completed")] | .[0].conclusion // "none"' 2>/dev/null)" ||
    { do_log "FAIL $comp: gh run list failed (gh login or GH_TOKEN)"; return 1; }
  if [[ "$gate" != success ]]; then
    green="$(box_update_gh run list --repo "$repo" --workflow 10_ci-quality.yml --branch master --status success \
      --limit 1 --json headSha --jq '.[0].headSha // ""' 2>/dev/null)"
    echo "SKIP $comp lags, but the CI gate on trunk ${trunk:0:12} is '${gate:-none}'; the newest green trunk sha is ${green:-unknown}. A dispatch runs at the master tip, so nothing red is dispatched; the next run decides."
    return 0
  fi
  inflight="$(box_update_gh run list --repo "$repo" --workflow "$wf" --branch master --limit 20 \
    --json status --jq '[.[] | select(.status != "completed")] | length' 2>/dev/null)"
  last="$(box_update_gh run list --repo "$repo" --workflow "$wf" --branch master --limit 25 --json conclusion \
    --jq '[.[] | select(.conclusion == "success" or .conclusion == "failure" or .conclusion == "timed_out")] | .[0].conclusion // "none"' 2>/dev/null)"
  if [[ "${inflight:-0}" -gt 0 ]]; then echo "SKIP $comp lags, but a $wf run is in flight on master: it deploys"; return 0; fi
  if [[ "$last" != success && "$last" != none ]]; then
    echo "FAIL $comp lags and the last $wf run concluded '$last': the deploy is broken, not starved; not dispatched"; return 1
  fi
  tip="$(git -C "$APP_PATH" ls-remote origin refs/heads/master 2>/dev/null | cut -f1)"
  [[ "$tip" == "$trunk" ]] || { echo "SKIP $comp: master moved to ${tip:0:12} since ${trunk:0:12}; the next run decides"; return 0; }
  if [[ "$dry" == 1 ]]; then echo "PLAN $comp: gh workflow run $wf --ref master -f environment=all (tip ${trunk:0:12}, gate green)"; return 0; fi
  box_update_gh workflow run "$wf" --repo "$repo" --ref master -f environment=all ||
    { do_log "FAIL $comp: gh workflow run $wf failed"; return 1; }
  echo "DO $comp: dispatched $wf at ${trunk:0:12} (environment=all, gate green)"
}
