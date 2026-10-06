#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the weekly docker prune's cron line: ONE
# @description line in the running user's crontab (the box user, who is in the
# @description docker group), on weekday PRUNE_CRON_DOW at PRUNE_CRON_HOUR:
# @description PRUNE_CRON_MINUTE, running prune-docker-images.sh with
# @description DRY_RUN=PRUNE_CRON_DRY_RUN and appending to
# @description /var/csi/csi-spl/docker-prune/cron.out. Tagged
# @description `# csi-spl:docker-prune`, matched only as the whole END of a
# @description line, so no other job is touched; idempotent (the line is
# @description replaced in place). From a linked worktree the install is
# @description refused (its path vanishes with it).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param PRUNE_CRON_ACTION (optional) - install (default) | remove
# @param PRUNE_CRON_DOW (optional) - 0..7, default 0 (Sunday)
# @param PRUNE_CRON_HOUR (optional) - 0..23, default 4
# @param PRUNE_CRON_MINUTE (optional) - 0..59, default 23
# @param PRUNE_CRON_DRY_RUN (optional) - the line's DRY_RUN: 0 (default) or 1
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_prune_docker_images_install_cron
# @example DRY_RUN=0 ./run -a do_prune_docker_images_install_cron
# @example DRY_RUN=0 PRUNE_CRON_ACTION=remove ./run -a do_prune_docker_images_install_cron
#------------------------------------------------------------------------------
do_prune_docker_images_install_cron() {
  local dry="${DRY_RUN:-1}" act="${PRUNE_CRON_ACTION:-install}" live="${PRUNE_CRON_DRY_RUN:-0}"
  local dow="${PRUNE_CRON_DOW:-0}" hour="${PRUNE_CRON_HOUR:-4}" min="${PRUNE_CRON_MINUTE:-23}"
  local ct="${PRUNE_CRONTAB:-crontab}" logdir="${PRUNE_CRON_LOG_DIR:-/var/csi/csi-spl/docker-prune}"
  local tag="csi-spl:docker-prune" script before after want gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$live" == 0 || "$live" == 1 ]] || { do_log "FATAL PRUNE_CRON_DRY_RUN must be 0 or 1, got: '$live'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL PRUNE_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$dow" =~ ^[0-7]$ ]] || { do_log "FATAL PRUNE_CRON_DOW must be 0..7, got: '$dow'"; return 1; }
  [[ "$hour" =~ ^[0-9]+$ ]] && (( hour <= 23 )) || { do_log "FATAL PRUNE_CRON_HOUR must be 0..23, got: '$hour'"; return 1; }
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL PRUNE_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  script="$PROJ_PATH/src/bash/scripts/prune-docker-images.sh"
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${PRUNE_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="$min $hour * * $dow PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin SPOOL_ROOT=/var/spool-hub DRY_RUN=$live bash $script >> $logdir/cron.out 2>&1 # $tag"
  before="$(mktemp)"; after="$(mktemp)"
  $ct -l 2>/dev/null >"$before" || true
  awk -v suf=" # $tag" '{ l = length($0); s = length(suf); if (l >= s && substr($0, l - s + 1) == suf) next; print }' "$before" >"$after"
  [[ "$act" == install ]] && printf '%s\n' "$want" >>"$after"
  if cmp -s "$before" "$after"; then
    echo "OK cron: nothing to change"; rm -f "$before" "$after"; return 0
  fi
  echo "$([[ "$dry" == 1 ]] && echo PLAN || echo DO) cron: the crontab before -> after"
  diff -u --label before --label after "$before" "$after" | sed 's/^/  /' || true
  if [[ "$dry" == 1 ]]; then
    rm -f "$before" "$after"; do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  if [[ "$act" == install ]] && ! mkdir -p "$logdir"; then
    rm -f "$before" "$after"; do_log "FATAL cannot create $logdir (the log dir)"; return 1
  fi
  $ct "$after" || { rm -f "$before" "$after"; do_log "FATAL crontab refused the new file"; return 1; }
  rm -f "$before" "$after"
  do_log "OK the docker prune cron is $([[ "$act" == install ]] && echo "installed (DRY_RUN=$live, weekday $dow at $hour:$(printf %02d "$min"))" || echo removed)"
}
