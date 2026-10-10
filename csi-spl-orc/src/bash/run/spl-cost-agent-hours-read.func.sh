#!/bin/bash
#------------------------------------------------------------------------------
# @description Agent-hours of one UTC day (spec 123 section 4.3), read-only:
# @description from the lease tick's day log dispatch/agent-run-<DAY>.log
# @description ("<epoch> <id> run|stop" per agent per tick). Each run sample
# @description is worth the MEASURED gap from the tick before it (the previous
# @description day's last tick for the first one), never an assumed interval;
# @description a gap over COST_TICK_GAP_MAX s (default 600: the ticker was
# @description down) is counted as that cap and reported. Used to split a
# @description vendor subscription per agent, never as a price. Writes
# @description <COST_DAY_DIR>/agent-hours-<DAY>.tsv.
# @param DAY (optional) - UTC day YYYY-MM-DD, default yesterday
# @param COST_DAY_DIR (optional) - default $SPOOL_ROOT/cost
# @example DAY=2026-10-09 ./run -a do_spl_cost_agent_hours_read
#------------------------------------------------------------------------------
do_spl_cost_agent_hours_read() {
  local day="${DAY:-$(date -u -d yesterday +%F)}" root="${SPOOL_ROOT:-/var/spool-hub}" log prev dir out
  spl_cost_day_ok "$day" || return 2
  log="$root/dispatch/agent-run-$day.log"
  [[ -r "$log" ]] || { echo "FATAL no day log $log (the lease tick writes it)" >&2; return 1; }
  prev="$(tail -n 1 "$root/dispatch/agent-run-$(date -u -d "$day -1 day" +%F).log" 2>/dev/null | awk '{print $1}')"
  dir="${COST_DAY_DIR:-$root/cost}"
  mkdir -p "$dir" || { echo "FATAL cannot create $dir" >&2; return 1; }
  out="$dir/agent-hours-$day.tsv"
  spl_cost_agent_hours_sum "$day" "${prev:-}" < "$log" > "$out.$$" && mv -f "$out.$$" "$out" || return 1
  grep '^#' "$out"
  echo "OK wrote $out"
}

# stdin: the day log. The ticks are its distinct epochs, in order; a run
# sample at tick i gets ts[i] - ts[i-1] (PREV for the first; none = 0).
spl_cost_agent_hours_sum() {
  sort -n -k1,1 | awk -v OFS='\t' -v day="$1" -v prev="$2" -v cap="${COST_TICK_GAP_MAX:-600}" '
    $1 !~ /^[0-9]+$/ || ($3 != "run" && $3 != "stop") { bad++; next }
    $1 != last { gap = (last != "" ? $1 - last : (prev ~ /^[0-9]+$/ && prev < $1 ? $1 - prev : 0))
                 if (gap > cap) { capped++; gap = cap }
                 ticks++; gaps += gap; last = $1 }
    { ids[$2] = 1 }
    $3 == "run" { runs[$2]++; secs[$2] += gap }
    END {
      printf "# agent-hours v1 day=%s ticks=%d measured_gap_s=%d gaps_capped=%d cap_s=%d bad_lines=%d\n", day, ticks, gaps, capped, cap, bad
      print "day", "agent_id", "run_samples", "agent_seconds"
      for (id in ids) print day, id, runs[id] + 0, secs[id] + 0
    }' | { IFS= read -r h; IFS= read -r c; printf '%s\n%s\n' "$h" "$c"; sort; }
}
