#!/bin/bash
#------------------------------------------------------------------------------
# @description Compare the box's identity map ($SPOOL_ROOT/agents) with the
# @description live agents, one row per agent, and exit 1 on any drift:
# @description a live agent missing from the map, a record that says alive
# @description with no such process, a pid / session / pane / window that
# @description differs, a window whose name carries another id, an id two
# @description processes carry, an agent in no tmux pane, or an index.json
# @description hash that no longer matches the records. Read-only.
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param SPOOL_TMUX_SOCKET (optional) - the box's tmux server (else $TMUX, else the default socket)
# @example ./run -a do_spl_agent_identity_check
#------------------------------------------------------------------------------
do_spl_agent_identity_check() {
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  ai_check
}
