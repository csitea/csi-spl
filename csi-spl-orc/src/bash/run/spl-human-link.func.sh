#!/bin/bash
#------------------------------------------------------------------------------
# @description Link two accounts of ONE person, BY A HUMAN'S ORDER, THROUGH THE
# @description HUB: POST /v1/operator/humans/<human_id>/links
# @description (human_links_operator.go; spec 042 "Note to self", owner HUM-10
# @description t1 df36f210, poll 3193d41f answer C: "Operator-set link only, no
# @description self-service"), authenticated as the env's project service
# @description account (do_gcp_pin_account, a Google id token for the hub URL;
# @description never the owner account). The hub stores both directions
# @description (human_links, rdb 0278); linking again changes nothing. A linked
# @description account's tag then reads as a note to self: no agent answers
# @description it and no "does not belong to this channel" note. It changes no
# @description membership. The audit is created_by "<AGENT_ID> for <ORDERED_BY>".
# @description Both runs print the read-back, GET /v1/operator/humans/<human_id>/links.
# @description DRY_RUN=1 (default): print the body it would send and the current
# @description links (a read), write nothing.
# @param ENV - required: dev or prd
# @param HUMAN_ID - required: the HUM-* id of the person's first account
# @param LINKED_HUMAN_ID - required: the HUM-* id of the same person's other account
# @param ORDERED_BY - required: the HUM-* id of the human who ordered it
# @param AGENT_ID - required: the agent that carries the order, e.g. c-042
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev HUMAN_ID=HUM-10 LINKED_HUMAN_ID=HUM-5 ORDERED_BY=HUM-10 AGENT_ID=c-042 ./run -a do_spl_human_link
# @example ENV=dev HUMAN_ID=HUM-10 LINKED_HUMAN_ID=HUM-5 ORDERED_BY=HUM-10 AGENT_ID=c-042 DRY_RUN=0 ./run -a do_spl_human_link
#------------------------------------------------------------------------------
do_spl_human_link() {
  do_require_bin yq jq curl gcloud || return 1
  local body hum="${HUMAN_ID:-}" dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  _spl_human_link_body || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( dry )); then
    echo "$body"
    _spl_human_link_list "now" || return 1
    do_log "OK DRY_RUN would POST /v1/operator/humans/$hum/links to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account, the body above; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_hub_operator_call POST "/v1/operator/humans/$hum/links" "$body" || return 1
  _spl_human_link_status || return 1
  _spl_human_link_list "after the link" || return 1
  do_log "OK $hum ($ENV): linked to $LINKED_HUMAN_ID both ways, read back through the hub (ordered_by $ORDERED_BY, via $AGENT_ID)."
}

# _spl_human_link_list <when>: GET the human's links and print them.
_spl_human_link_list() {
  spl_hub_operator_call GET "/v1/operator/humans/$hum/links" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || {
    do_log "FATAL the read-back of $hum ($1) answered http $SPL_HUB_OP_STATUS: $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
    return 1
  }
  do_log "INFO the accounts linked to $hum ($1): $(jq -c '.linked' <<<"$SPL_HUB_OP_BODY")"
}

# _spl_human_link_status: map the link's answer to OK or one FATAL.
_spl_human_link_status() {
  local detail err
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  err="$(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS:$err" in
    200:*) return 0 ;;
    400:same_human) do_log "FATAL HUMAN_ID and LINKED_HUMAN_ID are the same account (400). Nothing written." ;;
    409:technical) do_log "FATAL one of them is an agent or a clone, not a person's account (409). Nothing written." ;;
    404:not_found) do_log "FATAL the hub has no human $hum or $LINKED_HUMAN_ID, or no such route (404: $detail). Nothing written." ;;
    404:*) do_log "FATAL the hub has no POST /v1/operator/humans/{human_id}/links, or its operator routes are off (404: $detail): deploy a hub with it. Nothing written." ;;
    401:*|403:*) do_log "FATAL the hub refused the operator call ($SPL_HUB_OP_STATUS): $detail. Is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing written." ;;
    *) do_log "FATAL the link was not written (http $SPL_HUB_OP_STATUS): $detail" ;;
  esac
  return 1
}

# _spl_human_link_body: set the caller's local body to the request body
# (compact JSON) from the env vars; every refusal is made here, before cnf,
# gcloud or the hub.
_spl_human_link_body() {
  local linked="${LINKED_HUMAN_ID:-}" ordby="${ORDERED_BY:-}" agent="${AGENT_ID:-}"
  spl_require_cloud_env || return 1
  [[ "$hum" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must be a HUM-* id, got: '$hum'"; return 1; }
  [[ "$linked" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL LINKED_HUMAN_ID must be a HUM-* id, got: '$linked'"; return 1; }
  [[ "$linked" != "$hum" ]] || { do_log "FATAL LINKED_HUMAN_ID is HUMAN_ID: a person's OTHER account is linked, never the same one"; return 1; }
  [[ "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be the HUM-* id of the human who ordered it, got: '$ordby'"; return 1; }
  [[ "$agent" =~ ^[acgmq]-[0-9]{3}$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  body="$(jq -cn --arg linked "$linked" --arg agent "$agent" --arg ordby "$ordby" \
      '{linked_human_id: $linked, agent_id: $agent, ordered_by: $ordby}')" \
    || { do_log "FATAL could not build the request body"; return 1; }
}
