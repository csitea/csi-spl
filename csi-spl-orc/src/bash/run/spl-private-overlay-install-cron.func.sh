#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the private overlay's cron line
# @description for THIS box's role (spec 158 H4 + H5):
# @description   the overlay's master box (SPL_PRIVATE_MASTER_BOX, default sat):
# @description     every minute do_spl_tenant_host_reserve (a new hidden
# @description     workspace gets its placeholder, the secret and wf 40),
# @description     tagged `# <org>-<app>:tenant-host-reserve`; it needs
# @description     RESERVE_GH_TOKEN_FILE (no default), baked into the line
# @description   every other box: every 2 minutes do_spl_private_overlay_pull
# @description     from the master box, tagged `# <org>-<app>:private-overlay-pull`
# @description One line in the running user's crontab (the box owner user,
# @description whose overlay is the master copy), run from the main checkout
# @description under flock so two runs never overlap; the other role's line is
# @description dropped. Tags match only as the whole END of a line; every other
# @description line is kept. Idempotent. From a linked worktree the install is
# @description refused. Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param PRIVATE_OVERLAY_CRON_ACTION (optional) - install (default) | remove | check
# @param RESERVE_GH_TOKEN_FILE (optional) - the token file; needed to install on the master box
# @param SPL_PRIVATE_MASTER_BOX (optional) - default sat
# @param PRIVATE_OVERLAY_CRON_LOG_DIR (optional) - default <var>/<org>/<app>/private-overlay
# @param PRIVATE_OVERLAY_CRONTAB (optional, tests) - the crontab command, default crontab
# @param PRIVATE_OVERLAY_ALLOW_WORKTREE (optional, tests) - 1 accepts a linked worktree
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_private_overlay_install_cron
# @example RESERVE_GH_TOKEN_FILE=<token file> DRY_RUN=0 ./run -a do_spl_private_overlay_install_cron
# @example PRIVATE_OVERLAY_CRON_ACTION=check ./run -a do_spl_private_overlay_install_cron
#------------------------------------------------------------------------------
do_spl_private_overlay_install_cron() {
  local dry="${DRY_RUN:-1}" act="${PRIVATE_OVERLAY_CRON_ACTION:-install}" ct="${PRIVATE_OVERLAY_CRONTAB:-crontab}"
  local master="${SPL_PRIVATE_MASTER_BOX:-sat}" here org_app tag other logdir want="" line
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove|check) ;; *) do_log "FATAL PRIVATE_OVERLAY_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$master" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL SPL_PRIVATE_MASTER_BOX must be a box id, got: '$master'"; return 1; }
  here="$(spl_desk_box_default)"
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  if [[ "$here" == "$master" ]]; then tag="$org_app:tenant-host-reserve"; other="$org_app:private-overlay-pull"
  else tag="$org_app:private-overlay-pull"; other="$org_app:tenant-host-reserve"; fi
  logdir="${PRIVATE_OVERLAY_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir private-overlay || { do_log "FATAL cannot derive the cron log dir (no tree for spl_run_paths): set PRIVATE_OVERLAY_CRON_LOG_DIR"; return 1; }
  fi

  if [[ "$act" == check ]]; then
    line="$($ct -l 2>/dev/null | box_update_cron_tagged "$tag")"
    [[ -n "$line" ]] || { do_log "FAIL box $here: no cron line tagged $tag ($([[ "$here" == "$master" ]] && echo 'no new hidden workspace gets its placeholder' || echo 'the private overlay is not pulled'))"; return 1; }
    echo "$line"
    [[ -z "$($ct -l 2>/dev/null | box_update_cron_tagged "$other")" ]] || { do_log "FAIL box $here also carries the $other line (the other role's)"; return 1; }
    do_log "OK box $here: the $tag cron is installed"; return 0
  fi
  if [[ "$act" == install ]]; then
    spl_poc_worktree_ok "$dry" || return 1
    want="$(spl_poc_line "$here" "$master" "$tag" "$logdir")" || return 1
  fi
  cron_drop_tagged_line "$ct" "$other" "$dry" "$logdir" ""
  (( $? == 1 )) && return 1
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK box $here: the $tag cron is $([[ "$act" == install ]] && echo installed || echo removed)"
}

# spl_poc_worktree_ok <dry>: refuse an install from a linked worktree (its
# path vanishes with it); a dry run only warns
spl_poc_worktree_ok() {
  local gd cd
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [[ -n "$gd" && "$gd" != "$cd" && "${PRIVATE_OVERLAY_ALLOW_WORKTREE:-0}" != 1 ]] || return 0
  [[ "$1" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
  echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
}

# spl_poc_line <here> <master> <tag> <logdir> -> the cron line of this box's role
spl_poc_line() {
  local here="$1" master="$2" tag="$3" logdir="$4" tf
  # cron's PATH is /usr/bin:/bin; $HOME is expanded by the job's shell
  local pre="cd $PROJ_PATH && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n"
  if [[ "$here" != "$master" ]]; then
    printf '%s\n' "*/2 * * * * $pre $logdir/pull.lock env DRY_RUN=0 FROM_BOX=$master ./run -a do_spl_private_overlay_pull >> $logdir/pull.out 2>&1 # $tag"
    return 0
  fi
  tf="$(spl_thr_token_file)" || return 1
  [[ "$tf" == /* && "$tf" =~ ^[A-Za-z0-9/._-]+$ ]] || { do_log "FATAL RESERVE_GH_TOKEN_FILE must be an absolute path of letters, digits and /._- (it goes into the cron line), got: '$tf'" >&2; return 1; }
  printf '%s\n' "* * * * * $pre $logdir/reserve.lock env RESERVE_GH_TOKEN_FILE=$tf DRY_RUN=0 ./run -a do_spl_tenant_host_reserve >> $logdir/reserve.out 2>&1 # $tag"
}
