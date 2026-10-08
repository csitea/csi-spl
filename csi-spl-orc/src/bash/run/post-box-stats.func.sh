#!/bin/bash
#------------------------------------------------------------------------------
# @description Post ONE hardware sample of this box to the hub's history (rdb
# @description 0117, owner t1 8c4fcc46): load (/proc/loadavg), cpus (nproc),
# @description memory and swap (/proc/meminfo), the agents with a live pane, as
# @description and per mount the disk size, free and used space (rdb 0121; a
# @description binary or hub that refuses used_kb gets the sample without it), as
# @description `spool box-stats put` from this machine's desk box. Nothing else:
# @description no lane-map read, no BOX-0 row. The box-stats cron runs it every
# @description 5 min (do_setup_box_stats_cron); do_report_box_stats reads the
# @description history. The hub, fleet, env and tenant are the lane map's
# @description (spl_lane_init: env, then lease.conf).
# @param LANE_FLEET / LANE_ENV / LANE_TENANT / LANE_DESK_BOX (optional) - as do_spl_lane_map
# @param LANE_LOADAVG / LANE_MEMINFO / LANE_NPROC / LANE_DF_CMD / LANE_PANES_CMD / LANE_HUB_CMD (optional, tests) - replace the reads and the hub call
# @example ./run -a do_post_box_stats
#------------------------------------------------------------------------------

declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"

do_post_box_stats() {
  local live sample out rc
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL the box stats live on the hub: set LANE_FLEET (or LEASE_FLEET in lease.conf)"; return 1; }
  live="$(spl_lane_live_here)"
  [[ "$live" == null ]] && live='[]'
  sample="$(spl_lane_box_sample "$live")" ||
    { do_log "FATAL cannot read this box's load, cpus or memory (/proc/loadavg, nproc, /proc/meminfo)"; return 1; }
  out="$(spl_lane_spool box-stats put --json - <<<"$sample" 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$out" == *'"used_kb"'* || "$out" == *"one box stat object"* ]]; then
    # a spool binary (unknown field "used_kb") or a hub (lane must be one box
    # stat object) from before used_kb (c-542) refuses the field: send the
    # sample without it rather than none
    sample="$(jq -c 'del(.disks[]?.used_kb)' <<<"$sample")"
    out="$(spl_lane_spool box-stats put --json - <<<"$sample" 2>&1)"; rc=$?
  fi
  (( rc == 0 )) || { do_log "FATAL the hub did not record the sample of $LANE_BOX: $(tail -1 <<<"$out")"; return 1; }
  do_log "OK box stats of $LANE_BOX recorded: $sample"
}
