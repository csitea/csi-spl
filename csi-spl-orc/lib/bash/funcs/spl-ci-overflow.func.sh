#!/bin/bash
#------------------------------------------------------------------------------
# CI overflow settings (owner HUM-10, t1 f67e3656 msgs d4ba4b17, 70480eb3,
# 61cd35bc): wf 10 runs on GitHub-hosted runners and spills to the local
# self-hosted runners only while those are overwhelmed
# (do_route_ci_overflow); the local runners then take at most a capped share
# of a box (do_apply_gh_runner_cpu_budget). One reading of the settings for
# both actions, each key in this order:
#   env CI_OVERFLOW_<KEY>  >  the hub's fleet-load (the workspace admin's
#   setting; enabled and cpus only)  >  cnf env.box.ci_overflow.<key>  >
#   the defaults below
#   enabled          hub .ci_overflow                       default true
#   cpus             hub .boxes[<box>].runner_cpus // .runner_cpus
#                    (cores; 0 = no count, the share rules)  default 0
#   cap_pct          the box share, 20..30 (env 0 = no cap)  default 25
#   enter_queue_min / exit_queue_min / hold_min              10 / 3 / 30
# The runner target is the repo variable SPOOL_CI_RUNNER (wf 10's runs-on):
# CI_OVERFLOW_HOSTED_RUNNER on hosted, CI_OVERFLOW_LOCAL_RUNNER on local.
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # CI_OVERFLOW_* and CIO_* are read by the callers

CI_OVERFLOW_HOSTED_RUNNER='"ubuntu-latest"'
CI_OVERFLOW_LOCAL_RUNNER='["self-hosted","spool-ci"]'

# spl_ci_overflow_settings <cnf> <hub fleet-load json or ""> <box> - sets
# CIO_ENABLED (1/0), CIO_CPUS, CIO_CAP_PCT, CIO_ENTER, CIO_EXIT, CIO_HOLD and
# CIO_SRC (where enabled and cpus came from); 1 + a FATAL on a bad value
spl_ci_overflow_settings() {
  local cnf="$1" hub="$2" box="$3" k v ev src
  local -A def=([enabled]=true [cpus]=0 [cap_pct]=25 [enter_queue_min]=10 [exit_queue_min]=3 [hold_min]=30) got
  for k in "${!def[@]}"; do
    ev="CI_OVERFLOW_${k^^}" v="${!ev:-}" src=env
    if [[ -z "$v" && -n "$hub" ]]; then
      case "$k" in
        enabled) v="$(jq -r 'if .ci_overflow == null then "" else .ci_overflow | tostring end' <<<"$hub" 2>/dev/null)" ;;
        cpus) v="$(jq -r --arg b "$box" '(.boxes[$b].runner_cpus // .runner_cpus // "") | tostring' <<<"$hub" 2>/dev/null)" ;;
      esac
      src=hub
    fi
    if [[ -z "$v" && -r "$cnf" ]] && command -v yq >/dev/null; then
      v="$(yq ".env.box.ci_overflow.$k" "$cnf" 2>/dev/null)" src=cnf
      [[ "$v" == null ]] && v=""
    fi
    [[ -z "$v" ]] && v="${def[$k]}" src=default
    got[$k]="$v" got[$k.src]="$src"
  done
  case "${got[enabled]}" in true|1|on) CIO_ENABLED=1 ;; false|0|off) CIO_ENABLED=0 ;;
    *) do_log "FATAL ci_overflow enabled must be true or false, got: '${got[enabled]}'"; return 1 ;; esac
  CIO_CPUS="${got[cpus]}" CIO_CAP_PCT="${got[cap_pct]}"
  CIO_ENTER="${got[enter_queue_min]}" CIO_EXIT="${got[exit_queue_min]}" CIO_HOLD="${got[hold_min]}"
  [[ "$CIO_CPUS" =~ ^(0|[1-9][0-9]{0,2})$ ]] || { do_log "FATAL ci_overflow cpus must be 0..999 cores, got: '$CIO_CPUS'"; return 1; }
  # 0 is the env's alone: no cap (the budget as before the overflow rule)
  [[ "$CIO_CAP_PCT" =~ ^(2[0-9]|30)$ || ( "$CIO_CAP_PCT" == 0 && "${got[cap_pct.src]}" == env ) ]] ||
    { do_log "FATAL ci_overflow cap_pct must be 20..30 (% of a box), got: '$CIO_CAP_PCT'"; return 1; }
  for k in CIO_ENTER CIO_EXIT CIO_HOLD; do
    [[ "${!k}" =~ ^(0|[1-9][0-9]{0,3})$ ]] || { do_log "FATAL ci_overflow $k must be 0..9999 minutes, got: '${!k}'"; return 1; }
  done
  CIO_SRC="enabled from ${got[enabled.src]}, cpus from ${got[cpus.src]}"
}

# spl_ci_overflow_cap <cores> - the local runners' CPU cap in % of one core
# (CPUQuota), rounded down to 10: min(cpus, cores) * 100 when a count is set,
# else cores * cap_pct; 0 = no cap
spl_ci_overflow_cap() {
  local c="$1"
  if ((CIO_CPUS > 0)); then echo $(((CIO_CPUS < c ? CIO_CPUS : c) * 100)); return 0; fi
  echo $((c * CIO_CAP_PCT / 10 * 10))
}

# spl_ci_overflow_var [gh] - the repo variable SPOOL_CI_RUNNER on stdout.
# 0 = read, 2 = not set (wf 10 then runs on this repo's local runners),
# 1 = the read failed. gh resolves {owner}/{repo} from the cwd's origin
spl_ci_overflow_var() {
  local out rc
  out="$(timeout 20 ${1:-gh} api 'repos/{owner}/{repo}/actions/variables/SPOOL_CI_RUNNER' --jq .value 2>&1)"; rc=$?
  ((rc == 0)) && { printf '%s\n' "$out"; return 0; }
  [[ "$out" == *"HTTP 404"* ]] && return 2
  return 1
}

# spl_ci_overflow_is_local <value> - 0 when that runs-on value targets the
# self-hosted runners
spl_ci_overflow_is_local() { [[ "$1" == *self-hosted* ]]; }
