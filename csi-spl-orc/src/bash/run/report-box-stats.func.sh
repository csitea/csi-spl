#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY hardware history of the fleet's boxes (rdb 0117, owner
# @description t1 8c4fcc46): one row per box per UTC hour from the hub's
# @description box_stats, which every box's lane map appends to on its BOX-0
# @description tick (300 s, spl_lane_box_stats). Per hour: n samples, the cpus,
# @description load1 avg / peak, used memory (total - available) avg / peak in
# @description GiB, the live agents avg / peak, and per mount the least free
# @description of the hour over its size (DISK_FREE_MIN_G, `/=8.2/29.3`; rdb
# @description 0121, `-` for an hour with no disk sample). The read is `spool box-stats
# @description list` as this machine's desk box, the lane map's hub call
# @description (spl_lane_init: fleet, env and tenant from lease.conf). Nothing
# @description is written.
# @param BOX (optional) - one box (the lane map's box id), default every box
# @param SINCE (optional) - the window: 20h (default), 90m, 7d or an RFC 3339 time; the hub keeps 30 days
# @param ENV (optional) - dev or prd: the hub to read, default LANE_ENV / lease.conf LEASE_ENV
# @param BOX_STATS_FORMAT (optional) - table (default) or json (the hub's answer {since, rows, hours})
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `box-stats list ...`, prints the answer
# @example ./run -a do_report_box_stats
# @example BOX=sat SINCE=7d ./run -a do_report_box_stats
# @example ENV=dev BOX=sat SINCE=2h ./run -a do_report_box_stats
#------------------------------------------------------------------------------

declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"

do_report_box_stats() {
  local box="${BOX:-}" since="${SINCE:-20h}" fmt="${BOX_STATS_FORMAT:-table}" args out
  [[ -z "$box" || "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX must be a box id ([a-z0-9-], up to 32), got '$box'"; return 1; }
  [[ "$since" =~ ^([0-9]+[smhd]|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+))$ ]] ||
    { do_log "FATAL SINCE must be a duration (20h, 90m, 7d) or an RFC 3339 time, got '$since'"; return 1; }
  [[ "$fmt" =~ ^(table|json)$ ]] || { do_log "FATAL BOX_STATS_FORMAT must be table or json"; return 1; }
  [[ -n "${ENV:-}" ]] && export LANE_ENV="$ENV"  # spl_lane_init reads it
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL the box stats live on the hub: set LANE_FLEET (or LEASE_FLEET in lease.conf)"; return 1; }
  args=(box-stats list --since "$since")
  [[ -n "$box" ]] && args+=(--box "$box")
  out="$(spl_lane_spool "${args[@]}" 2>&1)" || { do_log "FATAL the hub did not answer the box stats read: $(tail -1 <<<"$out")"; return 1; }
  jq -e '.hours | type == "array"' >/dev/null 2>&1 <<<"$out" || { do_log "FATAL the hub's answer is not a box stats object: $(head -c 200 <<<"$out")"; return 1; }
  if [[ "$fmt" == json ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  report_box_stats_table "$out"
}

# One line per (box, hour); "no samples" when the window is empty.
report_box_stats_table() {  # ANSWER
  jq -r '"box stats since \(.since) (\(.rows | length) samples)"' <<<"$1"
  jq -r '
    def gib: (. / 1048576 * 10 | round) / 10 | tostring | if test("\\.") then . else . + ".0" end;
    if (.hours | length) == 0 then "no samples" else
      (["BOX", "HOUR(UTC)", "N", "CPUS", "LOAD1_AVG", "LOAD1_PEAK", "MEM_USED_AVG_G", "MEM_USED_PEAK_G", "AGENTS_AVG", "AGENTS_PEAK", "DISK_FREE_MIN_G"] | @tsv),
      (.hours[] | [.box, (.hour | sub(":00:00Z$"; "Z")), .n, .cpus, .load1_avg, .load1_peak,
                   (.mem_used_avg_kb | gib), (.mem_used_peak_kb | gib), .agents_avg, .agents_peak,
                   ([(.disks // [])[] | "\(.mount)=\(.avail_min_kb | gib)/\(.total_kb | gib)"] | join(",") | if . == "" then "-" else . end)] | @tsv)
    end' <<<"$1" | column -t -s $'\t'
}
