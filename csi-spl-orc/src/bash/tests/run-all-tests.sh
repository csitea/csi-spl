#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
#
# Perf round 4, C2: the files run ORC_TEST_JOBS at a time (default 6 on CI,
# 4 elsewhere, capped at the CPUs, nproc or ORC_TEST_NPROC; 1 = the old
# serial loop, streamed live; --print-jobs prints the value and exits). Each
# file's stdout and stderr are buffered to its own file and printed in suite
# order, so the log reads like a serial run and the per-file verdicts are
# the same. A test whose first 40 lines carry the line '# serial' (it shares
# a fixed /tmp path, $HOME or tmux state with another test) runs alone, after
# the pool.
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
# ORC_TEST_SHARD=<k>/<m> runs shard k of a longest-first pack of the files
# into m shards, so CI can split the suite across m parallel jobs; it is
# unset before any file runs, so a test that runs this script itself sees the
# whole suite. The weights are orc-shard-weights.txt beside this file
# (ORC_TEST_WEIGHTS=<file> overrides): '<file> <secs>' lines, '* <secs>' for
# every unlisted file. The heaviest file goes to the lightest shard (ties: the
# lower shard); with no weights every file ties and the pack is the old
# every-m-th split. The pool also starts the heaviest files first, so a
# 10-min file does not start last and hold the shard open alone (L5,
# 2026-10-12: two shards were 7,378 s and 5,543 s of summed wall, 33 % apart,
# under every-2nd-file). On CI (ORC_TEST_TIMES=1) the run ends with
# '--- every file (wall s)', one '<file> <secs>' line each, to refresh the
# weights from: save those lines of several runs into one file, then
#   run-all-tests.sh --weights-from <f>   prints the refreshed weights: each
#                                         file's median over its n >= 3
#                                         lines, '*' the median of those
#   run-all-tests.sh --check-weights <f>  exits 1 when a file's median and
#                                         its weight differ by > 2x and
#                                         > 60 s (a stale weight), naming it
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
changed=0 bg="" print_jobs=0 wmode="" wtimes=""
while (( $# )); do
  case "$1" in
    --changed) changed=1 ;;
    --background) bg="${2:-}"; [[ -n "$bg" ]] || { echo "--background needs a result file" >&2; exit 2; }; shift ;;
    --print-jobs) print_jobs=1 ;;
    --weights-from|--check-weights)
      wmode=$1 wtimes="${2:-}"; [[ -f "$wtimes" ]] || { echo "$1 needs a file of '<file> <secs>' lines" >&2; exit 2; }; shift ;;
    *) echo "usage: run-all-tests.sh [--changed] [--background <result-file>] [--print-jobs] [--weights-from|--check-weights <times-file>]" >&2; exit 2 ;;
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
# SPL-1874: no test reads or writes the box's private overlay (test-lib.inc.sh too)
export SPL_PRIVATE_CNF="${SPL_PRIVATE_CNF_FOR_TESTS:-/nonexistent/spl-private-cnf-for-tests.yaml}"
export SPL_PRIVATE_WARN=0
# SPL-3626: a lane worktree's git-ignored bin/spool is stale after any api
# commit, and spool-env's WARN about it leaked into the output of tests that
# do not source test-lib.inc.sh (spl-box-leave, tmux-close-window: two full
# gates red, c-884). The skip stays; only the line goes (SPL-2911 set it in
# the lib alone).
export SPOOL_BIN_STALE_WARN=0
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
# done_early <rc>: end a mode that runs no test (--print-jobs, the weights modes)
done_early() { (( guard_own )) && rm -f "$SPOOL_TEST_GUARD_LOG"; exit "$1"; }
# Test round 2 row 03 (SPL-2571): the default pool never exceeds the CPUs.
# CI ran 6 files at once on nproc=4 runners (68 of 68 shard jobs,
# 2026-10-19), so the same file ran up to 4x slower in a packed shard. An
# explicit ORC_TEST_JOBS is taken as given.
njobs="${ORC_TEST_JOBS:-}"
if [[ -z "$njobs" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then njobs=6; else njobs=4; fi
  ncpu="${ORC_TEST_NPROC:-$(nproc 2>/dev/null || echo 4)}"
  [[ "$ncpu" =~ ^[1-9][0-9]*$ ]] || { echo "ORC_TEST_NPROC must be a positive integer (got '$ncpu')" >&2; done_early 2; }
  (( njobs > ncpu )) && njobs=$ncpu
fi
[[ "$njobs" =~ ^[1-9][0-9]*$ ]] || { echo "ORC_TEST_JOBS must be a positive integer (got '$njobs')" >&2; done_early 2; }
(( print_jobs )) && { echo "$njobs"; done_early 0; }
all=()
for t in "$dir"/*.tst.sh; do [[ -f "$t" ]] && all+=("$t"); done
# wt[<basename>] = weight (s); wdef = the weight of an unlisted file
declare -A wt=()
wdef=1
wfile="${ORC_TEST_WEIGHTS:-$dir/orc-shard-weights.txt}"
if [[ -f "$wfile" ]]; then
  while read -r wf ws _; do
    [[ -z "$wf" || "$wf" == \#* ]] && continue
    [[ "$ws" =~ ^[0-9]+$ ]] || { echo "orc shard weights: bad line '$wf $ws' in $wfile" >&2; exit 2; }
    if [[ "$wf" == '*' ]]; then wdef=$ws; else wt[$wf]=$ws; fi
  done <"$wfile"
fi
weight() { local b=${1##*/}; echo "${wt[$b]:-$wdef}"; }
# medians <times-file>: '<file> <median s> <n>' per file of its
# '<file> <secs>' lines (a log timestamp column before them is skipped)
medians() {
  awk 'NF >= 2 && $(NF - 1) ~ /\.tst\.sh$/ && $NF ~ /^[0-9]+(\.[0-9]+)?$/ { print $(NF - 1), $NF }' "$1" \
    | sort -k1,1 -k2,2n \
    | awk 'function out() { if (n) printf "%s %.0f %d\n", f, (n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2), n }
           $1 != f { out(); f = $1; n = 0 } { v[++n] = $2 } END { out() }'
}
if [[ "$wmode" == --weights-from ]]; then
  med=$(medians "$wtimes" | awk '$3 >= 3 { print $1, $2 }')
  [[ -n "$med" ]] || { echo "* 1"; done_early 0; }
  echo "* $(awk '{ print $2 }' <<<"$med" | sort -n | awk '{ v[++n] = $1 } END { printf "%.0f", n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2 }')"
  echo "$med"
  done_early 0
fi
if [[ "$wmode" == --check-weights ]]; then
  checked=0 stale=0
  while read -r f m k; do
    w=$(weight "$f") checked=$((checked + 1))
    lo=$(( w < m ? w : m )) hi=$(( w < m ? m : w ))
    if (( hi > 2 * lo && hi - lo > 60 )); then
      echo "stale weight: $f weight $w s, measured median $m s (n=$k)"; stale=$((stale + 1))
    fi
  done < <(medians "$wtimes")
  echo "--- weights: $checked files checked, $stale stale"
  (( stale == 0 )) && done_early 0; done_early 1
fi
# heaviest_first <file>...: '<index> <weight>' per file (0-based), heaviest
# first, a tie in the given order
heaviest_first() {
  local i
  for ((i = 1; i <= $#; i++)); do echo "$((i - 1)) $(weight "${!i}")"; done | sort -s -k2,2nr
}
shard="${ORC_TEST_SHARD:-}"
unset ORC_TEST_SHARD
if [[ -n "$shard" ]]; then
  [[ "$shard" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && (( BASH_REMATCH[1] <= BASH_REMATCH[2] )) \
    || { echo "ORC_TEST_SHARD must be <k>/<m> with 1 <= k <= m (got '$shard')" >&2; exit 2; }
  sk=${BASH_REMATCH[1]} sm=${BASH_REMATCH[2]} mine=() sums=() owner=() total=0
  for ((s = 0; s < sm; s++)); do sums[s]=0; done
  while read -r i w; do
    best=0
    for ((s = 1; s < sm; s++)); do (( sums[s] < sums[best] )) && best=$s; done
    owner[i]=$best; sums[best]=$((sums[best] + w)); total=$((total + w))
  done < <(heaviest_first "${all[@]}")
  for ((i = 0; i < ${#all[@]}; i++)); do (( owner[i] == sk - 1 )) && mine+=("${all[$i]}"); done
  echo "--- shard $shard: ${#mine[@]} of ${#all[@]} files"
  echo "--- shard $shard weight: ${sums[sk - 1]} of $total s"
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
  # heaviest first; files[] keeps suite order, so the log still reads serial.
  # The order is read from a command substitution, not "< <(...)": bash 5.3
  # (ubuntu-26.04) lets wait -n return when a process substitution exits, so
  # the pool started a third file while two ran (SPL-3297).
  order=$(heaviest_first "${pool[@]}")
  while read -r i _; do
    [[ -n "$i" ]] || continue
    if (( running >= njobs )); then wait -n; running=$((running - 1)); flush; fi
    start "$i"; started=$((started + 1)) running=$((running + 1))
  done <<<"$order"
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
times_all="${ORC_TEST_TIMES:-}"
[[ -n "$times_all" ]] || { [[ "${GITHUB_ACTIONS:-}" == true ]] && times_all=1 || times_all=0; }
if [[ -s "$times" && "$times_all" == 1 ]]; then
  echo "--- every file (wall s), for orc-shard-weights.txt"
  awk '{ printf "%s %.0f\n", $4, $2 - $1 }' "$times" | sort
fi
rm -f "$times" "$times.cpu"
if [[ -s "$SPOOL_TEST_GUARD_LOG" ]]; then
  echo "FAILED: a test reached for the live spool root (refused by the SPOOL_TEST guard):"
  sed 's/^/  /' "$SPOOL_TEST_GUARD_LOG"
  fails=$((fails + 1))
fi
(( guard_own )) && rm -f "$SPOOL_TEST_GUARD_LOG"
[[ "$fails" -eq 0 ]]
