#!/bin/bash
#------------------------------------------------------------------------------
# @description Read or set the instance's runner CPU cap (rdb 0152, owner
# @description HUM-10 t1 338e5258 b3573121: "there will be always some 20%
# @description extra capacity"; 569c4846: "do those changes permanent in the
# @description db"), THROUGH THE HUB: GET / PATCH /v1/operator/fleet-load
# @description {runner_cpu_pct}, authenticated as the env's project service
# @description account (do_gcp_pin_account; never the owner account), as
# @description do_spl_hub_agent_kinds does. It is the % of a box's cores CI
# @description runners plus agents may use (1..100, default 80), read by every
# @description box's do_apply_gh_runner_cpu_budget. A box's own cap
# @description (boxes.<box>.runner_cpu_pct) is part of the boxes map, not set
# @description here. RUNNER_CPU_PCT unset: read only. DRY_RUN=1 (default) with
# @description RUNNER_CPU_PCT: print the change, call no cloud.
# @param ENV - required: dev or prd
# @param RUNNER_CPU_PCT (optional) - 1..100, or 'default' to reset it (80); unset = read
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered it, a HUM-* id
# @param ORDERED_VIA (optional) - the agent or channel that carried the order, at most 64 chars
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_hub_runner_cpu
# @example ENV=prd RUNNER_CPU_PCT=80 ORDERED_BY=HUM-10 ORDERED_VIA=c-543 DRY_RUN=0 ./run -a do_spl_hub_runner_cpu
#------------------------------------------------------------------------------
do_spl_hub_runner_cpu() {
  do_require_bin jq curl gcloud || return 1
  local set="${RUNNER_CPU_PCT-__read__}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" dry=1
  if [[ "$set" != __read__ ]]; then
    [[ "$set" == default || ( "$set" =~ ^[1-9][0-9]*$ && "$set" -le 100 ) ]] \
      || { do_log "FATAL RUNNER_CPU_PCT must be 1..100 or 'default', got: '$set'"; return 1; }
    [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
    [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if [[ "$set" != __read__ ]] && (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to set the runner CPU cap to $set for the whole instance (ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}), as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ "$set" == __read__ || -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if [[ "$set" == __read__ ]]; then
    spl_hub_operator_call GET /v1/operator/fleet-load || return 1
  else
    local body
    body="$(jq -cn --arg p "$set" --arg by "$ordby" --arg via "$ordvia" '
        {runner_cpu_pct: (if $p == "default" then null else ($p | tonumber) end), ordered_by: $by}
        + (if $via != "" then {ordered_via: $via} else {} end)')" || { do_log "FATAL could not build the request body"; return 1; }
    spl_hub_operator_call PATCH /v1/operator/fleet-load "$body" || return 1
  fi
  _spl_hub_runner_cpu_report "$set" "$ordby" "$ordvia"
}

# _spl_hub_runner_cpu_report <set> <ordered_by> <ordered_via> -> the hub's
# answer as one OK line, or the refusal
_spl_hub_runner_cpu_report() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200)
      do_log "OK $ENV instance runner CPU cap: $(jq -r '"\(.runner_cpu_pct // "absent (hub before rdb 0152)")% in force, stored \(.stored.runner_cpu_pct // "unset")"' <<<"$SPL_HUB_OP_BODY")$([[ "$1" != __read__ ]] && echo " (set by ordered_by=$2${3:+ via $3}, $GCP_ACCOUNT)")"
      return 0 ;;
    400) do_log "FATAL the hub refused the setting (400): $detail. Nothing changed."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    404) do_log "FATAL the hub answered 404 ($detail): no operator workspace, or a hub without this door yet. Nothing changed."; return 1 ;;
    *) do_log "FATAL the instance runner CPU cap was not read or changed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
}
