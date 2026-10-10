#!/bin/bash
#------------------------------------------------------------------------------
# @description Create one channel in one workspace, BY A HUMAN'S ORDER,
# @description THROUGH THE HUB: POST /v1/operator/channels (channel_operator.go;
# @description owner HUM-10 msg 5c7a9202), authenticated as the env's project
# @description service account (do_gcp_pin_account, a Google id token for the
# @description hub URL; never the owner account). created_by is ORDERED_BY, a
# @description HUM-* member of TENANT_ID, who the hub seats in the channel as
# @description the member create seats its creator; the channel lands only in
# @description TENANT_ID. A created channel is members-only (rdb 0028): seat
# @description others with do_spl_channel_member_add. After the write the
# @description channel is read back through GET /v1/operator/channels/<channel>.
# @description DRY_RUN=1 (default): print the request it would send, call no
# @description cloud, write nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param CHANNEL - required: the channel id, ^[a-z0-9][a-z0-9-]{0,63}$; not a
# @param   default (lobby, alerts, feedback), general, issues or tasks
# @param NAME (optional) - the display name, at most 80 characters (default CHANNEL)
# @param DESCRIPTION (optional) - what the channel is for, at most 500 characters
# @param PRIVACY (optional) - members (the default and the only value: a created
# @param   channel is members-only; only the default channels are public)
# @param ORDERED_BY - required on DRY_RUN=0: the HUM-* id of the human who ordered it
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=<tenant> CHANNEL=trading ORDERED_BY=HUM-10 ./run -a do_spl_channel_create
# @example ENV=dev TENANT_ID=<tenant> CHANNEL=trading ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_channel_create
#------------------------------------------------------------------------------
do_spl_channel_create() {
  do_require_bin yq jq curl gcloud || return 1
  local body dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  _spl_channel_create_body "$dry" || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if (( dry )); then
    printf '%s\n' "$body"
    do_log "OK DRY_RUN would POST /v1/operator/channels to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account, the body above; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call POST /v1/operator/channels "$body" || return 1
  _spl_channel_create_status || return 1
  spl_hub_operator_call GET "/v1/operator/channels/$CHANNEL?tenant=$TENANT_ID" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 && "$(jq -r '.channel // ""' <<<"$SPL_HUB_OP_BODY")" == "$CHANNEL" ]] \
    || { do_log "FATAL #$CHANNEL was created but its read-back answered http $SPL_HUB_OP_STATUS: $SPL_HUB_OP_BODY"; return 1; }
  jq -c '{channel, name, description, created_by, created_at, default, members}' <<<"$SPL_HUB_OP_BODY"
  do_log "OK #$CHANNEL in $TENANT_ID ($ENV), read back through the hub, created_by $(jq -r '.created_by' <<<"$SPL_HUB_OP_BODY"), members $(jq -r '.members | join(",")' <<<"$SPL_HUB_OP_BODY")"
}

# _spl_channel_create_status: map the create's answer to OK or one FATAL.
_spl_channel_create_status() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    201) return 0 ;;
    404) [[ "$(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)" == not_a_member ]] \
           && { do_log "FATAL ORDERED_BY $ORDERED_BY is not a member of $TENANT_ID: $detail. Nothing written."; return 1; }
         do_log "FATAL the hub has no POST /v1/operator/channels, or its operator routes are off (404: $detail): deploy a hub with it. Nothing written." ;;
    409) do_log "FATAL #$CHANNEL was not created in $TENANT_ID (409): $detail. To seat someone in an existing channel: do_spl_channel_member_add." ;;
    401|403) do_log "FATAL the hub refused the operator call ($SPL_HUB_OP_STATUS): $detail. Is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing written." ;;
    *) do_log "FATAL the channel was not created (http $SPL_HUB_OP_STATUS): $detail" ;;
  esac
  return 1
}

# _spl_channel_create_body <dry>: set the caller's local body to the request
# body (compact JSON) from the env vars; every refusal is made here, before
# cnf, gcloud or the hub.
_spl_channel_create_body() {
  local dry="$1" tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" name="${NAME:-}" desc="${DESCRIPTION:-}"
  local privacy="${PRIVACY:-members}" ordby="${ORDERED_BY:-}"
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id ^[a-z0-9][a-z0-9-]{0,63}\$, got: '$ch'"; return 1; }
  case "$ch" in
    lobby|alerts|feedback|general|issues|tasks)
      do_log "FATAL #$ch is reserved (a default channel, the lobby alias, the issue discussions or the retired #tasks): it is never created"
      return 1 ;;
  esac
  (( ${#name} <= 80 )) || { do_log "FATAL NAME must be at most 80 characters"; return 1; }
  (( ${#desc} <= 500 )) || { do_log "FATAL DESCRIPTION must be at most 500 characters"; return 1; }
  [[ "$privacy" == members ]] || { do_log "FATAL PRIVACY must be members, got: '$privacy' (a created channel is members-only; only the default channels are public)"; return 1; }
  if [[ -z "$ordby" ]]; then
    (( dry )) || { do_log "FATAL ORDERED_BY is required with DRY_RUN=0: the HUM-* id of the human who ordered the channel"; return 1; }
  else
    [[ "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  fi
  body="$(jq -cn --arg tenant "$tenant" --arg ch "$ch" --arg ordby "$ordby" --arg name "$name" --arg desc "$desc" --arg privacy "$privacy" '
      {tenant: $tenant, channel: $ch, ordered_by: $ordby, privacy: $privacy}
      + (if $name != "" then {name: $name} else {} end)
      + (if $desc != "" then {description: $desc} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
}
