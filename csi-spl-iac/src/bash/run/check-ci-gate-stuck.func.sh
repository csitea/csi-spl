#!/bin/bash
#------------------------------------------------------------------------------
# @description ONE blocker per gate run that sits stuck in the runner queue.
# @description On 2026-10-19 wf 10 push run 39281262959 (98060fd3e) had its
# @description 4 jobs queued on self-hosted,spool-ci for 9 h. It held the
# @description push concurrency group, so 36 later push runs waited and were
# @description cancelled as superseded, and master had no verdict until a
# @description hand `gh run cancel` at 01:10Z (c-001@sat note 4cbf224a).
# @description Reads the unfinished runs of the workflow on the branch (push
# @description runs; a run of another event has its own concurrency group). A
# @description run with a job `queued` for over CI_GATE_STUCK_MIN minutes
# @description since the job was created sends ONE blocker to the dispatch
# @description lease holder: the run, its sha, the job, its runner labels,
# @description how long it waits, and the named cancel action
# @description (do_cancel_ci_gate_run). Once per run: keyed by run id in
# @description CI_GATE_STUCK_STATE. Only the holder's box sends, as
# @description do_report_ci_red_note. It never cancels: a job queued because
# @description every runner is down loses nothing by waiting.
# @param CI_GATE_STUCK_MIN (optional) - default 60: minutes a job may queue
# @param CI_GATE_STUCK_EVENT (optional) - default push; empty = every event
# @param CI_GATE_STUCK_RUNS (optional) - default 30: runs read back
# @param CI_GATE_STUCK_STATE (optional) - the runs already told, default
# @param CI_GATE_STUCK_STATE $XDG_STATE_HOME/csi-spl/ci-gate-stuck.tsv
# @param CI_GATE_STUCK_NOW (optional) - epoch seconds for "now" (tests)
# @param CI_RED_NOTE_TO / _BOX / _SEND / _TASK - as do_report_ci_red_note
# @param CI_GATE_WORKFLOW / CI_GATE_BRANCH / CI_GATE_REPO - as do_report_ci_gate
# @example ./run -a do_check_ci_gate_stuck
# @example CI_GATE_STUCK_MIN=30 CI_RED_NOTE_TO=c-002 ./run -a do_check_ci_gate_stuck
#------------------------------------------------------------------------------
do_check_ci_gate_stuck() { (
  local wf="${CI_GATE_WORKFLOW:-10_ci-quality.yml}" branch="${CI_GATE_BRANCH-master}"
  local ev="${CI_GATE_STUCK_EVENT-push}" min="${CI_GATE_STUCK_MIN:-60}" n="${CI_GATE_STUCK_RUNS:-30}"
  local now="${CI_GATE_STUCK_NOW:-$(date +%s)}" top state to box tmp rid sha url told=0 stuck=0
  [[ "$min" =~ ^[0-9]+$ ]] || { do_log "FATAL CI_GATE_STUCK_MIN must be whole minutes, got: $min"; return 2; }
  [[ -n "${CI_GATE_REPO:-}" ]] && export GH_REPO="$CI_GATE_REPO"
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { do_log "FATAL gh and jq are required"; return 1; }
  declare -F _crn_holder >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/report-ci-red-note.func.sh"
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { do_log "FATAL not in a git checkout"; return 1; }
  state="${CI_GATE_STUCK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/ci-gate-stuck.tsv}"
  mkdir -p "$(dirname "$state")" && touch "$state" || { do_log "FATAL cannot write $state"; return 1; }
  to="${CI_RED_NOTE_TO:-$(_crn_holder "$top")}"
  [[ -n "$to" ]] || { do_log "FATAL no dispatch lease holder to send to"; return 1; }
  box="${CI_RED_NOTE_BOX:-$(_crn_box)}"
  if [[ "$to" == *@* && "${to#*@}" != "$box" ]]; then
    echo "OK ci-gate-stuck: the holder $to is not on this box ($box); its box checks"; return 0
  fi
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  gh run list --workflow "$wf" ${branch:+--branch "$branch"} ${ev:+--event "$ev"} --limit "$n" \
    --json databaseId,status,headSha,url \
    --jq '.[] | select(.status != "completed") | [.databaseId, .headSha, .url] | @tsv' \
    >"$tmp/open.tsv" 2>"$tmp/err" || { do_log "FATAL gh run list failed: $(head -2 "$tmp/err")"; return 1; }
  while IFS=$'\t' read -r rid sha url; do
    _cgs_stuck_job "$rid" "$now" "$min" >"$tmp/job" || continue
    stuck=$((stuck + 1))
    if awk -F'\t' -v r="$rid" '$1 == r { f = 1 } END { exit !f }' "$state"; then continue; fi
    _crn_send "$to" "$(_cgs_body "$wf" "$rid" "$sha" "$url" "$min" "$(cat "$tmp/job")")" || { do_log "FATAL send to $to failed for run $rid"; return 1; }
    printf '%s\t%s\t%s\n' "$rid" "$sha" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" >>"$state"
    told=$((told + 1))
  done <"$tmp/open.tsv"
  echo "OK ci-gate-stuck: $wf ${branch:-any branch} ${ev:-any event}: $stuck run(s) with a job queued over $min min, $told told $to"
) }

# _cgs_stuck_job <run id> <now> <min> - the run's longest-queued job when it
# waits over <min> minutes: "<minutes>\t<name>\t<labels>"; exit 1 when none.
_cgs_stuck_job() {
  gh api "repos/{owner}/{repo}/actions/runs/$1/jobs" --paginate 2>/dev/null |
    jq -r --argjson now "$2" --argjson min "$3" '
      .jobs[] | select(.status == "queued" and .created_at != null) |
      (($now - (.created_at | fromdate)) / 60 | floor) as $age |
      select($age > $min) | [$age, .name, ((.labels // []) | join(","))] | @tsv' 2>/dev/null |
    sort -t$'\t' -k1,1nr | sed -n 1p | grep .
}

# _cgs_body <wf> <run id> <sha> <url> <min> <job line> - the blocker text.
_cgs_body() {
  local age name labels
  IFS=$'\t' read -r age name labels <<<"$6"
  printf '## CI gate run stuck in the runner queue: %s run %s\n\n' "$1" "$2"
  printf 'Job `%s` has been queued for %s min (over %s) on runners `%s`. Run: %s (sha %s).\n' \
    "$name" "$age" "$5" "${labels:-?}" "$4" "$3"
  printf 'While it holds the concurrency group, every later run of the group waits and is cancelled as superseded: master gets no verdict.\n\n'
  printf 'Check the runners are up first (runners down: cancelling gains nothing). Then cancel it with the named action:\n'
  printf '`cd csi-spl-iac && CI_GATE_RUN_ID=%s ./run -a do_cancel_ci_gate_run`\n\n' "$2"
  printf 'One note per stuck run (do_check_ci_gate_stuck).'
}
