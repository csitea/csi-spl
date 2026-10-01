#!/bin/bash
#------------------------------------------------------------------------------
# @description CLE-77911: make the satellite's AGENT user, the user every
# @description agent there runs as (global rule: programmatic Claude Code
# @description starts run as the agent user, like on the box PC). Over the IAP
# @description ssh as the box user, with sudo: the spool group, the agent user
# @description (a FIXED uid, home on the data disk so a recreate keeps its
# @description claude login), its docker + spool groups, linger, and the spool
# @description root (<box user>:<group> 2770 + default ACLs). One AGENT line per
# @description part; idempotent. A dry run unless DRY_RUN=0.
# @description Then the owner logs in to claude AS the agent user once (SYS.md 1.5.9).
# @param DRY_RUN (optional) - 1 (default): PLAN lines only; 0 applies
# @param SPOOL_AGENT_USER - required: the agent user (the same value as the box PC's box.env; no default)
# @param AGENT_UID (optional) - default 1001
# @param SPOOL_GROUP (optional) - default spool-agents
# @example SPOOL_AGENT_USER=<HARNESS_USER> ./run -a do_satellite_agent_user
# @example SPOOL_AGENT_USER=<HARNESS_USER> DRY_RUN=0 ./run -a do_satellite_agent_user
#------------------------------------------------------------------------------
do_satellite_agent_user() {
  : "${SPOOL_AGENT_USER:?SPOOL_AGENT_USER must be set (no default) - the agent user, as in box.env on the box PC}"
  [[ "$SPOOL_AGENT_USER" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { do_log "FATAL SPOOL_AGENT_USER is not a user name: '$SPOOL_AGENT_USER'"; return 1; }
  do_satellite_ssh_opts || return 1
  local env="DRY_RUN='${DRY_RUN:-1}' AGENT_USER='$SPOOL_AGENT_USER' AGENT_UID='${AGENT_UID:-1001}' SPOOL_GROUP='${SPOOL_GROUP:-spool-agents}'"
  # shellcheck disable=SC2029 # expanded here on purpose: the values travel to the VM
  ssh "${SATELLITE_SSH[@]}" "$env bash -s" <"${PROJ_PATH}/src/bash/scripts/satellite-agent-user.sh" ||
    { do_log "FATAL a part failed (the AGENT line above)"; return 1; }
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to apply."
  else
    do_log "OK the agent user is ready; next, the owner's claude login as it: ssh satellite, then sudo -iu $SPOOL_AGENT_USER claude"
  fi
}
