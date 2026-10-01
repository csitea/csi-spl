#!/bin/bash
#------------------------------------------------------------------------------
# @description Record every live agent into the box's identity map:
# @description $SPOOL_ROOT/agents/<ID>.json, one per agent, plus index.json
# @description (a sha256 of all records that changes exactly when one does).
# @description Each value comes from the agent's PROCESS: SPOOL_AGENT_ID from
# @description its environment, the session from its own sessions/<pid>.json
# @description (else --session-id / --resume), its cwd, and the tmux pane whose
# @description process tree holds it. A window name or a registry row is never
# @description read as identity. A record outlives its process (alive=false),
# @description keeping session_id + worktree for a restore. An id carried by
# @description two live processes is reported and not recorded.
# @description Dry run unless DRY_RUN=0: prints one PLAN line per record that
# @description would change; DRY_RUN=0 writes them (atomic) and the index.
# @description Idempotent: an unchanged record is never rewritten.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub; the map is <root>/agents
# @param SPOOL_TMUX_SOCKET (optional) - the box's tmux server (else $TMUX, else the default socket)
# @example ./run -a do_spl_agent_identity_record
# @example DRY_RUN=0 ./run -a do_spl_agent_identity_record
#------------------------------------------------------------------------------
do_spl_agent_identity_record() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  if [[ "$dry" == 0 ]]; then ai_record --apply; else ai_record; fi
}
