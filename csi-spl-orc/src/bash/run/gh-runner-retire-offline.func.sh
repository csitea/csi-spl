#!/bin/bash
#------------------------------------------------------------------------------
# @description Retire this box's OFFLINE self-hosted org runners (security
# @description round 1 row 11, 2026-10-16: 8 registered, all offline, units
# @description enabled but inactive). Lists every org runner with its API
# @description status and its unit here, then hands the offline ones that
# @description have a unit on this box to do_gh_runner_remove (stop, the
# @description runner's service uninstall = the unit is gone, its config
# @description remove = deregistered, the dir is kept for rollback). An online runner is never
# @description touched. A runner registered offline with no unit here is
# @description listed only: run this action on its own box.
# @description Guard: wf 10 runs its jobs on [self-hosted, spool-ci] when the
# @description repo variable SPOOL_CI_RUNNER is unset, so it refuses unless
# @description that variable is set and names no self-hosted label; every
# @description workflow that still names self-hosted is printed as a WARN.
# @description Dry run unless DRY_RUN=0. Needs gh with admin:org and sudo.
# @param GH_RUNNER_ORG - required: the org the runners are registered on
# @param GH_RUNNER_REPO (optional) - <owner>/<repo> of SPOOL_CI_RUNNER, default: the origin remote
# @param DRY_RUN (optional) - 1 (default) or 0
# @example GH_RUNNER_ORG=<org> ./run -a do_gh_runner_retire_offline
# @example GH_RUNNER_ORG=<org> DRY_RUN=0 ./run -a do_gh_runner_retire_offline
#------------------------------------------------------------------------------

# ghro_repo - GH_RUNNER_REPO, else <owner>/<repo> of the origin remote
ghro_repo() {
  if [[ -n "${GH_RUNNER_REPO:-}" ]]; then printf '%s\n' "$GH_RUNNER_REPO"; return 0; fi
  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# ghro_guard <repo> - 0 when SPOOL_CI_RUNNER keeps wf 10 off self-hosted
ghro_guard() {
  local v f n
  v="$(gh api "repos/$1/actions/variables/SPOOL_CI_RUNNER" --jq .value 2>/dev/null)" || v=""
  for f in "$APP_PATH"/.github/workflows/*.yml; do
    n="$(grep -cE '^[[:space:]]*runs-on:.*self-hosted' "$f" 2>/dev/null)"
    [[ "${n:-0}" == 0 ]] || do_log "WARN ${f##*/}: $n runs-on line(s) name self-hosted; with no runner such a job queues"
  done
  [[ -n "$v" && "$v" != *self-hosted* && "$v" != *spool-ci* ]] ||
    { do_log "FATAL SPOOL_CI_RUNNER on $1 is '${v:-unset}': wf 10 would queue on self-hosted. Set it first: SPOOL_CI_RUNNER='\"ubuntu-latest\"' DRY_RUN=0 ./run -a do_gh_set_ci_vars (csi-spl-iac)"; return 1; }
  do_log "OK SPOOL_CI_RUNNER on $1 is $v: wf 10 does not need these runners"
}

do_gh_runner_retire_offline() {
  do_require_bin gh systemctl sudo jq || return 1
  local org="${GH_RUNNER_ORG:-}" repo all here
  [[ "$org" =~ ^[A-Za-z0-9_.-]+$ ]] || { do_log "FATAL GH_RUNNER_ORG must be set (no default): the org the runners serve"; return 1; }
  repo="$(ghro_repo)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { do_log "FATAL no GitHub repo: set GH_RUNNER_REPO=<owner>/<repo>"; return 1; }
  ghro_guard "$repo" || return 1
  all="$(gh api "orgs/$org/actions/runners" --paginate --jq '.runners[] | "\(.id) \(.name) \(.status) \(.busy)"')" ||
    { do_log "FATAL cannot list the runners of $org"; return 1; }
  here="$(ghrm_units "$org")"
  local -a retire=()
  local id name status busy unit state
  while read -r id name status busy; do
    [[ -n "$name" ]] || continue
    unit="actions.runner.$org.$name.service"
    if grep -qx -- "$name" <<<"$here"; then
      state="$(systemctl is-enabled "$unit" 2>/dev/null)/$(systemctl is-active "$unit" 2>/dev/null)"
    else unit="-"; state="no unit on this box"; fi
    do_log "INFO runner id=$id name=$name status=$status busy=$busy unit=$unit ($state)"
    [[ "$status" == offline && "$unit" != - ]] && retire+=("$name")
  done <<<"$all"
  ((${#retire[@]})) || { do_log "OK no offline runner of $org has a unit on this box: nothing to retire here"; return 0; }
  do_log "INFO ${#retire[@]} offline runner(s) to retire on this box: ${retire[*]}"
  GH_RUNNER_ORG="$org" GH_RUNNER_NAMES="${retire[*]}" GH_RUNNER_WAIT=0 do_gh_runner_remove
}
