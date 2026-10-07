#!/bin/bash
#------------------------------------------------------------------------------
# @description Take this box's self-hosted ORG runners out of service (the
# @description other half of do_gh_runner_add: moving the runners to another
# @description box). Per runner unit actions.runner.<org>.<name>.service here
# @description (dir and user read from the unit):
# @description   1. wait until it is idle (a running job is never killed)
# @description   2. stop its unit, then `svc.sh uninstall` (config.sh remove
# @description      refuses while the service is installed: "Uninstall
# @description      service first", 2026-10-07)
# @description   3. `config.sh remove` with an org remove-token: it leaves the
# @description      org runner list
# @description   4. verify: none of them is listed in the org any more
# @description The runner dirs stay on disk. Rollback per runner: register it
# @description again (`config.sh` with an org registration-token, the same
# @description name, labels and group), then `svc.sh install <user>` and
# @description `svc.sh start` in its dir. A unit already stopped or uninstalled
# @description by an earlier run is picked up again (idempotent).
# @description Tokens are short-lived, fetched per runner and never logged.
# @description Never touches the runner group's repo or workflow restriction.
# @description Needs sudo and gh with admin:org. Dry run unless DRY_RUN=0.
# @param GH_RUNNER_ORG - required: the org the runners are registered on
# @param GH_RUNNER_NAMES (optional) - space-separated runner names, default
# @param   every runner unit of GH_RUNNER_ORG on this box
# @param GH_RUNNER_WAIT (optional) - seconds to wait for a busy runner, default 1800
# @param DRY_RUN (optional) - 1 (default) or 0
# @example GH_RUNNER_ORG=<org> ./run -a do_gh_runner_remove
# @example GH_RUNNER_ORG=<org> GH_RUNNER_NAMES='<name-01> <name-02>' DRY_RUN=0 ./run -a do_gh_runner_remove
#------------------------------------------------------------------------------

# ghrm_units <org> - the names of the org's runner units on this box, loaded
# or not (a stopped + disabled unit is not in list-units)
ghrm_units() {
  local prefix="actions.runner.$1."
  { systemctl list-units --type=service --all --no-legend --plain 2>/dev/null
    systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null; } \
    | awk -v p="$prefix" 'index($1, p) == 1 && $1 ~ /\.service$/ {n = substr($1, length(p) + 1); sub(/\.service$/, "", n); print n}' \
    | LC_ALL=C sort -u
}

# ghrm_in <dir> <user> <cmd...> - run a command inside the runner's dir, which
# the box user cannot enter
ghrm_in() {
  local dir="$1" user="$2"; shift 2
  sudo -u "$user" bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

# ghrm_busy <org> <name> - prints true/false; an API error reads as busy
ghrm_busy() {
  local b
  b="$(gh api "orgs/$1/actions/runners" --paginate --jq ".runners[]|select(.name==\"$2\")|.busy")" || b=true
  echo "${b:-false}"
}

# ghrm_one <org> <name> - stop, uninstall the service of and deregister one
# idle runner
ghrm_one() {
  local org="$1" name="$2" u="actions.runner.$1.$2.service" dir user tok
  dir="$(systemctl show -p WorkingDirectory --value "$u")"; user="$(systemctl show -p User --value "$u")"
  [[ -n "$dir" && -n "$user" ]] && sudo test -x "$dir/config.sh" || { do_log "FATAL cannot read the dir/user of $u"; return 1; }
  sudo systemctl stop "$u" || { do_log "FATAL cannot stop $u"; return 1; }
  if sudo test -s "$dir/.service"; then
    ghrm_in "$dir" root ./svc.sh uninstall >/dev/null || { do_log "FATAL svc.sh uninstall failed for $name (its unit is stopped)"; return 1; }
  fi
  if sudo test -s "$dir/.runner"; then
    tok="$(gh api -X POST "orgs/$org/actions/runners/remove-token" --jq .token)" \
      && ghrm_in "$dir" "$user" ./config.sh remove --token "$tok" >/dev/null \
      || { tok=""; do_log "FATAL cannot deregister $name from $org (its service is stopped + uninstalled)"; return 1; }
    tok=""
  fi
  do_log "OK $name: service stopped + uninstalled, deregistered from $org, dir $dir kept"
}

do_gh_runner_remove() {
  do_require_bin gh systemctl sudo || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local org="${GH_RUNNER_ORG:-}" wait="${GH_RUNNER_WAIT:-1800}" here n
  [[ "$org" =~ ^[A-Za-z0-9_.-]+$ ]] || { do_log "FATAL GH_RUNNER_ORG must be set (no default): the org the runners serve"; return 1; }
  [[ "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL GH_RUNNER_WAIT must be a number of seconds"; return 1; }
  here="$(ghrm_units "$org")"
  local -a names
  if [[ -n "${GH_RUNNER_NAMES:-}" ]]; then
    read -ra names <<<"$GH_RUNNER_NAMES"
    for n in "${names[@]}"; do
      grep -qx -- "$n" <<<"$here" || { do_log "FATAL no unit actions.runner.$org.$n.service on this box"; return 1; }
    done
  else
    mapfile -t names < <(grep -v '^$' <<<"$here")
  fi
  ((${#names[@]})) || { do_log "OK no runner unit of $org on this box - nothing to remove"; return 0; }
  do_log "INFO ${#names[@]} runner(s) of $org to take out of service here: ${names[*]}"
  if ((dry)); then
    for n in "${names[@]}"; do do_log "INFO DRY_RUN would drain, stop + uninstall actions.runner.$org.$n.service and deregister $n from $org (dir kept)"; done
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0."
    return 0
  fi

  # each pass removes every idle runner, so one long job does not hold the
  # others back; a busy one is retried until GH_RUNNER_WAIT
  local pending=("${names[@]}") left t0
  t0=$(date +%s)
  while ((${#pending[@]})); do
    left=()
    for n in "${pending[@]}"; do
      [[ "$(ghrm_busy "$org" "$n")" == false ]] || { left+=("$n"); continue; }
      ghrm_one "$org" "$n" || return 1
    done
    pending=("${left[@]}")
    ((${#pending[@]})) || break
    (( $(date +%s) - t0 < wait )) || { do_log "FATAL still busy after ${wait}s, not removed (re-run later): ${pending[*]}"; return 1; }
    sleep 15
  done

  local listed stale=()
  listed="$(gh api "orgs/$org/actions/runners" --paginate --jq '.runners[].name')" \
    || { do_log "FATAL cannot list the runners of $org to verify"; return 1; }
  for n in "${names[@]}"; do grep -qx -- "$n" <<<"$listed" && stale+=("$n"); done
  ((${#stale[@]} == 0)) || { do_log "FATAL $org still lists: ${stale[*]}"; return 1; }
  do_log "OK ${#names[@]} runner(s) out of service and gone from $org: ${names[*]}"
}
