#!/bin/bash
#------------------------------------------------------------------------------
# @description The dead-agent reaper (specs/061 section 3.6): every agent id
# @description this machine holds whose agent has been dead for
# @description SPOOL_ID_REAP_H hours (default 6) is retired exactly as
# @description do_spl_agent_id_retire does it. Dead = no tmux window carries
# @description the id and its identity record does not prove a live process;
# @description dead since = the record's alive=false time, else the reaper's
# @description own first tick that saw it dead. Role ids (001-003) never; a
# @description blind tmux view or a gap in the ticks decides nothing. One
# @description PLAN|REAP / KEEP / SKIP line per decision.
# @description Dry run unless DRY_RUN=0. The cron line is
# @description do_spl_agent_id_reap_install_cron.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ID_REAP_H (optional) - hours dead before the retire, default 6
# @param SPOOL_ID_REAP_GAP_MIN (optional) - a tick gap that restarts the clock, default 60
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param RETIRE_LANE (optional) - 0 skips the hub lane row
# @example ./run -a do_spl_agent_id_reap
# @example DRY_RUN=0 ./run -a do_spl_agent_id_reap
#------------------------------------------------------------------------------
do_spl_agent_id_reap() {
  local dry="${DRY_RUN:-1}" args=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$dry" == 0 ]] && args=(--apply)
  DRY_RUN="$dry" bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-id-reap.sh" "${args[@]}"
}
