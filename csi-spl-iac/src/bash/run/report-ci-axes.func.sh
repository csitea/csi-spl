#!/bin/bash
#------------------------------------------------------------------------------
# @description The eight CI-gate axes of spec 133 (analysis.md section 4) for
# @description one window, from ONE command: every CI-refactor round reports
# @description its before and after with it (spec 133 fix F0; the owner's
# @description "nothing ad hoc" rule -- the v1.0 baselines came from three
# @description hand-run scripts).
# @description   X1 push to verdict p50 / p90 min: each push run to the first
# @description      run created at or after it that ended success or failure
# @description   X2 red minutes per day on the master tip: time since the
# @description      newest verdict was a failure, per day of the window
# @description   X3 verdicts green %: success / (success + failure)
# @description   X4 critical-path run time p50 min of a completed run
# @description   X5 job-minutes per completed run, median of per-run sums
# @description   X6 runner queue on the critical path p90 min
# @description   X7 jobs at timeout risk: p90 wall over 75 % of timeout-minutes
# @description   X8 first-red job rows on a suite pre-push cannot run (browser
# @description      e2e, nuxt generate, orc feature tests), % of first-red rows
# @description The critical path (X4, X6) is seat A's: classify, nuxt generate
# @description when the last job is an e2e shard, the last job, gate health.
# @description A first red (X8) is seat B's: a failed, timed-out or
# @description runner-lost job without the `gate fail-fast: stopped`
# @description annotation. Also printed, as a guard: red verdicts whose first
# @description reds are all timeout / runner-lost (seat B's non-code share).
# @description API cost: the runs list every time; jobs only for verdict runs
# @description (success / failure: every axis reads only those), and
# @description annotations only for the failed or cancelled jobs of failure
# @description runs. A finished run never changes, so its jobs and annotations
# @description are cached in CI_AXES_CACHE and a later round re-reads them
# @description from disk (2026-10-12: 60 s gh polling hit the shared token's
# @description rate limit).
# @param CI_AXES_SINCE (optional) - window start, ISO-8601 UTC; default 48 h ago
# @param CI_AXES_UNTIL (optional) - window end; default now. Runs created in
# @param CI_AXES_UNTIL [SINCE, UNTIL] are measured; a verdict after UNTIL still
# @param CI_AXES_UNTIL answers X1 for a push inside the window
# @param CI_AXES_WORKFLOW (optional) - default 10_ci-quality.yml
# @param CI_AXES_BRANCH (optional) - default master
# @param CI_AXES_REPO (optional) - passed to gh as GH_REPO; default: the cwd's
# @param CI_AXES_CACHE (optional) - default $HOME/.cache/csi-spl/ci-axes
# @param CI_AXES_WORKFLOW_FILE (optional) - where timeout-minutes are read;
# @param CI_AXES_WORKFLOW_FILE default <repo>/.github/workflows/<workflow>
# @param CI_AXES_RUNS_FILE (optional) - read the runs from this JSON-lines file
# @param CI_AXES_RUNS_FILE instead of the API (offline re-run, tests)
# @example ./run -a do_report_ci_axes
# @example CI_AXES_SINCE=2026-10-10T06:00:00Z CI_AXES_UNTIL=2026-10-12T06:25:00Z ./run -a do_report_ci_axes
#------------------------------------------------------------------------------
_RCA_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/ci-axes.py"

do_report_ci_axes() { (
  local wf="${CI_AXES_WORKFLOW:-10_ci-quality.yml}"
  local branch="${CI_AXES_BRANCH:-master}"
  local cache="${CI_AXES_CACHE:-$HOME/.cache/csi-spl/ci-axes}"
  local since until
  since="${CI_AXES_SINCE:-$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)}"
  until="${CI_AXES_UNTIL:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  if [[ -n "${CI_AXES_REPO:-}" ]]; then export GH_REPO="$CI_AXES_REPO"; fi

  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is required"; return 1; }
  command -v python3 >/dev/null 2>&1 || { do_log "FATAL python3 is required"; return 1; }
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  [[ "$since" =~ $re && "$until" =~ $re ]] || { do_log "FATAL CI_AXES_SINCE / CI_AXES_UNTIL must be YYYY-MM-DDTHH:MM:SSZ, got '$since' / '$until'"; return 1; }
  [[ "$since" < "$until" ]] || { do_log "FATAL the window is empty: $since .. $until"; return 1; }
  mkdir -p "$cache" || { do_log "FATAL cannot create the cache dir $cache"; return 1; }

  local tmp; tmp=$(mktemp -d) || return 1
  _rca_fetch_runs "$tmp" "$wf" "$branch" "$since" "$until" || { rm -rf "$tmp"; return 1; }

  _rca_fetch_jobs "$tmp" "$cache" "$since" "$until" || { rm -rf "$tmp"; return 1; }

  local wff="${CI_AXES_WORKFLOW_FILE:-}" top
  if [[ -z "$wff" ]]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null) && wff="$top/.github/workflows/$wf"
  fi
  if [[ -f "$wff" ]]; then _rcg_timeouts "$wff" >"$tmp/timeouts.tsv"; else : >"$tmp/timeouts.tsv"; fi

  echo "== CI axes (spec 133): $wf on $branch, runs created $since .. $until"
  _rca_compute "$tmp" "$cache" "$since" "$until"
  local rc=$?
  rm -rf "$tmp"
  return $rc
) }

# _rca_fetch_runs <tmp> <wf> <branch> <since> <until> - <tmp>/runs.jsonl, one
# run per line, from the API (or CI_AXES_RUNS_FILE); refuses a window with no
# run in it, which is "nothing measured", never "healthy".
_rca_fetch_runs() {
  local tmp="$1" wf="$2" branch="$3" since="$4" until="$5"
  if [[ -n "${CI_AXES_RUNS_FILE:-}" ]]; then
    cp "$CI_AXES_RUNS_FILE" "$tmp/runs.jsonl" || return 1
  else
    command -v gh >/dev/null 2>&1 || { do_log "FATAL gh is required"; return 1; }
    if ! gh api --paginate "repos/{owner}/{repo}/actions/workflows/$wf/runs?branch=$branch&created=>=$since&per_page=100" \
          --jq '.workflow_runs[] | {id, event, status, conclusion, created_at, updated_at, run_started_at, head_sha}' \
          >"$tmp/runs.jsonl" 2>"$tmp/err"; then
      do_log "FATAL gh api runs failed: $(head -2 "$tmp/err")"
      return 1
    fi
  fi
  jq -e -s --arg s "$since" --arg u "$until" 'map(select(.created_at >= $s and .created_at <= $u)) | length > 0' \
    "$tmp/runs.jsonl" >/dev/null 2>&1 && return 0
  do_log "FATAL no run of '$wf' on $branch created in $since .. $until -- nothing measured, which is not the same as nothing wrong"
  return 1
}

# _rca_fetch_jobs <tmp> <cache> <since> <until> - jobs of every verdict run in
# the window and annotations of the failed or cancelled jobs of its failure
# runs, each fetched once into <cache> (a completed run never changes).
# Cancelled runs are not read: no axis uses them, and `run_started_at` is set
# on a pending run too, so "ran >= 5 min" picked 160 runs where 66 started.
_rca_fetch_jobs() {
  local tmp="$1" cache="$2" since="$3" until="$4" rid concl jid
  jq -r -s --arg s "$since" --arg u "$until" '.[] | select(.created_at >= $s and .created_at <= $u and .status == "completed")
      | select(.conclusion == "success" or .conclusion == "failure")
      | [.id, .conclusion] | @tsv' "$tmp/runs.jsonl" >"$tmp/started.tsv"
  : >"$tmp/fetched.txt"
  while IFS=$'\t' read -r rid concl; do
    if [[ ! -s "$cache/jobs-$rid.json" ]]; then
      if gh api "repos/{owner}/{repo}/actions/runs/$rid/jobs?per_page=100&filter=all" --paginate \
           --jq '.jobs[] | {id, name, conclusion, created_at, started_at, completed_at, runner_name}' \
           >"$cache/jobs-$rid.json.part" 2>/dev/null; then
        mv "$cache/jobs-$rid.json.part" "$cache/jobs-$rid.json"
        echo "jobs $rid" >>"$tmp/fetched.txt"
      else
        rm -f "$cache/jobs-$rid.json.part"
        echo "$rid" >>"$tmp/jobs-missing.txt"
        continue
      fi
    fi
    [[ "$concl" == failure ]] || continue
    jq -r 'select(.conclusion == "failure" or .conclusion == "cancelled") | .id' "$cache/jobs-$rid.json" |
      while read -r jid; do
        [[ -f "$cache/ann-$jid.json" ]] && continue
        if gh api "repos/{owner}/{repo}/check-runs/$jid/annotations" --jq '[.[] | .message]' \
             >"$cache/ann-$jid.json.part" 2>/dev/null; then
          mv "$cache/ann-$jid.json.part" "$cache/ann-$jid.json"
          echo "ann $jid" >>"$tmp/fetched.txt"
        else
          rm -f "$cache/ann-$jid.json.part"
        fi
      done
  done <"$tmp/started.tsv"
  echo "== api: $(grep -c '^jobs' "$tmp/fetched.txt") jobs + $(grep -c '^ann' "$tmp/fetched.txt") annotation call(s); the rest from $cache"
  [[ -s "$tmp/jobs-missing.txt" ]] && echo "== WARN jobs not readable for $(wc -l <"$tmp/jobs-missing.txt") started run(s); they are left out of X4..X8"
  return 0
}

# _rca_compute <tmp> <cache> <since> <until> - the eight axes, one line each
# (the arithmetic lives in scripts/ci-axes.py).
_rca_compute() {
  python3 -I "$_RCA_PY" "$@"
}
