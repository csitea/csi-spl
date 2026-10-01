#!/bin/bash
#------------------------------------------------------------------------------
# @description Deliver a workspace's browser posts that were stored UNSIGNED
# @description while it had no box-wui pin (CLE-77876). Without the pin the hub
# @description cannot sign a browser post for box-wui, so it stores it unsigned
# @description and no member box receives it (prd 2026-10-01: csitea's people
# @description posted for two days, no agent read a line). Pin first
# @description (do_spl_cloud_pin_box_wui; do_spl_check_box_wui_pins lists the
# @description unpinned), then this asks the hub, POST
# @description /v1/operator/replay-unsigned, to sign each such human channel
# @description post since SINCE in place and route it to every member box as a
# @description fresh post (the agents get them in their inboxes, oldest
# @description first). A second run finds nothing: a signed row is never
# @description signed again. At most 500 per call: re-run while found = 500.
# @description Authenticated as the env's project service account (an id token
# @description for the hub's URL), never the owner account.
# @description DRY_RUN=1 (default) asks the hub for the list only (dry_run:
# @description true): nothing is signed or delivered.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param SINCE - required: RFC 3339 UTC, e.g. 2026-09-29T12:00:00Z (at most 30 days back)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<t> SINCE=2026-09-29T12:00:00Z ./run -a do_spl_replay_unsigned
# @example ENV=prd TENANT_ID=<t> SINCE=2026-09-29T12:00:00Z DRY_RUN=0 ./run -a do_spl_replay_unsigned
#------------------------------------------------------------------------------
do_spl_replay_unsigned() {
  do_require_bin yq jq curl gcloud || return 1
  local tenant="${TENANT_ID:-}" since="${SINCE:-}" dry=1 body
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    { do_log "FATAL SINCE must be RFC 3339 UTC like 2026-09-29T12:00:00Z, got: '$since'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  body="$(jq -cn --arg tenant "$tenant" --arg since "$since" --argjson dry "$( ((dry)) && echo true || echo false)" \
    '{tenant: $tenant, since: $since, dry_run: $dry}')" || return 1
  spl_hub_operator_call POST /v1/operator/replay-unsigned "$body" || return 1
  spl_replay_unsigned_report "$tenant" "$dry"
}

# spl_replay_unsigned_report <tenant> <dry>: reads SPL_HUB_OP_STATUS / _BODY.
spl_replay_unsigned_report() {
  local tenant="$1" dry="$2" found resigned skipped chans
  case "$SPL_HUB_OP_STATUS" in
    200) ;;
    409) do_log "FATAL $tenant has no box-wui pin matching the hub's key: run do_spl_cloud_pin_box_wui first. Nothing replayed."; return 1 ;;
    404) do_log "FATAL the hub has no replay route or operator routes are off (404): deploy the hub first. $SPL_HUB_OP_BODY"; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS) for $GCP_ACCOUNT. $SPL_HUB_OP_BODY"; return 1 ;;
    *) do_log "FATAL replay for $tenant failed (http $SPL_HUB_OP_STATUS): $SPL_HUB_OP_BODY"; return 1 ;;
  esac
  found="$(jq -r '.found' <<<"$SPL_HUB_OP_BODY")"
  resigned="$(jq -r '.resigned' <<<"$SPL_HUB_OP_BODY")"
  skipped="$(jq -r '.skipped' <<<"$SPL_HUB_OP_BODY")"
  chans="$(jq -r '.channels | map("#" + .) | join(" ")' <<<"$SPL_HUB_OP_BODY")"
  jq -c '{tenant, since, dry_run, found, resigned, skipped, channels}' <<<"$SPL_HUB_OP_BODY"
  if (( dry )); then
    do_log "OK DRY_RUN $tenant: $found unsigned human post(s) since $(jq -r .since <<<"$SPL_HUB_OP_BODY") in ${chans:-no channel}; nothing signed. Re-run with DRY_RUN=0 to deliver them."
    return 0
  fi
  do_log "OK $tenant: $resigned of $found unsigned post(s) signed and routed to the member boxes ($skipped skipped) in ${chans:-no channel}"
  [[ "$found" -lt 500 ]] || do_log "WARN the hub caps a call at 500: re-run for the rest"
  [[ "$skipped" == 0 ]]
}
