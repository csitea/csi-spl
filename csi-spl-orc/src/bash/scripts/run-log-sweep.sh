#!/usr/bin/env bash
# run-log-sweep.sh - the box sweep's `runlogs` step: the `./run` action logs
# older than a retention, oldest first. Every `./run` tees its stdout and
# stderr to $HOME/var/log/<proj>/<unit>.<YYYYmmdd_HHMMSS>.{out,err}.log and
# nothing pruned them: on sat, 2026-10-19, the box user's $HOME/var/log held
# 8.8 GB (csi-spl-orc 6.5 GB in 426713 files, csi-spl-iac 2.3 GB) while
# /mnt/data was at 91% (SPL-2649).
# They are read to debug a run of the last day or two; the default keeps 3
# days, like the sweep's session and docker ages, and less under pressure.
#
# Only regular files named *.log directly in a root's <proj>/ dir, whose
# mtime is older than the retention. A file a process still holds open (a
# running action's log; /proc/<pid>/fd of the processes this user can see)
# is kept and reported. Symlinks are never followed.
#
#   DRY_RUN=1 (default) | 0      1: the plan only, nothing removed
#   RUN_LOG_SWEEP_ROOTS          default "$HOME/var/log" (space-separated)
#   RUN_LOG_SWEEP_AGE_H          default 72 (hours)
#
# Prints START, a KEEP open <path> line per held file, then
#   DONE run-log sweep removed=<n> (<MB> MB) kept_open=<n> [planned]
# Exit: 0 done; 1 a removal failed; 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
roots="${RUN_LOG_SWEEP_ROOTS:-$HOME/var/log}"
age_h="${RUN_LOG_SWEEP_AGE_H:-72}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
[[ "$age_h" =~ ^[0-9]+$ ]] && (( age_h > 0 )) || { say "FAIL RUN_LOG_SWEEP_AGE_H must be a whole number of hours > 0, got '$age_h'"; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/run-log-sweep.XXXXXX")" || { say "FAIL mktemp"; exit 1; }
trap 'rm -rf "$work"' EXIT

# the candidates, "<mtime> <bytes> <path>", oldest first
for r in $roots; do
  [[ -d "$r" && ! -L "$r" ]] || continue
  find "$r" -mindepth 2 -maxdepth 2 -type f -name '*.log' -mmin +"$(( age_h * 60 ))" -printf '%T@ %s %p\n' 2>/dev/null
done | sort -n >"$work/cand"
# every file a process this user can see holds open
for fd in /proc/[0-9]*/fd/*; do readlink "$fd" 2>/dev/null; done | sort -u >"$work/open"

say "START run-log sweep dry_run=$dry age_h=$age_h roots='$roots' candidates=$(wc -l <"$work/cand")"
awk -v plist="$work/plist" '
  FNR == NR { open[$0] = 1; next }
  { p = substr($0, index($0, $3)) }
  p in open { print "KEEP open " p; kept++; next }
  { n++; b += $2; print p > plist }
  END { printf "TOTAL %d %d %d\n", n, b, kept }
' "$work/open" "$work/cand" >"$work/out"
grep -v '^TOTAL ' "$work/out" | while IFS= read -r l; do say "$l"; done
read -r _ n b kept < <(grep '^TOTAL ' "$work/out")
mb=$(( b / 1048576 ))
if [[ "$dry" == 1 ]]; then
  say "DONE run-log sweep removed=$n ($mb MB) kept_open=$kept planned"
  exit 0
fi
rc=0
if [[ -s "$work/plist" ]]; then
  xargs -d '\n' -r rm -f -- <"$work/plist" || { say "FAIL rm of the run logs rc=$?"; rc=1; }
fi
say "DONE run-log sweep removed=$n ($mb MB) kept_open=$kept"
exit "$rc"
