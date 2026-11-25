#!/bin/bash
#------------------------------------------------------------------------------
# @description Wait for the CI runs of ONE commit, at one GitHub API call per
# @description tick (SPL-6502). The lanes' replacement for `gh run watch`.
# @description
# @description Why: the fleet's agents share one GitHub account and its 5000
# @description REST calls an hour. `gh run watch` refreshes every 3 s by default
# @description and every refresh re-reads the run, its workflow, its jobs and
# @description the annotations of EVERY completed job: measured with
# @description GH_DEBUG=api, one `gh run watch --interval 10` on a 28-job run of
# @description wf 10 made 69 REST calls in 60 s (55 of them annotations). One
# @description lane's chain of three default-interval watches took the account
# @description from ~15 to ~100 calls a minute (2026-11-25, 12:58Z).
# @description
# @description This action makes exactly one call per tick,
# @description   GET repos/{owner}/{repo}/actions/runs?head_sha=<full sha>
# @description and never reads jobs or annotations. Every workflow run of the
# @description commit (wf 10, 20, 30, workflow_run-triggered ones) is in that
# @description one list. Only runs of CI_WAIT_EVENTS count: a scheduled or
# @description dispatched run that happened to start while the commit was trunk's
# @description head (wf 21, 40) also carries its head_sha, and is not the lane's.
# @description Done = every run completed on TWO consecutive ticks
# @description with the same run ids, so a run that a finished one triggers is
# @description waited for too. Prints one `<run id> <workflow> <conclusion>`
# @description line per run at the end.
# @description
# @description Exit: 0 every run green (success, skipped, neutral)
# @description       1 a run ended red (failure, cancelled, timed_out, ...),
# @description         or a bad setting (FATAL)
# @description       2 no run of the commit appeared within CI_WAIT_NORUN_MIN
# @description       4 not done within CI_WAIT_TIMEOUT_MIN
# @description A failed call (rate limit, network) is a WARN; the next tick
# @description tries again.
# @param SHA - optional: the commit to wait for (default: HEAD of the current dir)
# @param CI_WAIT_INTERVAL - optional: seconds between ticks (default 60, at least 30)
# @param CI_WAIT_TIMEOUT_MIN - optional: give up after this many minutes (default 90)
# @param CI_WAIT_NORUN_MIN - optional: minutes with no run before exit 2 (default 10)
# @param CI_WAIT_EVENTS - optional: comma list of run events that count (default push,workflow_run)
# @param CI_WAIT_REPO - optional: owner/repo (default: gh's {owner}/{repo} of the current dir)
# @param CI_WAIT_GH / CI_WAIT_SLEEP - optional: the gh and sleep commands (tests)
# @example cd csi-spl-orc && SHA=$(git rev-parse origin/master) ./run -a do_ci_wait_sha
#------------------------------------------------------------------------------
do_ci_wait_sha() {
  local gh="${CI_WAIT_GH:-gh}" slp="${CI_WAIT_SLEEP:-sleep}"
  local interval="${CI_WAIT_INTERVAL:-60}" timeout_min="${CI_WAIT_TIMEOUT_MIN:-90}" norun_min="${CI_WAIT_NORUN_MIN:-10}"
  local repo="${CI_WAIT_REPO:-}" events="${CI_WAIT_EVENTS:-push,workflow_run}" sha v
  [[ -n "$repo" ]] || repo='{owner}/{repo}'
  for v in interval timeout_min norun_min; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { do_log "FATAL $v must be a whole number, got: '${!v}'"; return 1; }
  done
  [[ "$events" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || { do_log "FATAL CI_WAIT_EVENTS must be a comma list of run events, got: '$events'"; return 1; }
  (( interval >= 30 )) || { do_log "FATAL CI_WAIT_INTERVAL must be at least 30 s (SPL-6502: one shared 5000 calls/h), got: $interval"; return 1; }
  sha="$(git rev-parse -q --verify "${SHA:-HEAD}^{commit}" 2>/dev/null)" ||
    { do_log "FATAL SHA '${SHA:-HEAD}' is not a commit of this checkout (fetch first)"; return 1; }

  local ticks=$(( timeout_min * 60 / interval )) norun_ticks=$(( (norun_min * 60 + interval - 1) / interval ))
  (( ticks > 0 )) || ticks=1
  local i rows ids pending prev=""
  do_log "INFO waiting for the CI runs of ${sha:0:9}: 1 call every ${interval}s, up to ${timeout_min} min"
  for (( i = 1; i <= ticks; i++ )); do
    if rows="$("$gh" api "repos/$repo/actions/runs?head_sha=$sha&per_page=100" \
                 --jq '.workflow_runs[] | [.id, .name, .status, (.conclusion // ""), .event] | @tsv' 2>/dev/null)"; then
      rows="$(awk -F'\t' -v ev=",$events," 'NF && index(ev, "," $5 ",")' <<<"$rows")"
      ids="$(cut -f1 <<<"$rows" | sort | paste -sd,)"
      pending="$(awk -F'\t' 'NF && $3 != "completed"' <<<"$rows" | wc -l)"
      if [[ -z "$rows" ]]; then
        (( i >= norun_ticks )) && { do_log "ERROR no CI run of ${sha:0:9} after ${norun_min} min"; return 2; }
      elif (( pending == 0 )) && [[ "$ids" == "$prev" ]]; then
        awk -F'\t' '{ printf "%s %s %s\n", $1, $2, $4 }' <<<"$rows"
        if awk -F'\t' '$4 !~ /^(success|skipped|neutral)$/ { bad = 1 } END { exit !bad }' <<<"$rows"; then
          do_log "ERROR a CI run of ${sha:0:9} ended red"; return 1
        fi
        do_log "OK every CI run of ${sha:0:9} is green"; return 0
      fi
      prev=""; (( pending == 0 )) && prev="$ids"
    else
      do_log "WARN the runs of ${sha:0:9} did not read (rate limit or network); next try in ${interval}s"
    fi
    (( i < ticks )) && "$slp" "$interval"
  done
  do_log "ERROR the CI runs of ${sha:0:9} are not done after ${timeout_min} min"
  return 4
}
