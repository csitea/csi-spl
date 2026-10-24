#!/bin/bash
#------------------------------------------------------------------------------
# Disk headroom (SPL-3179, c-001 msg 9647b400): on 2026-10-24 05:14Z sat's
# /mnt/data was at 91% (crit 92%) and do_spl_box_pick still placed lanes there,
# each one a new worktree, its builds and its caches. So the pick skips a box
# whose agent data mount is at or above the disk headroom guard's HIGH mark.
#   - the marks have ONE home, here: spl_box_disk_marks prints the guard's
#     high (blocks) and crit marks, DISK_HEADROOM_BLOCK_PCT (85) and
#     DISK_HEADROOM_CRIT_PCT (92); check-disk-headroom.sh and the pick both
#     read them from it, so the two can never disagree;
#   - the agent data mount is the first of BOX_PICK_DISK_MOUNTS ("/mnt/data /")
#     that a box's sample lists: the agents' homes, worktrees, spool and
#     caches live on the data disk where a box has one (sat: /opt,
#     /var/spool-hub and the homes are binds of /mnt/data, so df lists only
#     /mnt/data), else on /;
#   - every box reads every box the same way: its latest hub box_stats sample
#     (rdb 0117), whose disks (rdb 0121, spl_lane_box_disks, every 5 min from
#     the box-stats cron) carry used_kb / avail_kb per mount. Use % is df's:
#     used / (used + avail), rounded up (total - avail when a row has no
#     used_kb).
# NO SAMPLE: a box with a load sample whose disks list none of those mounts (a
# sample from before rdb 0121, df unreadable on that box: disks []) is
# "unknown" and judged as before this rule: placed, no new refusal. A box with
# no load sample at all is already skipped by the pick.
#------------------------------------------------------------------------------

# The guard's default marks, whole % of a mount's blocks: HIGH warns at <= 15%
# free, CRIT at <= 8% free (owner, t1 37349c9b, 2026-10-15).
SPL_BOX_DISK_HIGH_PCT=85
SPL_BOX_DISK_CRIT_PCT=92

# spl_box_disk_marks: "<high> <crit>". Each is its env override
# (DISK_HEADROOM_BLOCK_PCT / DISK_HEADROOM_CRIT_PCT) when it is 1..100, else
# the default above.
spl_box_disk_marks() {
  local h="${DISK_HEADROOM_BLOCK_PCT:-$SPL_BOX_DISK_HIGH_PCT}" c="${DISK_HEADROOM_CRIT_PCT:-$SPL_BOX_DISK_CRIT_PCT}"
  [[ "$h" =~ ^[0-9]+$ ]] && (( h >= 1 && h <= 100 )) || h="$SPL_BOX_DISK_HIGH_PCT"
  [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= 100 )) || c="$SPL_BOX_DISK_CRIT_PCT"
  echo "$h $c"
}

# spl_box_disk_from_stats STATS_JSON [MOUNTS]: each box's agent data mount from
# its latest sample, {"<box>": {"mount": "/mnt/data", "pct": 91}}. A box whose
# sample lists none of MOUNTS (default BOX_PICK_DISK_MOUNTS, "/mnt/data /") is
# absent: no sample, unknown.
spl_box_disk_from_stats() {
  local m="${2:-${BOX_PICK_DISK_MOUNTS:-/mnt/data /}}"
  jq -c --arg m "$m" '
    ($m | split(" ") | map(select(length > 0))) as $want
    | (.rows // []) | group_by(.box) | map(max_by(.at))
    | map(.box as $b | (.disks // []) as $d
        | (first($want[] as $w | $d[] | select(.mount == $w)) // null) as $x
        | select($x != null and ($x.avail_kb | type) == "number")
        | (if ($x.used_kb | type) == "number" then $x.used_kb else ($x.total_kb // 0) - $x.avail_kb end) as $u
        | select($u + $x.avail_kb > 0)
        | {key: $b, value: {mount: $x.mount, pct: (($u * 100 / ($u + $x.avail_kb)) | ceil)}})
    | from_entries' <<<"${1:-{\}}" 2>/dev/null || echo '{}'
}
