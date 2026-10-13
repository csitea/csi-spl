#!/bin/bash
#------------------------------------------------------------------------------
# @description The reverse of do_spl_local_hub_agent_join: ONE agent leaves the
# @description local spool hub. Stops the sidecar of the agent's own box
# @description lh-<agent> (DESK_ALL=1 is safe: no other agent sits on it),
# @description moves the box dir to <state>/left/<tenant>/<box>.<ts> (the inbox
# @description is the record) and deletes its box key and pin there, so a
# @description rejoin needs a fresh join token. The hub keeps the pin until the
# @description owner revokes the seat in Settings -> Agents of the local hub.
# @description Idempotent: an agent that never joined is OK. Dry run unless DRY_RUN=0.
# @param LOCAL_HUB_TENANT - required: the workspace slug (spl_local_hub_private_cnf when loaded)
# @param DESK_AGENT - required: the agent id that leaves
# @param LOCAL_HUB_HUB_PORT, LOCAL_HUB_DESK_BOX, LOCAL_HUB_DESK_STATE (optional) - as do_spl_local_hub_agent_join
# @param DRY_RUN (optional) - 1 (default) or 0
# @example LOCAL_HUB_TENANT=<workspace> DESK_AGENT=c-123 DRY_RUN=0 ./run -a do_spl_local_hub_agent_leave
#------------------------------------------------------------------------------
declare -F spl_local_hub_agent_ctx >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-local-hub-agent-join.func.sh"

do_spl_local_hub_agent_leave() {
  spl_local_hub_agent_ctx || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local d="$LH_STATE/desk/$LH_TENANT/$LH_BOX" dst
  [[ -d "$d" ]] || { do_log "OK $LH_AGENT has not joined the local hub in $LH_TENANT ($d): nothing to leave"; return 0; }
  ( ENV=self TENANT_ID="$LH_TENANT" DESK_BOX="$LH_BOX" DESK_ALL=1 SPOOL_HUB_URL="$LH_HUB" \
      SPL_STATE_DIR="$LH_STATE" DRY_RUN="$dry" do_spl_desk_down ) || return 1
  if (( dry )); then
    do_log "INFO DRY_RUN would: move $d to $LH_STATE/left/$LH_TENANT/ and delete its box key and pin"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  dst="$LH_STATE/left/$LH_TENANT/$LH_BOX.$(date -u +%Y%m%dT%H%M%SZ)"
  if ! mkdir -p "${dst%/*}" || ! mv "$d" "$dst"; then do_log "FATAL cannot move $d to $dst"; return 1; fi
  rm -rf "$dst/keys" "$dst/pinned" || { do_log "FATAL cannot delete the box key under $dst"; return 1; }
  do_log "OK $LH_AGENT left the local hub: sidecar of $LH_BOX stopped, key deleted, inbox kept at $dst"
  do_log "OK the owner revokes the seat $LH_BOX in the local hub's Settings -> Agents; a rejoin needs a new join token"
}
