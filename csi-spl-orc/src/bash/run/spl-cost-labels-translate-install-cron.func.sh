#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the nightly cost labels translate
# @description cron (spec 123 section 16.6.7, row L5; owner HUM-10, csitea
# @description 720fa031, msg e9f8e835 answer 3 "1D": once a night): ONE line in
# @description the AGENT user's crontab (SPOOL_AGENT_USER, else the box
# @description config's SPOOL_AGENT_USER= line, else the running user; another
# @description user's is written with sudo -n crontab -u, as SPL-4463; agy and
# @description its login live in that user's home, SPL-6346), its PATH holding
# @description that user's ~/.local/bin, running `ENV=<env> DRY_RUN=0 ./run -a
# @description do_spl_cost_labels_translate` from the main checkout, daily at
# @description cnf env.cost.labels_translate_utc (UTC, start 03:00, after the
# @description 02:00 rollup), under flock so two runs never overlap. cron reads
# @description box local time: the UTC time is turned into the box's local
# @description hour and minute at install, so a daylight saving change moves
# @description the run by an hour until the next install (check names it).
# @description Tagged `# <org>-<app>:cost-labels-translate` for prd and
# @description `# <org>-<app>:cost-labels-translate-<env>` elsewhere, matched
# @description only as the whole END of a line, so no other job is touched;
# @description idempotent. When the agent user is not the running user, the
# @description same install (and remove) also drops a line with the tag from the
# @description running user's own crontab, so the job never runs twice, and
# @description check fails while one is left there. From a linked worktree the
# @description install is refused. Dry
# @description run unless DRY_RUN=0 (prints the crontab diff). A prd install
# @description waits for the owner's go (spec 123 section 16.6.7), never from a lane.
# @param ENV - needed for install: dev or prd, baked into the line
# @param COST_LABELS_TRANSLATE_CRON_ACTION (optional) - install (default) | remove | check
# @param COST_LABELS_TRANSLATE_CRON_SCHEDULE (optional) - five cron fields, replaces the cnf time
# @param COST_LABELS_TRANSLATE_CRON_LOG_DIR (optional) - default <var>/<org>/<org>-<app>/cost-labels-translate
# @param COST_LABELS_TRANSLATE_CRONTAB (optional, tests) - the running user's crontab command, default crontab
# @param COST_LABELS_TRANSLATE_SUDO (optional, tests) - the sudo for another agent user, default sudo -n
# @param SPOOL_AGENT_USER (optional) - whose crontab; default as above
# @param COST_LABELS_TRANSLATE_ALLOW_WORKTREE (optional, tests) - 1 accepts a linked worktree
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_cost_labels_translate_install_cron
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_cost_labels_translate_install_cron
# @example ENV=dev COST_LABELS_TRANSLATE_CRON_ACTION=check ./run -a do_spl_cost_labels_translate_install_cron
#------------------------------------------------------------------------------
do_spl_cost_labels_translate_install_cron() {
  local dry="${DRY_RUN:-1}" act="${COST_LABELS_TRANSLATE_CRON_ACTION:-install}" ct="${COST_LABELS_TRANSLATE_CRONTAB:-crontab}"
  local sched="${COST_LABELS_TRANSLATE_CRON_SCHEDULE:-}" org_app tag logdir want gd cd agent act_ct ahome rc
  local sudo_="${COST_LABELS_TRANSLATE_SUDO:-sudo -n}" box_env="${SPOOL_BOX_ENV-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
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

  agent="${SPOOL_AGENT_USER:-}"
  [[ -n "$agent" || -z "$box_env" || ! -r "$box_env" ]] \
    || agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$box_env" | tail -1 | tr -d "\"'\r")"
  agent="${agent:-$(id -un)}"
  ahome="$(getent passwd "$agent" | cut -d: -f6)"
  [[ -n "$ahome" ]] || { do_log "FATAL no such agent user '$agent' (or no home)"; return 1; }
  act_ct="$ct"; [[ "$agent" == "$(id -un)" ]] || act_ct="$sudo_ crontab -u $agent"
  echo "INFO the crontab of the agent user $agent"

  if [[ "$act" == check ]]; then
    if [[ "$act_ct" != "$ct" && -n "$($ct -l 2>/dev/null | box_update_cron_tagged "$tag")" ]]; then
      do_log "FAIL a line tagged $tag is also in the running user's crontab ($(id -un)): the job runs twice; re-install"; return 1
    fi
    want="$($act_ct -l 2>/dev/null | box_update_cron_tagged "$tag")"
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
  # cron's PATH is /usr/bin:/bin; agy is in the agent user's ~/.local/bin, resolved for THAT user
  want="$sched cd $PROJ_PATH && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$ahome/.local/bin flock -n $logdir/cost-labels-translate-$ENV.lock env ENV=$ENV DRY_RUN=0 ./run -a do_spl_cost_labels_translate >> $logdir/cron-$ENV.out 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  if [[ "$dry" == 0 && -n "$want" && "$act_ct" != "$ct" && ! -d "$logdir" ]]; then
    $sudo_ -u "$agent" -- mkdir -p "$logdir" || { do_log "FATAL cannot create $logdir as $agent"; return 1; }
  fi
  cron_drop_tagged_line "$act_ct" "$tag" "$dry" "$logdir" "$want"; rc=$?
  (( rc == 1 )) && return 1
  if [[ "$act_ct" != "$ct" ]]; then
    echo "INFO the running user's crontab ($(id -un)): no line tagged $tag stays there"
    cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "" || (( $? == 2 )) || return 1
  fi
  [[ "$dry" == 1 ]] && return 0
  do_log "OK the cost labels translate cron is $([[ "$act" == install ]] && echo "installed ($sched box local, ENV=$ENV)" || echo removed) in the crontab of $agent"
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
