#!/usr/bin/env bash
# cron-no-stack.sh - run a crontab job at most once at a time (SPL-4495). Every
# every-minute and every-few-minute line the box installers write runs its job
# through this wrapper, each line on its own lock file:
#
#   cron-no-stack.sh <lock file> <command> [args...]
#
# It takes `flock -n` on <lock file>. While an earlier run of the same line
# still holds it, the new start exits 0 at once and writes one SKIP line (to
# the line's own log). Else it runs <command> and exits with its code. The
# lock lives on an fd of this wrapper only: <command> runs with that fd closed,
# so a daemon it leaves behind never holds the lock, and the lock goes when
# <command> returns.
#
# Why: on 2026-10-31 a slow box stacked 111 copies of the every-minute runner
# CPU budget line, 75 seat alarms, 25 box stats and 13 lane rotations (load
# 467 on 16 cores): a job that lasts longer than its period piles up.
#
# Exit: <command>'s code, 0 on a skip, 2 usage (no lock or command, no flock,
# the lock file cannot be opened).
set -uo pipefail

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[ "$#" -ge 2 ] || { say "FATAL usage: cron-no-stack.sh <lock file> <command> [args...]"; exit 2; }
lock="$1"; shift
case "$lock" in /*) ;; *) say "FATAL the lock file must be an absolute path, got: '$lock'"; exit 2 ;; esac
command -v flock >/dev/null 2>&1 || { say "FATAL flock is not installed: $1 not run"; exit 2; }
mkdir -p "$(dirname "$lock")" 2>/dev/null
exec 9>>"$lock" || { say "FATAL cannot open the lock file $lock: $1 not run"; exit 2; }
if ! flock -n 9; then
  say "SKIP an earlier run of $(basename "$1") still holds $lock: this start exits"
  exit 0
fi
"$@" 9>&-
