#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the shadow feed's cron line: ONE line in the
# @description running user's crontab, every SHADOW_FEED_EVERY minutes, running
# @description do_spl_shadow_feed under flock and appending to
# @description ~/.cache/csi-spl/shadow-feed.log. Install it as the user that
# @description owns the feed dir and NOT as the shadow seat's user: the mirror
# @description is then read-only to the seat (files 0444, dirs 0755). Tagged
# @description `# csi-spl:shadow-feed`, matched only as the whole END of a
# @description line, so no other job is touched; idempotent. From a linked
# @description worktree the install is refused (its path vanishes with it).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param SHADOW_FEED_CRON_ACTION (optional) - install (default) | remove
# @param SHADOW_FEED_EVERY (optional) - 1..59 minutes, default 5
# @param SHADOW_FEED_DIR, SHADOW_FEED_AGENTS, SHADOW_FEED_REMOTES, SHADOW_FEED_REMOTE_RSYNC (optional) - written into the line when set
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_shadow_feed_install_cron
# @example DRY_RUN=0 SHADOW_FEED_REMOTES="box-b=box-b.example.net" ./run -a do_spl_shadow_feed_install_cron
# @example DRY_RUN=0 SHADOW_FEED_CRON_ACTION=remove ./run -a do_spl_shadow_feed_install_cron
#------------------------------------------------------------------------------
do_spl_shadow_feed_install_cron() {
  local dry="${DRY_RUN:-1}" act="${SHADOW_FEED_CRON_ACTION:-install}" every="${SHADOW_FEED_EVERY:-5}"
  local ct="${SHADOW_FEED_CRONTAB:-crontab}" logdir="${SHADOW_FEED_LOG_DIR:-$HOME/.cache/csi-spl}"
  local tag="csi-spl:shadow-feed" want gd cd envs="" v
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL SHADOW_FEED_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL SHADOW_FEED_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  for v in SHADOW_FEED_DIR SHADOW_FEED_AGENTS SHADOW_FEED_REMOTES SHADOW_FEED_REMOTE_RSYNC; do
    [[ -z "${!v:-}" ]] && continue
    [[ "${!v}" =~ ^[A-Za-z0-9_./:=@\ -]+$ ]] || { do_log "FATAL $v carries a character a cron line cannot hold: '${!v}'"; return 1; }
    envs+=" $v='${!v}'"
  done
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${SHADOW_FEED_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="*/$every * * * * cd $PROJ_PATH && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $logdir/shadow-feed.lock env$envs ./run -a do_spl_shadow_feed >> $logdir/shadow-feed.log 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the shadow feed cron is $([[ "$act" == install ]] && echo "installed (every ${every}m)" || echo removed)"
}
