#!/usr/bin/env bash
# Run every csi-spl-orc feature test, features/*/tests/test-*.sh, as the
# quality gate (wf 10 job orc-features) does. Discovery, not a list: a new
# test-*.sh runs without touching this file or the workflow.
#
# Left out, each one printed by name with its reason:
#   - a file named in ci-skip.txt next to this script (a red on master owned
#     by another lane; the line names the owner). A line that names no file is
#     an error, so the list cannot rot;
#   - a file an orc-suite wrapper already runs (a csi-spl-orc/src/bash/tests
#     *.tst.sh that execs it), so CI does not run it twice.
#
# Every file runs FEATURE_TEST_JOBS at a time (default: the cpu count, at
# most 6), except the files named in ci-serial.txt (a timing check or a race
# that sibling load breaks), which run one by one after the pool. Output is
# buffered and printed in name order, then a table of file / verdict /
# seconds. Exit 1 when any file fails.
# Needs tmux (the spawn-agents tests drive a private tmux server each) and a
# short TMPDIR: a tmux socket path over 107 bytes fails to bind.
#
# Usage: bash csi-spl-orc/src/bash/features/run-ci-tests.sh [<feature>...]
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
orc_tests="$here/../tests"
skip_file="$here/ci-skip.txt"
serial_file="$here/ci-serial.txt"
# CLE-77923: under SPOOL_TEST=1 the send/notify path refuses the live root.
export SPOOL_TEST=1

njobs="${FEATURE_TEST_JOBS:-}"
if [[ -z "$njobs" ]]; then
  njobs=$(nproc 2>/dev/null || echo 4); (( njobs > 6 )) && njobs=6
fi
[[ "$njobs" =~ ^[1-9][0-9]*$ ]] || { echo "FEATURE_TEST_JOBS must be a positive integer (got '$njobs')" >&2; exit 2; }
command -v tmux >/dev/null || { echo "FAIL: tmux is not on PATH (the spawn-agents tests need it)" >&2; exit 1; }

feats=("$@")
if (( ${#feats[@]} == 0 )); then
  for d in "$here"/*/tests; do [[ -d "$d" ]] && feats+=("$(basename "$(dirname "$d")")"); done
fi

declare -A skip=() serial=()
rc=0
read_list() {  # <file> skip|serial: "<feature>/<file>  <reason>" lines
  local name reason
  [[ -f "$1" ]] || return 0
  while read -r name reason; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ -f "$here/${name%%/*}/tests/${name#*/}" ]] \
      || { echo "FAIL: ${1##*/} names $name, which does not exist (drop the line)"; rc=1; continue; }
    if [[ "$2" == skip ]]; then skip[$name]="$reason"; else serial[$name]="$reason"; fi
  done <"$1"
}
read_list "$skip_file" skip
read_list "$serial_file" serial

list=() alone=()
for f in "${feats[@]}"; do
  [[ -d "$here/$f/tests" ]] || { echo "FAIL: no feature $f" >&2; exit 2; }
  for t in "$here/$f/tests"/test-*.sh; do
    [[ -f "$t" ]] || continue
    name="$f/${t##*/}"
    if [[ -n "${skip[$name]:-}" ]]; then
      echo "=== skipped by name: $name -- ${skip[$name]}"; continue
    fi
    w=$(grep -lE "^exec .*features/$f/tests/${t##*/}\"?\$" "$orc_tests"/*.tst.sh 2>/dev/null | sed -n 1p)
    if [[ -n "$w" ]]; then
      echo "=== runs in orc-suite: $name (via ${w##*/})"; continue
    fi
    if [[ -n "${serial[$name]:-}" ]]; then
      echo "=== runs alone, after the pool: $name -- ${serial[$name]}"; alone+=("$t")
    else
      list+=("$t")
    fi
  done
done
(( ${#list[@]} + ${#alone[@]} )) || { echo "FAIL: no feature test found"; exit 1; }

out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
run_one() {  # <index> <file>
  local i="$1" t="$2" s e r
  s=$(date +%s%N)
  bash "$t" </dev/null >"$out/$i.log" 2>&1; r=$?
  e=$(date +%s%N)
  printf '%s %s\n' "$r" "$(( (e - s) / 1000000 ))" >"$out/$i.rc"
}
start=$(date +%s)
running=0
for i in "${!list[@]}"; do
  if (( running >= njobs )); then wait -n; running=$((running - 1)); fi
  run_one "$i" "${list[$i]}" &
  running=$((running + 1))
done
wait
n=${#list[@]}
for t in "${alone[@]}"; do run_one "$n" "$t"; list+=("$t"); n=$((n + 1)); done

pass=0 fail=0 table=""
for i in "${!list[@]}"; do
  t="${list[$i]}"; name="$(basename "$(dirname "$(dirname "$t")")")/${t##*/}"
  read -r r ms <"$out/$i.rc" 2>/dev/null || { r=99; ms=0; }
  echo "=== $name"
  cat "$out/$i.log"
  if [[ "$r" == 0 ]]; then v=PASS; pass=$((pass + 1)); else v="FAIL(rc=$r)"; fail=$((fail + 1)); rc=1; fi
  table+=$(printf '%-55s %-11s %6.1f' "$name" "$v" "$(awk -v m="$ms" 'BEGIN{print m/1000}')")$'\n'
done
echo "=== feature tests: file / verdict / seconds (jobs=$njobs)"
printf '%s' "$table"
echo "=== $pass/$(( pass + fail )) feature test files passed in $(( $(date +%s) - start )) s"
exit "$rc"
