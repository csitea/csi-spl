#!/bin/bash
#------------------------------------------------------------------------------
# @description Print a workspace's agent caps by vendor and the live count of
# @description each (spec 147 6.2, SPL-2675), as the hub answers this
# @description machine's desk box: {workspace_id, caps, live, can_edit}, caps
# @description null = uncapped. Read-only. The caps are set by the spool-hub
# @description admin only (PUT /v1/operator/workspaces/{id}/agent-caps, the
# @description operator console); a workspace reads them here or in its
# @description settings. The hub refuses a seat over a cap on every path
# @description (SetRoster); do_spl_desk_up also checks first (spl_desk_cap_check).
# @param ENV - required: dev or prd, or self for a self-hosted hub
# @param TENANT_ID - required: the workspace slug
# @param DESK_BOX (optional) - default box-desk: a desk box of this machine
# @param   that is pinned in TENANT_ID (do_spl_desk_up pins it)
# @example ENV=dev TENANT_ID=example-ws ./run -a do_spl_agent_caps
#------------------------------------------------------------------------------
do_spl_agent_caps() {
  do_require_bin python3 yq || return 1
  spl_box_ws_guard "${TENANT_ID:-}" || return 1
  do_spl_desk_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}"
  spl_desk_validate "$tenant" "$box" none || return 1
  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  [[ -s "$d/pinned" ]] || {
    do_log "FATAL $box is not pinned in $tenant on this machine ($d/pinned): seat a desk there first (do_spl_desk_up)"; return 1; }
  spl_host_spool || return 1
  spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- caps
}

# spl_desk_cap_check <state dir> <box> <tenant> <hub> <agent>: do_spl_desk_up's
# courtesy pre-check (spec 147 5.2), before any dir or process: 1 when the
# workspace's cap for the agent's vendor is already reached (spl_kind_of_agent_id
# and `spool caps check`, the FATAL names agent, vendor, workspace, cap and live
# count), else 0. The hub's SetRoster gate is the authority, so the check never
# blocks when it cannot ask: a box not pinned here yet (first seat), an agent
# whose desk dir is already there (a re-seat adds nothing), or a hub that does
# not answer the caps lane (an older hub) all go on with an INFO / WARN line.
spl_desk_cap_check() {
  local d="$1" box="$2" tenant="$3" hub="$4" agent="$5" out rc=0 kind
  kind="$(spl_kind_of_agent_id "$agent")" || { do_log "INFO $agent has no vendor kind: no cap pre-check"; return 0; }
  if [[ -d "$d/spool/$agent" ]]; then
    do_log "INFO $agent ($kind) already has its desk dir on $box: no cap pre-check (a re-seat adds no agent)"; return 0
  fi
  if [[ ! -s "$d/pinned" ]]; then
    do_log "INFO $box is not pinned in $tenant here yet: no cap pre-check (the hub's seat gate decides)"; return 0
  fi
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- caps check "$agent" 2>&1)" || rc=$?
  case "$rc" in
    0) do_log "INFO cap pre-check: ${out:-ok}"; return 0 ;;
    3) do_log "FATAL $out"; return 1 ;;
    *) do_log "WARN cap pre-check of $agent ($kind) in $tenant not answered (rc $rc: ${out##*$'\n'}); the hub's seat gate still decides"
       return 0 ;;
  esac
}
