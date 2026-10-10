#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the nightly cost rollup cron
# @description (spec 123 section 4.5, build lane 4): ONE line in the box
# @description user's crontab running `ENV=<env> DRY_RUN=0 ./run -a
# @description do_spl_cost_rollup_daily` from the main checkout, daily at cnf
# @description env.cost.rollup_utc (UTC, start 02:00), under flock so two runs
# @description never overlap. cron reads box local time: the UTC time is
# @description turned into the box's local hour and minute at install, so a
# @description daylight saving change moves the run by an hour until the next
# @description install (check names it); the rollup always reads the previous
# @description UTC day. Tagged `# <org>-<app>:cost-rollup` for prd and
# @description `# <org>-<app>:cost-rollup-<env>` elsewhere, matched only as the
# @description whole END of a line, so no other job is touched; idempotent.
# @description From a linked worktree the install is refused. Dry run unless
# @description DRY_RUN=0 (prints the crontab diff). A prd install is the
# @description operator's (the brief of spec 123 lane 4: never from a lane).
# @param ENV - required for install: dev or prd, baked into the line
# @param COST_ROLLUP_CRON_ACTION (optional) - install (default) | remove | check
# @param COST_ROLLUP_CRON_SCHEDULE (optional) - five cron fields, replaces the cnf time
# @param COST_ROLLUP_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/cost-rollup
# @param COST_ROLLUP_CRONTAB (optional, tests) - the crontab command, default crontab
# @param COST_ROLLUP_ALLOW_WORKTREE (optional, tests) - 1 accepts a linked worktree
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_cost_rollup_install_cron
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_cost_rollup_install_cron
# @example ENV=prd COST_ROLLUP_CRON_ACTION=check ./run -a do_spl_cost_rollup_install_cron
#------------------------------------------------------------------------------
do_spl_cost_rollup_install_cron() {
  local dry="${DRY_RUN:-1}" act="${COST_ROLLUP_CRON_ACTION:-install}" ct="${COST_ROLLUP_CRONTAB:-crontab}"
  local sched="${COST_ROLLUP_CRON_SCHEDULE:-}" org_app tag logdir want gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove|check) ;; *) do_log "FATAL COST_ROLLUP_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  spl_require_cloud_env || return 1
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  tag="$org_app:cost-rollup$([[ "$ENV" == prd ]] || printf -- '-%s' "$ENV")"
  logdir="${COST_ROLLUP_CRON_LOG_DIR:-/var/${org_app%%-*}/$org_app/cost-rollup}"

  if [[ "$act" == check ]]; then
    want="$($ct -l 2>/dev/null | box_update_cron_tagged "$tag")"
    [[ -n "$want" ]] || { do_log "FAIL the cost rollup cron is NOT installed (no line tagged $tag): no day is rolled up"; return 1; }
    echo "$want"
    sched="$(spl_cost_rollup_cron_schedule)" || { printf '%s\n' "$sched"; return 1; }
    [[ "$want" == "$sched "* ]] || do_log "INFO the installed time is not the cnf time now ($sched): a daylight saving change or a new cnf; re-install"
    do_log "OK the cost rollup cron is installed"; return 0
  fi
  if [[ "$act" == install ]]; then
    gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
    cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ -n "$gd" && "$gd" != "$cd" && "${COST_ROLLUP_ALLOW_WORKTREE:-0}" != 1 ]]; then
      [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
      echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
    fi
    [[ -n "$sched" ]] || sched="$(spl_cost_rollup_cron_schedule)" || { printf '%s\n' "$sched"; return 1; }
    [[ "$sched" =~ ^[0-9*,/-]+( [0-9*,/-]+){4}$ ]] || { do_log "FATAL COST_ROLLUP_CRON_SCHEDULE must be five cron fields, got: '$sched'"; return 1; }
  fi
  # cron's PATH is /usr/bin:/bin; $HOME is expanded by the job's shell
  want="$sched cd $PROJ_PATH && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $logdir/cost-rollup-$ENV.lock env ENV=$ENV DRY_RUN=0 ./run -a do_spl_cost_rollup_daily >> $logdir/cron-$ENV.out 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the cost rollup cron is $([[ "$act" == install ]] && echo "installed ($sched box local, ENV=$ENV)" || echo removed)"
}

# spl_cost_rollup_cron_schedule: the five cron fields of cnf env.cost.rollup_utc
# (HH:MM, UTC) in the box's local time, today.
spl_cost_rollup_cron_schedule() {
  local utc
  do_spl_cloud_cnf || return 1
  utc="$(yq -r '.env.cost.rollup_utc // ""' "$SPL_CNF")"
  [[ "$utc" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { do_log "FATAL env.cost.rollup_utc must be HH:MM (UTC), got: '$utc'"; return 1; }
  date -d "$(date -u +%F) $utc UTC" '+%-M %-H * * *'
}
