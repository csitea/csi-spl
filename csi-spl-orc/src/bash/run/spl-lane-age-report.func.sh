#!/bin/bash
#------------------------------------------------------------------------------
# @description List the live worker lanes on THIS machine older than 30 min
# @description (agent-token-focus-plan.md practice 11), one line each:
# @description <ID> <age-min> <last-push-age-min> <last-spool-msg-age-min>.
# @description Read-only: registry.tsv, the worktree's last commit, the spool
# @description outbox mtime; role seats left out, no message body read.
# @param LANE_AGE_MIN (optional) - the threshold in minutes, default 30
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_lane_age_report
# @example LANE_AGE_MIN=60 ./run -a do_spl_lane_age_report
#------------------------------------------------------------------------------
do_spl_lane_age_report() {
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/lane-age-report.sh"
}
