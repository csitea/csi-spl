#!/bin/bash
#------------------------------------------------------------------------------
# @description Reopen one auto-closed epic as the lease's seated desk: unarchive
# @description it, set it wip and comment why (li_epic_reopen, SPL-2558). The
# @description placer and the enqueue call it for a brief whose Epic: line names
# @description an epic the hub auto-closed (SPL-1729). When the lease's desk
# @description moved (spec 069 8.4), the action re-runs once as the desk's owner:
# @description the desk is 0700 under that user, so the box user's placer cron
# @description would find no seated desk (R7 W1 of SPL-4985).
# @description A dry run (the default) prints what it would do and calls no hub.
# @param EPIC_KEY - required: the epic, e.g. SPL-12
# @param EPIC_COMMENT - required: the comment that says why it was reopened
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ENV TENANT_ID (optional) - default LEASE_ENV / LEASE_TENANT of <spool root>/dispatch/lease.conf
# @param DESK_AGENT (optional) - default the lease's first seated desk on this box
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example EPIC_KEY=SPL-12 EPIC_COMMENT='Reopened: brief x names it' ./run -a do_spl_epic_reopen
# @example EPIC_KEY=SPL-12 EPIC_COMMENT='Reopened: brief x names it' DRY_RUN=0 ./run -a do_spl_epic_reopen
#------------------------------------------------------------------------------
do_spl_epic_reopen() {
  local root="${SPOOL_ROOT:-/var/spool-hub}"
  [[ "${EPIC_KEY:-}" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { do_log "FATAL EPIC_KEY must be an issue key like SPL-12, got: '${EPIC_KEY:-}'"; return 1; }
  [[ -n "${EPIC_COMMENT:-}" ]] || { do_log "FATAL EPIC_COMMENT must say why $EPIC_KEY is reopened"; return 1; }
  declare -F li_epic_reopen >/dev/null ||
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || return 1
  declare -F spl_lane_issue_desk >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-issue.func.sh" || return 1
  spl_epic_reopen_moved && return "$EPIC_REOPEN_HOP_RC"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would reopen $EPIC_KEY (unarchive, wip, one comment) as the lease's desk"
    return 0
  fi
  spl_lane_issue_desk "$root" 0 || return 1
  li_epic_reopen "$EPIC_KEY" "$EPIC_COMMENT"
}

# spl_epic_reopen_moved: 0 when the lease's desk moved and the action just
# re-ran as its owner, whose rc is in EPIC_REOPEN_HOP_RC; 1 when it runs here.
spl_epic_reopen_moved() {
  local ENV="${ENV:-}" TENANT_ID="${TENANT_ID:-}" box hop_to
  spl_lane_issue_where "${SPOOL_ROOT:-/var/spool-hub}" >/dev/null 2>&1 || return 1
  box="${DESK_BOX:-$(spl_desk_box_default)}"
  hop_to="$(spl_desk_action_hop_to "$TENANT_ID" "$box")" || return 1
  EPIC_REOPEN_HOP_RC=0
  spl_desk_action_hop do_spl_epic_reopen "$hop_to" "$TENANT_ID" "$box" "${DESK_AGENT:-}" EPIC_KEY EPIC_COMMENT || EPIC_REOPEN_HOP_RC=$?
}
