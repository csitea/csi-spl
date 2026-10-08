#!/bin/bash
#------------------------------------------------------------------------------
# @description Read or set the agent kinds switched off for the whole instance
# @description (rdb 0149, owner HUM-10 t1 41fa1f2d: "a setting to disable
# @description certain type of ai agents"), THROUGH THE HUB: GET / PATCH
# @description /v1/operator/fleet-load {agent_kinds_off}, authenticated as the
# @description env's project service account (do_gcp_pin_account, a Google id
# @description token for the hub URL; never the owner account), as
# @description do_spl_hub_member_access_until does. It is the same setting the
# @description operator admin switches on the Fleet load page; every box's
# @description do_spl_lane_mix then never picks a kind that is off. The hub
# @description refuses switching every kind off. KINDS_OFF unset: read only,
# @description print the kinds off and the running pauses. DRY_RUN=1 (default)
# @description with KINDS_OFF: print the change, call no cloud.
# @param ENV - required: dev or prd
# @param KINDS_OFF (optional) - the WHOLE set to switch off, comma separated
# @param   (claude,grok,agy,qwen,mistral), or 'none' to switch every kind on; unset = read
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered it, a HUM-* id
# @param ORDERED_VIA (optional) - the agent or channel that carried the order, at most 64 chars
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_hub_agent_kinds
# @example ENV=prd KINDS_OFF=grok ORDERED_BY=HUM-10 ORDERED_VIA=c-496 DRY_RUN=0 ./run -a do_spl_hub_agent_kinds
# @example ENV=prd KINDS_OFF=none ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_hub_agent_kinds
#------------------------------------------------------------------------------
do_spl_hub_agent_kinds() {
  do_require_bin jq curl gcloud || return 1
  local set="${KINDS_OFF-__read__}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" kinds dry=1
  if [[ "$set" != __read__ ]]; then
    kinds="$(_spl_hub_agent_kinds_list "$set")" || return 1
    [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
    [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if [[ "$set" != __read__ ]] && (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to switch off the agent kinds [${kinds:-none}] for the whole instance (ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}), as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ "$set" == __read__ || -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if [[ "$set" == __read__ ]]; then
    spl_hub_operator_call GET /v1/operator/fleet-load || return 1
  else
    local body
    body="$(jq -cn --arg k "$kinds" --arg by "$ordby" --arg via "$ordvia" '
        {agent_kinds_off: ($k | split(",") | map(select(. != ""))), ordered_by: $by}
        + (if $via != "" then {ordered_via: $via} else {} end)')" || { do_log "FATAL could not build the request body"; return 1; }
    spl_hub_operator_call PATCH /v1/operator/fleet-load "$body" || return 1
  fi
  _spl_hub_agent_kinds_report "$set" "$ordby" "$ordvia"
}

# _spl_hub_agent_kinds_list <KINDS_OFF> -> the kinds, distinct, comma joined
# in the hub's order ('' for none); refuses an unknown kind and all five
_spl_hub_agent_kinds_list() {
  local raw="${1// /}" k out=""
  [[ "$raw" == none ]] && { echo ""; return 0; }
  [[ "$raw" =~ ^[a-z]+(,[a-z]+)*$ ]] || { do_log "FATAL KINDS_OFF must be kinds like grok or grok,qwen, or 'none', got: '$1'"; return 1; }
  for k in ${raw//,/ }; do
    [[ "$k" =~ ^(claude|grok|agy|qwen|mistral)$ ]] || { do_log "FATAL KINDS_OFF: '$k' is not an agent kind (claude, grok, agy, qwen, mistral)"; return 1; }
  done
  for k in claude grok agy qwen mistral; do [[ ",$raw," == *",$k,"* ]] && out="$out,$k"; done
  [[ "$out" != ",claude,grok,agy,qwen,mistral" ]] || { do_log "FATAL KINDS_OFF names every kind: at least one stays on"; return 1; }
  echo "${out#,}"
}

# _spl_hub_agent_kinds_report <set> <ordered_by> <ordered_via> -> the hub's
# answer as one OK line, or the refusal
_spl_hub_agent_kinds_report() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200)
      do_log "OK $ENV instance agent kinds: $(jq -r '"off [\(.agent_kinds_off // [] | join(","))], paused [\((.agent_kinds_paused // {}) | to_entries | map("\(.key) until \(.value.until) (\(.value.reason))") | join("; "))]"' <<<"$SPL_HUB_OP_BODY")$([[ "$1" != __read__ ]] && echo " (set by ordered_by=$2${3:+ via $3}, $GCP_ACCOUNT)")"
      return 0 ;;
    400) do_log "FATAL the hub refused the setting (400): $detail. Nothing changed."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    404) do_log "FATAL the hub answered 404 ($detail): no operator workspace, or a hub without this door yet. Nothing changed."; return 1 ;;
    *) do_log "FATAL the instance agent kinds were not read or changed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
}
