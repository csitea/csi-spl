#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_agent_hours_read (spec 123 section 4.3) on synthetic
# lease-tick day logs in a mktemp dir.
#   1. a bad DAY and a missing day log are refused, nothing written
#   2. agent-seconds = each run sample x the MEASURED gap from the tick
#      before it (uneven gaps, the previous day's last tick for the first);
#      control: an assumed 60 s interval would read 240, not 750
#   3. a gap over COST_TICK_GAP_MAX is counted as the cap and reported
#   4. with no previous day log the first tick is worth 0 (never assumed)
#   5. a stop sample counts no seconds; a stop-only agent reads 0
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DAY=2026-10-09 R="$T/spool"
mkdir -p "$R/dispatch"
F="$PROJ_ROOT/src/bash/run"
run_read() {
  env SPOOL_ROOT="$R" COST_DAY_DIR="$T/cost" DAY="$DAY" "$@" bash -c '
    source "$0/spl-cost-tokens-read.func.sh"; source "$0/spl-cost-agent-hours-read.func.sh"
    do_spl_cost_agent_hours_read' "$F" 2>&1
}
OUT="$T/cost/agent-hours-$DAY.tsv"
secs() { awk -F'\t' -v a="$1" '$2 == a {print $3, $4}' "$OUT"; }

out="$(run_read DAY=2026-10-9)"; rc=$?
out2="$(run_read)"; rc2=$?
[[ "$rc" == 2 && "$rc2" == 1 && "$out2" == *"FATAL no day log"* && ! -e "$T/cost" ]] &&
  pass "1. a bad DAY (exit 2) and a missing day log (exit 1) are refused" || fail "1. $rc $out / $rc2 $out2"

printf '900 c-1 run\n940 c-1 run\n' > "$R/dispatch/agent-run-2026-10-08.log"
cat > "$R/dispatch/agent-run-$DAY.log" <<'EOF'
1000 c-1 run
1000 c-2 run
1000 g-3 stop
1060 c-1 run
1060 c-2 stop
1060 g-3 stop
1090 c-1 run
5000 c-1 run
EOF
out="$(run_read)"
[[ "$(secs c-1)" == "4 750" && "$(secs c-2)" == "1 60" ]] &&
  pass "2. run samples x the measured gaps (60 from the previous day, 60, 30, capped 600)" || fail "2. $(cat "$OUT")"
[[ "$(secs c-1)" != "4 240" ]] && pass "2. control: not samples x an assumed 60 s" || fail "2. control"
[[ "$out" == *"ticks=4 measured_gap_s=750 gaps_capped=1 cap_s=600 bad_lines=0"* ]] &&
  pass "3. the over-cap gap (ticker down) is capped and reported" || fail "3. $out"
run_read COST_TICK_GAP_MAX=10000 >/dev/null
[[ "$(secs c-1)" == "4 4060" ]] && pass "3. control: with a larger cap the measured 3910 s gap counts" || fail "3. control $(cat "$OUT")"

rm -f "$R/dispatch/agent-run-2026-10-08.log"
run_read >/dev/null
[[ "$(secs c-1)" == "4 690" && "$(secs c-2)" == "1 0" ]] &&
  pass "4. no previous day log: the first tick is worth 0" || fail "4. $(cat "$OUT")"
[[ "$(secs g-3)" == "0 0" ]] && pass "5. a stop-only agent reads 0 samples, 0 s" || fail "5. $(cat "$OUT")"

echo "spl-cost-agent-hours-read: ${fails} failure(s)"
[ "$fails" -eq 0 ]
