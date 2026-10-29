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
# @description GET /v1/operator/calendar/events/<id>, and its clickable link is
# @description printed (SPL-2282): link=https://<host>/calendar?d=<start day>&event=<id>,
# @description host = <tenant>.<env.dns.fqdn>, the apex for t1. DRY_RUN=1 (default):
# @description print the request it would send, call no cloud, write nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param TITLE - required: the event title (the hub takes 1..200 characters)
# @param DAY - required with ALL_DAY=1: the day, YYYY-MM-DD
# @param ALL_DAY (optional) - 1 (default): DAY 00:00Z to the next day 00:00Z;
# @param   0: a timed event from STARTS_AT to ENDS_AT
# @param STARTS_AT, ENDS_AT - required with ALL_DAY=0: RFC 3339 UTC (2026-10-12T09:00:00Z)
# @param DESCRIPTION (optional) - the event text, e.g. a link to the source message
# @param TOPIC_ID (optional) - a topic of TENANT_ID: a full id, or an 8-hex short id that matches exactly one topic there
# @param AGENT_ID - required: the agent shown as the creator, e.g. c-042
# @param ORDERED_BY (optional) - the human who ordered it, a HUM-* id (logged by the hub)
# @param ISSUE_KEYS (optional) - comma-separated issue keys of TENANT_ID (at most 20);
# @param   empty sends an empty list; unset omits the field
# @param EVENT_OWNER (optional) - the responsible member (HUM-n) or agent id;
# @param   empty or unset leaves the hub default (ORDERED_BY when that human is a member, else the agent)
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
  local link
  link="$(_spl_calendar_event_link "$TENANT_ID" "$(jq -r '.event.starts_at // ""' <<<"$SPL_HUB_OP_BODY")" "$id")" || return 1
  jq -c --arg link "$link" '.event | {id, title, starts_at, ends_at, all_day, creator_type, creator_id, topic_id, owner_id, issue_keys, audience, link: $link}' <<<"$SPL_HUB_OP_BODY"
  echo "link=$link"
  do_log "OK event $id in $TENANT_ID ($ENV), read back through the hub, creator $(jq -r '.event.creator_type + " " + .event.creator_id' <<<"$SPL_HUB_OP_BODY")"
}

# _spl_calendar_event_link <tenant> <starts_at> <id> (SPL-2282): the entry's
# clickable link, as the WUI opens it (/calendar?d=<YYYY-MM-DD>&event=<id>):
# https://<tenant>.<SPL_FQDN>, the apex for t1; the host comes from the cnf.
_spl_calendar_event_link() {
  local host="${SPL_FQDN:-}" day="${2:0:10}"
  [[ -n "$host" ]] || { do_log "FATAL env.dns.fqdn is empty: no link for event $3"; return 1; }
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { do_log "FATAL event $3 has no start day in the read-back: '$2'"; return 1; }
  [[ "$1" == t1 ]] || host="$1.$host"
  printf 'https://%s/calendar?d=%s&event=%s\n' "$host" "$day" "$3"
}

# _spl_calendar_issue_keys: print a JSON array of ISSUE_KEYS, or nothing when
# the variable is unset. An empty value prints []. A bad token logs FATAL and
# returns 1 (the caller reprints that line: a command substitution swallows it).
_spl_calendar_issue_keys() {
  [[ -v ISSUE_KEYS ]] || return 0
  local raw="${ISSUE_KEYS}" tok lower more json
  local -a keys=()
  declare -A seen=()
  [[ -n "$raw" ]] || { printf '[]\n'; return 0; }
  while true; do
    tok="${raw%%,*}"
    if [[ "$raw" == *","* ]]; then raw="${raw#*,}"; more=1; else raw=""; more=0; fi
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    if [[ -z "$tok" ]]; then
      do_log "FATAL ISSUE_KEYS has an empty key"
      return 1
    fi
    if (( ${#tok} > 32 )); then
      do_log "FATAL an ISSUE_KEYS key is longer than 32 characters: '$tok'"
      return 1
    fi
    if [[ ! "$tok" =~ ^[1-9][0-9]*$ && ! "$tok" =~ ^[A-Za-z][A-Za-z0-9]{0,9}-[1-9][0-9]*$ ]]; then
      do_log "FATAL ISSUE_KEYS is not an issue key: '$tok'"
      return 1
    fi
    lower="${tok,,}"
    if [[ -z "${seen[$lower]:-}" ]]; then
      seen[$lower]=1
      keys+=("$tok")
      if (( ${#keys[@]} > 20 )); then
        do_log "FATAL ISSUE_KEYS lists more than 20 keys"
        return 1
      fi
    fi
    if (( more == 0 )); then break; fi
  done
  json="$(jq -cn '$ARGS.positional' --args "${keys[@]}")" || { do_log "FATAL could not encode ISSUE_KEYS"; return 1; }
  printf '%s\n' "$json"
}

# _spl_calendar_event_owner: print EVENT_OWNER when it is a HUM-* id or an
# agent id (optional @box). Unset or empty prints nothing. A bad value logs
# FATAL and returns 1.
_spl_calendar_event_owner() {
  [[ -v EVENT_OWNER ]] || return 0
  local owner="${EVENT_OWNER}"
  [[ -n "$owner" ]] || return 0
  if [[ "$owner" =~ ^HUM-[0-9]+$ || "$owner" =~ ^([acgmq]-[0-9]{3,}|(CLE|AGY|GRK|QWN)-[0-9]+)(@[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
    printf '%s\n' "$owner"
    return 0
  fi
  do_log "FATAL EVENT_OWNER must be a HUM-* id or an agent id, got: '$owner'"
  return 1
}

# _spl_calendar_event_body: set the caller's local body to the request body
# (compact JSON) from the env vars; every refusal is made here, before cnf,
# gcloud or the hub.
_spl_calendar_event_body() {
  local tenant="${TENANT_ID:-}" title="${TITLE:-}" day="${DAY:-}" all="${ALL_DAY:-1}" agent="${AGENT_ID:-}"
  local ordby="${ORDERED_BY:-}" topic="${TOPIC_ID:-}" start="${STARTS_AT:-}" end="${ENDS_AT:-}"
  local issues="" owner=""
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
  issues="$(_spl_calendar_issue_keys)" || { printf '%s\n' "$issues"; return 1; }
  owner="$(_spl_calendar_event_owner)" || { printf '%s\n' "$owner"; return 1; }
  body="$(jq -cn --arg tenant "$tenant" --arg agent "$agent" --arg ordby "$ordby" --arg title "$title" \
    --arg desc "${DESCRIPTION:-}" --arg start "$start" --arg end "$end" --arg topic "$topic" --arg owner "$owner" \
    --argjson all "$([[ "$all" == 1 ]] && echo true || echo false)" --argjson issues "${issues:-null}" '
      {tenant: $tenant, agent_id: $agent, title: $title, description: $desc, starts_at: $start, ends_at: $end, all_day: $all}
      + (if $ordby != "" then {ordered_by: $ordby} else {} end)
      + (if $topic != "" then {topic_id: $topic} else {} end)
      + (if $issues == null then {} else {issue_keys: $issues} end)
      + (if $owner != "" then {owner_id: $owner} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
}
