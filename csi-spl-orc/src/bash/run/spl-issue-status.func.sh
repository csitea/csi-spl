#!/bin/bash
#------------------------------------------------------------------------------
# @description One issue's status on the hub, read-only: `spool issue get` as
# @description the lease's seated desk (the same desk do_spl_lane_issue files
# @description with). The /exit-clean issue gate (li_gate, spawn-agents/lib/
# @description lane-issue.inc.sh) asks it when a lane landed no commit: an
# @description issue the orchestrator already set done on the hub lets the
# @description lane exit (SPL-1813). Prints one line `issue-status<TAB><key>
# @description <TAB><status>`, and for an archived issue (SPL-2607) a 4th
# @description field: `auto-closed` when the hub's SPL-1729 epic close archived
# @description it, else `archived` (SPL-2558: the placer reopens only the
# @description first); exit 1 when the hub read fails or has no status.
# @description A read, so it calls the hub without DRY_RUN=0.
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param ENV TENANT_ID (optional) - default LEASE_ENV / LEASE_TENANT of <spool root>/dispatch/lease.conf
# @param DESK_AGENT (optional) - default the lease's first seated desk on this box
# @param DESK_BOX (optional) - default this box's desk box
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ISSUE_REF=SPL-12 ./run -a do_spl_issue_status
#------------------------------------------------------------------------------
do_spl_issue_status() {
  do_require_bin jq || return 1
  spl_issue_check_ref || return 1
  local out st arch
  spl_lane_issue_desk "${SPOOL_ROOT:-/var/spool-hub}" 0 || return 1
  out="$(spl_desk_issue_run get --ref "$ISSUE_REF")" || return 1
  st="$(tail -n 1 <<<"$out" | jq -r '(.result.issue.status // .result.status // "")' 2>/dev/null)"
  [[ "$st" =~ ^[a-z_]+$ ]] || { do_log "FATAL no status for $ISSUE_REF in the hub answer"; return 1; }
  arch="$(tail -n 1 <<<"$out" | jq -r '(.result.issue // .result) as $i | if ($i.archived // false) != true then "" elif $i.auto_closed == true then "\tauto-closed" else "\tarchived" end' 2>/dev/null)"
  printf 'issue-status\t%s\t%s%s\n' "$ISSUE_REF" "$st" "$arch"
}
