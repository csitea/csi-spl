#!/bin/bash
#------------------------------------------------------------------------------
# @description Change one event of one workspace's calendar, AS AN AGENT,
# @description THROUGH THE HUB: PATCH /v1/operator/calendar/events/<id> with
# @description only the fields given (calendar_operator_write.go, SPL-5720):
# @description title, description, the day or the times, reminders. A private
# @description event is reached only when an agent made it for ORDERED_BY (a
# @description member named in its mentions); a private event the person made,
# @description or one made for another person, is 404. The event is read back
# @description (GET ?ordered_by=) and every field sent must read back as sent.
# @description Google Calendar follows the hub row (spec 097 section 4.10).
# @description DRY_RUN=1 (default): print the request, call no cloud, write nothing.
# @param ENV (required) - dev or prd
# @param TENANT_ID (required) - the workspace slug
# @param EVENT_ID (required) - the event id (uuid)
# @param AGENT_ID (required) - the agent doing it, e.g. c-042
# @param ORDERED_BY (optional) - the human who ordered it, a HUM-* id; a private
# @param   event needs it: the member it was made for
# @param TITLE (optional) - the new title (1..200 characters); unset leaves it
# @param DESCRIPTION (optional) - the new text; set and empty clears it; unset leaves it
# @param DAY (optional) - move it to a whole day, YYYY-MM-DD; not with STARTS_AT / ENDS_AT
# @param STARTS_AT, ENDS_AT (optional) - move it to a timed slot, both RFC 3339 UTC (2026-10-12T09:00:00Z)
# @param REMINDERS (optional) - as do_spl_calendar_event_add takes them (15m,1h,1d);
# @param   set and empty clears them; unset leaves them
# @param AUDIENCE (optional) - private only (SPL-5963, owner msg eac307d4): makes an agent's entry
# @param   made for ORDERED_BY (its owner, required) private to that person; nothing widens one
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<tenant> EVENT_ID=<uuid> AGENT_ID=c-042 ORDERED_BY=HUM-10 AUDIENCE=private ./run -a do_spl_calendar_event_update
# @example ENV=prd TENANT_ID=<tenant> EVENT_ID=<uuid> AGENT_ID=c-042 ORDERED_BY=HUM-10 REMINDERS=15m ./run -a do_spl_calendar_event_update
# @example ENV=dev TENANT_ID=<tenant> EVENT_ID=<uuid> AGENT_ID=c-042 ORDERED_BY=HUM-10 TITLE='Call' DAY=2026-11-20 DRY_RUN=0 ./run -a do_spl_calendar_event_update
#------------------------------------------------------------------------------
do_spl_calendar_event_update() {
  do_require_bin jq curl gcloud || return 1
  local body dry=1
  _spl_calendar_update_body || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  local path="/v1/operator/calendar/events/$EVENT_ID"
  if (( dry )); then
    printf 'PATCH %s %s\n' "$path" "$body"
    do_log "OK DRY_RUN would PATCH $path through $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account, the body above; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call PATCH "$path" "$body" || return 1
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200) ;;
    404) do_log "FATAL event $EVENT_ID is not one the operator reaches (404: $detail): a private event needs ORDERED_BY = the member an agent made it for; a person's own private event stays theirs. Nothing written."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator call ($SPL_HUB_OP_STATUS): $detail. Is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing written."; return 1 ;;
    *) do_log "FATAL event $EVENT_ID was not changed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
  spl_hub_operator_call GET "$path?tenant=$TENANT_ID${ORDERED_BY:+&ordered_by=$ORDERED_BY}" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { do_log "FATAL event $EVENT_ID was changed but its read-back answered http $SPL_HUB_OP_STATUS: $SPL_HUB_OP_BODY"; return 1; }
  local off
  off="$(_spl_calendar_update_mismatch "$body" "$SPL_HUB_OP_BODY")"
  [[ -z "$off" ]] || { do_log "FATAL event $EVENT_ID read back with $off not as sent: $SPL_HUB_OP_BODY"; return 1; }
  local link
  link="$(_spl_calendar_event_link "$TENANT_ID" "$(jq -r '.event.starts_at // ""' <<<"$SPL_HUB_OP_BODY")" "$EVENT_ID")" || return 1
  jq -c --arg link "$link" '.event | {id, title, starts_at, ends_at, all_day, audience, creator_type, creator_id, mentions, reminders, link: $link}' <<<"$SPL_HUB_OP_BODY"
  echo "link=$link"
  do_log "OK event $EVENT_ID in $TENANT_ID ($ENV) changed ($(jq -r '[keys[] | select(. != "tenant" and . != "agent_id" and . != "ordered_by")] | join(", ")' <<<"$body")) and read back through the hub"
}

# _spl_calendar_update_mismatch <body> <read-back>: print the fields of the
# body whose read-back differs (reminders by amount and unit), else nothing.
_spl_calendar_update_mismatch() {
  jq -rn --argjson b "$1" --argjson r "$2" '
    def rs: [.[]? | {amount: (.amount | tonumber), unit}] | sort;
    [ ($b | del(.tenant, .agent_id, .ordered_by) | keys[]) as $k
      | select(if $k == "reminders" then ($b.reminders | rs) != ($r.event.reminders | rs)
               else $b[$k] != $r.event[$k] end) | $k ] | join(", ")' 2>/dev/null || echo "an unreadable body"
}

# _spl_calendar_update_times: print the JSON object of the move (DAY, or
# STARTS_AT and ENDS_AT), {} when neither is set. A refusal logs FATAL and
# returns 1.
_spl_calendar_update_times() {
  local day="${DAY:-}" start="${STARTS_AT:-}" end="${ENDS_AT:-}"
  if [[ -n "$day" ]]; then
    [[ -z "$start$end" ]] || { do_log "FATAL DAY moves to a whole day; STARTS_AT / ENDS_AT to a timed slot: set one, not both"; return 1; }
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$(date -u -d "$day" +%F 2>/dev/null)" == "$day" ]] \
      || { do_log "FATAL DAY must be a real day YYYY-MM-DD, got: '$day'"; return 1; }
    jq -cn --arg s "${day}T00:00:00Z" --arg e "$(date -u -d "$day + 1 day" +%F)T00:00:00Z" '{starts_at: $s, ends_at: $e, all_day: true}'
    return 0
  fi
  [[ -n "$start$end" ]] || { echo '{}'; return 0; }
  _spl_utc_time_ok "$start" && _spl_utc_time_ok "$end" \
    || { do_log "FATAL STARTS_AT and ENDS_AT go together, RFC 3339 UTC like 2026-10-12T09:00:00Z"; return 1; }
  [[ "$(date -u -d "$start" +%s)" -lt "$(date -u -d "$end" +%s)" ]] || { do_log "FATAL STARTS_AT must be before ENDS_AT"; return 1; }
  jq -cn --arg s "$start" --arg e "$end" '{starts_at: $s, ends_at: $e, all_day: false}'
}

# _spl_calendar_update_body: set the caller's local body to the PATCH body
# from the env vars; every refusal is made here, before cnf, gcloud or the hub.
_spl_calendar_update_body() {
  local tenant="${TENANT_ID:-}" agent="${AGENT_ID:-}" ordby="${ORDERED_BY:-}" id="${EVENT_ID:-}" times rems=""
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$agent" =~ ^[acgmq]-[0-9]{3,}$ || "$agent" =~ ^(CLE|AGY|GRK|QWN)-[0-9]+$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { do_log "FATAL EVENT_ID must be an event id (uuid), got: '$id'"; return 1; }
  [[ ! -v TITLE || -n "${TITLE// /}" ]] || { do_log "FATAL TITLE is set but empty: unset it to keep the title"; return 1; }
  [[ -z "${AUDIENCE:-}" || ( "$AUDIENCE" == private && -n "$ordby" ) ]] \
    || { do_log "FATAL AUDIENCE takes only private, with ORDERED_BY the member the entry was made for, got: '${AUDIENCE:-}'"; return 1; }
  times="$(_spl_calendar_update_times)" || { printf '%s\n' "$times"; return 1; }
  if [[ -v REMINDERS ]]; then
    rems="$(_spl_calendar_reminders)" || { printf '%s\n' "$rems"; return 1; }
    rems="${rems:-[]}"
  fi
  body="$(jq -cn --arg tenant "$tenant" --arg agent "$agent" --arg ordby "$ordby" --argjson times "$times" \
    --arg title "${TITLE:-}" --arg ht "${TITLE+1}" --arg desc "${DESCRIPTION:-}" --arg hd "${DESCRIPTION+1}" \
    --argjson rems "${rems:-null}" --arg aud "${AUDIENCE:-}" '
      {tenant: $tenant, agent_id: $agent}
      + (if $ordby != "" then {ordered_by: $ordby} else {} end)
      + (if $ht == "1" then {title: $title} else {} end)
      + (if $hd == "1" then {description: $desc} else {} end)
      + $times
      + (if $rems == null then {} else {reminders: $rems} end)
      + (if $aud != "" then {audience: $aud} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
  [[ "$(jq 'del(.tenant, .agent_id, .ordered_by) | length' <<<"$body")" -gt 0 ]] \
    || { do_log "FATAL nothing to change: set TITLE, DESCRIPTION, DAY, STARTS_AT and ENDS_AT, REMINDERS, or AUDIENCE"; return 1; }
}
