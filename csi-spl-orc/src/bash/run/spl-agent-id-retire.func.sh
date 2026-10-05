#!/bin/bash
#------------------------------------------------------------------------------
# @description Retire an agent id on THIS machine (specs/061 section 3.6), so
# @description the allocator may reuse its number after the quarantine
# @description (SPOOL_ID_QUARANTINE_H, default 24). Moves the spool dir whole
# @description to $SPOOL_ROOT/.retired/<ID>.<spawned-utc>/ (unread mail stays
# @description there), the registry.tsv rows to registry.retired.tsv with a
# @description retired-utc column, the identity record to agents/retired/
# @description (index.json re-hashed), and closes the hub lane row (state
# @description done). Refuses a role id (001-003) and an id a tmux window
# @description still carries. /exit-clean runs the same script after its
# @description window closes (tmux-close-window.sh --retire).
# @description It also writes the id's alias row (agent-id-aliases.tsv: old ->
# @description RETIRE_SUCCESSOR, else "retired") and drops the id's seat from
# @description every hub desk of this box, so no desk announces it as a
# @description member / tag target (owner 2026-10-05, t1 dc6d5e3f). With
# @description HUB_ENV a legacy id's successor row also goes into the hub's
# @description agent_id_aliases (do_spl_agent_id_map's writer).
# @description Dry run unless DRY_RUN=0: prints one PLAN line per step.
# @param AGENT_ID (required) - the id to retire, e.g. c-004 (or <ID>@<box>)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param RETIRE_LANE (optional) - 0 skips the hub lane row
# @param RETIRE_SUCCESSOR (optional) - the new id taking over a legacy id
# @param RETIRE_DESKS (optional) - 0 leaves the desk seats
# @param HUB_ENV (optional) - dev or prd: write the hub alias row there (prd
# @param   needs the owner's go)
# @example AGENT_ID=c-004 ./run -a do_spl_agent_id_retire
# @example AGENT_ID=c-004 DRY_RUN=0 ./run -a do_spl_agent_id_retire
# @example AGENT_ID=CLE-35012 RETIRE_SUCCESSOR=c-012 HUB_ENV=dev DRY_RUN=0 ./run -a do_spl_agent_id_retire
#------------------------------------------------------------------------------
do_spl_agent_id_retire() {
  local dry="${DRY_RUN:-1}" args=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -n "${AGENT_ID:-}" ]] || { do_log "FATAL AGENT_ID must be set (the id to retire, e.g. c-004)"; return 1; }
  [[ "$dry" == 0 ]] && args=(--apply)
  [[ -n "${RETIRE_SUCCESSOR:-}" ]] && args+=(--successor "$RETIRE_SUCCESSOR")
  [[ -z "${HUB_ENV:-}" || "$HUB_ENV" == dev || "$HUB_ENV" == prd ]] || { do_log "FATAL HUB_ENV must be dev or prd, got: '$HUB_ENV'"; return 1; }
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-id-retire.sh" "${args[@]}" "$AGENT_ID" || return 1
  [[ -n "${HUB_ENV:-}" && -n "${RETIRE_SUCCESSOR:-}" ]] || return 0
  ENV="$HUB_ENV" spl_agent_id_map_hub "$dry"
}
