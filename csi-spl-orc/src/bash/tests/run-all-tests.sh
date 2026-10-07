#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
#
# Perf round 4, C2: the files run ORC_TEST_JOBS at a time (default 6 on CI,
# 4 elsewhere; 1 = the old serial loop, streamed live). Each file's stdout and
# stderr are buffered to its own file and printed in suite order, so the log
# reads like a serial run and the per-file verdicts are the same. A test whose
# first 40 lines carry the line '# serial' (it shares a fixed /tmp path, $HOME
# or tmux state with another test) runs alone, after the pool.
#
# Default: every file, as CI runs it. Lane mode (doc
# fleet-hot-commands-2026-10-07.md 3.9, the full suite is ~11 min):
#   run-all-tests.sh --changed          only the files changed-tests.sh maps
#                                       this tree's changes to (vs
#                                       ORC_TEST_BASE, default origin/master),
#                                       plus ORC_TEST_ALWAYS; prints what it
#                                       skipped and why; falls back to every
#                                       file when a change maps to no test
#   run-all-tests.sh --background <f> [--changed]
#                                       detach; the log goes to <f>.log, and
#                                       <f> appears only when the run is done:
#                                       "rc=<n> <k>/<m> test files passed"
#                                       (poll: until [ -f <f> ]; do sleep 10; done)
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
changed=0 bg=""
while (( $# )); do
  case "$1" in
    --changed) changed=1 ;;
    --background) bg="${2:-}"; [[ -n "$bg" ]] || { echo "--background needs a result file" >&2; exit 2; }; shift ;;
    *) echo "usage: run-all-tests.sh [--changed] [--background <result-file>]" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$bg" ]]; then
  rm -f "$bg" "$bg.tmp"
  args=(); (( changed )) && args+=(--changed)
  ( bash "$dir/run-all-tests.sh" "${args[@]}" </dev/null >"$bg.log" 2>&1; rc=$?
    echo "rc=$rc $(grep -E '^=== [0-9]+/[0-9]+ test files passed' "$bg.log" | tail -1 | sed 's/^=== //')" >"$bg.tmp"
    mv "$bg.tmp" "$bg" ) >/dev/null 2>&1 &
  echo "started pid $! log $bg.log result $bg (appears when done)"
  exit 0
fi
# CLE-77923: no test may write the live spool root or ring a live pane. Under
# SPOOL_TEST=1 spool-send.sh / agent-send.sh / spool-notify.sh refuse the live
# root, poke no box tmux and relay nothing to the hub. A refusal is logged to
# SPOOL_TEST_GUARD_LOG and fails the suite: callers often send 2>/dev/null, so
# a test can pass while a send of its own tried to reach the live root.
export SPOOL_TEST=1
# specs/061 FR-004: pin the clock the legacy agent-id cutoff reads, so the
# CLE-/PRB-/ORC- fixtures here do not turn the suite red at
# SPOOL_LEGACY_ID_UNTIL on their own. The cutoff itself is tested in
# features/spawn-agents/tests/test-agent-id.sh; L9c drops this pin when it
# converts the fixtures to c-NNN.
export SPOOL_NOW="${SPOOL_NOW:-2026-10-01T00:00:00Z}"
guard_own=0
if [[ -z "${SPOOL_TEST_GUARD_LOG:-}" ]]; then
  SPOOL_TEST_GUARD_LOG=$(mktemp); guard_own=1
fi
export SPOOL_TEST_GUARD_LOG
njobs="${ORC_TEST_JOBS:-}"
if [[ -z "$njobs" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then njobs=6; else njobs=4; fi
fi
[[ "$njobs" =~ ^[1-9][0-9]*$ ]] || { echo "ORC_TEST_JOBS must be a positive integer (got '$njobs')" >&2; exit 2; }
all=()
for t in "$dir"/*.tst.sh; do [[ -f "$t" ]] && all+=("$t"); done
list=("${all[@]}")
if (( changed )); then
  plan=$(bash "$dir/changed-tests.sh")
  if grep -q '^full' <<<"$plan"; then
    echo "=== changed-only: running every file ($(grep '^full' <<<"$plan" | cut -f2))"
  else
    declare -A pick=()
    while IFS=$'\t' read -r kind a b; do
      case "$kind" in
        run) pick[$a]=1; echo "=== changed-only: run $a ($b)" ;;
        ignore) echo "=== changed-only: ignored $a ($b)" ;;
      esac
    done <<<"$plan"
    list=() skipped=()
    for t in "${all[@]}"; do
      if [[ -n "${pick[$(basename "$t")]:-}" ]]; then list+=("$t"); else skipped+=("$(basename "$t")"); fi
    done
    echo "=== changed-only: skipped ${#skipped[@]} of ${#all[@]} files, no changed file or function is named in them: ${skipped[*]}"
  fi
fi
fails=0 n=0
if (( njobs == 1 )); then
  for t in "${list[@]}"; do
    n=$((n + 1))
    echo "=== $(basename "$t")"
    bash "$t" || { echo "FAILED: $(basename "$t")"; fails=$((fails + 1)); }
  done
else
  work=$(mktemp -d)
  trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT
  trap 'exit 130' INT TERM
  pool=() serial=()
  for t in "${list[@]}"; do
    if head -40 "$t" | grep -E '^# serial( |$)' >/dev/null; then serial+=("$t"); else pool+=("$t"); fi
  done
  files=("${pool[@]}" "${serial[@]}")
  n=${#files[@]}
  # start <i>: run file i in the background; <i>.rc appears only once the
  # file is done, so an existing <i>.rc means <i>.out is complete.
  start() { ( bash "${files[$1]}" </dev/null >"$work/$1.out" 2>&1; echo $? >"$work/$1.rc.tmp"; mv "$work/$1.rc.tmp" "$work/$1.rc" ) & }
  next=0
  flush() {
    while (( next < n )) && [[ -f "$work/$next.rc" ]]; do
      echo "=== $(basename "${files[$next]}")"
      cat "$work/$next.out"
      [[ "$(cat "$work/$next.rc")" == 0 ]] || { echo "FAILED: $(basename "${files[$next]}")"; fails=$((fails + 1)); }
      next=$((next + 1))
    done
  }
  running=0
  for ((i = 0; i < ${#pool[@]}; i++)); do
    if (( running >= njobs )); then wait -n; running=$((running - 1)); flush; fi
    start "$i"; running=$((running + 1))
  done
  wait; flush
  for ((i = ${#pool[@]}; i < n; i++)); do start "$i"; wait; flush; done
fi
echo "=== $((n - fails))/$n test files passed"
if [[ -s "$SPOOL_TEST_GUARD_LOG" ]]; then
  echo "FAILED: a test reached for the live spool root (refused by the SPOOL_TEST guard):"
  sed 's/^/  /' "$SPOOL_TEST_GUARD_LOG"
  fails=$((fails + 1))
fi
(( guard_own )) && rm -f "$SPOOL_TEST_GUARD_LOG"
[[ "$fails" -eq 0 ]]
