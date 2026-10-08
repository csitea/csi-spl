#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove OLD Claude Code session transcripts of dead sessions
# @description (~/.claude/projects/<slug>/<uuid>.jsonl and its <uuid>/ dir) for
# @description each agent user, as that user: only when no agent record names
# @description the session (a restore could resume it), no live process claims
# @description it, and nothing of it changed for AGE_DAYS days. One PLAN|REMOVE
# @description / KEEP line per session. Dry run unless DRY_RUN=0. Runs every 4 h
# @description inside do_box_disk_sweep.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param AGE_DAYS (optional) - idle days before removal, default 3
# @param SESSION_PRUNE_USERS (optional) - space-separated users; default the
# @param   box user, SPOOL_AGENT_USER and the spool-agents group
# @example ./run -a do_spl_session_prune
# @example DRY_RUN=0 ./run -a do_spl_session_prune
#------------------------------------------------------------------------------
do_spl_session_prune() {
  DRY_RUN="${DRY_RUN:-1}" AGE_DAYS="${AGE_DAYS:-3}" bash "$PROJ_PATH/src/bash/scripts/spl-session-prune.sh"
}
