#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: fail a CI job early, with one clear line, when the runner's disk is
# too full for it (SPL-4790, owner t1 4b50446f). On 2026-11-04 the hub-pg job
# of wf 10 died 3x mid cache restore with "tar: ... .cache/go-build ...:
# Cannot write: No space left on device" (run 41794536858): the runner was
# lost, no step failed, and the red read like a test failure. This step runs
# before the cache restore and the tests, prints `df -h` of each path, and
# exits 1 with
#   disk full before tests: <free> < <need> (<path>)
# (also as an ::error:: annotation) when a path has less free space than the
# need.
#
# Usage: ci-disk-guard.sh [<path> ...]   default: / and $RUNNER_TEMP
# Env:   CI_DISK_NEED_GB (required, whole GB: wf 10 states it in its env)
#        CI_DISK_DF      the df to run (tests), default df
# Exit:  0 every path has the need free; 1 a path is short or unreadable;
#        2 usage.
#------------------------------------------------------------------------------
set -uo pipefail

need="${CI_DISK_NEED_GB:-}"
[[ "$need" =~ ^[0-9]+$ ]] || { echo "usage: CI_DISK_NEED_GB=<whole GB> $0 [<path> ...] (got '$need')" >&2; exit 2; }
df_cmd="${CI_DISK_DF:-df}"
paths=("$@")
((${#paths[@]})) || paths=(/ ${RUNNER_TEMP:+"$RUNNER_TEMP"})

"$df_cmd" -h "${paths[@]}" || true
need_kb=$((need * 1024 * 1024))
bad=0
for p in "${paths[@]}"; do
  # -P: one line per path even for a long device name; field 4 = available KB
  avail_kb=$("$df_cmd" -Pk "$p" 2>/dev/null | awk 'NR == 2 {print $4}')
  if ! [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    echo "::error::disk guard: cannot read the free space of $p"
    bad=1
    continue
  fi
  free_gb=$(awk -v k="$avail_kb" 'BEGIN {printf "%.1fG", k / 1048576}')
  if ((avail_kb < need_kb)); then
    echo "::error::disk full before tests: $free_gb < ${need}G ($p)"
    echo "disk full before tests: $free_gb < ${need}G ($p)"
    bad=1
  else
    echo "ok - disk free $free_gb >= ${need}G ($p)"
  fi
done
exit "$bad"
