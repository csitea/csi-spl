#!/bin/bash
#------------------------------------------------------------------------------
# @description Derive every agent window's name from the identity map:
# @description record the live agents first (do_spl_agent_identity_record),
# @description then set each agent window to "<tag>: <ID> [badge] <title>",
# @description the title taken from the agent's own session name (/rename,
# @description --name). The id always comes from the process environment, so
# @description a window that took a neighbour's name is put back. Only windows
# @description that hold a recorded agent are touched; the state badge is kept
# @description when the window already carries the right id. Each rename is a
# @description compare-and-set on the pane id, never a window index, and the
# @description window stops taking names from the CLI's terminal title.
# @description Dry run unless DRY_RUN=0 (PLAN lines only).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub; the map is <root>/agents
# @param SPOOL_TMUX_SOCKET (optional) - the box's tmux server
# @param SPOOL_BOX_TAG (optional) - the box tag; else the one most agent windows carry
# @example ./run -a do_spl_agent_identity_reconcile
# @example DRY_RUN=0 ./run -a do_spl_agent_identity_reconcile
#------------------------------------------------------------------------------
do_spl_agent_identity_reconcile() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  if [[ "$dry" == 0 ]]; then ai_reconcile --apply; else ai_reconcile; fi
}
