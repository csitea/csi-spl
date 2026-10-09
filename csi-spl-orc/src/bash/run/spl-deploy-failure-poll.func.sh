#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1255 (box-cron form): poll GitHub for FAILED runs of the
# @description deploy workflows (20 hub, 30 wui) and post one #spool-hub-ops
# @description blocker per NEW failure, via do_spl_deploy_failure_post. The
# @description owner chose a box cron over a workflow_run trigger, so this is the
# @description poller the cron calls every 10 min. Edge-dedup: each run id is
# @description recorded in a state file and posted at most once.
# @description The lister and the poster are injectable (FAIL_POLL_LIST_CMD,
# @description OPS_POST_FN) so the routing is testable without gh or the hub;
# @description the real path uses gh and is DRY_RUN=1 until a seated ops desk.
# @param TENANT_ID / DESK_AGENT / DESK_BOX - the ops desk that posts (do_spl_desk_post)
# @param DESK_CHANNEL (optional) - default spool-hub-ops
# @param FAIL_POLL_STATE (optional) - dedup file (default cache dir)
# @param FAIL_POLL_LIST_CMD (optional, testing) - prints TSV rows
# @param   "<run_id>\t<workflow>\t<url>\t<sha>\t<subject>\t<step>"; default uses gh
# @param OPS_POST_FN (optional, testing) - the poster; default do_spl_deploy_failure_post
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TENANT_ID=t1 DESK_AGENT=c-685 DESK_BOX=box-ci DRY_RUN=0 ./run -a do_spl_deploy_failure_poll
#------------------------------------------------------------------------------

# The real lister: failed 20/30 runs as TSV, newest first, with the failing step.
_spl_failed_deploy_runs() {
  command -v gh >/dev/null 2>&1 || { do_log "WARN failure-poll: gh not on PATH -- nothing polled"; return 0; }
  local wf rid url sha title step
  for wf in "20 ci-cd: spool hub build + deploy" "30 ci-cd: spool wui build + deploy"; do
    while IFS=$'\t' read -r rid url sha title; do
      [[ -n "$rid" ]] || continue
      # best-effort failing step (first failed step of any job)
      step="$(gh api "repos/{owner}/{repo}/actions/runs/$rid/jobs" \
                --jq '.jobs[].steps[] | select(.conclusion=="failure") | .name' 2>/dev/null | sed -n 1p)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" "$wf" "$url" "$sha" "$title" "$step"
    done < <(gh run list --workflow "$wf" --status failure --limit 5 \
               --json databaseId,url,headSha,displayTitle \
               --jq '.[] | [.databaseId, .url, .headSha, .displayTitle] | @tsv' 2>/dev/null)
  done
}

do_spl_deploy_failure_poll() {
  local state="${FAIL_POLL_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/deploy-failure-poll.state}"
  local post_fn="${OPS_POST_FN:-do_spl_deploy_failure_post}"
  mkdir -p "$(dirname "$state")" 2>/dev/null || true
  [[ -f "$state" ]] || : >"$state"

  local rows
  if [[ -n "${FAIL_POLL_LIST_CMD:-}" ]]; then
    rows="$(bash -c "$FAIL_POLL_LIST_CMD" 2>/dev/null)"
  else
    rows="$(_spl_failed_deploy_runs)"
  fi

  local posted=0 rid wf url sha subj step
  while IFS=$'\t' read -r rid wf url sha subj step; do
    [[ -z "$rid" ]] && continue
    grep -qxF "$rid" "$state" 2>/dev/null && continue     # already posted this run
    do_log "INFO failure-poll: new failed run $rid ($wf) -- posting"
    FAIL_RUN_URL="$url" FAIL_WORKFLOW="$wf" FAIL_SHA="$sha" FAIL_COMMIT_SUBJECT="$subj" FAIL_STEP="$step" \
      "$post_fn" || { do_log "FATAL failure-poll: post for run $rid FAILED -- state not advanced, retried next tick"; return 1; }
    printf '%s\n' "$rid" >>"$state"
    posted=$((posted + 1))
  done <<< "$rows"

  do_log "INFO failure-poll: $posted new failed run(s) posted"
  return 0
}
