#!/bin/bash
#------------------------------------------------------------------------------
# @description Per-JOB failure counts for a workflow over its last N runs, so a
# @description recurring red job is visible in one line instead of needing
# @description twelve run pages opened by hand.
# @description Why per job and not per run: on 2026-09-21 the gate had 31 red
# @description runs, and they were FOUR defects -- each red for the 4..12
# @description pushes that landed before its lane fixed it. Counting runs says
# @description "CI is broken"; counting jobs says which four things broke, and
# @description a job that shows up in window after window is the flake.
# @description The per-job table counts a job's REDS apart from its fail-fast
# @description STOPS (a "stopped" column, I9): a run with one red and three
# @description stops shows 1 red, not 4.
# @description Then the FIRST red per job (fail-fast stops left out) and, per
# @description failed job, its last green run in the window (r7-02).
# @description A job that hit its timeout-minutes concludes "cancelled" on
# @description GitHub, with the annotation "exceeded the maximum execution
# @description time": it is counted as a red job, and its run as `timeout`, not
# @description `cancelled` (spec 131 C1: 18 of 22 started-then-cancelled jobs
# @description on 2026-10-11 were timeouts the report never showed). A
# @description superseded pending run starts no job and stays `cancelled`.
# @description A job whose self-hosted runner "lost communication with the
# @description server" (no steps, no log) reads `runner-lost`, an infra red
# @description counted like a timeout (dispatch holder, 2026-10-11).
# @description Then the timeout headroom (spec 131 C4): per job, the p90 of its
# @description wall time over the started runs in the window against its
# @description timeout-minutes in the workflow file; over 75 % reads AT RISK,
# @description so the next timeout is seen before it turns trunk red.
# @description Reads the runs, jobs and check-run annotations APIs (no logs)
# @description unless CI_GATE_SIGNATURES=1, which also prints the first FAIL /
# @description ::error line per failed job.
# @description The repo comes from the checkout's own remote -- no default URL.
# @param CI_GATE_RUNS (optional) - default 40: how many recent runs to read
# @param CI_GATE_WORKFLOW (optional) - default 10_ci-quality.yml
# @param CI_GATE_BRANCH (optional) - default master: only that branch's runs
# @param CI_GATE_BRANCH are read (r8-03: 3 of 13 failed runs in round 7's
# @param CI_GATE_BRANCH report were branch dispatches). Set but empty
# @param CI_GATE_BRANCH (CI_GATE_BRANCH=) reads every branch.
# @param CI_GATE_REPO (optional) - default: whatever `gh` infers from the cwd.
# @param CI_GATE_REPO It is passed as GH_REPO, the only way `gh api` takes a
# @param CI_GATE_REPO repo (that subcommand has no --repo flag). The whole body
# @param CI_GATE_REPO runs in a subshell, so the export dies with the action.
# @param CI_GATE_SIGNATURES (optional) - 1 also fetches each failed job's log
# @param CI_GATE_WORKFLOW_FILE (optional) - default <repo>/.github/workflows/<wf>:
# @param CI_GATE_WORKFLOW_FILE where the timeout-minutes per job are read
# @example ./run -a do_report_ci_gate
# @example CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
# @example CI_GATE_BRANCH= ./run -a do_report_ci_gate
#------------------------------------------------------------------------------
do_report_ci_gate() { (
  local n="${CI_GATE_RUNS:-40}"
  local wf="${CI_GATE_WORKFLOW:-10_ci-quality.yml}"
  local branch="${CI_GATE_BRANCH-master}"
  local -a on_branch=()
  [[ -n "$branch" ]] && on_branch=(--branch "$branch")
  if [[ -n "${CI_GATE_REPO:-}" ]]; then export GH_REPO="$CI_GATE_REPO"; fi

  command -v gh >/dev/null 2>&1 || { do_log "FATAL gh is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is required"; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || { do_log "FATAL CI_GATE_RUNS must be a positive integer, got '$n'"; return 1; }

  local tmp; tmp=$(mktemp -d) || return 1
  if ! gh run list --workflow "$wf" "${on_branch[@]}" --limit "$n" \
        --json databaseId,conclusion,createdAt,headSha,startedAt,updatedAt \
        --jq '.[] | [.databaseId, (if (.conclusion // "") == "" then "running" else .conclusion end), .createdAt, .headSha[0:8],
                     (if .startedAt and .updatedAt then ((.updatedAt | fromdate) - (.startedAt | fromdate)) else 0 end)] | @tsv' >"$tmp/runs.tsv" 2>"$tmp/err"; then
    do_log "FATAL gh run list failed: $(head -2 "$tmp/err")"
    rm -rf "$tmp"; return 1
  fi
  if [[ ! -s "$tmp/runs.tsv" ]]; then
    do_log "FATAL no runs of '$wf' on ${branch:-any branch} -- nothing measured, which is not the same as nothing wrong"
    rm -rf "$tmp"; return 1
  fi

  _rcg_mark_timeout_runs "$tmp"
  local total newest oldest
  total=$(wc -l <"$tmp/runs.tsv")
  newest=$(head -1 "$tmp/runs.tsv" | cut -f3)
  oldest=$(tail -1 "$tmp/runs.tsv" | cut -f3)
  echo "== $wf on ${branch:-every branch} -- last $total run(s), $oldest .. $newest"
  cut -f2 "$tmp/runs.tsv" | sort | uniq -c | sort -rn | sed 's/^/   /'

  _rcg_headroom "$tmp" "$wf"

  awk -F'\t' '$2 == "failure" || $2 == "timeout"' "$tmp/runs.tsv" >"$tmp/failed.tsv"
  local nf; nf=$(wc -l <"$tmp/failed.tsv")
  if (( nf == 0 )); then
    echo "== no failed run in the window"
    rm -rf "$tmp"; return 0
  fi

  local rid concl created sha jid jname jconcl
  : >"$tmp/jobs.tsv"
  while IFS=$'\t' read -r rid concl created sha _; do
    _rcg_run_jobs "$tmp" "$rid" | while IFS=$'\t' read -r jid jconcl jname; do
      [[ "$jconcl" == failure || "$jconcl" == timeout || "$jconcl" == runner-lost ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" "$created" "$sha" "$jid" "$jname" "$jconcl" >>"$tmp/jobs.tsv"
    done
  done <"$tmp/failed.tsv"

  _rcg_stop_marks "$tmp"
  _rcg_job_table "$tmp" "$nf"
  _rcg_first_red "$tmp" "$nf"
  _rcg_last_green "$tmp" "$total"

  _rcg_list_failed "$tmp"

  rm -rf "$tmp"
  return 0
) }

# _rcg_list_failed <tmp> - one line per red job of each failed run, newest
# first, with its signature: the timeout annotation, or with
# CI_GATE_SIGNATURES=1 the first FAIL / ::error line of its log.
_rcg_list_failed() {
  echo "== failed runs, newest first"
  local tmp="$1" sig rid created sha jid jname jconcl
  while IFS=$'\t' read -r rid created sha jid jname jconcl; do
    sig=""
    if [[ "$jconcl" == timeout || "$jconcl" == runner-lost ]]; then
      sig="$jconcl: $(cat "$tmp/timeout-$jid.txt" 2>/dev/null)"
    elif [[ "${CI_GATE_SIGNATURES:-0}" == 1 ]]; then
      sig=$(gh api "repos/{owner}/{repo}/actions/jobs/$jid/logs" 2>/dev/null | _rcg_signature)
      [[ -n "$sig" ]] || sig=$(_rcg_annotation_sig "$jid")
      sig="${sig:0:160}"
    fi
    printf '   %s  %s  %s  %s%s\n' "$rid" "$created" "$sha" "$jname" "${sig:+  || $sig}"
  done <"$tmp/jobs.tsv"
}

# _rcg_signature - stdin a job log, stdout its first FAIL / ::error line. A
# test's own PASS line that quotes the word ("PASS: 9. ... RS-HANDOFF FAIL
# (never OK)") is not a failure: 6 of 17 signature lines on 822df3050 were
# such PASS lines (c-830, spec 131 C1).
_rcg_signature() {
  grep -aE '(^|[[:space:]])(FAIL[:[:space:]]|FAILED:|--- FAIL|::error::)' |
    grep -avE '36;1m|echo "::error' | sed -E 's/^[^ ]*Z //' |
    grep -avE '^[[:space:]]*(PASS|ok)([:[:space:]]|$)' | sed -n 1p
}

# _rcg_annotation_sig <job id> - the job's first failure-level check-run
# annotation, the generic "Process completed with exit code N." last: the
# signature of a job with no FAIL line, or no log at all (a lost runner).
_rcg_annotation_sig() {
  gh api "repos/{owner}/{repo}/check-runs/$1/annotations" \
    --jq '.[] | select((.annotation_level // "failure") == "failure") | .message' 2>/dev/null |
    awk '/^Process completed with exit code/ { g = g ? g : $0; next } { print; f = 1; exit } END { if (!f && g) print g }'
}

# _rcg_run_jobs <tmp> <run id> - "<job id>\t<conclusion>\t<name>" for every job
# of the run, fetched once and cached in <tmp>: the per-job, first-red and
# last-green sections all read the same jobs. A cancelled or failed job whose
# annotation says it "exceeded the maximum execution time" reads `timeout`,
# one whose runner "lost communication with the server" `runner-lost`; the
# message is kept in <tmp>/timeout-<job id>.txt.
_rcg_run_jobs() {
  local f="$1/jobs-$2.tsv" jid jconcl jname msg
  if [[ ! -f "$f" ]]; then
    gh api "repos/{owner}/{repo}/actions/runs/$2/jobs" --paginate >"$1/jobs-$2.json" 2>/dev/null || echo '{"jobs":[]}' >"$1/jobs-$2.json"
    jq -r '.jobs[] | [.id, (.conclusion // "running"), .name] | @tsv' "$1/jobs-$2.json" >"$f.raw" 2>/dev/null || : >"$f.raw"
    jq -r '.jobs[] | select(.started_at and .completed_at) |
           [.id, ((.completed_at | fromdate) - (.started_at | fromdate))] | @tsv' "$1/jobs-$2.json" >"$1/dur-$2.tsv" 2>/dev/null || : >"$1/dur-$2.tsv"
    while IFS=$'\t' read -r jid jconcl jname; do
      if [[ "$jconcl" == cancelled || "$jconcl" == failure ]]; then
        msg=$(gh api "repos/{owner}/{repo}/check-runs/$jid/annotations" --jq '.[].message' 2>/dev/null |
              grep -aE 'exceeded the maximum execution time|lost communication with the server' | sed -n 1p)
        case "$msg" in
          *"exceeded the maximum execution time"*) jconcl=timeout ;;
          *"lost communication with the server"*) jconcl=runner-lost ;;
        esac
        [[ -n "$msg" ]] && printf '%s\n' "$msg" >"$1/timeout-$jid.txt"
      fi
      printf '%s\t%s\t%s\n' "$jid" "$jconcl" "$jname"
    done <"$f.raw" >"$f"
  fi
  cat "$f"
}

# _rcg_timeouts <workflow file> - "<job name pattern>\t<timeout s>" per job of
# the workflow. A matrix expression in a name ("${{ matrix.shard }}") is kept
# as written; _rcg_headroom matches it as a wildcard.
_rcg_timeouts() {
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { name = ""; next }
    /^    name:/ { name = $0; sub(/^    name:[[:space:]]*/, "", name); gsub(/^"|"$/, "", name); next }
    /^    timeout-minutes:/ && name != "" { printf "%s\t%d\n", name, $2 * 60 }' "$1"
}

# _rcg_headroom <tmp> <wf> - per job, the p90 (nearest rank) of its wall time
# over the started runs in the window against its timeout-minutes; a job over
# 75 % is AT RISK. 2026-10-11: orc hermetic 1/2 ran a median 918 s of 1,200 s
# and timed out 8 times in 11 started runs (spec 131 C4).
_rcg_headroom() {
  local tmp="$1" wf="$2" rid concl wff top
  wff="${CI_GATE_WORKFLOW_FILE:-}"
  if [[ -z "$wff" ]]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null) && wff="$top/.github/workflows/$wf"
  fi
  [[ -f "$wff" ]] || { echo "== timeout headroom: no workflow file ${wff:-for $wf}, skipped"; return 0; }
  _rcg_timeouts "$wff" >"$tmp/timeouts.tsv"
  while IFS=$'\t' read -r rid concl _; do
    [[ "$concl" == success || "$concl" == failure || "$concl" == timeout ]] || continue
    # fetch first: in one pipeline awk's BEGIN would read dur-<rid> before
    # _rcg_run_jobs had written it
    _rcg_run_jobs "$tmp" "$rid" >"$tmp/run-jobs.tsv"
    awk -F'\t' -v d="$tmp/dur-$rid.tsv" '
      BEGIN { while ((getline l < d) > 0) { split(l, p, "\t"); dur[p[1]] = p[2] } }
      ($2 == "success" || $2 == "failure" || $2 == "timeout") && ($1 in dur) { print $3 "\t" dur[$1] }' "$tmp/run-jobs.tsv"
  done <"$tmp/runs.tsv" >"$tmp/walls.tsv"
  echo "== timeout headroom: p90 wall time per JOB of its timeout-minutes (AT RISK over 75 %)"
  sort -t$'\t' -k1,1 -k2,2n "$tmp/walls.tsv" | awk -F'\t' -v tf="$tmp/timeouts.tsv" '
    # glob-ish match: a "${{ ... }}" in the workflow name matches any text
    function matches(job, pat,    pre, rest, i) {
      i = index(pat, "${{")
      if (i == 0) return job == pat
      pre = substr(pat, 1, i - 1); rest = substr(pat, index(pat, "}}") + 2)
      return substr(job, 1, length(pre)) == pre && length(job) >= length(pre) + length(rest) &&
             substr(job, length(job) - length(rest) + 1) == rest
    }
    BEGIN { while ((getline l < tf) > 0) { split(l, p, "\t"); np++; pat[np] = p[1]; to[np] = p[2] } }
    { n[$1]++; w[$1, n[$1]] = $2 }
    END {
      for (j in n) {
        k = int((n[j] * 9 + 9) / 10); p90 = w[j, k]; t = 0
        for (i = 1; i <= np; i++) if (matches(j, pat[i])) { t = to[i]; break }
        if (t == 0) continue
        printf "   %-7s  %s  p90 %d s of %d s (%d %%, n=%d)\n", (p90 * 100 > t * 75 ? "AT RISK" : "ok"), j, p90, t, p90 * 100 / t, n[j]
      }
    }' | sort
}

# _rcg_mark_timeout_runs <tmp> - a cancelled run that ran long enough for a
# job to time out (5 min, the shortest timeout-minutes in wf 10) and has a
# timed-out job is re-read as `timeout`. A superseded run never ran that long,
# so this reads the jobs of a few runs, not of all 90 superseded ones.
_rcg_mark_timeout_runs() {
  local tmp="$1" rid concl created sha dur
  while IFS=$'\t' read -r rid concl created sha dur; do
    if [[ "$concl" == cancelled && "${dur:-0}" -ge 300 ]] &&
       _rcg_run_jobs "$tmp" "$rid" | cut -f2 | grep -xE 'timeout|runner-lost' >/dev/null; then
      concl=timeout
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$rid" "$concl" "$created" "$sha" "${dur:-0}"
  done <"$tmp/runs.tsv" >"$tmp/runs.marked" && mv "$tmp/runs.marked" "$tmp/runs.tsv"
}

# _rcg_stop_marks <tmp> - "<run id>\t<job name>\t<reds it names>" in
# <tmp>/stops.tsv for every red job of each failed run; the third field is
# empty unless the job is a fail-fast STOP. gate-fail-fast.sh stops every
# other job of a red run and a stopped job concludes failure too (24 failed
# runs to 2026-10-10: 133 job failures, 47 first reds; 41 of 167 failed jobs
# in the 100 runs to 2026-10-25, I9). A stopped job carries the check-run
# annotation
#   gate fail-fast: stopped, so the next gate run starts; red in this run: <names>
_rcg_stop_marks() {
  local tmp="$1" rid jid jconcl jname msg
  : >"$tmp/stops.tsv"
  while IFS=$'\t' read -r rid _; do
    _rcg_run_jobs "$tmp" "$rid" | while IFS=$'\t' read -r jid jconcl jname; do
      [[ "$jconcl" == failure || "$jconcl" == timed_out || "$jconcl" == timeout || "$jconcl" == runner-lost ]] || continue
      msg=$(gh api "repos/{owner}/{repo}/check-runs/$jid/annotations" --jq '.[].message' 2>/dev/null |
            grep -a 'gate fail-fast: stopped' | sed -n 1p)
      printf '%s\t%s\t%s\n' "$rid" "$jname" "${msg:+${msg#*red in this run: }}" >>"$tmp/stops.tsv"
    done
  done <"$tmp/failed.tsv"
}

# _rcg_job_table <tmp> <failed runs> - per job, the runs it was RED in (it
# failed itself) apart from the runs it was STOPPED in (fail-fast, because
# another job was red), from <tmp>/stops.tsv. Counted together, one red and
# three stops read as 4 broken jobs (I9).
_rcg_job_table() {
  echo "== $2 failed run(s); per JOB, red = it failed, stopped = fail-fast stop for another job's red (a job red over ~3 is a defect that sat on trunk, or a flake)"
  printf '   %7s %7s  %s\n' red stopped job
  awk -F'\t' '{ if ($3 == "") red[$2]++; else stop[$2]++; seen[$2] = 1 }
    END { for (j in seen) printf "%d\t%d\t%s\n", red[j], stop[j], j }' "$1/stops.tsv" |
    sort -t$'\t' -k1,1rn -k2,2rn -k3,3 | awk -F'\t' '{ printf "   %7d %7d  %s\n", $1, $2, $3 }'
}

# _rcg_first_red <tmp> <failed runs> - the job(s) that broke each failed run,
# counted per job, from <tmp>/stops.tsv (_rcg_stop_marks). A run's first reds are the jobs named there plus the jobs that failed with
# no such annotation, minus the stopped jobs: a job stopped early is named by
# the jobs stopped after it. Job names hold commas and the annotation joins
# them with commas, so a name is matched whole against the run's own failed
# jobs, never split.
_rcg_first_red() {
  local tmp="$1" nf="$2"
  echo "== first red per JOB, over the $nf failed run(s): the job(s) that broke each run, fail-fast stops left out"
  awk -F'\t' '
    { k = $1 SUBSEP $2; red[k] = 1; if ($3 == "") own[k] = 1; else { stop[k] = 1; list[$1] = list[$1] "," $3 } }
    END {
      for (k in red) {
        split(k, p, SUBSEP)
        if (k in stop) continue
        if ((k in own) || index(list[p[1]] ",", "," p[2] ",")) { n[p[2]]++; runs[p[1]] = 1 }
      }
      for (j in n) printf "%7d %s\n", n[j], j
    }' "$tmp/stops.tsv" | sort -rn
}

# _rcg_last_green <tmp> <runs> - per job that failed in the window, the newest
# completed run in which it passed: since when that job is red. Reads the jobs
# of success, failure and timeout runs only (any other cancelled wf 10 run on
# master is a superseded pending one, with no job), newest first, until each
# has one.
_rcg_last_green() {
  local tmp="$1" total="$2" rid rconcl created sha jid jconcl jname
  cut -f5 "$tmp/jobs.tsv" | sort -u >"$tmp/want.txt"
  : >"$tmp/green.tsv"
  while IFS=$'\t' read -r rid rconcl created sha _; do
    (( $(wc -l <"$tmp/green.tsv") < $(wc -l <"$tmp/want.txt") )) || break
    [[ "$rconcl" == success || "$rconcl" == failure || "$rconcl" == timeout ]] || continue
    _rcg_run_jobs "$tmp" "$rid" | while IFS=$'\t' read -r jid jconcl jname; do
      [[ "$jconcl" == success ]] || continue
      grep -qxF -- "$jname" "$tmp/want.txt" || continue
      cut -f1 "$tmp/green.tsv" | grep -xF -- "$jname" >/dev/null ||
        printf '%s\t%s %s %s\n' "$jname" "$rid" "$sha" "$created" >>"$tmp/green.tsv"
    done
  done <"$tmp/runs.tsv"
  echo "== last green per failed JOB: run, sha, time (newest in the last $total run(s))"
  local seen
  while IFS= read -r jname; do
    seen=$(awk -F'\t' -v j="$jname" '$1 == j { print $2; exit }' "$tmp/green.tsv")
    printf '   last green: %s  %s\n' "${seen:-none in the last $total run(s)}" "$jname"
  done <"$tmp/want.txt"
}
