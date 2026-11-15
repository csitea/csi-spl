#!/bin/bash
#------------------------------------------------------------------------------
# @description Per-part wall times of the pre-push gate, from its verdict log
# @description (the PART lines _pp_verdict writes): for each part and tier, the
# @description last PRE_PUSH_TIMES_N runs that PASSed (a run that ran, not
# @description PASS-cached or SKIP-untouched), with p50, p95 and max (nearest
# @description rank), how many of the part's runs in that window TIMED OUT
# @description (censored: their real time is not in the log), and p95 x 1.5
# @description rounded up to 10 s: the value for env.prepush.part_budget_s
# @description (csi-spl-cnf/csi-spl/all.env.yaml, csi-spl-doc/doc/md/pre-push-gate.md).
# @description Several logs (one per box user) are merged by timestamp.
# @param PRE_PUSH_TIMES_LOGS (optional) - space-separated log files, default PRE_PUSH_LOG, else ~/.cache/csi-spl/pre-push.log
# @param PRE_PUSH_TIMES_N (optional) - runs per part and tier, default 50
# @example ./run -a do_report_pre_push_part_times
# @example PRE_PUSH_TIMES_LOGS="/a/pre-push.log /b/pre-push.log" PRE_PUSH_TIMES_N=100 ./run -a do_report_pre_push_part_times
#------------------------------------------------------------------------------
do_report_pre_push_part_times() {
  local n="${PRE_PUSH_TIMES_N:-50}" f
  local logs="${PRE_PUSH_TIMES_LOGS:-${PRE_PUSH_LOG:-$HOME/.cache/csi-spl/pre-push.log}}"
  local -a files=()
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "PRE_PUSH_TIMES_N must be a positive integer, got '$n'" >&2; return 2; }
  for f in $logs; do
    [[ -r "$f" ]] || { echo "pre-push log not readable: $f" >&2; return 2; }
    files+=("$f")
  done
  printf '%-18s %-5s %4s %6s %6s %6s %5s %8s\n' part tier n p50 p95 max t/o budget
  _rpt_part_lines "${files[@]}" | _rpt_part_stats "$n"
}

# <log>... -> "<ts> <part> <tier> <verdict> <secs> <timedout 0|1>", oldest first
_rpt_part_lines() {
  awk '$3 == "PART" && $6 ~ /^[0-9]+s$/ {
    tier = ""; for (i = 7; i <= NF; i++) if ($i ~ /^tier=/) tier = substr($i, 6)
    if (tier == "") next
    print $1, $4, tier, $5, substr($6, 1, length($6) - 1), (index($0, "TIMED OUT") ? 1 : 0)
  }' "$@" | LC_ALL=C sort -s -k1,1
}

# stdin from _rpt_part_lines -> one row per part+tier, sorted by part
_rpt_part_stats() {  # <n>
  awk -v n="$1" '
    function rank(q,   r) { r = int(q * c); if (r < q * c) r++; if (r < 1) r = 1; return v[r] }
    { k = $2 " " $3
      if ($6 == 1) to[k, ++tc[k]] = $1
      if ($4 != "PASS") next
      pc[k]++; p[k, pc[k]] = $5; at[k, pc[k]] = $1; keys[k] = 1 }
    END {
      for (k in keys) {
        lo = pc[k] - n + 1; if (lo < 1) lo = 1; c = 0
        for (i = lo; i <= pc[k]; i++) v[++c] = p[k, i] + 0
        for (i = 2; i <= c; i++) { x = v[i]; for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]; v[j + 1] = x }
        t = 0; for (i = 1; i <= tc[k]; i++) if (to[k, i] >= at[k, lo]) t++
        p95 = rank(0.95); b = p95 * 1.5; if (b > int(b / 10) * 10) b = (int(b / 10) + 1) * 10
        split(k, kk, " ")
        printf "%-18s %-5s %4d %6d %6d %6d %5d %8d\n", kk[1], kk[2], c, rank(0.5), p95, v[c], t, b
      }
    }' | LC_ALL=C sort
}
