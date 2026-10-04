#!/usr/bin/env bash
#------------------------------------------------------------------------------
# gate-fail-fast.sh <cmd>... - run <cmd>, and stop it once another job of the
# SAME workflow run attempt is red (spec 072 US1, gate 10 fail-fast).
#
# Why: gate 10 holds one running run per ref (cancel-in-progress false,
# gate10-concurrency.tst.sh). Run 37206701762 had e2e shards 1/3 and 2/3 red
# by 14:03Z / 14:12Z while shard 3/3 hung in one file until its 45 min
# timeout (14:36Z): a known-red gate held the only slot ~24 minutes longer.
# Once any job is red the verdict cannot turn green, so the long jobs end and
# the waiting run starts. The run still concludes `failure`, not `cancelled`,
# so a red reads as a red (cancelled = superseded on this gate).
#
# Why not cancel the run: that needs `actions: write`, and wf 11 calls wf 10
# granting `actions: read` only -- a nested job asking for more fails every
# pull request at startup. Reading the run's jobs needs `actions: read` only.
#
# Off unless GATE_FAIL_FAST=1: wf 10 sets it on a master push only. A pull
# request (wf 11) keeps the full red report: the contributor gets every red
# file in one round, and nothing on master queues behind its run.
#
# Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GH_TOKEN (gh),
#      GATE_FAIL_FAST_POLL_S (seconds between queries, default 30).
# A failing jobs query is NOT a red: the command just keeps running.
#------------------------------------------------------------------------------
set -uo pipefail
[[ $# -gt 0 ]] || { echo "usage: $0 <cmd>..." >&2; exit 2; }
[[ "${GATE_FAIL_FAST:-}" == 1 ]] || exec "$@"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY unset}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID unset}"
poll="${GATE_FAIL_FAST_POLL_S:-30}"
jobs_api="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs"

# red_jobs - names of this run attempt's jobs that ended failure / timed_out.
# A job still running has no conclusion, so this job never counts itself.
red_jobs() {
  gh api "$jobs_api" --paginate \
    --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | .name' 2>/dev/null
}

# The command in its own process group, so a stop reaches every child
# (servers, Chrome) and not this watcher.
set -m
"$@" &
pid=$!
set +m
trap 'kill -TERM -- "-$pid" 2>/dev/null' EXIT

while kill -0 "$pid" 2>/dev/null; do
  for ((i = 0; i < poll; i++)); do
    kill -0 "$pid" 2>/dev/null || break 2
    sleep 1
  done
  red=$(red_jobs) || red=""
  if [[ -n "$red" ]]; then
    echo "::error::gate fail-fast: stopped, so the next gate run starts; red in this run: $(paste -sd, <<<"$red")"
    kill -TERM -- "-$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exit 1
  fi
done
trap - EXIT
wait "$pid"
