#!/bin/bash
#------------------------------------------------------------------------------
# @description Agent-hours of one UTC day (spec 123 section 4.3), read-only:
# @description from this box's day log dispatch/agent-run-<DAY>.log
# @description ("<epoch> <id> run|stop" per agent per tick), written by the
# @description lease watch / fleet tick that runs on EVERY box, lease holder
# @description or not (spl_lease_agent_run_report, first written
# @description 2026-10-10: an earlier day has no log on any box). Each run sample
# @description is worth the MEASURED gap from the tick before it (the previous
# @description day's last tick for the first one), never an assumed interval;
# @description a gap over COST_TICK_GAP_MAX s (default 600: the ticker was
# @description down) is counted as that cap and reported. Used to split a
# @description vendor subscription per agent, never as a price. Writes
# @description <COST_DAY_DIR>/agent-hours-<DAY>.tsv; with ENV and DRY_RUN=0 it
# @description posts the day as cost source agent_hours.<box> to the hub's
# @description operator ingest (spl-cost-source.func.sh; the nightly
# @description do_spl_cost_rollup_daily posts it itself).
# @param DAY (optional) - UTC day YYYY-MM-DD, default yesterday
# @param COST_DAY_DIR (optional) - default $SPOOL_ROOT/cost
# @param ENV (optional) - dev or prd: the hub posted to (with DRY_RUN=0)
# @param DRY_RUN (optional) - 1 (default): file only. 0: also post it
# @example DAY=2026-10-09 ./run -a do_spl_cost_agent_hours_read
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_cost_agent_hours_read
#------------------------------------------------------------------------------
do_spl_cost_agent_hours_read() {
  local day="${DAY:-$(date -u -d yesterday +%F)}" root="${SPOOL_ROOT:-/var/spool-hub}" log prev dir out
  spl_cost_day_ok "$day" || return 2
  log="$root/dispatch/agent-run-$day.log"
  [[ -r "$log" ]] || { echo "FATAL agent_hours: no day log $log ($(spl_cost_agent_hours_first_log "$root"))" >&2; return 1; }
  prev="$(tail -n 1 "$root/dispatch/agent-run-$(date -u -d "$day -1 day" +%F).log" 2>/dev/null | awk '{print $1}')"
  dir="${COST_DAY_DIR:-$root/cost}"
  mkdir -p "$dir" || { echo "FATAL cannot create $dir" >&2; return 1; }
  out="$dir/agent-hours-$day.tsv"
  if ! spl_cost_agent_hours_sum "$day" "${prev:-}" < "$log" > "$out.$$" || ! mv -f "$out.$$" "$out"; then
    rm -f "$out.$$"; echo "FATAL agent_hours: cannot write $out from $log" >&2; return 1
  fi
  grep '^#' "$out"
  echo "OK wrote $out"
  spl_cost_reader_post agent_hours "$day" "$out" spl_cost_agent_hours_lines
}

# Why a day has no log: this box's lease watch tick (every box runs one)
# appends to it, so the earliest log names when this box started writing.
spl_cost_agent_hours_first_log() {
  local f
  f="$(compgen -G "$1/dispatch/agent-run-*.log" | sort | sed -n 1p)"
  if [[ -z "$f" ]]; then echo "this box has no day log at all: its lease watch tick wrote none"
  else f="${f##*/agent-run-}"; echo "this box's earliest day log is ${f%.log}: its lease watch tick wrote none that day"; fi
}

# Cost source agent_hours (spec 123 4.6, spl-cost-source.func.sh): this box's
# day log of DAY, read by the action above and mapped to the
# contract's rows. Nothing posted here: the rollup posts.
spl_cost_source_agent_hours() {
  local root="${SPOOL_ROOT:-/var/spool-hub}"
  COST_POST=0 DAY="$1" do_spl_cost_agent_hours_read >"$2.log" || return 1
  spl_cost_agent_hours_lines "${COST_DAY_DIR:-$root/cost}/agent-hours-$1.tsv" "$2"
}

# spl_cost_agent_hours_lines FILE OUT: an agent-hours day file as the source
# contract's OUT.lines (vendor, agent, -, agent_seconds, seconds, agent_run)
# and OUT.cov: partial when a tick gap was capped (the ticker was down).
spl_cost_agent_hours_lines() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" day id secs capped
  [[ -r "$1" ]] || { echo "no agent-hours day file $1" >&2; return 1; }
  while IFS=$'\t' read -r day id _ secs; do
    [[ "$day" == day || "$day" == \#* || -z "$id" ]] && continue
    printf '%s\t%s\t-\tagent_seconds\t%s\tagent_run\n' "$(spl_cost_agent_vendor "$root" "$id")" "$id" "$secs"
  done <"$1" >"$2.lines"
  capped="$(sed -n 's/^# agent-hours .* gaps_capped=\([0-9]*\) .*/\1/p' "$1")"
  if [[ "${capped:-0}" != 0 ]]; then
    printf 'partial\t%s tick gap(s) over the cap: the lease ticker was down, those gaps count as the cap\n' "$capped" >"$2.cov"
  else
    printf 'ok\n' >"$2.cov"
  fi
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
