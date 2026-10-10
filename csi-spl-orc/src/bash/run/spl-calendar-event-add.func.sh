#!/bin/bash
#------------------------------------------------------------------------------
# @description Add one event to one workspace's calendar, AS AN AGENT, THROUGH
# @description THE HUB: POST /v1/operator/calendar/events (calendar_operator.go;
# @description owner HUM-10 msg b13c164c), authenticated as the env's project
# @description service account (do_gcp_pin_account, a Google id token for the
# @description hub URL; never the owner account), as do_spl_hub_invite does. The
# @description event's creator is AGENT_ID (creator_type agent), never a human;
# @description it lands only in TENANT_ID (the hub refuses a topic of another
# @description workspace). After the write the event is read back through
# @description GET /v1/operator/calendar/events/<id>. DRY_RUN=1 (default):
# @description print the request it would send, call no cloud, write nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param TITLE - required: the event title (the hub takes 1..200 characters)
# @param DAY - required with ALL_DAY=1: the day, YYYY-MM-DD
# @param ALL_DAY (optional) - 1 (default): DAY 00:00Z to the next day 00:00Z;
# @param   0: a timed event from STARTS_AT to ENDS_AT
# @param STARTS_AT, ENDS_AT - required with ALL_DAY=0: RFC 3339 UTC (2026-10-12T09:00:00Z)
# @param DESCRIPTION (optional) - the event text, e.g. a link to the source message
# @param TOPIC_ID (optional) - a topic (task id) of TENANT_ID the event points to
# @param AGENT_ID - required: the agent shown as the creator, e.g. c-042
# @param ORDERED_BY (optional) - the human who ordered it, a HUM-* id (logged by the hub)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=<tenant> TITLE='Payment due' DAY=2026-10-12 AGENT_ID=c-042 ./run -a do_spl_calendar_event_add
# @example ENV=dev TENANT_ID=<tenant> TITLE='Payment due' DAY=2026-10-12 AGENT_ID=c-042 ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_calendar_event_add
#------------------------------------------------------------------------------
do_spl_calendar_event_add() {
  do_require_bin yq jq curl gcloud || return 1
  local body dry=1
  _spl_calendar_event_body || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if (( dry )); then
    printf '%s\n' "$body"
    do_log "OK DRY_RUN would POST /v1/operator/calendar/events to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account, the body above; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call POST /v1/operator/calendar/events "$body" || return 1
  local detail id
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    201) ;;
    404) do_log "FATAL the hub has no POST /v1/operator/calendar/events, or its operator routes are off (404: $detail): deploy a hub with it. Nothing written."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator call ($SPL_HUB_OP_STATUS): $detail. Is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing written."; return 1 ;;
    *) do_log "FATAL the event was not written (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
  id="$(jq -r '.event.id // ""' <<<"$SPL_HUB_OP_BODY")"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL the hub answered 201 with no event id: $SPL_HUB_OP_BODY"; return 1; }
  spl_hub_operator_call GET "/v1/operator/calendar/events/$id?tenant=$TENANT_ID" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 && "$(jq -r '.event.id // ""' <<<"$SPL_HUB_OP_BODY")" == "$id" ]] \
    || { do_log "FATAL event $id was written but its read-back answered http $SPL_HUB_OP_STATUS: $SPL_HUB_OP_BODY"; return 1; }
  jq -c '.event | {id, title, starts_at, ends_at, all_day, creator_type, creator_id, topic_id, audience}' <<<"$SPL_HUB_OP_BODY"
  do_log "OK event $id in $TENANT_ID ($ENV), read back through the hub, creator $(jq -r '.event.creator_type + " " + .event.creator_id' <<<"$SPL_HUB_OP_BODY")"
}

# _spl_calendar_event_body: set the caller's local body to the request body
# (compact JSON) from the env vars; every refusal is made here, before cnf,
# gcloud or the hub.
_spl_calendar_event_body() {
  local tenant="${TENANT_ID:-}" title="${TITLE:-}" day="${DAY:-}" all="${ALL_DAY:-1}" agent="${AGENT_ID:-}"
  local ordby="${ORDERED_BY:-}" topic="${TOPIC_ID:-}" start="${STARTS_AT:-}" end="${ENDS_AT:-}"
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "$tenant" || return 1
  [[ -n "${title// /}" ]] || { do_log "FATAL TITLE is required"; return 1; }
  [[ "$agent" =~ ^[acgmq]-[0-9]{3,}$ || "$agent" =~ ^(CLE|AGY|GRK|QWN)-[0-9]+$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ -z "$topic" || "$topic" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL TOPIC_ID is not a task id: '$topic'"; return 1; }
  case "$all" in
    1)
      [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$(date -u -d "$day" +%F 2>/dev/null)" == "$day" ]] \
        || { do_log "FATAL DAY must be a real day YYYY-MM-DD, got: '$day'"; return 1; }
      start="${day}T00:00:00Z" end="$(date -u -d "$day + 1 day" +%F)T00:00:00Z" ;;
    0)
      [[ -z "$day" ]] || { do_log "FATAL DAY is for ALL_DAY=1; a timed event takes STARTS_AT and ENDS_AT"; return 1; }
      _spl_utc_time_ok "$start" && _spl_utc_time_ok "$end" \
        || { do_log "FATAL ALL_DAY=0 needs STARTS_AT and ENDS_AT as RFC 3339 UTC like 2026-10-12T09:00:00Z"; return 1; }
      [[ "$(date -u -d "$start" +%s)" -lt "$(date -u -d "$end" +%s)" ]] || { do_log "FATAL STARTS_AT must be before ENDS_AT"; return 1; } ;;
    *) do_log "FATAL ALL_DAY must be 0 or 1, got: '$all'"; return 1 ;;
  esac
  body="$(jq -cn --arg tenant "$tenant" --arg agent "$agent" --arg ordby "$ordby" --arg title "$title" \
    --arg desc "${DESCRIPTION:-}" --arg start "$start" --arg end "$end" --arg topic "$topic" --argjson all "$([[ "$all" == 1 ]] && echo true || echo false)" '
      {tenant: $tenant, agent_id: $agent, title: $title, description: $desc, starts_at: $start, ends_at: $end, all_day: $all}
      + (if $ordby != "" then {ordered_by: $ordby} else {} end)
      + (if $topic != "" then {topic_id: $topic} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
}
