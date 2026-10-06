#!/bin/bash
#------------------------------------------------------------------------------
# @description Schedule ONE run of do_spl_hub_member_access_check at a UTC
# @description time, whose verdict is sent through the spool (spool-send.sh) to
# @description REPORT_TO on REPORT_TASK: kind result when the access has ended,
# @description blocker otherwise. A transient systemd timer (systemd-run
# @description --on-calendar, via sudo, run as the calling user); no crontab.
# @description The timer carries the human id, never the email: an email is
# @description resolved through the member list when it is scheduled. It runs
# @description this tree's ./run, so schedule it from a checkout that will
# @description still exist then (not a lane worktree). CHECK_AT=now is what
# @description the timer runs: check and report here, at once. DRY_RUN=1
# @description (default): print the schedule (or, for now, the report), send
# @description and schedule nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param MEMBER_EMAIL - the member's email; or HUMAN_ID (e.g. HUM-4), not both
# @param CHECK_AT - required: RFC 3339 UTC, in the future; or 'now'
# @param REPORT_FROM - required: the spool id that sends the report
# @param REPORT_TO - required: the spool id that gets it
# @param REPORT_TASK - required: the topic (task_id) of the report
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<tenant> HUMAN_ID=HUM-4 CHECK_AT=2026-10-07T06:05:00Z REPORT_FROM=c-001 REPORT_TO=c-001 REPORT_TASK=<task-id> DRY_RUN=0 ./run -a do_spl_hub_member_access_schedule_check
#------------------------------------------------------------------------------
do_spl_hub_member_access_schedule_check() {
  do_require_bin jq || return 1
  local tenant="${TENANT_ID:-}" at="${CHECK_AT:-}" from="${REPORT_FROM:-}" to="${REPORT_TO:-}" task="${REPORT_TASK:-}" email human dry=1
  _spl_hub_member_target || return 1
  [[ "$at" == now ]] || _spl_utc_time_ok "$at" || { do_log "FATAL CHECK_AT must be an RFC 3339 UTC time like 2026-10-07T06:05:00Z, or 'now', got: '$at'"; return 1; }
  local id
  for id in "$from" "$to"; do
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$ ]] || { do_log "FATAL REPORT_FROM and REPORT_TO must be spool ids, got: '$from' / '$to'"; return 1; }
  done
  [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { do_log "FATAL REPORT_TASK must be a task id (uuid), got: '$task'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local send="${SPL_SPOOL_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  if [[ "$at" == now ]]; then
    local out rc=0 kind=result verdict
    out="$(do_spl_hub_member_access_check 2>&1)" || rc=$?
    case $rc in
      0) verdict="ACCESS ENDED: the hub refuses this member (403). Removal confirmed." ;;
      1) kind=blocker; verdict="ACCESS NOT ENDED: the member still has access. Act now." ;;
      *) kind=blocker; verdict="CHECK FAILED: the member could not be read (exit $rc)." ;;
    esac
    local body
    body="$(printf '**Scheduled access check** ENV=%s TENANT=%s %s\n\n%s\n\n%s\n' "$ENV" "$tenant" "${human:-}" "$verdict" \
      "$(grep -E '^\{|^(OK|WARN|FATAL|FAIL) ' <<<"$out" | grep -viE '[^[:space:]]+@[^[:space:]]+\.[a-z]' | sed 's/^/    /')")"
    if (( dry )); then
      do_log "OK DRY_RUN would send $to (task $task, kind $kind, from $from):"
      printf '%s\n' "$body"
      return 0
    fi
    [[ -x "$send" ]] || { do_log "FATAL no spool-send.sh at $send"; return 1; }
    "$send" --from "$from" --to "$to" --kind "$kind" --task "$task" --body "$body" || { do_log "FATAL the report did not reach $to"; return 1; }
    do_log "OK sent the access check of ${human:-the member} in $tenant to $to (kind $kind)"
    return 0
  fi
  local epoch now
  epoch="$(date -u -d "$at" +%s)" && now="$(date -u +%s)" || return 1
  (( epoch > now + 30 )) || { do_log "FATAL CHECK_AT $at is not in the future (a transient timer never fires for a past time)"; return 1; }
  if [[ "$PROJ_PATH" == *-wt/* ]]; then
    do_log "WARN $PROJ_PATH is a lane worktree: the timer runs this tree's ./run, so it must still exist at $at"
  fi
  local unit cal user
  user="$(id -un)"
  cal="$(date -u -d "$at" '+%Y-%m-%d %H:%M:%S') UTC"
  if [[ -z "$human" ]] && (( ! dry )); then
    human="$(_spl_hub_member_row "$tenant" "$email" "" | jq -r .human_id)" || return 1
    [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL the member list gave no human id for that email in $tenant"; return 1; }
  fi
  unit="spl-access-check-$ENV-$tenant-${human:-HUM-x}-$epoch"
  local -a cmd=(sudo -n systemd-run --unit="$unit" --on-calendar="$cal" --timer-property=AccuracySec=1s
    --uid="$user" --working-directory="$PROJ_PATH"
    --setenv=HOME="$HOME" --setenv=PATH="$PATH" --setenv=SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
    --setenv=ENV="$ENV" --setenv=TENANT_ID="$tenant" --setenv=HUMAN_ID="${human:-<resolved from the email>}"
    --setenv=CHECK_AT=now --setenv=REPORT_FROM="$from" --setenv=REPORT_TO="$to" --setenv=REPORT_TASK="$task"
    --setenv=DRY_RUN=0 "$PROJ_PATH/run" -a do_spl_hub_member_access_schedule_check)
  if (( dry )); then
    do_log "OK DRY_RUN would schedule, as $user, at $cal, then report to $to on $task:"
    printf '%q ' "${cmd[@]}"; echo
    return 0
  fi
  "${cmd[@]}" || { do_log "FATAL systemd-run could not schedule $unit"; return 1; }
  do_log "OK scheduled $unit at $cal (as $user): it reports to $to on $task. See: systemctl list-timers $unit.timer; journalctl -u $unit.service"
}
