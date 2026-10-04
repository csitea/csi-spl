#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the box update cron (owner
# @description 2026-10-04: the latest version "at least once in 12h"): ONE
# @description line in the box user's crontab running
# @description `ENV=<env> DRY_RUN=0 ./run -a do_spl_box_update` from the main
# @description checkout at BOX_UPDATE_CRON_SCHEDULE, default `0 0,12 * * *`
# @description (box local time: 00:00 and 12:00), under flock so two runs
# @description never overlap. Tagged `# <org>-<app>:box-update`, matched only
# @description as the whole END of a line, so no other job is touched;
# @description idempotent (the tagged line is replaced in place). From a
# @description linked worktree the install is refused (its path vanishes with
# @description it). do_spl_box_deploy installs it on every box.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param ENV - required for install: dev or prd, baked into the line
# @param BOX_UPDATE_CRON_ACTION (optional) - install (default) | remove | check
# @param BOX_UPDATE_CRON_SCHEDULE (optional) - five cron fields, default "0 0,12 * * *"
# @param BOX_UPDATE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/box-update
# @param BOX_UPDATE_CRONTAB (optional, tests) - the crontab command, default crontab
# @param BOX_UPDATE_ALLOW_WORKTREE (optional, tests) - 1 accepts a linked worktree
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_box_update_install_cron
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_box_update_install_cron
# @example BOX_UPDATE_CRON_ACTION=check ./run -a do_spl_box_update_install_cron
#------------------------------------------------------------------------------
do_spl_box_update_install_cron() {
  local dry="${DRY_RUN:-1}" act="${BOX_UPDATE_CRON_ACTION:-install}" ct="${BOX_UPDATE_CRONTAB:-crontab}"
  local sched="${BOX_UPDATE_CRON_SCHEDULE:-0 0,12 * * *}" org_app tag logdir want before after gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove|check) ;; *) do_log "FATAL BOX_UPDATE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$sched" =~ ^[0-9*,/-]+( [0-9*,/-]+){4}$ ]] || { do_log "FATAL BOX_UPDATE_CRON_SCHEDULE must be five cron fields, got: '$sched'"; return 1; }
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  tag="$org_app:box-update"
  logdir="${BOX_UPDATE_CRON_LOG_DIR:-/var/${org_app%%-*}/$org_app/box-update}"

  if [[ "$act" == check ]]; then
    want="$($ct -l 2>/dev/null | box_update_cron_tagged "$tag")"
    [[ -n "$want" ]] || { do_log "FAIL the box update cron is NOT installed (no line tagged $tag)"; return 1; }
    echo "$want"; do_log "OK the box update cron is installed"; return 0
  fi
  if [[ "$act" == install ]]; then
    [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
    gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
    cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ -n "$gd" && "$gd" != "$cd" && "${BOX_UPDATE_ALLOW_WORKTREE:-0}" != 1 ]]; then
      [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
      echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
    fi
  fi
  # cron's PATH is /usr/bin:/bin; $HOME is expanded by the job's shell
  want="$sched cd $PROJ_PATH && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $logdir/box-update.lock env ENV=${ENV:-} DRY_RUN=0 ./run -a do_spl_box_update >> $logdir/cron.out 2>&1 # $tag"
  before="$(mktemp)"; after="$(mktemp)"
  $ct -l 2>/dev/null >"$before"
  awk -v suf=" # $tag" '{ l = length($0); s = length(suf); if (l >= s && substr($0, l - s + 1) == suf) next; print }' "$before" >"$after"
  [[ "$act" == install ]] && printf '%s\n' "$want" >>"$after"
  if cmp -s "$before" "$after"; then
    echo "OK cron: nothing to change"; rm -f "$before" "$after"; return 0
  fi
  echo "$([[ "$dry" == 1 ]] && echo PLAN || echo DO) cron: the crontab before -> after"
  diff -u --label before --label after "$before" "$after" | sed 's/^/  /'
  if [[ "$dry" == 1 ]]; then
    rm -f "$before" "$after"; do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  if [[ "$act" == install ]] && ! mkdir -p "$logdir"; then
    rm -f "$before" "$after"; do_log "FATAL cannot create $logdir (the log dir)"; return 1
  fi
  $ct "$after" || { rm -f "$before" "$after"; do_log "FATAL crontab refused the new file"; return 1; }
  rm -f "$before" "$after"
  do_log "OK the box update cron is $([[ "$act" == install ]] && echo "installed ($sched, ENV=$ENV)" || echo removed)"
}

# box_update_cron_tagged <tag>: the stdin lines ending in " # <tag>"
box_update_cron_tagged() {
  awk -v suf=" # $1" '{ l = length($0); s = length(suf); if (l >= s && substr($0, l - s + 1) == suf) print }'
}
