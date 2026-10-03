#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: measure how long each machine reads OFFLINE across
# @description hub rolls (t1 b3bf3d13). Polls the LIVE GET /v1/view/roster
# @description (the WUI's door, one member session) and GET /v1/wui/revision
# @description every WATCH_EVERY seconds for WATCH_SECS, one JSON line per read
# @description into WATCH_OUT, then prints per roll (a change of the serving
# @description revision) the offline windows per box: n, min, median, max
# @description seconds, plus any offline run with no roll near it. WATCH_SUMMARY
# @description re-summarises a recorded file with no network.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param WATCH_SECS (optional) - default 5400
# @param WATCH_EVERY (optional) - default 5
# @param WATCH_OUT (optional) - default <state>/box-presence/<env>-<tenant>-<utc>.jsonl
# @param WATCH_SUMMARY (optional) - a recorded JSONL: summarise it, read nothing live
# @param PROBE_EMAIL / PROBE_PW_FILE / PROBE_API (optional) - as do_spl_roster_show
# @example ENV=dev TENANT_ID=t1 WATCH_SECS=5400 ./run -a do_spl_box_presence_watch
# @example WATCH_SUMMARY=/path/dev-t1.jsonl ./run -a do_spl_box_presence_watch
#------------------------------------------------------------------------------
do_spl_box_presence_watch() {
  local py="$PROJ_PATH/src/bash/scripts/box-presence-watch.py"
  if [[ -n "${WATCH_SUMMARY:-}" ]]; then
    [[ -r "$WATCH_SUMMARY" ]] || { do_log "FATAL WATCH_SUMMARY $WATCH_SUMMARY is not readable"; return 1; }
    WATCH_SUMMARY="$WATCH_SUMMARY" python3 "$py"
    return
  fi
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" api
  spl_require_tenant_slug "$tenant" || return 1
  [[ "${WATCH_SECS:-5400}" =~ ^[1-9][0-9]*$ && "${WATCH_EVERY:-5}" =~ ^[1-9][0-9]*$ ]] \
    || { do_log "FATAL WATCH_SECS and WATCH_EVERY must be positive integers"; return 1; }
  spl_cnf_api_fqdn api || return 1
  local pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (run do_spl_m3_e2e first, or set PROBE_PW_FILE)"; return 1; }
  local out="${WATCH_OUT:-$SPL_STATE_DIR/box-presence/$ENV-$tenant-$(date -u +%Y%m%dT%H%M%SZ).jsonl}"
  mkdir -p "$(dirname "$out")" || return 1
  do_log "INFO watching $ENV/$tenant presence every ${WATCH_EVERY:-5}s for ${WATCH_SECS:-5400}s into $out"
  PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="${PROBE_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$pw" WATCH_SECS="${WATCH_SECS:-5400}" WATCH_EVERY="${WATCH_EVERY:-5}" WATCH_OUT="$out" python3 "$py"
}
