#!/bin/bash
#------------------------------------------------------------------------------
# @description The watchdogs' ONE start command (spec 102 10.4.1, 10.4.2,
# @description 15.6): start every missing watchdog instance (1..3), detached,
# @description as the caller (the box user), each under its own
# @description run.<inst>.start.lock. It is what the crontab starter line runs
# @description (`* * * * *` and `@reboot`, do_spl_wd_ensure_install_cron) and
# @description what a surviving peer runs for a dead or hung one
# @description (spl-wd-peers.func.sh): there is no other start path, no
# @description keeper logic, no heartbeat and no alert here. Each run writes
# @description <spool root>/dispatch/wd/starter.last (the epoch) and
# @description starter.src (the checkout it ran from), which the watchdogs
# @description read to see that cron still runs. An instance starts from the
# @description verified snapshot <wd dir>/code/good/<org>-<app>-orc/run when
# @description it exists (10.4.4), else from this checkout's ./run.
# @param WD_INSTANCES (optional) - the instances to keep running, default "1 2 3"
# @param WD_INST_DRY (optional) - DRY_RUN handed to the started loops, default 0 (they act)
# @param WD_INST_START_WAIT (optional) - seconds to wait for a started loop to hold its lock, default 5
# @param WD_STATE_DIR (optional) - the watchdog dir, default <spool root>/dispatch/wd
# @param WD_RUN (optional) - the ./run a loop is started with when there is no code/good (tests)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_wd_inst_start
# @example WD_INSTANCES=2 ./run -a do_spl_wd_inst_start
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_wd_inst_start() {
  local dir i rc=0 now
  spl_rotate_conf || return 1
  dir="${WD_STATE_DIR:-$LEASE_DIR/wd}"
  mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  now="$(spl_lease_now)"
  # the cron heartbeat the watchdogs read (10.4.1); a full disk must not stop the starts
  if ! { echo "$now" > "$dir/starter.last.tmp.$$" && mv -f "$dir/starter.last.tmp.$$" "$dir/starter.last"; } 2>/dev/null; then
    do_log "WARN cannot write $dir/starter.last"
  fi
  if [[ -n "${PROJ_PATH:-}" && -d "$PROJ_PATH/.." ]]; then
    (cd "$PROJ_PATH/.." && pwd) > "$dir/starter.src" 2>/dev/null || true
  fi
  for i in ${WD_INSTANCES:-1 2 3}; do spl_wd_inst_start "$i" || rc=1; done
  return "$rc"
}

# spl_wd_inst_runner DIR: the ./run an instance starts with: the verified
# snapshot DIR/code/good/<orc>/run (10.4.4) when it is there, else WD_RUN,
# else this checkout's ./run. Empty when none is executable.
spl_wd_inst_runner() {
  local r
  for r in "$1"/code/good/*-orc/run; do
    if [[ -x "$r" ]]; then echo "$r"; return 0; fi
  done
  r="${WD_RUN:-${PROJ_PATH:-}/run}"
  if [[ -x "$r" ]]; then echo "$r"; fi
  return 0
}

# spl_wd_inst_start INST: start watchdog instance INST (1..3) detached
# (setsid, as the caller: the box user) when its run.<inst>.lock is free.
# One starter at a time per instance (run.<inst>.start.lock, flock -n). The
# loop acts (DRY_RUN = WD_INST_DRY, default 0) and runs forever. Lock files
# are never removed.
spl_wd_inst_start() {
  local inst="$1" dir
  [[ "$inst" =~ ^[1-3]$ ]] || { do_log "FATAL watchdog instance must be 1, 2 or 3, got: '$inst'"; return 1; }
  spl_rotate_conf || return 1
  dir="${WD_STATE_DIR:-$LEASE_DIR/wd}"
  mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  (
    exec 8>>"$dir/run.$inst.start.lock"
    flock -n 8 || { do_log "INFO watchdog instance $inst: another starter holds run.$inst.start.lock"; exit 0; }
    spl_wd_inst_start_locked "$inst" "$dir"
  )
}

# spl_wd_inst_start_locked INST DIR: the start itself, for a caller that
# already holds DIR/run.<inst>.start.lock (spl_wd_inst_start, or a peer that
# has just stopped a hung INST under that lock). Waits up to
# WD_INST_START_WAIT s (5) for the new loop to hold its lock, so a second
# starter right after it starts nothing: it waits for a new live pid in
# run.<inst>.pid, which the loop writes only once it holds the lock. It
# never probes the lock meanwhile: a probe (flock -n) holds a free lock for
# an instant, and a loop whose flock -w 0 lands in it exits "already runs"
# (CI 2026-10-07: a loaded box lost the restarted loop that way).
# spl_lease_detach closes every fd above 2, so the loop does not inherit the
# start lock. 1 = no runner.
spl_wd_inst_start_locked() {
  local inst="$1" dir="$2" run i old p
  if [[ -f "$dir/run.$inst.lock" ]] && ! flock -n "$dir/run.$inst.lock" true; then
    do_log "INFO watchdog instance $inst runs (pid $(cat "$dir/run.$inst.pid" 2>/dev/null || echo unknown))"
    return 0
  fi
  run="$(spl_wd_inst_runner "$dir")"
  old="$(cat "$dir/run.$inst.pid" 2>/dev/null || true)"
  [[ -n "$run" ]] || { do_log "FATAL watchdog runner is missing or not executable: ${WD_RUN:-${PROJ_PATH:-<none>}/run}"; return 1; }
  (
    export WD_INST="$inst" INSTANCE="$inst" DRY_RUN="${WD_INST_DRY:-0}" WD_TICKS="" WD_INST_START=""
    spl_lease_detach "$dir/run.$inst.out" "$run" -a do_spl_watchdog
  )
  for (( i = 0; i < ${WD_INST_START_WAIT:-5} * 10; i++ )); do
    p="$(cat "$dir/run.$inst.pid" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ && "$p" != "$old" ]] && kill -0 "$p" 2>/dev/null && break
    sleep 0.1
  done
  do_log "INFO watchdog instance $inst started from $run (log $dir/run.$inst.out)"
  return 0
}
