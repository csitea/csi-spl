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
#   docker     prune-docker-images.sh   unused images + build cache older than BOX_SWEEP_DOCKER_UNTIL,
#                                       then the build cache down to its cap
#   journal    journal-sweep.sh         systemd journal down to BOX_SWEEP_JOURNAL_MAX (default 500M)
#   runners    runner-sweep.sh          idle runners only: _work/_temp files and _diag/*.log older
#                                       than BOX_SWEEP_RUNNER_AGE days (default 2); never
#                                       _work/<repo>, .runner or .credentials*
# A failing step is a FAIL line and the next step still runs. One sweep at a
# time (flock); a second one started meanwhile skips.
#
# PRESSURE: the lowest free % of BOX_SWEEP_MOUNTS picks the level, and the
# level the limits (2026-10-09: /mnt/data filled at 1.5..4 GB/h while the
# fixed 72h / 1440 min limits found ~0 to remove, and the disk hit 100%):
#   level   free %                 docker until   go cache age   gate
#   normal  >= LOW (15)            72h            1440 min       every 4 h
#   low     <  LOW                 12h            360 min        every tick
#   crit    <  CRIT (7)            2h             60 min         every tick
# The busy-CI wait and the in-use image pins of the docker step still apply.
# At EVERY level the build cache is then cut to BOX_SWEEP_BUILDER_CAP_PCT
# (10) % of the docker disk's size, whatever its age (2026-10-11: sat's
# 25 GB of cache was nearly all under 12 h old, the low-level prune freed
# 0 B and /mnt/data reached 93%; the main box held 144 GB on an 889G disk).
# A crit sweep that leaves the disk under CRIT sends ONE note to the
# orchestrator (task disk-sweep-<box>), again only after free went back up.
#
# Installed by do_box_disk_sweep_install_cron as ONE line in the box user's
# crontab, every 15 minutes with BOX_SWEEP_GATE=1, tagged
# `# csi-spl:box-disk-sweep`: a normal-level tick runs only when the last
# normal run is BOX_SWEEP_EVERY_MIN (240) old; a low / crit tick always runs.
#
#   DRY_RUN=1 (default) | 0           passed to every step
#   BOX_SWEEP_STEPS        default "sessions tmp worktrees go docker journal runners"
#   BOX_SWEEP_JOURNAL_MAX  default 500M (journalctl --vacuum-size)
#   BOX_SWEEP_RUNNER_ROOT  default /srv/gh-runner
#   BOX_SWEEP_RUNNER_AGE   default 2 (days); idle runners only
#   BOX_SWEEP_DOCKER_UNTIL default 72h (the session age, AGE_DAYS=3)
#   BOX_SWEEP_GO_AGE_MIN   default 1440
#   BOX_SWEEP_LOW_FREE_PCT / _CRIT_FREE_PCT              default 15 / 7
#   BOX_SWEEP_LOW_DOCKER_UNTIL / _CRIT_DOCKER_UNTIL      default 12h / 2h
#   BOX_SWEEP_LOW_GO_AGE_MIN / _CRIT_GO_AGE_MIN          default 360 / 60
#   BOX_SWEEP_BUILDER_CAP_PCT default 10 (0 = no cap), the docker step's
#                          PRUNE_BUILDER_CAP_PCT
#   BOX_SWEEP_GATE         1: skip a normal-level tick younger than
#                          BOX_SWEEP_EVERY_MIN (240); default 0 (always run)
#   BOX_SWEEP_FREE_PCT     the measured free % (tests: a planted value)
#   BOX_SWEEP_SEND         the note sender (tests), default spool-send.sh
#   BOX_SWEEP_NOTE=0       no note
#   BOX_SWEEP_LOCK         default <log dir or /tmp>/box-disk-sweep.lock
#   BOX_SWEEP_MOUNTS       default "/ /mnt/data /tmp" (those that exist)
#   BOX_SWEEP_SCRIPTS      the step scripts' dir (tests), default this dir
#   BOX_SWEEP_ORC          the orc dir for ./run (tests), default ../..
#
# Exit: 0 every step ran clean; 1 a step failed; 2 usage.
# spl_role_seat: the role seat ids in their live vendor letter (SPL-1695)
declare -F spl_role_seat >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin${PATH:+:$PATH}"
export PATH

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dry="${DRY_RUN:-1}"
steps="${BOX_SWEEP_STEPS:-sessions tmp worktrees go docker journal runners}"
until="${BOX_SWEEP_DOCKER_UNTIL:-72h}"
scripts="${BOX_SWEEP_SCRIPTS:-$self_dir}"
orc="${BOX_SWEEP_ORC:-$(cd "$self_dir/../../.." && pwd)}"
lock="${BOX_SWEEP_LOCK:-${TMPDIR:-/tmp}/box-disk-sweep.$(id -un).lock}"
go_age="${BOX_SWEEP_GO_AGE_MIN:-1440}"
cap_pct="${BOX_SWEEP_BUILDER_CAP_PCT:-10}"
low_pct="${BOX_SWEEP_LOW_FREE_PCT:-15}" crit_pct="${BOX_SWEEP_CRIT_FREE_PCT:-7}"
gate="${BOX_SWEEP_GATE:-0}" every="${BOX_SWEEP_EVERY_MIN:-240}"
send="${BOX_SWEEP_SEND:-$orc/src/bash/features/spawn-agents/scripts/spool-send.sh}"
journal_max="${BOX_SWEEP_JOURNAL_MAX:-500M}"
runner_root="${BOX_SWEEP_RUNNER_ROOT:-/srv/gh-runner}"
runner_age="${BOX_SWEEP_RUNNER_AGE:-2}"
export SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
df_line() {
  local m
  for m in ${BOX_SWEEP_MOUNTS:-/ /mnt/data /tmp}; do
    [[ -d "$m" ]] && df -P -B1M "$m" | awk -v m="$m" 'NR==2 { printf "%s=%sMB-free/%s ", m, $4, $5 }'
  done
}

# free_pct - "<lowest free %> <its mount>" over BOX_SWEEP_MOUNTS
free_pct() {
  if [[ -n "${BOX_SWEEP_FREE_PCT:-}" ]]; then echo "$BOX_SWEEP_FREE_PCT planted"; return; fi
  local m
  for m in ${BOX_SWEEP_MOUNTS:-/ /mnt/data /tmp}; do
    [[ -d "$m" ]] && df -P "$m" | awk -v m="$m" 'NR==2 && $2 > 0 { printf "%d %s\n", 100 * $4 / $2, m }'
  done | sort -n | sed -n 1p
}

# note <text> - a spool note to the orchestrator; a failed send is a WARN
note() {
  [[ "${BOX_SWEEP_NOTE:-1}" == 0 || "$dry" == 1 ]] && { say "PLAN note to orchestrator: $1"; return 0; }
  local box; box="$(hostname -s)"
  if bash "$send" --from "${LEASE_ORCH:-$(spl_role_seat 1)}" --to orchestrator --kind note --task "disk-sweep-$box" \
      --body "box disk sweep on $box ($(id -un)): $1" >/dev/null 2>&1 7>&- 8>&- 9>&-; then
    say "INFO note sent to the orchestrator (task disk-sweep-$box)"; return 0
  fi
  say "WARN the note to the orchestrator was NOT delivered: $1"; return 1
}

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
for v in "$cap_pct" "$low_pct" "$crit_pct" "$every" "$go_age" "${BOX_SWEEP_LOW_GO_AGE_MIN:-360}" "${BOX_SWEEP_CRIT_GO_AGE_MIN:-60}" "$runner_age"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { say "FAIL the free %, age and interval limits must be whole numbers, got '$v'"; exit 2; }
done
[[ "$journal_max" =~ ^[0-9]+[KMGT]?$ ]] || { say "FAIL BOX_SWEEP_JOURNAL_MAX must be a size like 500M, got '$journal_max'"; exit 2; }
[[ "$gate" == 0 || "$gate" == 1 ]] || { say "FAIL BOX_SWEEP_GATE must be 0 or 1, got '$gate'"; exit 2; }
for s in $steps; do
  case "$s" in sessions|tmp|worktrees|go|docker|journal|runners) ;; *) say "FAIL unknown step '$s'"; exit 2 ;; esac
done
exec 9>>"$lock" || { say "FAIL cannot open the lock $lock"; exit 2; }
flock -n 9 || { say "SKIP another box disk sweep holds $lock"; exit 0; }

read -r fpct fmount <<<"$(free_pct)"
if ! [[ "$fpct" =~ ^[0-9]+$ ]]; then
  say "WARN cannot measure the free space of '${BOX_SWEEP_MOUNTS:-/ /mnt/data /tmp}': the normal level runs"
  fpct=100 fmount=unmeasured
fi
level=normal
if (( fpct < crit_pct )); then
  level=crit until="${BOX_SWEEP_CRIT_DOCKER_UNTIL:-2h}" go_age="${BOX_SWEEP_CRIT_GO_AGE_MIN:-60}"
elif (( fpct < low_pct )); then
  level=low until="${BOX_SWEEP_LOW_DOCKER_UNTIL:-12h}" go_age="${BOX_SWEEP_LOW_GO_AGE_MIN:-360}"
fi
stamp="$lock.last-normal" noted="$lock.crit-noted"
if [[ "$gate" == 1 && "$level" == normal && -f "$stamp" ]] && [[ -n "$(find "$stamp" -mmin -"$every" 2>/dev/null)" ]]; then
  say "SKIP level=normal free=${fpct}% ($fmount): the last normal sweep is under ${every} min old"; exit 0
fi
(( fpct >= crit_pct )) && rm -f "$noted" 2>/dev/null

say "START box=$(hostname -s) user=$(id -un) dry_run=$dry level=$level free=${fpct}% ($fmount) docker_until=$until builder_cap_pct=$cap_pct go_age_min=$go_age steps='$steps' $(df_line)"
rc=0
for s in $steps; do
  say "STEP $s"
  case "$s" in
    sessions)  DRY_RUN="$dry" AGE_DAYS="${AGE_DAYS:-3}" PROJ_PATH="$orc" bash "$scripts/spl-session-prune.sh" ;;
    tmp)       DRY_RUN="$dry" bash "$scripts/tmp-stale-sweep.sh" ;;
    worktrees) DRY_RUN="$dry" bash "$scripts/wt-dead-sweep.sh" ;;
    go)        ( cd "$orc" && DRY_RUN="$dry" GO_CACHE_MAX_AGE_MIN="$go_age" ./run -a do_prune_go_build_cache ) ;;
    docker)    DRY_RUN="$dry" PRUNE_UNTIL="$until" PRUNE_BUILDER_CAP_PCT="$cap_pct" bash "$scripts/prune-docker-images.sh" ;;
    journal)   DRY_RUN="$dry" BOX_SWEEP_JOURNAL_MAX="$journal_max" bash "$scripts/journal-sweep.sh" ;;
    runners)   DRY_RUN="$dry" BOX_SWEEP_RUNNER_ROOT="$runner_root" BOX_SWEEP_RUNNER_AGE="$runner_age" bash "$scripts/runner-sweep.sh" ;;
  esac
  r=$?
  if [[ "$r" == 0 ]]; then say "STEP-OK $s $(df_line)"; else say "FAIL step $s rc=$r"; rc=1; fi
done
[[ "$level" == normal && "$dry" == 0 ]] && touch "$stamp" 2>/dev/null
read -r apct amount <<<"$(free_pct)"
if [[ "$level" == crit && "$apct" =~ ^[0-9]+$ ]] && (( apct < crit_pct )); then
  say "FAIL level=crit: still ${apct}% free ($amount) after the sweep, under ${crit_pct}%"
  if [[ ! -e "$noted" ]]; then
    note "CRITICAL $amount is still at ${apct}% free after a crit sweep (docker until=$until, go cache age ${go_age} min): the disk fills soon, free it by hand" \
      && [[ "$dry" == 0 ]] && touch "$noted" 2>/dev/null
  fi
  rc=1
fi
say "DONE rc=$rc level=$level $(df_line)"
exit "$rc"
