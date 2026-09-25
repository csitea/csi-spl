#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat agents in a channel on a cloud env's DEPLOYED hub, as a
# @description signed-in tenant member - the web UI's "channel -> Agents -> add"
# @description without a browser (specs/038: an agent may post only into a
# @description channel it is a member of). Optionally creates the channel first
# @description (the member becomes its owner; an existing one is fine).
# @description Agents must be announced on AGENT_BOX (a seated desk is). Only
# @description the channel's owner (or anyone, for #lobby / #tasks / #alerts)
# @description may add agents; the hub answers 403 otherwise.
# @description The password is read from a 0600 file and never printed.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param CHANNEL - required: the channel id
# @param AGENTS - required: space-separated agent ids, e.g. "CLE-555 CLE-666"
# @param AGENT_BOX (optional) - default box-desk
# @param CHANNEL_CREATE (optional) - 1 = create the channel first, default 0
# @param MEMBER_EMAIL (optional) - default m3-e2e-human@example.com (the M3 e2e member)
# @param MEMBER_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 CHANNEL=agent-post-proof CHANNEL_CREATE=1 AGENTS="CLE-555 CLE-666" DRY_RUN=0 ./run -a do_spl_channel_agent_add
#------------------------------------------------------------------------------
do_spl_channel_agent_add() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-box-desk}" agents="${AGENTS:-}" a
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL AGENT_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ -n "$agents" ]] || { do_log "FATAL AGENTS must name at least one agent id"; return 1; }
  for a in $agents; do
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ && "${a%%-*}" != BOX && "${a%%-*}" != HUM ]] || { do_log "FATAL AGENTS entry '$a' is not an agent id"; return 1; }
  done
  [[ "${CHANNEL_CREATE:-0}" =~ ^[01]$ ]] || { do_log "FATAL CHANNEL_CREATE must be 0 or 1"; return 1; }
  local api
  api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  if (( dry )); then
    do_log "INFO DRY_RUN would: sign in on $api$([[ ${CHANNEL_CREATE:-0} == 1 ]] && echo ", create #$ch,") and add $agents on $box to #$ch in $tenant"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  local pw="${MEMBER_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}" out rc=0
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set MEMBER_PW_FILE)"; return 1; }
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="$agents" SEAT_BOX="$box" SEAT_CREATE="${CHANNEL_CREATE:-0}" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/channel-agent-add.py")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL seating $agents in #$ch on $ENV/$tenant (exit $rc): $out"; return 1; }
  do_log "OK seated $agents in #$ch on $ENV/$tenant: $out"
}
