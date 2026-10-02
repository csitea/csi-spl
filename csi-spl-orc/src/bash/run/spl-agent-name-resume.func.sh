#!/bin/bash
#------------------------------------------------------------------------------
# @description Every live claude on THIS machine carries the ONE name (spec
# @description 061, owner 07af027a): `--name` = its tmux window's first token =
# @description "c-NNN@<tag>", and SPOOL_AGENT_ID=<id> in its environment. One
# @description that does not (the old "<tag>: <id>" name, a bare id, a role
# @description renamed by do_spl_agent_id_rename, a resume that dropped
# @description SPOOL_AGENT_ID) is resumed in its own pane, same session, through
# @description restore-claude-plain.sh. Run it as the agent user (it reads the
# @description agents' /proc environ and ~/.claude/sessions). The caller's own
# @description claude is never touched. Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param RESUME_ONLY (optional) - ids to resume, comma separated (old or new
# @param   form); roles go one at a time, the orchestrator last
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_name_resume
# @example DRY_RUN=0 RESUME_ONLY=c-003 ./run -a do_spl_agent_name_resume
#------------------------------------------------------------------------------
do_spl_agent_name_resume() {
  local dry=1 args=()
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  (( dry )) || args+=(--apply)
  [[ -n "${RESUME_ONLY:-}" ]] && args+=(--only "$RESUME_ONLY")
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-name-resume.sh" "${args[@]}"
}
