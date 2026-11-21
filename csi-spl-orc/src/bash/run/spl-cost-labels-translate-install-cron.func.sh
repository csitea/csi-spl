#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the nightly cost labels translate
# @description cron (spec 123 section 16.6.7, row L5; owner HUM-10, csitea
# @description 720fa031, msg e9f8e835 answer 3 "1D": once a night): ONE line in
# @description the box user's crontab running `ENV=<env> DRY_RUN=0 ./run -a
# @description do_spl_cost_labels_translate` from the main checkout, daily at
# @description cnf env.cost.labels_translate_utc (UTC, start 03:00, after the
# @description 02:00 rollup), under flock so two runs never overlap. cron reads
# @description box local time: the UTC time is turned into the box's local
# @description hour and minute at install, so a daylight saving change moves
# @description the run by an hour until the next install (check names it).
# @description Tagged `# <org>-<app>:cost-labels-translate` for prd and
# @description `# <org>-<app>:cost-labels-translate-<env>` elsewhere, matched
# @description only as the whole END of a line, so no other job is touched;
# @description idempotent. From a linked worktree the install is refused. Dry
# @description run unless DRY_RUN=0 (prints the crontab diff). A prd install
# @description waits for the owner's go (spec 123 section 16.6.7), never from a lane.
# @param ENV - needed for install: dev or prd, baked into the line
# @param COST_LABELS_TRANSLATE_CRON_ACTION (optional) - install (default) | remove | check
# @param COST_LABELS_TRANSLATE_CRON_SCHEDULE (optional) - five cron fields, replaces the cnf time
# @param COST_LABELS_TRANSLATE_CRON_LOG_DIR (optional) - default <var>/<org>/<org>-<app>/cost-labels-translate
# @param COST_LABELS_TRANSLATE_CRONTAB (optional, tests) - the crontab command, default crontab
# @param COST_LABELS_TRANSLATE_ALLOW_WORKTREE (optional, tests) - 1 accepts a linked worktree
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_cost_labels_translate_install_cron
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_cost_labels_translate_install_cron
# @example ENV=dev COST_LABELS_TRANSLATE_CRON_ACTION=check ./run -a do_spl_cost_labels_translate_install_cron
#------------------------------------------------------------------------------
do_spl_cost_labels_translate_install_cron() {
  local dry="${DRY_RUN:-1}" act="${COST_LABELS_TRANSLATE_CRON_ACTION:-install}" ct="${COST_LABELS_TRANSLATE_CRONTAB:-crontab}"
  local sched="${COST_LABELS_TRANSLATE_CRON_SCHEDULE:-}" org_app tag logdir want gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove|check) ;; *) do_log "FATAL COST_LABELS_TRANSLATE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  spl_require_cloud_env || return 1
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  tag="$org_app:cost-labels-translate$([[ "$ENV" == prd ]] || printf -- '-%s' "$ENV")"
  logdir="${COST_LABELS_TRANSLATE_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir cost-labels-translate || { do_log "FATAL cannot derive the cost labels translate cron log dir (no tree for spl_run_paths): set COST_LABELS_TRANSLATE_CRON_LOG_DIR"; return 1; }
  fi

  if [[ "$act" == check ]]; then
    want="$($ct -l 2>/dev/null | box_update_cron_tagged "$tag")"
    [[ -n "$want" ]] || { do_log "FAIL the cost labels translate cron is NOT installed (no line tagged $tag): no night review of the machine drafts"; return 1; }
    echo "$want"
    sched="$(spl_cost_labels_translate_cron_schedule)" || { printf '%s\n' "$sched"; return 1; }
    [[ "$want" == "$sched "* ]] || do_log "INFO the installed time is not the cnf time now ($sched): a daylight saving change or a new cnf; re-install"
    do_log "OK the cost labels translate cron is installed, schedule '${want%% cd *}' box local (the cnf time is '$sched')"; return 0
  fi
  if [[ "$act" == install ]]; then
    gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
    cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ -n "$gd" && "$gd" != "$cd" && "${COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0}" != 1 ]]; then
      [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
      echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
    fi
    [[ -n "$sched" ]] || sched="$(spl_cost_labels_translate_cron_schedule)" || { printf '%s\n' "$sched"; return 1; }
    [[ "$sched" =~ ^[0-9*,/-]+( [0-9*,/-]+){4}$ ]] || { do_log "FATAL COST_LABELS_TRANSLATE_CRON_SCHEDULE must be five cron fields, got: '$sched'"; return 1; }
  fi
  # cron's PATH is /usr/bin:/bin; $HOME is expanded by the job's shell (agy is in ~/.local/bin)
  want="$sched cd $PROJ_PATH && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $logdir/cost-labels-translate-$ENV.lock env ENV=$ENV DRY_RUN=0 ./run -a do_spl_cost_labels_translate >> $logdir/cron-$ENV.out 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the cost labels translate cron is $([[ "$act" == install ]] && echo "installed ($sched box local, ENV=$ENV)" || echo removed)"
}

# spl_cost_labels_translate_cron_schedule: the five cron fields of cnf
# env.cost.labels_translate_utc (HH:MM, UTC) in the box's local time, today.
spl_cost_labels_translate_cron_schedule() {
  local utc
  do_spl_cloud_cnf || return 1
  utc="$(yq -r '.env.cost.labels_translate_utc // ""' "$SPL_CNF")"
  [[ "$utc" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { do_log "FATAL env.cost.labels_translate_utc must be HH:MM (UTC), got: '$utc'"; return 1; }
  date -d "$(date -u +%F) $utc UTC" '+%-M %-H * * *'
}
