#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 134 section 4.3 (c) "one kind out -> the other kind takes all
#          seats, and back", step P3 / T3: do_spl_od_pool_supervise and
#          do_spl_od_seat against the stubs of od-pool-stub.inc.sh.
#   1. both Claude seats show a usage limit with a future reset: tick 1
#      changes nothing; tick 2 writes the pool row (claude 0, grok 4,
#      vendor_out claude, out_until = the banner's reset) and retires both
#      Claude seats; the next ticks spawn Grok up to 4, one per tick; a new
#      route_post is locked by a Grok seat
#   2. the clock past out_until: the row goes back to 2 + 2; the extra Grok
#      seat holding a job stays (marked retire, takes no new job), the one
#      holding none is retired; Claude is spawned back; 0 rows lost, no row
#      held by two seats; once its job is closed the last extra is retired
#   3. controls: one Claude able and one stalled -> the target stays 2 + 2
#      and only the stalled seat is replaced; a passed reset on both Claude
#      seats -> no vendor out
#   4. mutation control: a supervisor that calls a vendor out when ANY of its
#      seats failed twice turns case 3's first control red
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
source "$TEST_DIR/od-pool-stub.inc.sh"
LIMIT="You've hit your limit · resets 3pm (Etc/GMT-3)"
PASSED="Usage limit reached · resets 9am (Etc/GMT-3)"
of() { awk -F'\t' -v v="$1" '$2 == v {print $1}' "$S/od/seats.tsv" | sort | tr '\n' ' '; }
# newest first: the newest Grok seat (an extra once the target is back) locks
# the job, and renews it before an older seat could lock it again
gticks() { local s; for s in $(of grok | tr ' ' '\n' | sort -r); do seat "$s"; done; }
fill() { for _ in 1 2 3 4; do sup; done; }

# --- 1. Claude out --------------------------------------------------------------------
fill
c1="$(seatpid c-601)" c2="$(seatpid c-602)"
pane "$c1" "$LIMIT"; pane "$c2" "$LIMIT"
sup
t1=0; [[ "$(pool .claude_n)" == 2 && -d "$P/$c1" ]] && t1=1
sup
[[ "$t1" == 1 && "$(pool .claude_n)" == 0 && "$(pool .grok_n)" == 4 && "$(pool .vendor_out)" == claude && "$(pool .out_until)" == 2026-10-13T12:00:00Z ]] &&
  [[ ! -d "$P/$c1" && ! -d "$P/$c2" && -z "$(of claude)" ]] &&
  pass "1. both Claude seats at their limit: tick 1 waits, tick 2 sets claude 0 + grok 4 until the reset (12:00Z) and retires both" ||
  fail "1. t1=$t1 pool $(cat "$H/pool.json") seats $(cat "$S/od/seats.tsv")"
sup; sup
hub ask pool --set --kinds route_post > /dev/null
hub ask enqueue --id v-1 --kind route_post > /dev/null
gticks
[[ "$(of grok)" == "g-603 g-604 g-605 g-606 " && "$(row v-1 .acked_by)" =~ ^g-60[3-6]@b1$ ]] &&
  pass "1. Grok is spawned up to 4, one per tick; a new route_post is locked by a Grok seat ($(row v-1 .acked_by))" ||
  fail "1. grok seats '$(of grok)' v-1 by '$(row v-1 .acked_by)'"

# --- 2. back --------------------------------------------------------------------------
holder="$(row v-1 .acked_by)"; holder="${holder%@*}"
NOW=$((NOW + 2 * 3600 + 60))
gticks
sup
back=0; [[ "$(pool .claude_n)" == 2 && "$(pool .grok_n)" == 2 && -z "$(pool .vendor_out)" ]] && back=1
for _ in 1 2 3 4; do sup; gticks; done
held=0; [[ "$(row v-1 .state)" == acked && "$(row v-1 .acked_by)" == "$holder@b1" && -n "$(seatpid "$holder")" && -e "$S/od/$holder/retire" ]] && held=1
[[ "$back" == 1 && "$held" == 1 && "$(of claude | wc -w)" == 2 && "$(of grok | wc -w)" == 3 && "$(jq length "$H/rows.json")" == 1 ]] &&
  pass "2. past the reset: back to 2 + 2; the extra Grok seat holding v-1 stays (retire, no new job), the idle extra is gone, Claude is back, 0 rows lost" ||
  fail "2. back=$back held=$held holder $holder claude '$(of claude)' grok '$(of grok)' rows $(cat "$H/rows.json")"
hub ask enqueue --id v-2 --kind route_post > /dev/null
seat "$holder"
[[ "$(row v-2 .state)" == open ]] && pass "2. the retiring seat locks no new job" || fail "2. v-2 $(row v-2 .acked_by)"
hub ask "done" --id v-1 --by "$holder@b1" --gen "$(row v-1 .gen)" > /dev/null
seat "$holder"; sup
[[ "$(of claude | wc -w)" == 2 && "$(of grok | wc -w)" == 2 && -z "$(seatpid "$holder")" ]] &&
  pass "2. its job closed, the last extra is retired: 2 + 2" || fail "2. claude '$(of claude)' grok '$(of grok)'"

# --- 3. controls ------------------------------------------------------------------------
control_one() {
  NOW=1791885600
  rm -rf "$S/od" "$H"/lease/*; : > "$T/takeover.log"
  echo '[]' > "$H/rows.json"
  echo '{"claude_n":2,"grok_n":2,"min_boxes":2,"vendor_out":"","out_until":"","kinds":[]}' > "$H/pool.json"
  fill
  pane "$(seatpid "$(of claude | cut -d' ' -f2)")" "$LIMIT"
  sup; sup
  [[ "$(pool .claude_n)" == 2 && "$(pool .grok_n)" == 2 && -z "$(pool .vendor_out)" && "$(of claude | wc -w)" == 2 ]] &&
    [[ "$(cut -d' ' -f1 "$T/takeover.log" | tr '\n' ' ')" == "$(of claude | cut -d' ' -f2) " ]]
}
control_one && pass "3. control: one Claude able, one stalled -> 2 + 2 stays, only the stalled seat is replaced" ||
  fail "3. pool $(cat "$H/pool.json") takeovers $(cat "$T/takeover.log")"
for s in $(of claude); do pane "$(seatpid "$s")" "$PASSED"; done
: > "$T/takeover.log"; sup; sup
[[ -z "$(pool .vendor_out)" && "$(pool .claude_n)" == 2 && ! -s "$T/takeover.log" ]] &&
  pass "3. control: a reset that already passed is no vendor out" || fail "3. pool $(cat "$H/pool.json")"

# --- 4. mutation control ----------------------------------------------------------------
ODSRC="$(mutant any-seat spl-od-pool-supervise.func.sh '(( n >= 2 )) || { all=0; break; }' '(( n >= 2 )) || continue')" || fail "4. mutant not built"
export ODSRC
control_one && fail "4. control: a vendor called out on one stalled seat still passed" ||
  pass "4. control: calling a vendor out on ANY stalled seat turns case 3 red ($(pool .vendor_out) out)"
unset ODSRC

[[ "$fails" == 0 ]] && echo "OK od-pool-vendor: all passed" || { echo "FAILED od-pool-vendor: $fails"; exit 1; }
