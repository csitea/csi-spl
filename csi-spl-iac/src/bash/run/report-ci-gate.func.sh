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
# @description Then the FIRST red per job (fail-fast stops left out) and, per
# @description failed job, its last green run in the window (r7-02).
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
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || { do_log "FATAL CI_GATE_RUNS must be a positive integer, got '$n'"; return 1; }

  local tmp; tmp=$(mktemp -d) || return 1
  if ! gh run list --workflow "$wf" "${on_branch[@]}" --limit "$n" \
        --json databaseId,conclusion,createdAt,headSha \
        --jq '.[] | [.databaseId, (if (.conclusion // "") == "" then "running" else .conclusion end), .createdAt, .headSha[0:8]] | @tsv' >"$tmp/runs.tsv" 2>"$tmp/err"; then
    do_log "FATAL gh run list failed: $(head -2 "$tmp/err")"
    rm -rf "$tmp"; return 1
  fi
  if [[ ! -s "$tmp/runs.tsv" ]]; then
    do_log "FATAL no runs of '$wf' on ${branch:-any branch} -- nothing measured, which is not the same as nothing wrong"
    rm -rf "$tmp"; return 1
  fi

  local total newest oldest
  total=$(wc -l <"$tmp/runs.tsv")
  newest=$(head -1 "$tmp/runs.tsv" | cut -f3)
  oldest=$(tail -1 "$tmp/runs.tsv" | cut -f3)
  echo "== $wf on ${branch:-every branch} -- last $total run(s), $oldest .. $newest"
  cut -f2 "$tmp/runs.tsv" | sort | uniq -c | sort -rn | sed 's/^/   /'

  awk -F'\t' '$2 == "failure"' "$tmp/runs.tsv" >"$tmp/failed.tsv"
  local nf; nf=$(wc -l <"$tmp/failed.tsv")
  if (( nf == 0 )); then
    echo "== no failed run in the window"
    rm -rf "$tmp"; return 0
  fi

  local rid concl created sha jid jname jconcl
  : >"$tmp/jobs.tsv"
  while IFS=$'\t' read -r rid concl created sha; do
    _rcg_run_jobs "$tmp" "$rid" | while IFS=$'\t' read -r jid jconcl jname; do
      [[ "$jconcl" == failure ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$rid" "$created" "$sha" "$jid" "$jname" >>"$tmp/jobs.tsv"
    done
  done <"$tmp/failed.tsv"

  echo "== $nf failed run(s); failures per JOB (a job over ~3 is a defect that sat on trunk, or a flake)"
  cut -f5 "$tmp/jobs.tsv" | sort | uniq -c | sort -rn | sed 's/^/   /'
  _rcg_first_red "$tmp" "$nf"
  _rcg_last_green "$tmp" "$total"

  echo "== failed runs, newest first"
  local sig
  while IFS=$'\t' read -r rid created sha jid jname; do
    sig=""
    if [[ "${CI_GATE_SIGNATURES:-0}" == 1 ]]; then
      sig=$(gh api "repos/{owner}/{repo}/actions/jobs/$jid/logs" 2>/dev/null |
            grep -aE '(^|[[:space:]])(FAIL[:[:space:]]|FAILED:|--- FAIL|::error::)' |
            grep -avE '36;1m|echo "::error' | sed -E 's/^[^ ]*Z //' | sed -n 1p)
      sig="${sig:0:160}"
    fi
    printf '   %s  %s  %s  %s%s\n' "$rid" "$created" "$sha" "$jname" "${sig:+  || $sig}"
  done <"$tmp/jobs.tsv"

  rm -rf "$tmp"
  return 0
) }

# _rcg_run_jobs <tmp> <run id> - "<job id>\t<conclusion>\t<name>" for every job
# of the run, fetched once and cached in <tmp>: the per-job, first-red and
# last-green sections all read the same jobs.
_rcg_run_jobs() {
  local f="$1/jobs-$2.tsv"
  [[ -f "$f" ]] || gh api "repos/{owner}/{repo}/actions/runs/$2/jobs" --paginate \
    --jq '.jobs[] | [.id, (.conclusion // "running"), .name] | @tsv' >"$f" 2>/dev/null || : >"$f"
  cat "$f"
}

# _rcg_first_red <tmp> <failed runs> - the job(s) that broke each failed run,
# counted per job. gate-fail-fast.sh stops every other job of a red run and a
# stopped job concludes failure too, so the per-job counts say 20 jobs broke
# when 1 did (24 failed runs to 2026-10-10: 133 job failures, 47 first reds).
# A stopped job carries the check-run annotation
#   gate fail-fast: stopped, so the next gate run starts; red in this run: <names>
# A run's first reds are the jobs named there plus the jobs that failed with
# no such annotation, minus the stopped jobs: a job stopped early is named by
# the jobs stopped after it. Job names hold commas and the annotation joins
# them with commas, so a name is matched whole against the run's own failed
# jobs, never split.
_rcg_first_red() {
  local tmp="$1" nf="$2" rid jid jconcl jname msg
  : >"$tmp/stops.tsv"
  while IFS=$'\t' read -r rid _; do
    _rcg_run_jobs "$tmp" "$rid" | while IFS=$'\t' read -r jid jconcl jname; do
      [[ "$jconcl" == failure || "$jconcl" == timed_out ]] || continue
      msg=$(gh api "repos/{owner}/{repo}/check-runs/$jid/annotations" --jq '.[].message' 2>/dev/null |
            grep -a 'gate fail-fast: stopped' | sed -n 1p)
      printf '%s\t%s\t%s\n' "$rid" "$jname" "${msg:+${msg#*red in this run: }}" >>"$tmp/stops.tsv"
    done
  done <"$tmp/failed.tsv"
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
# of success and failure runs only (a cancelled wf 10 run on master is a
# superseded pending one, with no job), newest first, until each has one.
_rcg_last_green() {
  local tmp="$1" total="$2" rid rconcl created sha jid jconcl jname
  cut -f5 "$tmp/jobs.tsv" | sort -u >"$tmp/want.txt"
  : >"$tmp/green.tsv"
  while IFS=$'\t' read -r rid rconcl created sha; do
    (( $(wc -l <"$tmp/green.tsv") < $(wc -l <"$tmp/want.txt") )) || break
    [[ "$rconcl" == success || "$rconcl" == failure ]] || continue
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
