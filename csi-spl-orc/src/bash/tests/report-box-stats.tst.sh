#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_report_box_stats (rdb 0117) prints the hub's per-hour box stats
#          as one line per (box, hour), passes BOX / SINCE through to
#          `spool box-stats list`, refuses a bad BOX / SINCE before any hub
#          call, fails non-zero when the hub does not answer, and says
#          "no samples" for an empty window.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/spool"

cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
cat "$ANSWER"
STUB
chmod +x "$T/bin/hub"
cat >"$T/answer.json" <<'JSON'
{"box":"sat","since":"2026-10-03T16:00:00Z","rows":[{},{},{}],"hours":[
 {"box":"sat","hour":"2026-10-04T10:00:00Z","n":2,"cpus":8,"load1_avg":3.5,"load1_peak":4.5,"mem_used_avg_kb":6291456,"mem_used_peak_kb":8388608,"mem_avail_min_kb":200,"agents_avg":4,"agents_peak":5},
 {"box":"sat","hour":"2026-10-04T11:00:00Z","n":1,"cpus":8,"load1_avg":1.25,"load1_peak":1.25,"mem_used_avg_kb":1048576,"mem_used_peak_kb":1048576,"mem_avail_min_kb":900,"agents_avg":1,"agents_peak":1}]}
JSON
echo '{"since":"2026-10-03T16:00:00Z","rows":[],"hours":[]}' >"$T/empty.json"

run() {
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=box-desk LANE_FLEET=main LANE_HUB_CMD="$T/bin/hub" \
    CALLS="$T/calls" ANSWER="$T/answer.json" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/report-box-stats.func.sh"
    do_report_box_stats'
}

: >"$T/calls"
out="$(run BOX=sat)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == "box-stats list --since 20h --box sat" ]] &&
  pass "BOX=sat, SINCE default 20h: one hub call, box-stats list --since 20h --box sat" || fail "call (rc=$rc): $(cat "$T/calls")"
grep -qE '^sat +2026-10-04T10Z +2 +8 +3\.5 +4\.5 +6\.0 +8\.0 +4 +5$' <<<"$out" &&
  pass "one line per hour: n, cpus, load1 avg / peak, used GiB avg / peak, agents avg / peak" || fail "table: $out"
[[ "$(head -1 <<<"$out")" == "box stats since 2026-10-03T16:00:00Z (3 samples)" && "$(grep -c '^sat ' <<<"$out")" -eq 2 ]] &&
  pass "a header with the window and the sample count, two hour lines" || fail "header: $out"

: >"$T/calls"
out="$(run SINCE=7d BOX_STATS_FORMAT=json)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == "box-stats list --since 7d" && "$(jq -r '.hours | length' <<<"$out")" == 2 ]] &&
  pass "no BOX = every box; json prints the hub's answer" || fail "json (rc=$rc): $(cat "$T/calls") / $out"

out="$(run ANSWER="$T/empty.json")"; rc=$?
[[ $rc -eq 0 && "$out" == *"no samples"* ]] && pass "an empty window says no samples, exit 0" || fail "empty (rc=$rc): $out"

: >"$T/calls"
for bad in BOX=Sat "SINCE=yesterday" "SINCE=20h;rm" BOX_STATS_FORMAT=csv; do
  out="$(run "$bad")"; rc=$?
  [[ $rc -eq 1 && "$out" == FATAL* ]] || fail "$bad accepted (rc=$rc): $out"
done
[[ ! -s "$T/calls" ]] && pass "a bad BOX / SINCE / format is refused before any hub call" || fail "refusal called the hub: $(cat "$T/calls")"

out="$(run HUB_DOWN=1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"did not answer"*"connection refused"* ]] && pass "hub down: exit 1 naming the error" || fail "hub down (rc=$rc): $out"
out="$(run LANE_FLEET= LEASE_FLEET=)"; rc=$?
[[ $rc -eq 1 && "$out" == *"live on the hub"* ]] && pass "control: no fleet, no hub: refused" || fail "no fleet (rc=$rc): $out"

echo
if [ "$fails" -eq 0 ]; then echo "report-box-stats: all passed"; exit 0; fi
echo "report-box-stats: $fails FAILED"; exit 1
