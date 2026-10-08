#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only health of THIS box's self-hosted GitHub runners, one
# @description line per runner unit (actions.runner.*.service):
# @description   service - active; a runner the CPU budget parked (stopped on
# @description     purpose, listed in CPU_BUDGET_STATE_DIR/parked) is PARKED,
# @description     not a failure; any other state is
# @description   restart - Restart=always (do_gh_runner_add's drop-in), so a
# @description     listener that exits by itself comes back
# @description   docker  - the runner user's rootless docker unit is enabled
# @description     (it comes back at boot) and its socket answers docker info
# @description One CHECK line at the end; exit 1 when any runner fails. A box
# @description with no runner unit: OK, exit 0. Changes nothing. Fix with
# @description do_gh_runner_add (APPLY=1). Needs sudo.
# @param CPU_BUDGET_STATE_DIR (optional) - default /var/tmp/gh-runner-cpu-budget
# @param CHECK_GH_RUNNER_DOCKER_TIMEOUT (optional) - seconds, default 15
# @example ./run -a do_check_gh_runner
#------------------------------------------------------------------------------

# cghr_docker <user> - "ok", or what is wrong with the user's rootless docker
cghr_docker() {
  local u="$1" uid t="${CHECK_GH_RUNNER_DOCKER_TIMEOUT:-15}"
  uid="$(id -u "$u" 2>/dev/null)" || { echo "no user $u"; return; }
  sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user is-enabled --quiet docker \
    || { echo "docker unit of $u NOT enabled (gone after a boot)"; return; }
  sudo -u "$u" env DOCKER_HOST="unix:///run/user/$uid/docker.sock" timeout "$t" docker info >/dev/null 2>&1 \
    || { echo "docker socket /run/user/$uid/docker.sock does not answer"; return; }
  echo ok
}

do_check_gh_runner() {
  local parked="${CPU_BUDGET_STATE_DIR:-/var/tmp/gh-runner-cpu-budget}/parked"
  local unit name state restart user bad=0 n=0 why
  local -A dock=()
  local -a units
  mapfile -t units < <(sudo systemctl list-units 'actions.runner.*.service' --all --plain --no-legend 2>/dev/null |
    awk '$1 ~ /^actions\.runner\..*\.service$/ {print $1}')
  ((${#units[@]})) || { echo "CHECK gh-runner OK: no runner unit on $(hostname -s)"; return 0; }
  for unit in "${units[@]}"; do
    n=$((n + 1)); name="${unit#actions.runner.*.}"; name="${name%.service}"; why=""
    state="$(sudo systemctl show "$unit" -p ActiveState --value 2>/dev/null)"
    restart="$(sudo systemctl show "$unit" -p Restart --value 2>/dev/null)"
    user="$(sudo systemctl show "$unit" -p User --value 2>/dev/null)"
    [[ -n "${dock[$user]+x}" ]] || dock[$user]="$(cghr_docker "${user:-root}")"
    if [[ "$state" != active ]]; then
      grep -qx "$unit" "$parked" 2>/dev/null && state=PARKED || why+="service $state; "
    fi
    [[ "$restart" == always ]] || why+="Restart=${restart:-?} (not always); "
    [[ "${dock[$user]}" == ok ]] || why+="${dock[$user]}; "
    if [[ -n "$why" ]]; then
      echo "FAIL $name: ${why%; }"; bad=$((bad + 1))
    else
      echo "OK $name: service $state, Restart=always, docker of $user enabled and answering"
    fi
  done
  if ((bad)); then
    echo "CHECK gh-runner FAIL: $bad of $n runner(s) on $(hostname -s); fix: APPLY=1 ./run -a do_gh_runner_add"
    return 1
  fi
  echo "CHECK gh-runner OK: $n runner(s) on $(hostname -s)"
}
