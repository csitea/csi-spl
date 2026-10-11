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
#
# Timing guard: every file's wall time and CPU (user + sys of the file and
# its children) are measured and the run ends with "--- slowest 10 test
# files (wall s, cpu s)" (ORC_TEST_SLOWEST=<n>, 0 = off), so a creep toward
# CI's timeout-minutes shows in the log before the cap cancels the job. On a
# CPU-quota'd runner the cpu column is what the quota divides.
# ORC_TEST_SHARD=<k>/<m> runs the k-th of m shards, so CI can split the suite
# across m parallel jobs; it is unset before any file runs, so a test that
# runs this script itself sees the whole suite. The shards are balanced by
# the wall time each file took (shard-times.tsv, spec 131 C3): heaviest file
# first onto the lightest shard; a file not in the table weighs the table's
# mean. Refresh the table with a full run:
#   ORC_TEST_TIMES_OUT=<this dir>/shard-times.tsv run-all-tests.sh
# Round-robin (every m-th file, the pre-131 split: 918 s vs 520 s median on
# 2026-10-11) when the table is missing or ORC_TEST_SHARD_BALANCE=0.
#   run-all-tests.sh --list   prints the files this run would run, runs none
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
changed=0 bg="" listonly=0
while (( $# )); do
  case "$1" in
    --changed) changed=1 ;;
    --list) listonly=1 ;;
    --background) bg="${2:-}"; [[ -n "$bg" ]] || { echo "--background needs a result file" >&2; exit 2; }; shift ;;
    *) echo "usage: run-all-tests.sh [--changed] [--list] [--background <result-file>]" >&2; exit 2 ;;
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
# shard_pick <times tsv> <k> <m> - stdin the file names in suite order, stdout
# the k-th of m shards in suite order: heaviest first (ties by suite order)
# onto the shard with the smallest sum so far (ties to the lowest shard).
shard_pick() {
  awk -F'\t' 'NR == FNR { if ($2 + 0 > 0) { w[$1] = $2; s += $2; c++ }; next }
    { printf "%s\t%d\t%s\n", (($0 in w) ? w[$0] : (c ? s / c : 1)), FNR, $0 }' "$1" - |
    sort -t$'\t' -k1,1gr -k2,2n |
    awk -F'\t' -v k="$2" -v m="$3" '{ b = 1; for (i = 2; i <= m; i++) if (sum[i] < sum[b]) b = i
      sum[b] += $1; if (b == k) print $2 "\t" $3 }' |
    sort -t$'\t' -k1,1n | cut -f2
}
all=()
for t in "$dir"/*.tst.sh; do [[ -f "$t" ]] && all+=("$t"); done
shard="${ORC_TEST_SHARD:-}"
unset ORC_TEST_SHARD
if [[ -n "$shard" ]]; then
  [[ "$shard" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && (( BASH_REMATCH[1] <= BASH_REMATCH[2] )) \
    || { echo "ORC_TEST_SHARD must be <k>/<m> with 1 <= k <= m (got '$shard')" >&2; exit 2; }
  sk=${BASH_REMATCH[1]} sm=${BASH_REMATCH[2]} mine=()
  shard_times="${ORC_TEST_SHARD_TIMES:-$dir/shard-times.tsv}"
  if [[ "${ORC_TEST_SHARD_BALANCE:-1}" == 1 && -s "$shard_times" ]]; then
    while IFS= read -r t; do mine+=("$dir/$t"); done < <(printf '%s\n' "${all[@]##*/}" | shard_pick "$shard_times" "$sk" "$sm")
    how="balanced by $(basename "$shard_times")"
  else
    for ((i = sk - 1; i < ${#all[@]}; i += sm)); do mine+=("${all[$i]}"); done
    how="every ${sm}th file"
  fi
  (( listonly )) || echo "--- shard $shard: ${#mine[@]} of ${#all[@]} files ($how)"
  all=("${mine[@]}")
fi
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
if (( listonly )); then (( guard_own )) && rm -f "$SPOOL_TEST_GUARD_LOG"; printf '%s\n' "${list[@]##*/}"; exit 0; fi
fails=0 n=0
# <start> <end> <cpu s> <file> per test file, for the slowest-N report below.
times=$(mktemp)
TIMEFORMAT='%U %S'
if (( njobs == 1 )); then
  for t in "${list[@]}"; do
    n=$((n + 1))
    echo "=== $(basename "$t")"
    t0=$EPOCHREALTIME rc=0
    { time bash "$t" 2>&3; } 3>&2 2>"$times.cpu" || rc=$?
    (( rc == 0 )) || { echo "FAILED: $(basename "$t")"; fails=$((fails + 1)); }
    echo "$t0 $EPOCHREALTIME $(awk '{ print $1 + $2 }' "$times.cpu") $(basename "$t")" >>"$times"
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
  start() { ( t0=$EPOCHREALTIME rc=0
    { time bash "${files[$1]}" </dev/null >"$work/$1.out" 2>&1; } 2>"$work/$1.cpu" || rc=$?
    echo "$rc" >"$work/$1.rc.tmp"
    echo "$t0 $EPOCHREALTIME $(awk '{ print $1 + $2 }' "$work/$1.cpu") $(basename "${files[$1]}")" >"$work/$1.sec"
    mv "$work/$1.rc.tmp" "$work/$1.rc" ) & }
  next=0 started=0
  # show <i>: print finished file i: its header, output and verdict
  show() {
    echo "=== $(basename "${files[$1]}")"
    cat "$work/$1.out"
    [[ "$(cat "$work/$1.rc")" == 0 ]] || { echo "FAILED: $(basename "${files[$1]}")"; fails=$((fails + 1)); }
    cat "$work/$1.sec" >>"$times"
  }
  flush() {
    while (( next < n )) && [[ -f "$work/$next.rc" ]]; do show "$next"; next=$((next + 1)); done
  }
  # Round 8 row 02: a stopped or timed-out shard printed 1236 of 5288
  # verdicts (23 %): flush waits in suite order for the slowest file, and the
  # EXIT trap removed $work with the finished files unprinted. On INT/TERM
  # print every finished file not yet printed, in suite order, then the count;
  # the EXIT trap removes $work after that.
  stopped() {
    local i done_n=$next
    for ((i = next; i < n; i++)); do
      [[ -f "$work/$i.rc" ]] || continue
      show "$i"; done_n=$((done_n + 1))
    done
    echo "=== stopped: $done_n of $n files finished, $((n - started)) not run"
    exit 130
  }
  trap stopped INT TERM
  running=0
  for ((i = 0; i < ${#pool[@]}; i++)); do
    if (( running >= njobs )); then wait -n; running=$((running - 1)); flush; fi
    start "$i"; started=$((i + 1)) running=$((running + 1))
  done
  wait; flush
  for ((i = ${#pool[@]}; i < n; i++)); do start "$i"; started=$((i + 1)); wait; flush; done
fi
echo "=== $((n - fails))/$n test files passed"
slowest="${ORC_TEST_SLOWEST:-10}"
if [[ -s "$times" && "$slowest" =~ ^[1-9][0-9]*$ ]]; then
  echo "--- slowest $slowest test files (wall s, cpu s)"
  awk '{ printf "%8.1f %8.1f  %s\n", $2 - $1, $3, $4 }' "$times" | sort -rn | sed -n "1,${slowest}p"
  awk '{ w += $2 - $1; c += $3 } END { printf "--- sum over %d files: wall %.0f s, cpu %.0f s\n", NR, w, c }' "$times"
fi
if [[ -n "${ORC_TEST_TIMES_OUT:-}" && -s "$times" ]]; then
  awk '{ printf "%s\t%.0f\n", $4, $2 - $1 }' "$times" | sort >"$ORC_TEST_TIMES_OUT"
fi
rm -f "$times" "$times.cpu"
if [[ -s "$SPOOL_TEST_GUARD_LOG" ]]; then
  echo "FAILED: a test reached for the live spool root (refused by the SPOOL_TEST guard):"
  sed 's/^/  /' "$SPOOL_TEST_GUARD_LOG"
  fails=$((fails + 1))
fi
(( guard_own )) && rm -f "$SPOOL_TEST_GUARD_LOG"
[[ "$fails" -eq 0 ]]
