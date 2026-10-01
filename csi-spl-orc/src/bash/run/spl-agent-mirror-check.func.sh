#!/bin/bash
#------------------------------------------------------------------------------
# @description Per live agent on this box: is its terminal mirrored into its
# @description web UI DM (specs/036, owner 2026-10-01 "per launch")? One row per
# @description agent (mirrored yes/no and why), then a summary line naming the
# @description agents that need a relaunch to pick the hooks up. Mirrored =
# @description the CLI loads the mirror hook (claude: --settings or
# @description ~/.claude/settings.json), its process env names its id, it has a
# @description desk seat, and $SPOOL_ROOT/.mirror-off is absent. The live agents
# @description come from the identity map's facts (agent-identity.py), never a
# @description window name. Read-only; exit 1 when an agent is not mirrored.
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param MIRROR_CHECK_JSON (optional) - 1 = one JSON object per agent
# @example ./run -a do_spl_agent_mirror_check
#------------------------------------------------------------------------------
do_spl_agent_mirror_check() {
  do_require_bin python3 || return 1
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  local py="$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-mirror-check.py"
  ai_panes | ai_py facts | python3 "$py" ${MIRROR_CHECK_JSON:+--json}
}
