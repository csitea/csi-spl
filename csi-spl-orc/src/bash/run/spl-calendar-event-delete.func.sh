#!/bin/bash
#------------------------------------------------------------------------------
# @description Move events of one workspace's calendar to the trash, AS AN
# @description AGENT, THROUGH THE HUB: DELETE /v1/operator/calendar/events/<id>
# @description (calendar_operator_write.go, SPL-5453), the member soft delete:
# @description each event leaves the calendar and sits in ORDERED_BY's trash
# @description (a member, who can Undo it in the WUI), else the agent's. Only a
# @description single workspace event: a private, synced or repeating one is
# @description refused by the hub. Each id is read back: GET answers 404 once
# @description it is in the trash. DRY_RUN=1 (default): print what it would
# @description send, call no cloud, write nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param EVENT_IDS - required: 1..200 event ids (uuids), comma- or space-separated
# @param AGENT_ID - required: the agent doing it, e.g. c-042
# @param ORDERED_BY (optional) - the human who ordered it, a HUM-* id: their trash
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<tenant> EVENT_IDS=<uuid>,<uuid> AGENT_ID=c-042 ORDERED_BY=HUM-10 ./run -a do_spl_calendar_event_delete
#------------------------------------------------------------------------------
do_spl_calendar_event_delete() {
  do_require_bin jq curl gcloud || return 1
  _spl_calendar_event_each delete
}

# _spl_calendar_event_each <delete|pin>: the shared driver of
# do_spl_calendar_event_delete and do_spl_calendar_event_pin. Every refusal
# comes before cnf, gcloud or the hub; then one call and one read-back per
# id. A failed id does not stop the others; the run fails if any failed.
_spl_calendar_event_each() {
  local verb="$1" tenant="${TENANT_ID:-}" agent="${AGENT_ID:-}" ordby="${ORDERED_BY:-}" pinned="${PINNED:-1}"
  local -a ids=()
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$agent" =~ ^[acgmq]-[0-9]{3,}$ || "$agent" =~ ^(CLE|AGY|GRK|QWN)-[0-9]+$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ "$verb" != pin || "$pinned" == 0 || "$pinned" == 1 ]] || { do_log "FATAL PINNED must be 1 or 0, got: '$pinned'"; return 1; }
  read -r -a ids <<<"${EVENT_IDS//,/ }"
  (( ${#ids[@]} >= 1 && ${#ids[@]} <= 200 )) || { do_log "FATAL EVENT_IDS must name 1..200 event ids, got ${#ids[@]}"; return 1; }
  local id
  for id in "${ids[@]}"; do
    [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { do_log "FATAL EVENT_IDS holds a non-uuid: '$id'"; return 1; }
  done
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if (( dry )); then
    for id in "${ids[@]}"; do _spl_calendar_event_req "$verb" "$tenant" "$agent" "$ordby" "$pinned" "$id"; done
    do_log "OK DRY_RUN would $verb ${#ids[@]} event(s) of $tenant through $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account, the requests above; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local ok=0 bad=0
  for id in "${ids[@]}"; do
    if _spl_calendar_event_one "$verb" "$tenant" "$agent" "$ordby" "$pinned" "$id"; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
  done
  (( bad == 0 )) || { do_log "FATAL $verb: $ok of ${#ids[@]} event(s) of $tenant ($ENV) done and read back, $bad failed (lines above)"; return 1; }
  do_log "OK $verb: ${#ids[@]} of ${#ids[@]} event(s) of $tenant ($ENV) done and read back through the hub"
}

# _spl_calendar_event_req <verb> <tenant> <agent> <ordby> <pinned> <id>:
# print "<METHOD> <path> <body>", the one request for that id.
_spl_calendar_event_req() {
  local verb="$1" tenant="$2" agent="$3" ordby="$4" pinned="$5" id="$6"
  if [[ "$verb" == delete ]]; then
    printf 'DELETE /v1/operator/calendar/events/%s?tenant=%s&agent_id=%s%s\n' "$id" "$tenant" "$agent" "${ordby:+&ordered_by=$ordby}"
    return 0
  fi
  printf 'PATCH /v1/operator/calendar/events/%s %s\n' "$id" "$(jq -cn --arg t "$tenant" --arg a "$agent" --arg o "$ordby" \
    --argjson p "$([[ "$pinned" == 1 ]] && echo true || echo false)" \
    '{tenant: $t, agent_id: $a} + (if $o != "" then {ordered_by: $o} else {} end) + {props: {pinned: $p}}')"
}

# _spl_calendar_event_one <verb> <tenant> <agent> <ordby> <pinned> <id>: the
# call and its read-back for one id; one OK or FAIL line.
_spl_calendar_event_one() {
  local verb="$1" tenant="$2" pinned="$5" id="$6" req method path body detail
  req="$(_spl_calendar_event_req "$@")" || return 1
  method="${req%% *}" req="${req#* }" path="${req%% *}" body=""
  [[ "$req" == *" "* ]] && body="${req#* }"
  spl_hub_operator_call "$method" "$path" "$body" || return 1
  detail="$(jq -r '.detail // .error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { do_log "FAIL $verb $id: http $SPL_HUB_OP_STATUS ${detail:-$SPL_HUB_OP_BODY}"; return 1; }
  local title
  title="$(jq -r '.event.title // ""' <<<"$SPL_HUB_OP_BODY")"
  spl_hub_operator_call GET "/v1/operator/calendar/events/$id?tenant=$tenant" || return 1
  if [[ "$verb" == delete ]]; then
    [[ "$SPL_HUB_OP_STATUS" == 404 ]] || { do_log "FAIL delete $id: the read-back answered http $SPL_HUB_OP_STATUS, not 404"; return 1; }
    do_log "OK trashed $id ($title): read back 404, in the trash"
    return 0
  fi
  local got want
  got="$(jq -r '.event.pinned // false' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  want="$([[ "$pinned" == 1 ]] && echo true || echo false)"
  [[ "$SPL_HUB_OP_STATUS" == 200 && "$got" == "$want" ]] || { do_log "FAIL pin $id: read back http $SPL_HUB_OP_STATUS pinned=$got, want $want"; return 1; }
  do_log "OK pinned=$want $id ($title): read back"
}
