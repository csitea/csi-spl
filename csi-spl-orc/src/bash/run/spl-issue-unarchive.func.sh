#!/bin/bash
#------------------------------------------------------------------------------
# @description Restore issues a do_spl_issue_archive run archived:
# @description `spool issue unarchive --as <agent> --ref <key>` for each key
# @description in ISSUE_KEYS_FILE, last key first. DRY_RUN=1 (the default)
# @description prints the count and the keys and restores nothing.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_KEYS_FILE - required: the journal do_spl_issue_archive wrote
# @param ISSUE_ARCHIVE_JOBS (optional) - how many restores run at once, default 4
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_KEYS_FILE=/tmp/archived.keys DRY_RUN=0 ./run -a do_spl_issue_unarchive
#------------------------------------------------------------------------------
do_spl_issue_unarchive() {
  [[ -n "${ISSUE_KEYS_FILE:-}" && -f "$ISSUE_KEYS_FILE" ]] || {
    do_log "FATAL ISSUE_KEYS_FILE must be the journal do_spl_issue_archive wrote"
    return 1
  }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local n rev journal rc=0 got
  n="$(grep -cE '^([A-Za-z][A-Za-z0-9]{0,9}-)?[1-9][0-9]*$' "$ISSUE_KEYS_FILE" || true)"
  if (( dry )); then
    do_log "INFO DRY_RUN would unarchive $n keys from $ISSUE_KEYS_FILE"
    grep -E '^([A-Za-z][A-Za-z0-9]{0,9}-)?[1-9][0-9]*$' "$ISSUE_KEYS_FILE" || true
    do_log "OK DRY_RUN count=$n nothing was restored"
    return 0
  fi
  rev="$(mktemp)"
  journal="$(mktemp)"
  grep -E '^([A-Za-z][A-Za-z0-9]{0,9}-)?[1-9][0-9]*$' "$ISSUE_KEYS_FILE" | tac >"$rev" || true
  spl_issue_archive_pool unarchive "$rev" "$journal" || rc=1
  got="$(grep -c . "$journal" || true)"
  if (( rc == 0 )); then
    do_log "OK restored $got keys"
  else
    do_log "INFO restored $got keys before a failure"
  fi
  rm -f "$rev" "$journal"
  return $rc
}
