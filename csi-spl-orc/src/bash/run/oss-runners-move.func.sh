#!/bin/bash
#------------------------------------------------------------------------------
# @description Move this box's self-hosted GitHub Actions runners from one repo
# @description to another (spec 044 / SPL-64, CLE-35070: the runners serve the
# @description PRIVATE ops repo only, so no workflow of the public repo - and no
# @description fork pull request - can ever reach them). Per runner registered
# @description on OSS_RUNNER_FROM (found by its systemd unit
# @description actions.runner.<owner>-<repo>.<name>.service; dir and user come
# @description from the unit, name and labels from the GitHub API):
# @description   1. wait until it is idle (a running job is never killed)
# @description   2. stop + uninstall its service, `config.sh remove` with a
# @description      remove-token of OSS_RUNNER_FROM
# @description   3. `config.sh` on OSS_RUNNER_TO with the SAME name and custom
# @description      labels (a registration-token of OSS_RUNNER_TO, --replace),
# @description      then install + start its service as the same user
# @description   4. verify: online on OSS_RUNNER_TO, gone from OSS_RUNNER_FROM
# @description Tokens are short-lived (1 h), fetched per runner and never logged.
# @description Needs sudo and gh with repo admin on both repos.
# @description Dry run unless DRY_RUN=0.
# @param OSS_RUNNER_FROM - required: <owner>/<repo> the runners serve now
# @param OSS_RUNNER_TO - required: <owner>/<repo> they must serve, OR an org
# @param   name (no slash) together with OSS_RUNNER_GROUP: the runners then
# @param   register on the org, in that runner group (whose repo + workflow
# @param   restriction decides who may use them)
# @param OSS_RUNNER_GROUP (optional) - the org runner group name (org target only)
# @param OSS_RUNNER_WAIT (optional) - seconds to wait for a busy runner, default 1800
# @param DRY_RUN (optional) - 1 (default) or 0
# @example OSS_RUNNER_FROM=<owner>/<app> OSS_RUNNER_TO=<owner>/<app>-ops ./run -a do_oss_runners_move
#------------------------------------------------------------------------------

# oss_runner_units <owner>/<repo> - the systemd units of runners registered on it
oss_runner_units() {
  local prefix="actions.runner.${1/\//-}."
  systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -F "$prefix" || true
}

# oss_runner_in <dir> <user|root> <cmd...> - run a command inside the runner's
# dir, which the box user cannot enter
oss_runner_in() {
  local dir="$1" user="$2"; shift 2
  sudo -u "$user" bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

do_oss_runners_move() {
  do_require_bin gh systemctl sudo || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local from="${OSS_RUNNER_FROM:-}" to="${OSS_RUNNER_TO:-}" wait="${OSS_RUNNER_WAIT:-1800}"
  local re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  local group="${OSS_RUNNER_GROUP:-}" api_to url_to gid=""
  [[ "$from" =~ $re && "$from" != "$to" ]] \
    || { do_log "FATAL OSS_RUNNER_FROM must be <owner>/<repo> and differ from OSS_RUNNER_TO (no default)"; return 1; }
  if [[ "$to" =~ $re ]]; then
    [[ "$(gh api "repos/$to" --jq .private 2>/dev/null)" == true ]] \
      || { do_log "FATAL $to is not a private repo this token can read - a repo-level runner serves private repos only"; return 1; }
    api_to="repos/$to"
  elif [[ "$to" =~ ^[A-Za-z0-9_.-]+$ && -n "$group" ]]; then
    gid="$(gh api "orgs/$to/actions/runner-groups" --jq ".runner_groups[]|select(.name==\"$group\")|.id")"
    [[ -n "$gid" ]] || { do_log "FATAL no runner group '$group' in org $to"; return 1; }
    [[ "$(gh api "orgs/$to/actions/runner-groups/$gid" --jq '"\(.visibility) \(.restricted_to_workflows)"')" == "selected true" ]] \
      || { do_log "FATAL runner group $group must be restricted to selected repos AND selected workflows"; return 1; }
    api_to="orgs/$to"
  else
    do_log "FATAL OSS_RUNNER_TO must be <owner>/<repo>, or an org name with OSS_RUNNER_GROUP"; return 1
  fi
  url_to="https://github.com/$to"
  local -a units; mapfile -t units < <(oss_runner_units "$from")
  ((${#units[@]})) || { do_log "OK no runner unit of $from on this box - nothing to move"; return 0; }
  do_log "INFO ${#units[@]} runner(s) of $from on this box: ${units[*]}"

  # a runner is moved when it is IDLE (a running job is never killed); each
  # pass moves every idle one, so one long job does not hold the others back
  local u name dir user labels busy t0 tok pending=("${units[@]}") left
  t0=$(date +%s)
  while ((${#pending[@]})); do
    left=()
    for u in "${pending[@]}"; do
      name="${u#actions.runner.${from/\//-}.}"; name="${name%.service}"
      dir="$(systemctl show -p WorkingDirectory --value "$u")"; user="$(systemctl show -p User --value "$u")"
      [[ -n "$dir" && -n "$user" ]] && sudo test -x "$dir/config.sh" || { do_log "FATAL cannot read the dir/user of $u"; return 1; }
      labels="$(gh api "repos/$from/actions/runners" --paginate --jq ".runners[]|select(.name==\"$name\")|[.labels[]|select(.type==\"custom\")|.name]|join(\",\")")"
      if ((dry)); then
        do_log "INFO DRY_RUN would move $name ($dir, user $user, labels ${labels:-none}) from $from to $to${group:+ (runner group $group)}"
        continue
      fi
      busy="$(gh api "repos/$from/actions/runners" --paginate --jq ".runners[]|select(.name==\"$name\")|.busy")" || busy=true
      [[ "$busy" == false ]] || { left+=("$u"); continue; }
      { oss_runner_in "$dir" root ./svc.sh stop >/dev/null && oss_runner_in "$dir" root ./svc.sh uninstall >/dev/null; } \
        || { do_log "FATAL cannot stop/uninstall the service of $name"; return 1; }
      tok="$(gh api -X POST "repos/$from/actions/runners/remove-token" --jq .token)" \
        && oss_runner_in "$dir" "$user" ./config.sh remove --token "$tok" >/dev/null \
        || { do_log "FATAL cannot deregister $name from $from"; return 1; }
      tok="$(gh api -X POST "$api_to/actions/runners/registration-token" --jq .token)" \
        && oss_runner_in "$dir" "$user" ./config.sh --unattended --replace --url "$url_to" \
               --token "$tok" --name "$name" --labels "${labels:-self-hosted}" --work _work ${group:+--runnergroup "$group"} >/dev/null \
        || { do_log "FATAL cannot register $name on $to - it is now registered NOWHERE: re-run this action"; return 1; }
      tok=""
      { oss_runner_in "$dir" root ./svc.sh install "$user" >/dev/null && oss_runner_in "$dir" root ./svc.sh start >/dev/null; } \
        || { do_log "FATAL $name is registered on $to but its service did not start"; return 1; }
      do_log "OK $name moved: $from -> $to"
    done
    ((dry)) && break
    pending=("${left[@]}")
    ((${#pending[@]})) || break
    (( $(date +%s) - t0 < wait )) || { do_log "FATAL still busy after ${wait}s, not moved (re-run later): ${pending[*]}"; return 1; }
    sleep 15
  done
  ((dry)) && { do_log "OK DRY_RUN nothing moved. Re-run with DRY_RUN=0."; return 0; }

  sleep 10
  local online stale
  local list_to="$api_to/actions/runners"; [[ -n "$gid" ]] && list_to="orgs/$to/actions/runner-groups/$gid/runners"
  online="$(gh api "$list_to" --paginate --jq '[.runners[]|select(.status=="online")|.name]|join(" ")')"
  stale="$(gh api "repos/$from/actions/runners" --paginate --jq '[.runners[].name]|join(" ")')"
  do_log "INFO $to runners online: ${online:-none}; $from runners left: ${stale:-none}"
  [[ -z "$stale" ]] || { do_log "FATAL $from still lists runner(s): $stale"; return 1; }
  do_log "OK every runner of this box now serves $to only"
}
