#!/bin/bash
#------------------------------------------------------------------------------
# @description Bug B (t1 #spool-hub-bugs 4ecb4b0d): measure how late a person's
# @description message reaches the OTHER person on the LIVE path. Two sessions
# @description of the m3-e2e member: a RECEIVER socket kept open for the whole
# @description run (a tab left open) and a FRESH sender socket per send (a
# @description person who just opened the app). Per send: send -> hub ack,
# @description send -> the receiver's socket event, and a MISS when that event
# @description never comes within PROBE_WAIT (then the WUI's catch-up read).
# @description Prints p50 / p90 / max and writes delivery-results.json.
# @description
# @description A receiver left on a retired Cloud Run revision is the case it
# @description exists for: run it across a hub deploy and the misses show up.
# @description
# @description It sends real messages, into a TEST tenant only (e2e, or
# @description e2e-<x>); it is a dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - default e2e; must match ^e2e(-[a-z0-9]+)?$
# @param PROBE_N (optional) - sends, default 20
# @param PROBE_GAP (optional) - seconds between sends, default 20
# @param PROBE_WAIT (optional) - seconds a live frame may take, default 30
# @param PROBE_FRESH_SENDER (optional) - 1 (default) new sender socket per send
# @param PROBE_CHECK_EVERY (optional) - 0 (default) a raw receiver socket; N =
# @param   the receiver re-dials like the WUI when GET /v1/wui/revision moves
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd DRY_RUN=0 PROBE_N=24 ./run -a do_spl_delivery_probe
#------------------------------------------------------------------------------
do_spl_delivery_probe() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-e2e}"
  spl_delivery_probe_tenant_ok "$tenant" || return 1

  local api_fqdn hub st email
  spl_cnf_api_fqdn api_fqdn || return 1
  hub="https://$api_fqdn"
  st="$SPL_STATE_DIR/m3-e2e/$tenant"
  if (( dry )); then
    do_log "INFO DRY_RUN would: sign the m3-e2e member of $tenant in twice on $hub and send ${PROBE_N:-20} messages, timing each to the other session's socket"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to measure."
    return 0
  fi
  email="$(cat "$st/human-email" 2>/dev/null || true)"
  [[ -n "$email" && -s "$st/pw-human" ]] || {
    do_log "FATAL no seated m3-e2e member in $st: run ENV=$ENV TENANT_ID=$tenant DRY_RUN=0 ./run -a do_spl_m3_e2e first"; return 1; }
  local out="$st/delivery-results.json" rc=0
  PROBE_N="${PROBE_N:-20}" PROBE_GAP="${PROBE_GAP:-20}" PROBE_WAIT="${PROBE_WAIT:-30}" \
  PROBE_FRESH_SENDER="${PROBE_FRESH_SENDER:-1}" PROBE_CHECK_EVERY="${PROBE_CHECK_EVERY:-0}" PROBE_OUT="$out" \
  M3_HUB_URL="$hub" M3_AUTH_URL="$hub" M3_TENANT="$tenant" M3_STATE="$st" M3_HUMAN_EMAIL="$email" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/delivery-probe.py" || rc=$?
  (( rc == 0 )) || { do_log "FAIL the delivery probe on $tenant ($ENV) measured nothing: see $out"; return 1; }
  do_log "OK delivery measured on $tenant ($ENV): $out"
}

# spl_delivery_probe_tenant_ok <tenant>: only a test tenant is ever written to.
spl_delivery_probe_tenant_ok() {
  [[ "$1" =~ ^e2e(-[a-z0-9]+)?$ ]] && return 0
  do_log "FATAL TENANT_ID '$1' is not a test tenant (^e2e(-[a-z0-9]+)?\$): the probe posts real messages"
  return 1
}
