#!/bin/bash
#------------------------------------------------------------------------------
# @description Rerun a finished workflow run's failed jobs ONCE when every one of
# @description them died at "Set up job" fetching an action archive from GitHub
# @description (codeload answered 404 for a valid pinned SHA). The runner tries
# @description that download once and a workflow cannot wrap `uses:` in a retry,
# @description so the job is lost before its first step. Measured 2026-10-15:
# @description actions/setup-go@b7ad1dad (v7.0.0, a valid tag) failed so 3 times
# @description in 35 min on GitHub-hosted runners (wf10 38685379352 job
# @description 116259956077, wf20 38687357160 job 116269416377, ...), and the
# @description same URL served 200 minutes later. A red wf20 also stops wf21's
# @description catch-up (it never re-dispatches over a FAILED deploy), so dev
# @description lagged until a person reran it.
# @description
# @description It reruns only when ALL failed jobs are that flake: one real red
# @description among them and nothing is rerun (a rerun must never hide one). A
# @description run past attempt 1 is never rerun again.
# @description
# @description Prints one verdict line and exits 0 for every verdict:
# @description   rerun     - the failed jobs were rerun (`gh run rerun --failed`)
# @description   nothing   - no job failed
# @description   real      - a job failed somewhere else, or at "Set up job" for
# @description               another reason: not touched
# @description   attempt   - the run is already a rerun: not touched
# @description exit 1 only when the run cannot be read.
# @param RUN_ID (required) - the workflow run id
# @param REPO (optional) - owner/name; default $GITHUB_REPOSITORY (no default otherwise)
# @param DRY_RUN (optional) - 1: say what it would do, rerun nothing
# @param CI_RERUN_GH (optional) - the gh binary (tests point it at a stub)
# @example RUN_ID=38685379352 REPO=<owner>/<repo> DRY_RUN=1 ./run -a do_ci_rerun_setup_flake
#------------------------------------------------------------------------------

# The two lines GitHub's runner prints when an action archive will not download.
CI_SETUP_FLAKE_RE="Failed to download archive '|An action could not be found at the URI '"

do_ci_rerun_setup_flake() {
  local run="${RUN_ID:-}" repo="${REPO:-${GITHUB_REPOSITORY:-}}" gh="${CI_RERUN_GH:-gh}"
  [[ "$run" =~ ^[0-9]+$ ]] || { do_log "FATAL RUN_ID must be a workflow run id, got: '$run'"; return 1; }
  [[ "$repo" == */* ]] || { do_log "FATAL REPO must be owner/name (or set GITHUB_REPOSITORY), got: '$repo'"; return 1; }
  local attempt jobs
  attempt="$("$gh" api "repos/$repo/actions/runs/$run" -q .run_attempt)" ||
    { do_log "FATAL cannot read run $run of $repo"; return 1; }
  jobs="$("$gh" api --paginate "repos/$repo/actions/runs/$run/jobs?per_page=100" \
    -q '.jobs[] | select(.conclusion == "failure") | "\(.id)\t\([.steps[]? | select(.conclusion == "failure") | .name] | join(","))\t\(.name)"')" ||
    { do_log "FATAL cannot read the jobs of run $run"; return 1; }
  if [[ -z "$jobs" ]]; then echo "nothing run=$run: no job failed"; return 0; fi
  if [[ "$attempt" != 1 ]]; then echo "attempt run=$run: attempt $attempt is already a rerun, not touched"; return 0; fi
  local id step name n=0
  while IFS=$'\t' read -r id step name; do
    [[ -n "$id" ]] || continue
    if [[ "$step" != "Set up job" ]] || ! grep -qE "$CI_SETUP_FLAKE_RE" <<<"$("$gh" api "repos/$repo/actions/jobs/$id/logs" 2>/dev/null)"; then
      echo "real run=$run: job $id ($name) failed at '${step:-?}', not an action download: not touched"
      return 0
    fi
    n=$((n + 1))
  done <<<"$jobs"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then echo "rerun run=$run: would rerun $n failed job(s), all an action download at 'Set up job' (DRY_RUN)"; return 0; fi
  "$gh" run rerun "$run" --failed --repo "$repo" || { do_log "FATAL gh run rerun $run --failed refused"; return 1; }
  echo "rerun run=$run: reran $n failed job(s), all an action download at 'Set up job'"
}
