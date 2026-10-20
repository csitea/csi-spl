#!/bin/bash
#------------------------------------------------------------------------------
# @description Cancel ONE gate run by id: the named action behind the
# @description do_check_ci_gate_stuck blocker, instead of a hand
# @description `gh run cancel` (c-001@sat note 4cbf224a, 2026-10-20). Refuses
# @description a run of another workflow (so a typo cannot cancel a deploy)
# @description and a run that already finished. Prints the run's state before
# @description and after.
# @param CI_GATE_RUN_ID (required) - the run to cancel
# @param CI_GATE_WORKFLOW (optional) - default 10_ci-quality.yml: the run
# @param CI_GATE_WORKFLOW must belong to it
# @param CI_GATE_REPO (optional) - as do_report_ci_gate
# @example CI_GATE_RUN_ID=39281262959 ./run -a do_cancel_ci_gate_run
#------------------------------------------------------------------------------
do_cancel_ci_gate_run() { (
  local rid="${CI_GATE_RUN_ID:-}" wf="${CI_GATE_WORKFLOW:-10_ci-quality.yml}" info path status sha
  [[ "$rid" =~ ^[0-9]+$ ]] || { do_log "FATAL CI_GATE_RUN_ID must be a run id (digits), got: '${rid}'"; return 2; }
  [[ -n "${CI_GATE_REPO:-}" ]] && export GH_REPO="$CI_GATE_REPO"
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { do_log "FATAL gh and jq are required"; return 1; }
  info=$(gh api "repos/{owner}/{repo}/actions/runs/$rid" --jq '[.path, .status, .head_sha] | @tsv' 2>&1) ||
    { do_log "FATAL cannot read run $rid: ${info:0:200}"; return 1; }
  IFS=$'\t' read -r path status sha <<<"$info"
  [[ "${path##*/}" == "$wf" ]] || { do_log "FATAL run $rid belongs to ${path:-?}, not $wf: refused"; return 2; }
  [[ "$status" != completed ]] || { echo "OK run $rid already finished: nothing to cancel"; return 0; }
  echo "INFO cancelling $wf run $rid (sha $sha, status $status)"
  gh run cancel "$rid" || { do_log "FATAL gh run cancel $rid failed"; return 1; }
  status=$(gh api "repos/{owner}/{repo}/actions/runs/$rid" --jq '.status' 2>/dev/null)
  echo "OK cancel of run $rid sent; its status now: ${status:-unknown}"
) }
