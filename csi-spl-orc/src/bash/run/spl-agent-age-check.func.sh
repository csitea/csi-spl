#!/bin/bash
#------------------------------------------------------------------------------
# @description Report every agent session on THIS box older than
# @description ROTATE_LANE_REPORT_AGE (default 65 min), the age read from the
# @description process start time (/proc), one line each:
# @description "<id>@<box> <kind> pid <pid> <min> min". Owner HUM-10,
# @description 2026-10-11: no agent runs for more than one hour; the hourly
# @description rotation (do_spl_lane_rotate, the role rotations) keeps it so,
# @description and this check names any session it missed. The cron tick of
# @description do_spl_lane_rotate sends the same list to the dispatch lease
# @description holder when it changes, on every box. Read-only.
# @description Exit 0 = none, 1 = at least one.
# @param ROTATE_LANE_REPORT_AGE (optional) - seconds, default 3900
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_age_check
# @example ROTATE_LANE_REPORT_AGE=3600 ./run -a do_spl_agent_age_check
#------------------------------------------------------------------------------
declare -F spl_lane_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-rotate.func.sh"

do_spl_agent_age_check() {
  spl_rotate_conf || return 1
  spl_lane_rotate_conf || return 1
  local scan old
  scan="$(spl_lane_rotate_scan)"
  old="$(spl_lane_rotate_old "$scan")"
  echo "agent-age@$ROTATE_BOX: $(grep -c . <<<"$scan" || true) agent session(s), $(grep -c . <<<"$old" || true) older than $((ROTATE_LANE_REPORT_AGE / 60)) min"
  [[ -z "$old" ]] && return 0
  printf '  OLD %s\n' "${old//$'\n'/$'\n'  OLD }"
  return 1
}
