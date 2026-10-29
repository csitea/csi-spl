#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 08 (rel-08, SPL-2451, Refs: SPL-2364):
# @description GitHub Actions runner health and job hang detector. A
# @description self-hosted runner listener can hang or disconnect, and a job
# @description can run for hours, stalling CI with nothing reporting it.
# @description
# @description It asks the GitHub API (gh api, read-only), in parallel:
# @description   repos/<repo>/actions/runners and orgs/<org>/actions/runners
# @description   repos/<repo>/actions/runs?status=in_progress, then each
# @description   run's jobs
# @description and prints one line per runner and per hung job:
# @description   gh-runner <name> ONLINE    busy=<true|false> labels=<l,...>
# @description   gh-runner <name> PARKED    offline, its unit is in
# @description     CPU_BUDGET_STATE_DIR/parked (stopped on purpose by
# @description     do_apply_gh_runner_cpu_budget): never an alert
# @description   gh-runner <name> OFFLINE   offline with a unit on THIS box
# @description     (actions.runner.<org>.<name>.service), not parked: ALERT
# @description   gh-runner <name> OTHER_BOX offline, no unit here: its parked
# @description     state lives on its own box, so it is listed, never an
# @description     alert here (run the check on that box)
# @description   gh-job <run>/<job> HUNG <min> min on <runner>: a job of a
# @description     self-hosted runner in progress for more than
# @description     GH_RUNNER_HEALTH_JOB_MAX_MIN (45) minutes: ALERT
# @description   gh-api ERROR <path>: an API call failed: ALERT (a check
# @description     that cannot see the runners never reads as OK)
# @description A parked-list line that names no registered runner is an INFO
# @description line. Ends with one CHECK line (state, counts, ms).
# @description GH_RUNNER_HEALTH_UNIT_CHECK=1 also runs csi-spl-orc's
# @description do_check_gh_runner (the units, Restart=, docker; it needs sudo
# @description and up to 15 s, so it is off by default) and alerts on its FAIL.
# @description
# @description ALERT OR REPORT ONLY: it never starts, stops, removes or
# @description re-registers a runner nor cancels a job. An alert sends ONE
# @description spool note to the orchestrator, only with DRY_RUN=0 (default 1
# @description prints the plan), throttled by a state stamp: again when the
# @description alert set changes or after GH_RUNNER_HEALTH_THROTTLE_S. OK
# @description clears the stamp.
# @description Exit 0 OK, 1 an alert, 2 a usage error.
# @param GH_RUNNER_HEALTH_REPO (optional) - <owner>/<repo>, default: the origin remote
# @param GH_RUNNER_HEALTH_ORG (optional) - default the repo owner; "-" skips the org runners
# @param GH_RUNNER_HEALTH_JOB_MAX_MIN (optional) - default 45
# @param GH_RUNNER_HEALTH_GH (optional) - the gh binary, default gh (tests stub it)
# @param GH_RUNNER_HEALTH_UNITS (optional) - this box's runner units, space separated,
# @param   instead of systemctl list-units 'actions.runner.*.service' (tests)
# @param GH_RUNNER_HEALTH_NOW (optional) - epoch seconds for "now" (tests)
# @param GH_RUNNER_HEALTH_UNIT_CHECK (optional) - 1 also runs do_check_gh_runner (sudo)
# @param GH_RUNNER_HEALTH_UNIT_CHECK_SH (optional) - default ../csi-spl-orc/src/bash/run/check-gh-runner.func.sh
# @param CPU_BUDGET_STATE_DIR (optional) - default /var/tmp/gh-runner-cpu-budget
# @param GH_RUNNER_HEALTH_STATE_DIR (optional) - default <SPL_STATE_DIR or
# @param   $HOME/.local/state/csi-spl>/gh-runner-health
# @param GH_RUNNER_HEALTH_THROTTLE_S (optional) - default 1800
# @param GH_RUNNER_HEALTH_SEND_CMD (optional) - the sender, called with
# @param   --from <id> --to <id> --kind note --task <task> --no-poke --body <text>;
# @param   default bash <repo>/csi-spl-orc/.../spawn-agents/scripts/spool-send.sh
# @param GH_RUNNER_HEALTH_ALERT_TO / _FROM / _TASK (optional) - default orchestrator /
# @param   $SPOOL_AGENT_ID or gh-runner-health@<box> / gh-runner-health
# @param DRY_RUN (optional) - 1 (default) plans the alert; 0 sends it
# @example ./run -a do_gh_runner_health_check
# @example GH_RUNNER_HEALTH_REPO=<owner>/<repo> DRY_RUN=0 ./run -a do_gh_runner_health_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

do_gh_runner_health_check() {
  local repo org max="${GH_RUNNER_HEALTH_JOB_MAX_MIN:-45}" dry="${DRY_RUN:-1}" now t0 tmp counts ms
  local parked="${CPU_BUDGET_STATE_DIR:-/var/tmp/gh-runner-cpu-budget}/parked"
  local -a alerts=() lines=()
  [[ "$max" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL GH_RUNNER_HEALTH_JOB_MAX_MIN must be 1..9999 minutes, got: '$max'"; return 2; }
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not on PATH"; return 2; }
  command -v "${GH_RUNNER_HEALTH_GH:-gh}" >/dev/null 2>&1 || { do_log "FATAL ${GH_RUNNER_HEALTH_GH:-gh} is not on PATH"; return 2; }
  repo="$(ghrh_repo)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { do_log "FATAL no GitHub repo: set GH_RUNNER_HEALTH_REPO=<owner>/<repo>"; return 2; }
  org="${GH_RUNNER_HEALTH_ORG:-${repo%%/*}}"
  [[ "$org" == - || "$org" =~ ^[A-Za-z0-9_.-]+$ ]] || { do_log "FATAL GH_RUNNER_HEALTH_ORG '$org' is not a plain name"; return 2; }
  now="${GH_RUNNER_HEALTH_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  [[ "$now" =~ ^[0-9]+$ ]] || { do_log "FATAL GH_RUNNER_HEALTH_NOW must be epoch seconds, got: '$now'"; return 2; }
  t0="$(ghrh_ms)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gh-runner-health.XXXXXX")" || { do_log "FATAL mktemp failed"; return 2; }
  ghrh_fetch "$tmp" "$repo" "$org" "$now"
  ghrh_runners "$tmp" "$org" "$parked"
  ghrh_jobs "$tmp" "$max"
  [[ "${GH_RUNNER_HEALTH_UNIT_CHECK:-0}" == 1 ]] && ghrh_unit_check "$tmp"
  mapfile -t lines <"$tmp/out"
  [[ -s "$tmp/alerts" ]] && mapfile -t alerts <"$tmp/alerts"
  counts="$(<"$tmp/counts")"
  rm -rf "$tmp"
  ((${#lines[@]})) && printf '%s\n' "${lines[@]}"
  ms=$(($(ghrh_ms) - t0))
  if ((${#alerts[@]} == 0)); then
    do_log "INFO CHECK gh-runner-health OK: repo=$repo $counts ms=$ms"
    ghrh_clear "$dry"
    return 0
  fi
  do_log "WARN CHECK gh-runner-health ALERT: ${#alerts[@]} alert(s) repo=$repo $counts ms=$ms"
  ghrh_alert "$repo" "$dry" "${alerts[@]}"
  return 1
}

# do_gh_runner_health - the filename's own action name (same check)
do_gh_runner_health() { do_gh_runner_health_check "$@"; }

# ghrh_repo - GH_RUNNER_HEALTH_REPO, else <owner>/<repo> of the origin remote
ghrh_repo() {
  if [[ -n "${GH_RUNNER_HEALTH_REPO:-}" ]]; then printf '%s\n' "$GH_RUNNER_HEALTH_REPO"; return 0; fi
  local url; url="$(git -C "${PROJ_PATH:-.}" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# ghrh_api <out> <path> - one paginated gh api call into <out>; a failure
# writes <out>.err with the path and gh's first error line
ghrh_api() {
  "${GH_RUNNER_HEALTH_GH:-gh}" api --paginate "$2" >"$1" 2>"$1.stderr" ||
    printf '%s (%s)\n' "$2" "$(head -1 "$1.stderr" | tr -d '\r')" >"$1.err"
}

# ghrh_fetch <tmp> <repo> <org> <now> - the runner lists and the in-progress
# runs in parallel, then the jobs of every run in parallel. Writes
# <tmp>/runners.tsv (id name status busy labels) and <tmp>/jobs.tsv
# (run job runner age_min self_hosted name url)
ghrh_fetch() {
  local tmp="$1" repo="$2" org="$3" now="$4" id f
  local -a pids=()
  ghrh_api "$tmp/r.repo" "repos/$repo/actions/runners?per_page=100" & pids+=($!)
  if [[ "$org" != - ]]; then ghrh_api "$tmp/r.org" "orgs/$org/actions/runners?per_page=100" & pids+=($!); fi
  ghrh_api "$tmp/runs" "repos/$repo/actions/runs?status=in_progress&per_page=100" & pids+=($!)
  wait "${pids[@]}" 2>/dev/null
  cat "$tmp"/r.repo "$tmp"/r.org 2>/dev/null |
    jq -r '.runners[]? | [.id, .name, .status, (.busy | tostring), ([.labels[]?.name] | join(","))] | @tsv' 2>/dev/null |
    sort -u -t $'\t' -k1,1 >"$tmp/runners.tsv"
  : >"$tmp/jobs.tsv"
  [[ -f "$tmp/runs.err" ]] && return 0
  pids=()
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    ghrh_api "$tmp/jobs.$id" "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" & pids+=($!)
  done < <(jq -r '.workflow_runs[]?.id' "$tmp/runs" 2>/dev/null)
  ((${#pids[@]})) && wait "${pids[@]}" 2>/dev/null
  for f in "$tmp"/jobs.*.err; do
    [[ -f "$f" ]] && cat "$f" >>"$tmp/jobs.err"
  done
  for f in "$tmp"/jobs.[0-9]*; do
    [[ "$f" == *.err || "$f" == *.stderr || ! -f "$f" ]] && continue
    jq -r --argjson now "$now" '.jobs[]? | select(.status == "in_progress" and .started_at != null) |
      [.run_id, .id, (.runner_name // "-"), ((($now - (.started_at | fromdateiso8601)) / 60) | floor),
       (if ((.labels // []) | index("self-hosted")) then 1 else 0 end), (.name | gsub("\\s"; " ")), (.html_url // "-")] | @tsv' \
      "$f" 2>/dev/null >>"$tmp/jobs.tsv"
  done
}

# ghrh_local_units - this box's runner unit names, one per line
ghrh_local_units() {
  if [[ -n "${GH_RUNNER_HEALTH_UNITS+x}" ]]; then tr ' ' '\n' <<<"$GH_RUNNER_HEALTH_UNITS" | grep -v '^$'; return 0; fi
  systemctl list-units 'actions.runner.*.service' --all --plain --no-legend 2>/dev/null |
    awk '$1 ~ /^actions\.runner\..*\.service$/ {print $1}'
}

# ghrh_runners <tmp> <org> <parked> - one line per runner; alerts for the
# offline ones of this box that the CPU budget did not park
ghrh_runners() {
  local tmp="$1" org="$2" parked="$3" id name status busy labels unit e
  local n=0 on=0 pk=0 off=0 other=0 units="" pl=""
  : >"$tmp/out"; : >"$tmp/alerts"
  for e in "$tmp"/r.repo.err "$tmp"/r.org.err "$tmp"/runs.err "$tmp"/jobs.err; do
    [[ -f "$e" ]] || continue
    sed 's/^/gh-api ERROR /' "$e" | tee -a "$tmp/alerts" >>"$tmp/out"
  done
  units="$(ghrh_local_units)"
  [[ -r "$parked" ]] && pl="$(<"$parked")"
  while IFS=$'\t' read -r id name status busy labels; do
    [[ -n "$name" ]] || continue
    n=$((n + 1))
    if [[ "$status" == online ]]; then
      on=$((on + 1)); echo "gh-runner $name ONLINE busy=$busy labels=$labels" >>"$tmp/out"; continue
    fi
    unit="$(ghrh_unit_of "$name" "$org" "$units"$'\n'"$pl")"
    if [[ -n "$unit" ]] && grep -qxF -- "$unit" <<<"$pl"; then
      pk=$((pk + 1)); echo "gh-runner $name PARKED $status, $unit is in $parked" >>"$tmp/out"
    elif [[ -n "$unit" ]]; then
      off=$((off + 1)); echo "gh-runner $name OFFLINE $status, $unit is on this box and not parked" | tee -a "$tmp/alerts" >>"$tmp/out"
    else
      other=$((other + 1)); echo "gh-runner $name OTHER_BOX $status, no unit here: run the check on its own box" >>"$tmp/out"
    fi
  done <"$tmp/runners.tsv"
  ghrh_stale_parked "$tmp" "$pl" "$parked"
  echo "runners=$n online=$on parked=$pk offline=$off other_box=$other" >"$tmp/counts"
}

# ghrh_unit_of <name> <org> <candidates> - the unit of runner <name> among
# <candidates> (actions.runner.<scope>.<name>.service), org scope first
ghrh_unit_of() {
  local name="$1" org="$2" u
  if grep -qxF -- "actions.runner.$org.$name.service" <<<"$3"; then echo "actions.runner.$org.$name.service"; return 0; fi
  while read -r u; do
    [[ "$u" == actions.runner.*."$name".service ]] && { echo "$u"; return 0; }
  done <<<"$3"
}

# ghrh_stale_parked <tmp> <parked lines> <parked file> - INFO for a parked
# unit that names no registered runner (left over after a runner was retired)
ghrh_stale_parked() {
  local tmp="$1" u name
  [[ -f "$tmp/r.repo.err" || -f "$tmp/r.org.err" ]] && return 0
  while read -r u; do
    [[ "$u" == actions.runner.*.service ]] || continue
    name="${u%.service}"; name="${name##*.}"
    grep -qxF -- "$name" < <(cut -f2 "$tmp/runners.tsv") ||
      echo "gh-runner-parked INFO $u is in $3 but no runner $name is registered" >>"$tmp/out"
  done <<<"$2"
}

# ghrh_jobs <tmp> <max_min> - a HUNG line (an alert) per self-hosted job in
# progress for more than <max_min> minutes
ghrh_jobs() {
  local tmp="$1" max="$2" run job runner age sh name url hung=0 n=0
  while IFS=$'\t' read -r run job runner age sh name url; do
    [[ -n "$job" ]] || continue
    n=$((n + 1))
    [[ "$sh" == 1 && "$age" =~ ^[0-9]+$ ]] && ((age > max)) || continue
    hung=$((hung + 1))
    echo "gh-job $run/$job HUNG $age min on $runner (> $max): $name $url" | tee -a "$tmp/alerts" >>"$tmp/out"
  done <"$tmp/jobs.tsv"
  echo "$(<"$tmp/counts") jobs_in_progress=$n hung_jobs=$hung" >"$tmp/counts"
}

# ghrh_unit_check <tmp> - csi-spl-orc's do_check_gh_runner (units, Restart=,
# docker), in a subshell; its FAIL lines become alerts
ghrh_unit_check() {
  local tmp="$1" sh out rc
  sh="${GH_RUNNER_HEALTH_UNIT_CHECK_SH:-${PROJ_PATH:-.}/../csi-spl-orc/src/bash/run/check-gh-runner.func.sh}"
  if [[ ! -r "$sh" ]]; then
    echo "gh-unit-check ERROR no $sh" | tee -a "$tmp/alerts" >>"$tmp/out"; return 0
  fi
  # shellcheck disable=SC1090 # the path is the orc check, resolved at run time
  out="$( (source "$sh" && do_check_gh_runner) 2>&1)"; rc=$?
  sed 's/^/gh-unit-check /' <<<"$out" >>"$tmp/out"
  ((rc == 0)) && return 0
  if grep -q '^FAIL ' <<<"$out"; then
    grep '^FAIL ' <<<"$out" | sed 's/^/gh-unit-check /' >>"$tmp/alerts"
  else
    echo "gh-unit-check ERROR exit $rc" | tee -a "$tmp/alerts" >>"$tmp/out"
  fi
}

# ghrh_stamp - the throttle stamp path
ghrh_stamp() { echo "${GH_RUNNER_HEALTH_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/gh-runner-health}/last-alert.stamp"; }

# ghrh_clear <dry> - an OK check forgets its last alert (real run only)
ghrh_clear() {
  local stamp; stamp="$(ghrh_stamp)"
  [[ "$1" == 0 && -f "$stamp" ]] && rm -f "$stamp"
  return 0
}

# ghrh_alert <repo> <dry> <alert...> - one throttled spool note
ghrh_alert() {
  local repo="$1" dry="$2" stamp key prev="" at=0 now box body from
  local to="${GH_RUNNER_HEALTH_ALERT_TO:-orchestrator}" task="${GH_RUNNER_HEALTH_ALERT_TASK:-gh-runner-health}"
  local throttle="${GH_RUNNER_HEALTH_THROTTLE_S:-1800}"
  local -a send
  shift 2
  box="$(spl_box_name)"
  from="${GH_RUNNER_HEALTH_ALERT_FROM:-${SPOOL_AGENT_ID:-gh-runner-health@$box}}"
  # the key leaves out the minute count, so a hung job that only aged is
  # the same alert
  key="$(printf '%s\n' "$@" | sed -E 's/ HUNG [0-9]+ min / HUNG /' | sort | cksum | cut -d' ' -f1)"
  stamp="$(ghrh_stamp)"
  now="${GH_RUNNER_HEALTH_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  [[ -f "$stamp" ]] && read -r prev at <"$stamp"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  if [[ "$prev" == "$key" ]] && ((now - at < throttle)); then
    do_log "INFO gh-runner-health alert throttled by $stamp"
    return 0
  fi
  body="gh-runner-health on $box for $repo, $# alert(s): $(printf '%s; ' "$@")nothing was restarted, cancelled or removed: check by hand (cd csi-spl-utl && ./run -a do_gh_runner_health_check)."
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  read -ra send <<<"${GH_RUNNER_HEALTH_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: alert not sent"; return 0; }
  fi
  if timeout -k 2 20 "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$key $now" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run alerts again"
    do_log "INFO gh-runner-health note sent to $to"
  else
    do_log "WARN gh-runner-health: the note to $to failed"
  fi
  return 0
}

# ghrh_ms - a millisecond wall clock (no fork)
ghrh_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

# The file name gives do_gh_runner_health; the plan's action name is
# do_gh_runner_health_check, registered here when run.sh sources the file.
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_gh_runner_health_check"]="${BASH_SOURCE[0]}"
fi
