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
# @description Reads only the runs API (no logs) unless CI_GATE_SIGNATURES=1,
# @description which also prints the first FAIL / ::error line per failed job.
# @description The repo comes from the checkout's own remote -- no default URL.
# @param CI_GATE_RUNS (optional) - default 40: how many recent runs to read
# @param CI_GATE_WORKFLOW (optional) - default 10_ci-quality.yml
# @param CI_GATE_REPO (optional) - default: whatever `gh` infers from the cwd.
# @param CI_GATE_REPO It is passed as GH_REPO, the only way `gh api` takes a
# @param CI_GATE_REPO repo (that subcommand has no --repo flag). The whole body
# @param CI_GATE_REPO runs in a subshell, so the export dies with the action.
# @param CI_GATE_SIGNATURES (optional) - 1 also fetches each failed job's log
# @example ./run -a do_report_ci_gate
# @example CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
#------------------------------------------------------------------------------
do_report_ci_gate() { (
  local n="${CI_GATE_RUNS:-40}"
  local wf="${CI_GATE_WORKFLOW:-10_ci-quality.yml}"
  if [[ -n "${CI_GATE_REPO:-}" ]]; then export GH_REPO="$CI_GATE_REPO"; fi

  command -v gh >/dev/null 2>&1 || { do_log "FATAL gh is required"; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || { do_log "FATAL CI_GATE_RUNS must be a positive integer, got '$n'"; return 1; }

  local tmp; tmp=$(mktemp -d) || return 1
  if ! gh run list --workflow "$wf" --limit "$n" \
        --json databaseId,conclusion,createdAt,headSha \
        --jq '.[] | [.databaseId, (if (.conclusion // "") == "" then "running" else .conclusion end), .createdAt, .headSha[0:8]] | @tsv' >"$tmp/runs.tsv" 2>"$tmp/err"; then
    do_log "FATAL gh run list failed: $(head -2 "$tmp/err")"
    rm -rf "$tmp"; return 1
  fi
  if [[ ! -s "$tmp/runs.tsv" ]]; then
    do_log "FATAL no runs of '$wf' -- nothing measured, which is not the same as nothing wrong"
    rm -rf "$tmp"; return 1
  fi

  local total newest oldest
  total=$(wc -l <"$tmp/runs.tsv")
  newest=$(head -1 "$tmp/runs.tsv" | cut -f3)
  oldest=$(tail -1 "$tmp/runs.tsv" | cut -f3)
  echo "== $wf -- last $total run(s), $oldest .. $newest"
  cut -f2 "$tmp/runs.tsv" | sort | uniq -c | sort -rn | sed 's/^/   /'

  awk -F'\t' '$2 == "failure"' "$tmp/runs.tsv" >"$tmp/failed.tsv"
  local nf; nf=$(wc -l <"$tmp/failed.tsv")
  if (( nf == 0 )); then
    echo "== no failed run in the window"
    rm -rf "$tmp"; return 0
  fi

  local rid concl created sha jid jname
  : >"$tmp/jobs.tsv"
  while IFS=$'\t' read -r rid concl created sha; do
    gh api "repos/{owner}/{repo}/actions/runs/$rid/jobs" --paginate \
      --jq '.jobs[] | select(.conclusion=="failure") | [.id, .name] | @tsv' 2>/dev/null |
      while IFS=$'\t' read -r jid jname; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$rid" "$created" "$sha" "$jid" "$jname" >>"$tmp/jobs.tsv"
      done
  done <"$tmp/failed.tsv"

  echo "== $nf failed run(s); failures per JOB (a job over ~3 is a defect that sat on trunk, or a flake)"
  cut -f5 "$tmp/jobs.tsv" | sort | uniq -c | sort -rn | sed 's/^/   /'

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
