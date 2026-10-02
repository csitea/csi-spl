#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the /tmp scratch sweep's cron line: ONE
# @description line in the running user's crontab (the agent user, <HARNESS_USER>),
# @description at minute SCRATCH_CRON_MINUTE of every hour, running
# @description tmp-scratch-sweep.sh with DRY_RUN=SCRATCH_CRON_DRY_RUN and
# @description appending to ~/.cache/csi-spl/tmp-scratch-sweep.log. Tagged
# @description `# csi-spl:tmp-scratch-sweep`, matched only as the whole END of
# @description a line, so no other job is touched; idempotent (the line is
# @description replaced in place). From a linked worktree the install is
# @description refused (its path vanishes with it).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param SCRATCH_CRON_ACTION (optional) - install (default) | remove
# @param SCRATCH_CRON_MINUTE (optional) - 0..59, default 17
# @param SCRATCH_CRON_DRY_RUN (optional) - the line's DRY_RUN: 0 (default) or 1
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_tmp_scratch_sweep_install_cron
# @example DRY_RUN=0 ./run -a do_tmp_scratch_sweep_install_cron
# @example DRY_RUN=0 SCRATCH_CRON_ACTION=remove ./run -a do_tmp_scratch_sweep_install_cron
#------------------------------------------------------------------------------
do_tmp_scratch_sweep_install_cron() {
  local dry="${DRY_RUN:-1}" act="${SCRATCH_CRON_ACTION:-install}" min="${SCRATCH_CRON_MINUTE:-17}"
  local live="${SCRATCH_CRON_DRY_RUN:-0}" ct="${SCRATCH_CRONTAB:-crontab}"
  local logdir="${SCRATCH_CRON_LOG_DIR:-$HOME/.cache/csi-spl}"
  local tag="csi-spl:tmp-scratch-sweep" script before after want gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$live" == 0 || "$live" == 1 ]] || { do_log "FATAL SCRATCH_CRON_DRY_RUN must be 0 or 1, got: '$live'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL SCRATCH_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL SCRATCH_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  script="$PROJ_PATH/src/bash/scripts/tmp-scratch-sweep.sh"
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${SCRATCH_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="$min * * * * DRY_RUN=$live bash $script >> $logdir/tmp-scratch-sweep.log 2>&1 # $tag"
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
  do_log "OK the scratch sweep cron is $([[ "$act" == install ]] && echo "installed (DRY_RUN=$live, hourly at :$min)" || echo removed)"
}
