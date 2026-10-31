#!/usr/bin/env bash
# cron-no-stack.sh - run a crontab job at most once at a time (SPL-4495). Every
# every-minute and every-few-minute line the box installers write runs its job
# through this wrapper, each line on its own lock file:
#
#   cron-no-stack.sh <lock file> <command> [args...]
#
# It takes `flock -n` on <lock file> and writes the holder (pid, start epoch,
# job) into it. While an earlier run of the same line still holds it, the new
# start exits 0 at once and writes one SKIP line (to the line's own log). Else
# it runs <command> and exits with its code. The lock lives on an fd of this
# wrapper only: <command> runs with that fd closed, so a daemon it leaves
# behind never holds the lock, and the lock goes when <command> returns.
#
# A holder older than CRON_NO_STACK_MAX_S is stuck: the start writes a STUCK
# line, exits 3 and sends one spool note per stuck holder, so a hung job never
# reads as a quiet, healthy line (review W1).
#
# Why: on 2026-10-31 a slow box stacked 111 copies of the every-minute runner
# CPU budget line, 75 seat alarms, 25 box stats and 13 lane rotations (load
# 467 on 16 cores): a job that lasts longer than its period piles up.
#
# Env:
#   CRON_NO_STACK_MAX_S: holder age that counts as stuck (default 1800).
#   CRON_NO_STACK_ALERT_TO: spool recipient (default "orchestrator").
#   CRON_NO_STACK_ALERT_FROM: spool sender (default $SPOOL_AGENT_ID or
#     cron-no-stack@<box>, the box name from the config).
#   CRON_NO_STACK_ALERT_TASK: spool task id (default "cron-no-stack").
#   CRON_NO_STACK_ALERT_SEND_BIN: spool-send.sh or a compatible tool (default
#     the orc spool-send.sh next to this script); "none" sends nothing.
#
# Exit: <command>'s code, 0 on a skip, 2 usage (no lock or command, no flock,
# the lock file cannot be opened), 3 the holder is stuck.
set -uo pipefail

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
_box_lib="$(dirname "$0")/../../../lib/bash/funcs/spl-desk-box.func.sh"
# shellcheck source=/dev/null
[ -r "$_box_lib" ] && source "$_box_lib"
box() { if declare -F spl_box_name >/dev/null; then spl_box_name; else hostname -s; fi; }

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# alert_stuck <body>: one spool note per stuck holder; the marker
# <lock>.stuck keeps the holder record it was sent for.
alert_stuck() {
  local rec="$1" body="$2" marker="$lock.stuck"
  [ "$(cat "$marker" 2>/dev/null)" = "$rec" ] && { say "INFO the alert for this stuck holder was sent already ($marker)"; return 0; }
  local send="${CRON_NO_STACK_ALERT_SEND_BIN:-$(dirname "$0")/../features/spawn-agents/scripts/spool-send.sh}"
  [ "$send" = none ] && return 0
  [ -f "$send" ] || { say "WARN no spool-send.sh at $send: stuck alert not sent"; return 0; }
  if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" \
    --from "${CRON_NO_STACK_ALERT_FROM:-${SPOOL_AGENT_ID:-cron-no-stack@$(box)}}" \
    --to "${CRON_NO_STACK_ALERT_TO:-orchestrator}" --kind note \
    --task "${CRON_NO_STACK_ALERT_TASK:-cron-no-stack}" --body "$body" >/dev/null 2>&1; then
    printf '%s\n' "$rec" >"$marker"
    say "INFO stuck alert sent"
  else
    say "WARN the stuck alert failed to send via $send"
  fi
}

[ "$#" -ge 2 ] || { say "FATAL usage: cron-no-stack.sh <lock file> <command> [args...]"; exit 2; }
lock="$1"; shift
case "$lock" in /*) ;; *) say "FATAL the lock file must be an absolute path, got: '$lock'"; exit 2 ;; esac
command -v flock >/dev/null 2>&1 || { say "FATAL flock is not installed: $1 not run"; exit 2; }
mkdir -p "$(dirname "$lock")" 2>/dev/null
exec 9>>"$lock" || { say "FATAL cannot open the lock file $lock: $1 not run"; exit 2; }
if ! flock -n 9; then
  rec="$(head -n 1 "$lock" 2>/dev/null)"
  hpid="$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' <<<"$rec")"
  hstart="$(sed -n 's/.*start=\([0-9]*\).*/\1/p' <<<"$rec")"
  hjob="$(sed -n 's/.*job=\([^ ]*\).*/\1/p' <<<"$rec")"
  max="${CRON_NO_STACK_MAX_S:-1800}"
  if [[ "$hstart" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
    age=$(( $(date +%s) - hstart ))
    if [ "$age" -gt "$max" ]; then
      msg="STUCK ${hjob:-?} held $age s by pid ${hpid:-?} on $(box) (max $max s): $lock; this start of $(basename "$1") exits 3"
      say "$msg"
      alert_stuck "$rec" "$msg"
      exit 3
    fi
  fi
  say "SKIP an earlier run of ${hjob:-$(basename "$1")} (pid ${hpid:-?}) still holds $lock: this start exits"
  exit 0
fi
rm -f "$lock.stuck"
printf 'pid=%s start=%s job=%s\n' "$$" "$(date +%s)" "$(basename "$1")" >"$lock"
"$@" 9>&-
