#!/bin/bash
#------------------------------------------------------------------------------
# @description Route wf 10 to the local self-hosted runners only while the
# @description GitHub-hosted ones are overwhelmed, and back (owner HUM-10, t1
# @description f67e3656 msg d4ba4b17: "If the GitHub runners are overwhelmed,
# @description then we should spawn local runners"). Overwhelmed, measured:
# @description a job of this repo bound for a hosted runner (no "self-hosted"
# @description label) has been QUEUED enter_queue_min minutes or longer (the
# @description runs queued or in progress, their jobs, gh api). Then the repo
# @description variable SPOOL_CI_RUNNER (wf 10's runs-on, via
# @description do_gh_set_ci_vars, never a hand `gh variable set`) goes to
# @description ["self-hosted","spool-ci"]; the runner budget
# @description (do_apply_gh_runner_cpu_budget) brings the parked runners up
# @description to the box cap. Back to "ubuntu-latest" once it held hold_min
# @description AND no hosted job (other workflows still run there) has waited
# @description exit_queue_min: the hysteresis. Switched off (the workspace
# @description admin's fleet-load ci_overflow, else cnf enabled), the variable
# @description goes to hosted at once. A query that fails changes nothing.
# @description Settings and their order: lib/bash/funcs/spl-ci-overflow.func.sh
# @description (cnf env.box.ci_overflow). The trade-off: a variable switches
# @description NEW runs only (a queued job stays where it queued), and every
# @description wf 10 job follows it, not just the excess; GitHub has no
# @description "hosted, else local" runs-on. Ticks every 5 minutes from ONE
# @description box (do_setup_ci_overflow_cron). Dry run unless DRY_RUN=0.
# @param CI_OVERFLOW_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param CI_OVERFLOW_<KEY> (optional) - overrides a setting (spl-ci-overflow.func.sh)
# @param CI_OVERFLOW_STATE_DIR (optional) - default /var/tmp/ci-overflow (since: when it went local)
# @param CI_OVERFLOW_MAX_RUNS (optional) - runs whose jobs are read, default 30
# @param CI_OVERFLOW_GH (optional, tests) - default gh
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_route_ci_overflow
# @example DRY_RUN=0 ./run -a do_route_ci_overflow
#------------------------------------------------------------------------------
declare -F spl_ci_overflow_settings >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-ci-overflow.func.sh"

# _rco_gh <args...> - gh in this checkout (gh resolves {owner}/{repo} from it)
_rco_gh() { (cd "$(dirname "${BASH_SOURCE[0]}")" && timeout 30 ${CI_OVERFLOW_GH:-gh} "$@"); }

# _rco_hosted_wait - the longest a hosted-bound job of this repo has been
# queued, whole minutes (0 = none queued); 1 when a query fails
_rco_hosted_wait() {
  local ids id st now oldest="" t max="${CI_OVERFLOW_MAX_RUNS:-30}" n=0
  ids=""
  for st in queued in_progress; do
    t="$(_rco_gh api "repos/{owner}/{repo}/actions/runs?status=$st&per_page=100" --jq '.workflow_runs[].id' 2>/dev/null)" || return 1
    ids+="$t"$'\n'
  done
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    ((n++ >= max)) && break
    t="$(_rco_gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" --jq '[.jobs[]
      | select(.status == "queued" and ((.labels // []) | index("self-hosted") | not))
      | (.created_at // .started_at) | fromdate] | min // ""' 2>/dev/null)" || return 1
    [[ "$t" =~ ^[0-9]+$ ]] && { [[ -z "$oldest" ]] || ((t < oldest)); } && oldest="$t"
  done <<<"$ids"
  now="$(date +%s)"
  [[ -z "$oldest" ]] && { echo 0; return 0; }
  echo $(((now - oldest) / 60))
}

do_route_ci_overflow() {
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq not found"; return 1; }
  local dry="${DRY_RUN:-1}" state="${CI_OVERFLOW_STATE_DIR:-/var/tmp/ci-overflow}" orc oa cnf hub="" cur rc
  local wait since now held=0 want why
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "${CI_OVERFLOW_MAX_RUNS:-30}" =~ ^[1-9][0-9]{0,2}$ ]] || { do_log "FATAL CI_OVERFLOW_MAX_RUNS must be 1..999"; return 1; }
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" oa="$(basename "$orc")" oa="${oa%-orc}"
  cnf="${CI_OVERFLOW_CNF:-$(dirname "$orc")/$oa-cnf/$oa/all.env.yaml}"
  declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
  if spl_lane_init >/dev/null 2>&1 && [[ "$LANE_MODE" == hub ]]; then
    hub="$(LANE_TIMEOUT="${LANE_TIMEOUT:-15}" spl_lane_spool fleet-load get 2>/dev/null)"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$hub" || { echo "WARN the hub did not answer fleet-load get: cnf settings"; hub=""; }
  fi
  spl_ci_overflow_settings "$cnf" "$hub" "${LANE_BOX:-}" || return 1
  cur="$(spl_ci_overflow_var "${CI_OVERFLOW_GH:-gh}")"; rc=$?
  ((rc == 1)) && { do_log "FATAL SPOOL_CI_RUNNER does not read: nothing changed"; return 1; }
  ((rc == 2)) && cur=""
  now="$(date +%s)"
  if ((CIO_ENABLED == 0)); then
    want="$CI_OVERFLOW_HOSTED_RUNNER" why="overflow switched off ($CIO_SRC)"
  else
    wait="$(_rco_hosted_wait)" || { do_log "FATAL the runs or jobs query failed: nothing changed"; return 1; }
    if [[ -n "$cur" ]] && ! spl_ci_overflow_is_local "$cur"; then
      if ((wait >= CIO_ENTER)); then want="$CI_OVERFLOW_LOCAL_RUNNER" why="a hosted job queued ${wait} min (>= $CIO_ENTER): overflow"
      else want="$cur" why="hosted wait ${wait} min (< $CIO_ENTER): stay hosted"; fi
    else
      since="$(head -1 "$state/since" 2>/dev/null)"
      if ! [[ "$since" =~ ^[0-9]+$ ]]; then
        since="$now"
        [[ "$dry" == 0 ]] && { mkdir -p "$state" && echo "$now" >"$state/since" || { do_log "FATAL cannot write $state/since"; return 1; }; }
      fi
      held=$(((now - since) / 60))
      if ((held >= CIO_HOLD && wait < CIO_EXIT)); then
        want="$CI_OVERFLOW_HOSTED_RUNNER" why="local for ${held} min (>= $CIO_HOLD) and hosted wait ${wait} min (< $CIO_EXIT): back to hosted"
      else
        want="${cur:-$CI_OVERFLOW_LOCAL_RUNNER}" why="local for ${held} min of $CIO_HOLD, hosted wait ${wait} min (exit < $CIO_EXIT): stay local"
      fi
    fi
  fi
  echo "ROUTE SPOOL_CI_RUNNER ${cur:-<unset>} -> $want: $why"
  [[ "$want" == "$cur" ]] && { do_log "OK no change"; return 0; }
  # shellcheck source=/dev/null
  declare -F do_gh_set_ci_vars >/dev/null ||
    source "$(dirname "$orc")/$oa-iac/src/bash/run/gh-set-ci-vars.func.sh" ||
    { do_log "FATAL no do_gh_set_ci_vars"; return 1; }
  SPOOL_CI_RUNNER="$want" DRY_RUN="$dry" do_gh_set_ci_vars || return 1
  [[ "$dry" == 1 ]] && return 0
  if spl_ci_overflow_is_local "$want"; then
    mkdir -p "$state" && echo "$now" >"$state/since" || { do_log "FATAL cannot write $state/since"; return 1; }
  else
    rm -f "$state/since"
  fi
  do_log "OK SPOOL_CI_RUNNER is $want"
}
