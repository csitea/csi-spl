#!/bin/bash
#------------------------------------------------------------------------------
# @description End (or clear) one tenant member's access at a set UTC time,
# @description THROUGH THE HUB: PATCH /v1/operator/members/<human_id>
# @description {tenant, access_until} (rdb 0113, spec 072 A27), authenticated as
# @description the env's project service account (do_gcp_pin_account, a Google
# @description id token for the hub URL; never the owner account), as
# @description do_spl_hub_invite does. At or past access_until the hub answers
# @description 403 to that member, sign-in included; the row stays listed. The
# @description hub applies the same last-owner / last-admin guards as the
# @description admin's PATCH. MEMBER_EMAIL resolves to the human id through the
# @description member list (do_spl_hub_member_list, read-only). Confirm it with
# @description do_spl_hub_member_access_check; schedule that confirmation with
# @description do_spl_hub_member_access_schedule_check. DRY_RUN=1 (default):
# @description print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param MEMBER_EMAIL - the member's email; or HUMAN_ID (e.g. HUM-4), not both
# @param ACCESS_UNTIL - required: RFC 3339 UTC (2026-10-07T06:00:00Z), or
# @param   'clear' for no end
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered it, a HUM-* id
# @param ORDERED_VIA (optional) - the agent or channel that carried the order, at most 64 chars
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<tenant> MEMBER_EMAIL=<email> ACCESS_UNTIL=2026-10-07T06:00:00Z ORDERED_BY=HUM-10 ORDERED_VIA=c-001 DRY_RUN=0 ./run -a do_spl_hub_member_access_until
#------------------------------------------------------------------------------
do_spl_hub_member_access_until() {
  do_require_bin yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  local tenant="${TENANT_ID:-}" until="${ACCESS_UNTIL:-}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" email human dry=1
  _spl_hub_member_target || return 1
  [[ "$until" == clear ]] || _spl_utc_time_ok "$until" || { do_log "FATAL ACCESS_UNTIL must be an RFC 3339 UTC time like 2026-10-07T06:00:00Z, or 'clear', got: '$until'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local what="end the access of ${human:-the member with that email} in $tenant at $until"
  [[ "$until" == clear ]] && what="clear the end of access of ${human:-the member with that email} in $tenant"
  if (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to $what (ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}), as the $SPL_PROJECT service account$([[ -n "$email" ]] && echo ', after resolving the email to a human id through the member list'). Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0"; return 1; }
  if [[ -z "$human" ]]; then
    human="$(_spl_hub_member_row "$tenant" "$email" "" | jq -r .human_id)" || return 1
    [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL the member list gave no human id for that email in $tenant"; return 1; }
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local body
  body="$(jq -cn --arg tenant "$tenant" --arg until "$until" --arg ordered_by "$ordby" --arg ordered_via "$ordvia" '
      {tenant: $tenant, access_until: (if $until == "clear" then null else $until end), ordered_by: $ordered_by}
      + (if $ordered_via != "" then {ordered_via: $ordered_via} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
  spl_hub_operator_call PATCH "/v1/operator/members/$human" "$body" || return 1
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200)
      do_log "OK $tenant member $human: access_until=$(jq -r '.access_until // "none"' <<<"$SPL_HUB_OP_BODY") access_ended=$(jq -r '.access_ended' <<<"$SPL_HUB_OP_BODY") (ordered_by=$ordby${ordvia:+ via $ordvia}, $GCP_ACCOUNT)"
      return 0 ;;
    404)
      if [[ "$SPL_HUB_OP_BODY" == *"not enabled"* ]]; then
        do_log "FATAL the hub operator route is not enabled (404) on $ENV. Nothing changed."
      elif [[ "$SPL_HUB_OP_BODY" == *"no such member"* ]]; then
        do_log "FATAL $human is not a member of $tenant (404). Nothing changed."
      else
        do_log "FATAL the hub has no PATCH /v1/operator/members route yet (404: $detail): deploy a hub with it. Nothing changed."
      fi
      return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    *) do_log "FATAL access_until of $human in $tenant not changed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
}

#------------------------------------------------------------------------------
# @description READ-ONLY: print one member's access_until and whether the
# @description access has ended (at or past access_until, as the hub's door
# @description decides), from the member list (do_spl_hub_member_list).
# @description Exit 0 when the access HAS ended, 1 when it has not (no end, or
# @description an end still ahead), 2 when the member could not be read.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param MEMBER_EMAIL - the member's email; or HUMAN_ID (e.g. HUM-4), not both
# @example ENV=prd TENANT_ID=<tenant> HUMAN_ID=HUM-4 ./run -a do_spl_hub_member_access_check
#------------------------------------------------------------------------------
do_spl_hub_member_access_check() {
  do_require_bin jq || return 2
  local tenant="${TENANT_ID:-}" email human row
  _spl_hub_member_target || return 2
  row="$(_spl_hub_member_row "$tenant" "$email" "$human")" || return 2
  jq -c '{tenant_id, human_id, role, access_until, access_ended}' <<<"$row"
  human="$(jq -r .human_id <<<"$row")"
  if [[ "$(jq -r '.access_ended' <<<"$row")" == true ]]; then
    do_log "OK the access of $human in $tenant HAS ENDED (access_until $(jq -r .access_until <<<"$row")): the hub refuses this member (403)"
    return 0
  fi
  do_log "WARN the access of $human in $tenant has NOT ended (access_until $(jq -r '.access_until // "none"' <<<"$row"))"
  return 1
}

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

# _spl_hub_member_target: from MEMBER_EMAIL / HUMAN_ID (exactly one) and
# TENANT_ID, set the caller's locals email (lower-cased) and human.
_spl_hub_member_target() {
  spl_require_tenant_slug "$tenant" || return 1
  email="${MEMBER_EMAIL:-}" human="${HUMAN_ID:-}"
  if [[ -n "$email" && -n "$human" ]] || [[ -z "$email" && -z "$human" ]]; then
    do_log "FATAL set exactly one of MEMBER_EMAIL and HUMAN_ID"; return 1
  fi
  [[ -z "$human" || "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  [[ -z "$email" || "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL MEMBER_EMAIL is not an email"; return 1; }
  email="${email,,}"
}

# _spl_utc_time_ok <t>: t is RFC 3339 UTC to the second (…Z) and a real time.
_spl_utc_time_ok() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && date -u -d "$1" +%s >/dev/null 2>&1
}

# _spl_hub_member_row <tenant> <email> <human_id> -> the one member row of the
# member list (compact JSON) whose email (or human id) matches exactly. Fails
# when the list cannot be read or not exactly one member matches.
_spl_hub_member_row() {
  local tenant="$1" email="$2" human="$3" out rc=0 rows n match=""
  [[ -n "$email" && "$email" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] && match="$email"
  out="$(TENANT_ID="$tenant" MATCH="$match" do_spl_hub_member_list)" || rc=$?
  (( rc == 0 || rc == 2 )) || { do_log "FATAL the member list of $tenant could not be read (exit $rc)"; return 1; }
  rows="$(jq -cR --arg e "$email" --arg h "$human" 'fromjson? | select(.type == "member")
      | select(($e != "" and ((.email // "") | ascii_downcase) == $e) or ($h != "" and .human_id == $h))' <<<"$out")"
  n="$(grep -c . <<<"$rows")"
  (( n == 1 )) || { do_log "FATAL $n member(s) of $tenant match ${human:-that email}: want exactly 1"; return 1; }
  printf '%s\n' "$rows"
}
