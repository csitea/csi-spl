#!/bin/bash
#------------------------------------------------------------------------------
# @description List, add or remove ONE fleet desk box of a cloud env's hub
# @description (spec 158 section 4.2 item 2, rdb 0230 fleet_desk_boxes, build
# @description row T6): the desk boxes of the operator workspace that may
# @description self-enrol a key into every workspace marked for fleet seating.
# @description THROUGH THE HUB: GET /v1/operator/fleet-desks, PUT and DELETE
# @description /v1/operator/fleet-desks/{box}, authenticated as the env's
# @description project service account (do_gcp_pin_account; never the owner
# @description account). The hub refuses a box with no live pin in the
# @description operator workspace (409 no_live_pin) and writes one
# @description operator_audit row per change. Removing a box stops its new
# @description enrolments; its pins elsewhere stay (spec 158 4.2.5).
# @description FLEET_DESK_CMD=list reads only. add / remove: DRY_RUN=1
# @description (default) prints the change and calls no cloud. Adding a real
# @description box on dev or prd is the orchestrator's, with the owner's go.
# @param ENV - required: dev or prd
# @param FLEET_DESK_CMD (optional) - list (default), add or remove
# @param BOX_ID - required for add and remove: the box id, ^[a-z0-9][a-z0-9-]{0,31}$
# @param DRY_RUN (optional) - 1 (default) or 0, for add and remove
# @example ENV=dev ./run -a do_spl_fleet_desk_box
# @example ENV=dev FLEET_DESK_CMD=add BOX_ID=desk-a ./run -a do_spl_fleet_desk_box
# @example ENV=dev FLEET_DESK_CMD=remove BOX_ID=desk-a DRY_RUN=0 ./run -a do_spl_fleet_desk_box
#------------------------------------------------------------------------------
do_spl_fleet_desk_box() {
  do_require_bin jq curl gcloud yq || return 1
  local cmd="${FLEET_DESK_CMD:-list}" box="${BOX_ID:-}" dry=1 method path
  case "$cmd" in
    list) method=GET; path=/v1/operator/fleet-desks ;;
    add|remove)
      [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
        || { do_log "FATAL BOX_ID must match ^[a-z0-9][a-z0-9-]{0,31}\$, got: '$box'"; return 1; }
      method=PUT; [[ "$cmd" == remove ]] && method=DELETE
      path="/v1/operator/fleet-desks/$box"
      if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi ;;
    *) do_log "FATAL FLEET_DESK_CMD must be list, add or remove, got: '$cmd'"; return 1 ;;
  esac
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if [[ "$cmd" != list ]] && (( dry )); then
    do_log "OK DRY_RUN would $method $SPL_HUB_URL$path ($cmd fleet desk box $box), as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call "$method" "$path" || return 1
  _spl_fleet_desk_box_report "$cmd" "$box"
}

# _spl_fleet_desk_box_report <cmd> <box> -> the hub's answer as OK lines, or
# the refusal as one FATAL line
_spl_fleet_desk_box_report() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$1:$SPL_HUB_OP_STATUS" in
    list:200)
      do_log "OK $ENV fleet desk boxes: $(jq -r '.items | length' <<<"$SPL_HUB_OP_BODY")"
      jq -r '.items[] | "  \(.box_id)  live_pin=\(.live_pin)  added_by=\(.added_by)  added_at=\(.added_at)"' <<<"$SPL_HUB_OP_BODY"
      return 0 ;;
    add:201) do_log "OK $ENV fleet desk box $2 added ($GCP_ACCOUNT)"; return 0 ;;
    add:200) do_log "OK $ENV fleet desk box $2 was already listed: nothing changed"; return 0 ;;
    remove:204) do_log "OK $ENV fleet desk box $2 removed ($GCP_ACCOUNT): its new enrolments stop"; return 0 ;;
    add:409) do_log "FATAL the hub refused $2 (409): $detail. Pin it in the operator workspace first. Nothing changed."; return 1 ;;
    remove:404) do_log "FATAL $2 is not a fleet desk box of $ENV (404). Nothing changed."; return 1 ;;
    *:401|*:403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    *) do_log "FATAL fleet desk $1 failed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
}
