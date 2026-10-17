#!/bin/bash
#------------------------------------------------------------------------------
# @description The log tail of every failed job of one workflow run, read job
# @description by job through `gh api .../actions/jobs/<id>/logs`.
# @description Why not `gh run view <id> --log-failed`: with gh 2.46 it exits 0
# @description and prints 0 lines for every job whose name holds `:` or `/`
# @description (all of ours). GitHub sanitizes those characters in the log
# @description zip's folder names and gh matches the raw job name, so no step
# @description log is found (measured 2026-10-17 on 6 failed runs, SPL-2340).
# @description gh v2.75.0 (cli/cli#11172) falls back to this same per-job API.
# @description Per failed job: a header (name, id, url), its first FAIL /
# @description ::error line, then the last CI_LOG_TAIL lines of its log. A
# @description job that timed out or lost its runner is listed too.
# @description The repo comes from the checkout's own remote -- no default URL.
# @param RUN_ID (required) - the workflow run id (`gh run list --commit <sha>`)
# @param CI_LOG_TAIL (optional) - default 80: log lines printed per job
# @param CI_GATE_REPO (optional) - default: whatever `gh` infers from the cwd;
# @param CI_GATE_REPO passed as GH_REPO (`gh api` has no --repo flag)
# @example RUN_ID=39017748969 ./run -a do_ci_failed_log
# @example RUN_ID=39017748969 CI_LOG_TAIL=200 ./run -a do_ci_failed_log
#------------------------------------------------------------------------------
do_ci_failed_log() { (
  if [[ -z "${RUN_ID:-}" ]]; then
    do_log "FATAL RUN_ID must be set (no default) -- e.g. RUN_ID=<id from gh run list --commit <sha>>"
    return 1
  fi
  local n="${CI_LOG_TAIL:-80}"
  [[ "$RUN_ID" =~ ^[0-9]+$ ]] || { do_log "FATAL RUN_ID must be a numeric run id, got '$RUN_ID'"; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || { do_log "FATAL CI_LOG_TAIL must be a positive integer, got '$n'"; return 1; }
  if [[ -n "${CI_GATE_REPO:-}" ]]; then export GH_REPO="$CI_GATE_REPO"; fi
  command -v gh >/dev/null 2>&1 || { do_log "FATAL gh is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is required"; return 1; }

  local tmp; tmp=$(mktemp -d) || return 1
  _rcg_run_jobs "$tmp" "$RUN_ID" >"$tmp/all.tsv"
  if ! jq -e '.jobs | length > 0' "$tmp/jobs-$RUN_ID.json" >/dev/null 2>&1; then
    do_log "FATAL no jobs read for run $RUN_ID (wrong id, or gh api failed) -- nothing read is not nothing failed"
    rm -rf "$tmp"; return 1
  fi
  awk -F'\t' '$2 == "failure" || $2 == "timeout" || $2 == "runner-lost"' "$tmp/all.tsv" >"$tmp/failed.tsv"
  local nf; nf=$(wc -l <"$tmp/failed.tsv")
  if (( nf == 0 )); then
    echo "== run $RUN_ID: no failed job ($(wc -l <"$tmp/all.tsv") job(s) read)"
    rm -rf "$tmp"; return 0
  fi
  echo "== run $RUN_ID: $nf failed job(s), last $n log lines each"
  local jid jconcl jname
  while IFS=$'\t' read -r jid jconcl jname; do
    _cfl_job "$tmp" "$jid" "$jconcl" "$jname" "$n"
  done <"$tmp/failed.tsv"
  rm -rf "$tmp"
  return 0
) }

# _cfl_job <tmp> <job id> <conclusion> <name> <tail n> - one failed job: its
# header, its first red line (_rcg_signature, else the timeout or annotation
# message) and its log tail.
_cfl_job() {
  local tmp="$1" jid="$2" jconcl="$3" jname="$4" n="$5" url sig
  url=$(jq -r --argjson id "$jid" '.jobs[] | select(.id == $id) | .html_url // ""' "$tmp/jobs-$RUN_ID.json")
  echo
  echo "=== $jname"
  echo "    job $jid  $jconcl  ${url:-<no url>}"
  if ! gh api "repos/{owner}/{repo}/actions/jobs/$jid/logs" >"$tmp/log-$jid.txt" 2>"$tmp/err-$jid"; then
    echo "    no log: $(head -1 "$tmp/err-$jid")"
  fi
  sig=$(_rcg_signature <"$tmp/log-$jid.txt")
  [[ -n "$sig" ]] || sig=$(cat "$tmp/timeout-$jid.txt" 2>/dev/null)
  [[ -n "$sig" ]] || sig=$(_rcg_annotation_sig "$jid")
  echo "    first red: ${sig:-<none found>}"
  echo "    --- last $n of $(wc -l <"$tmp/log-$jid.txt") log line(s)"
  tail -n "$n" "$tmp/log-$jid.txt"
}
