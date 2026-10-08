#!/usr/bin/env bash
# box-disk-sweep.sh - free this box's disk of data that is safe to remove,
# one step after the other (owner, HUM-10 t1 a5aeaef8, 2026-10-08: "remove
# data from the sandbox on a scheduled basis every 4th hour via cron").
# Each step is its own action with its own guards; this only runs them in
# order and prints the free space before and after:
#   sessions   spl-session-prune.sh   old transcripts of dead, unrestorable sessions
#   tmp        tmp-stale-sweep.sh     idle go-build / tmp.X / Test* / *-gocache in /tmp
#   worktrees  wt-dead-sweep.sh       clean, landed worktrees of agents that are gone
#   go         do_prune_go_build_cache  Go build-cache entries older than a day
#   docker     prune-docker-images.sh   unused images + build cache older than BOX_SWEEP_DOCKER_UNTIL
# A failing step is a FAIL line and the next step still runs. One sweep at a
# time (flock); a second one started meanwhile skips.
#
# Installed by do_box_disk_sweep_install_cron as ONE line in the box user's
# crontab, every 4 hours, tagged `# csi-spl:box-disk-sweep`.
#
#   DRY_RUN=1 (default) | 0           passed to every step
#   BOX_SWEEP_STEPS        default "sessions tmp worktrees go docker"
#   BOX_SWEEP_DOCKER_UNTIL default 72h (the session age, AGE_DAYS=3)
#   BOX_SWEEP_LOCK         default <log dir or /tmp>/box-disk-sweep.lock
#   BOX_SWEEP_MOUNTS       default "/ /mnt/data /tmp" (those that exist)
#   BOX_SWEEP_SCRIPTS      the step scripts' dir (tests), default this dir
#   BOX_SWEEP_ORC          the orc dir for ./run (tests), default ../..
#
# Exit: 0 every step ran clean; 1 a step failed; 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin${PATH:+:$PATH}"
export PATH

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dry="${DRY_RUN:-1}"
steps="${BOX_SWEEP_STEPS:-sessions tmp worktrees go docker}"
until="${BOX_SWEEP_DOCKER_UNTIL:-72h}"
scripts="${BOX_SWEEP_SCRIPTS:-$self_dir}"
orc="${BOX_SWEEP_ORC:-$(cd "$self_dir/../../.." && pwd)}"
lock="${BOX_SWEEP_LOCK:-${TMPDIR:-/tmp}/box-disk-sweep.$(id -un).lock}"
export SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
df_line() {
  local m
  for m in ${BOX_SWEEP_MOUNTS:-/ /mnt/data /tmp}; do
    [[ -d "$m" ]] && df -P -B1M "$m" | awk -v m="$m" 'NR==2 { printf "%s=%sMB-free/%s ", m, $4, $5 }'
  done
}

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
for s in $steps; do
  case "$s" in sessions|tmp|worktrees|go|docker) ;; *) say "FAIL unknown step '$s'"; exit 2 ;; esac
done
exec 9>>"$lock" || { say "FAIL cannot open the lock $lock"; exit 2; }
flock -n 9 || { say "SKIP another box disk sweep holds $lock"; exit 0; }

say "START box=$(hostname -s) user=$(id -un) dry_run=$dry steps='$steps' $(df_line)"
rc=0
for s in $steps; do
  say "STEP $s"
  case "$s" in
    sessions)  DRY_RUN="$dry" AGE_DAYS="${AGE_DAYS:-3}" PROJ_PATH="$orc" bash "$scripts/spl-session-prune.sh" ;;
    tmp)       DRY_RUN="$dry" bash "$scripts/tmp-stale-sweep.sh" ;;
    worktrees) DRY_RUN="$dry" bash "$scripts/wt-dead-sweep.sh" ;;
    go)        ( cd "$orc" && DRY_RUN="$dry" ./run -a do_prune_go_build_cache ) ;;
    docker)    DRY_RUN="$dry" PRUNE_UNTIL="$until" bash "$scripts/prune-docker-images.sh" ;;
  esac
  r=$?
  if [[ "$r" == 0 ]]; then say "STEP-OK $s $(df_line)"; else say "FAIL step $s rc=$r"; rc=1; fi
done
say "DONE rc=$rc $(df_line)"
exit "$rc"
