#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat ONE box agent at the LOCAL spool hub (the docker compose
# @description hub on 127.0.0.1, do_spl_local_hub_up), only when the owner
# @description allows it: the first seat needs a join token a workspace admin
# @description minted in that hub's Settings -> Agents. No agent is seated
# @description there by default, and none by do_spl_desk_up_all or the
# @description reconcile cron: those read the dev/prd state dirs, never this one.
# @description Each agent gets its OWN desk box lh-<agent> and box key, so its
# @description token admits that one agent, and do_spl_local_hub_agent_leave
# @description stops that box's sidecar without taking any other seat offline.
# @description An agent is DEDICATED to one workspace: joined to one, a join to
# @description another is refused until it leaves.
# @description It runs do_spl_desk_up with ENV=self against
# @description http://127.0.0.1:<hub port>; the box names its tenant with
# @description X-Spool-Tenant (SPOOL_TENANT), which the hub honours on a host
# @description that is not a tenant host (specs/026 section 4).
# @description Refused: a non-loopback SPOOL_HUB_URL (a cloud hub never),
# @description ENV other than self, ROOT_KEY_JSON, SPOOL_JOIN_TOKEN in the
# @description environment (the token comes from a 0600 file and never reaches
# @description argv or output). Dry run unless DRY_RUN=0.
# @param LOCAL_HUB_TENANT - required: the workspace slug (spl_local_hub_private_cnf when loaded)
# @param DESK_AGENT - required: the agent id of the pane to seat
# @param LOCAL_HUB_JOIN_TOKEN_FILE - required on the first join of the agent's
# @param   box: a 0600 file holding the join token spj1.<workspace>.<secret>
# @param LOCAL_HUB_HUB_PORT (optional) - the hub's loopback port, default 58180
# @param   (spl_local_hub_cnf when loaded)
# @param LOCAL_HUB_DESK_BOX (optional) - default lh-<agent, lower case>
# @param LOCAL_HUB_DESK_STATE (optional) - default $HOME/.local/share/<org>-<app>/local-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example LOCAL_HUB_TENANT=<workspace> DESK_AGENT=c-123 LOCAL_HUB_JOIN_TOKEN_FILE=<0600 file> DRY_RUN=0 ./run -a do_spl_local_hub_agent_join
#------------------------------------------------------------------------------

# spl_local_hub_agent_ctx: validate the inputs both actions share and set
# LH_TENANT, LH_AGENT, LH_BOX, LH_STATE, LH_HUB. The tenant and the port come
# from the lead's cnf lib when it is loaded (no second parse here).
spl_local_hub_agent_ctx() {
  declare -F spl_local_hub_cnf >/dev/null && { spl_local_hub_cnf || return 1; }
  declare -F spl_local_hub_private_cnf >/dev/null && { spl_local_hub_private_cnf || return 1; }
  [[ -z "${ENV:-}" || "${ENV}" == self ]] ||
    { do_log "FATAL ENV=$ENV: the local hub is ENV=self only; a cloud desk is do_spl_desk_up"; return 1; }
  LH_TENANT="${LOCAL_HUB_TENANT:-}"
  [[ -n "$LH_TENANT" ]] || { do_log "FATAL LOCAL_HUB_TENANT is not set (no default): the local hub's workspace slug"; return 1; }
  spl_require_tenant_slug "$LH_TENANT" || return 1
  declare -F spl_is_participant_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  LH_AGENT="${DESK_AGENT:-}"
  spl_is_participant_id "$LH_AGENT" || { do_log "FATAL DESK_AGENT '$LH_AGENT' is not an agent id (e.g. c-123)"; return 1; }
  LH_BOX="${LOCAL_HUB_DESK_BOX:-lh-${LH_AGENT,,}}"
  [[ "$LH_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL desk box '$LH_BOX' is not a box id"; return 1; }
  local port="${LOCAL_HUB_HUB_PORT:-58180}"
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
    do_log "FATAL LOCAL_HUB_HUB_PORT must be a port number, got: '$port'"; return 1
  fi
  LH_HUB="http://127.0.0.1:$port"
  if [[ -n "${SPOOL_HUB_URL:-}" && ! "${SPOOL_HUB_URL%/}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$ ]]; then
    do_log "FATAL SPOOL_HUB_URL=$SPOOL_HUB_URL is not a loopback hub: an agent joins the local hub on 127.0.0.1 only, never a cloud hub"
    return 1
  fi
  [[ -z "${SPOOL_HUB_URL:-}" ]] || LH_HUB="${SPOOL_HUB_URL%/}"
  local base; base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
  LH_STATE="${LOCAL_HUB_DESK_STATE:-$HOME/.local/share/${base%-orc}/local-hub}"
}

do_spl_local_hub_agent_join() {
  spl_local_hub_agent_ctx || return 1
  [[ -z "${ROOT_KEY_JSON:-}" ]] || { do_log "FATAL ROOT_KEY_JSON is refused: a local hub agent joins with a join token only (LOCAL_HUB_JOIN_TOKEN_FILE)"; return 1; }
  [[ -z "${SPOOL_JOIN_TOKEN:-}" ]] ||
    { do_log "FATAL SPOOL_JOIN_TOKEN in the environment is refused: put the token in a 0600 file and pass LOCAL_HUB_JOIN_TOKEN_FILE"; return 1; }
  local d="$LH_STATE/desk/$LH_TENANT/$LH_BOX" f="${LOCAL_HUB_JOIN_TOKEN_FILE:-}" tok="" o
  for o in "$LH_STATE"/desk/*/"$LH_BOX"; do
    [[ -d "$o" && "$o" != "$d" ]] || continue
    do_log "FATAL $LH_AGENT is dedicated to another workspace on this box ($o): one agent serves one workspace; it leaves that one first, or the workspace gets its own agent"
    return 1
  done
  if [[ ! -s "$d/pinned" ]]; then
    [[ -n "$f" ]] || { do_log "FATAL $LH_AGENT has not joined the local hub: the owner allows it with a join token (Settings -> Agents of the local hub) in a 0600 file, LOCAL_HUB_JOIN_TOKEN_FILE"; return 1; }
    [[ -f "$f" && -r "$f" ]] || { do_log "FATAL LOCAL_HUB_JOIN_TOKEN_FILE $f is not a readable file"; return 1; }
    [[ "$(stat -c %a "$f")" == 600 ]] || { do_log "FATAL LOCAL_HUB_JOIN_TOKEN_FILE $f must be mode 0600"; return 1; }
    tok="$(head -n 1 "$f")"; tok="${tok%$'\r'}"
    SPOOL_JOIN_TOKEN="$tok" spl_desk_join_token_ok "$LH_TENANT" || return 1
  fi
  mkdir -p "$LH_STATE" && chmod 700 "$LH_STATE" || return 1
  ( unset ROOT_KEY_JSON
    [[ -n "$tok" ]] && export SPOOL_JOIN_TOKEN="$tok"
    ENV=self TENANT_ID="$LH_TENANT" DESK_AGENT="$LH_AGENT" DESK_BOX="$LH_BOX" SPOOL_HUB_URL="$LH_HUB" \
      SPL_STATE_DIR="$LH_STATE" DRY_RUN="${DRY_RUN:-1}" do_spl_desk_up ) || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK $LH_AGENT joined the local hub $LH_HUB as $LH_BOX in $LH_TENANT; it leaves with do_spl_local_hub_agent_leave"
  return 0
}
