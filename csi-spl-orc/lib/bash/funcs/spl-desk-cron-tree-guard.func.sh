#!/bin/bash
#------------------------------------------------------------------------------
# @description Refuse a tree write into a self-updating cron checkout (bug
# @description round 1 row 04, SPL-2491). The desk crons run from a detached
# @description `*-desk-cron` worktree that each tick moves to origin/<trunk>
# @description with `git checkout --detach`; a file an action writes there
# @description blocks that checkout, and every later tick runs stale code
# @description (desk-reconcile: 11 of 16 blockers carried `dirty:`). So an
# @description action that writes the repo tree calls this before its first
# @description write: when PROJ_PATH, APP_PATH or a path it is given has a
# @description component named `*-desk-cron` (as written, or once symlinks
# @description resolve), it logs a FATAL naming the path and returns 1.
# @description It never exits; the caller returns its rc.
# @param what (required) - the action, for the message
# @param paths (optional) - further paths the action writes (a destination)
# @return 0 no path is in a desk-cron checkout; 1 refused (logged)
# @example spl_refuse_desk_cron_tree do_spl_doctree_export_md || return 1
#------------------------------------------------------------------------------
spl_refuse_desk_cron_tree() {
  local what="$1" p q
  shift
  for p in "${PROJ_PATH:-}" "${APP_PATH:-}" "$@"; do
    [[ -n "$p" ]] || continue
    for q in "$p" "$(realpath -m -- "$p" 2>/dev/null)"; do
      [[ "/$q/" == */*-desk-cron/* ]] || continue
      do_log "FATAL $what writes files and refuses a desk-cron checkout: $p (the cron's self-updating worktree; a file written there blocks its next checkout). Run it from your own worktree."
      return 1
    done
  done
  return 0
}
