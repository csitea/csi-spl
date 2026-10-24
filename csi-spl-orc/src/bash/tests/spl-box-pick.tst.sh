#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_pick (owner HUM-10, t1 c13e8023 + t1 29b19f85) prints
#          the box a new lane starts on: the first box in the fill order below
#          its LOW mark, else the first below its HIGH mark (load5 / cpus);
#          every box at or above its HIGH -> the box least past its band
#          (load% / high) while below its OVERFLOW mark (high *
#          BOX_PICK_OVERFLOW / 100, default 200); every box at or above its
#          OVERFLOW -> hold. A box's band is its own
#          per-box band (rdb 0134 `boxes`) or the fleet band. The bands and
#          the order come from the hub (`spool fleet-load get`, rdb 0118);
#          an empty hub order -> the cnf seed; a hub that does not answer ->
#          50 / 75 and the cnf seed with a WARN; a box with no sample is
#          skipped with a WARN; no box stats answer -> FATAL.
#          12. a DEGRADED box (hub beats, t1 3cfc236e) is never picked: a
#          replay of the 2026-10-11 night (the PC box's beats per 10 min as
#          measured on prd) picks the other box all through the outage and
#          the PC box again once its beats recover; every box degraded ->
#          the pick as before, with a WARN.
#          15. BOX_PICK_KIND (SPL-1649): a box measured without that vendor's
#          CLI (this box: spool_vendor_clis; another: the cli= of its BOX-0
#          row) is never picked; no box left -> pick=nokind; no cli= is
#          unknown and stays in; no BOX_PICK_KIND -> the pick as before.
#          16. weekly quota (SPL-2035): a box whose BOX_PICK_KIND usage (this
#          box: its panes' banner; another: the wk= of its BOX-0 row) is at or
#          over env.box.quota.weekly_max_pct (90) is never picked; every box
#          over -> pick=hold "waiting: ..."; no reading or a stale row ->
#          unknown, placed with an INFO line; RED CONTROL: the same loads with
#          no kind (the pick before SPL-2035) take the box at 96 %.
#          16e. (SPL-2196) the CLI's "<synthetic>" limit entry in the agent
#          user's transcripts reads 100 until its reset, with no banner in a
#          pane; a newer real answer, a passed reset, an entry older than
#          LANE_QUOTA_LOG_MIN or a quote by a model -> no reading.
#          17. a CORDONED box (do_spl_box_cordon, sat alone panel row 01)
#          is never picked, not by the every-box-degraded fallback either;
#          every box cordoned -> hold; an expired cordon is none.
#          18. disk headroom (SPL-3179): a box whose agent data mount (the
#          first of /mnt/data, / its sample lists) is at or over the headroom
#          guard's HIGH mark (85) is never picked, not by the degraded
#          fallback either; every box over -> hold; a sample without that
#          mount is unknown and placed as before; the % from a stubbed df
#          (spl_lane_box_disks) is df's Capacity.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/spool"

cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1" in
  fleet-load) [ "${TARGET_DOWN:-0}" = 1 ] && { echo 'unknown command "fleet-load"' >&2; exit 1; }; cat "$TARGET" ;;
  box-stats) [ "${STATS_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }; cat "$STATS" ;;
  box-beat) [ -n "${BEATS:-}" ] || exit 0
    jq -c --argjson now "$HUB_NOW" --argjson s "$(( ${4%m} * 60 ))" \
      '{rows: [.[] | select(.e <= $now and .e > $now - $s) | {box, beat_at: (.e | todate)}]}' "$BEATS" ;;
  lane) if [ -n "${LANES:-}" ]; then cat "$LANES"; else echo '{"fleet":"main","lanes":[]}'; fi ;;
esac
STUB
chmod +x "$T/bin/hub"
printf 'env:\n  box:\n    fleet_load:\n      box_order: [box-a, box-b]\n' >"$T/cnf.yaml"

# target LOW HIGH ORDER_JSON [BOXES_JSON]
target() { printf '{"low":%s,"high":%s,"box_order":%s,"boxes":%s,"source":"hub"}\n' "$1" "$2" "$3" "${4:-{\}}" >"$T/target.json"; }
# stats BOX:LOAD5:CPUS[:AGENTS] ... (one older sample of every box first, which the latest overrides)
stats() {
  local rows="" s b l c a
  for s in "$@"; do
    IFS=: read -r b l c a <<<"$s"
    rows+="{\"box\":\"$b\",\"at\":\"2026-10-04T10:00:00Z\",\"load5\":99,\"cpus\":$c},"
    rows+="{\"box\":\"$b\",\"at\":\"2026-10-04T10:05:00Z\",\"load5\":$l,\"cpus\":$c${a:+,\"agents_live\":$a}},"
  done
  printf '{"since":"x","rows":[%s],"hours":[]}\n' "${rows%,}" >"$T/stats.json"
}

run() {
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=box-desk LANE_FLEET=main LANE_HUB_CMD="$T/bin/hub" \
    CALLS="$T/calls" TARGET="$T/target.json" STATS="$T/stats.json" BOX_PICK_CNF="$T/cnf.yaml" \
    LANE_CI_CMD="echo 0" LANE_QUOTA_CMD="echo" PROJ_PATH=/x/csi-spl-orc APP_PATH=/x "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-box-pick.func.sh"
    do_spl_box_pick'
}
pick() { grep '^pick=' <<<"$1" | sed 's/^pick=\([^ ]*\).*/\1/'; }

# 1. band edges on box-a (8 cores), box-b in band at 56%: 49% (under low) and
#    50% (in band, no box under low) pick box-a; 75% and 76% pass it on.
target 50 75 '["box-a","box-b"]'
for c in 3.92:box-a 4:box-a 6:box-b 6.08:box-b; do
  stats "box-a:${c%%:*}:8" "box-b:4.5:8"
  out="$(run)"; got="$(pick "$out")"
  [[ "$got" == "${c#*:}" ]] && pass "1. box-a load5 ${c%%:*} / 8 cores -> pick=$got" || fail "1. edge ${c%%:*}: $out"
done
grep -q '^BOX box-a  load5 6.08  cpus 8  76%  full  band 50..75 (fleet)$' <<<"$out" && pass "1. the per-box line says 76% full" || fail "1. line: $out"

# 2. fill order: the hub order wins; both boxes under HIGH -> the first named.
target 50 75 '["box-b","box-a"]'
stats "box-a:1:8" "box-b:3:8"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q 'order box-b box-a (hub)' <<<"$out" &&
  pass "2. the hub's order box-b, box-a puts the lane on box-b" || fail "2. order: $out"
# a box in no order comes after the named ones.
stats "box-a:7:8" "box-b:7:8" "box-c:1:8"
out="$(run)"
[[ "$(pick "$out")" == box-c ]] && grep -q 'order box-b box-a box-c (hub)' <<<"$out" &&
  pass "2. an unnamed box with a sample comes last, and takes the lane when the named are full" || fail "2. unnamed: $out"

# 3. every box at or above its OVERFLOW (2 x high = 150%) -> hold; the edge:
#    box-a at 149% still takes it. BOX_PICK_OVERFLOW=100 holds at HIGH.
stats "box-a:12:8" "box-b:24:16"
out="$(run)"; rc=$?
[[ $rc -eq 0 && "$(pick "$out")" == hold ]] && grep -q 'below its overflow mark (200% of its high)' <<<"$out" &&
  pass "3. every box at or above its OVERFLOW (150%) -> pick=hold, exit 0" || fail "3. hold (rc=$rc): $out"
stats "box-a:11.92:8" "box-b:24:16"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && pass "3. box-a at 149% is below its overflow 150% -> pick=box-a" || fail "3. overflow edge: $out"
stats "box-a:6:8" "box-b:16:16"
out="$(run BOX_PICK_OVERFLOW=100)"
[[ "$(pick "$out")" == hold ]] && pass "3. BOX_PICK_OVERFLOW=100: every box at or above HIGH -> hold" || fail "3. overflow 100: $out"
out="$(run BOX_PICK_OVERFLOW=50 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL BOX_PICK_OVERFLOW"* ]] && pass "3. BOX_PICK_OVERFLOW under 100 is refused" || fail "3. overflow 50 (rc=$rc): $out"

# 4. a missing sample: that box is skipped with a WARN.
target 50 75 '["box-a","box-b"]'
stats "box-b:1:8"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^WARN box box-a: no load sample in the last 15m, skipped$' <<<"$out" &&
  pass "4. box-a without a sample is skipped with a WARN; box-b takes the lane" || fail "4. missing: $out"

# 5. the hub's band is respected (here 20..40), and an empty hub order is the cnf seed.
target 20 40 '[]'
stats "box-a:3.5:8" "box-b:3:8"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q '20..40 % of cores (source hub), 0 per-box band(s), order box-a box-b (cnf seed)' <<<"$out" &&
  pass "5. hub band 20..40: box-a 43% is full, box-b 37% takes it; empty hub order = cnf seed" || fail "5. band: $out"

# 6. hub unreachable for the target: defaults 50 / 75 + cnf seed, with a WARN.
stats "box-a:5:8" "box-b:4.5:8"
out="$(run TARGET_DOWN=1 2>&1)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^WARN the hub did not answer the fleet load target' <<<"$out" &&
  grep -q '50..75 % of cores (source built-in default), 0 per-box band(s), order box-a box-b (cnf seed)' <<<"$out" &&
  pass "6. no hub target: WARN, 50 / 75 and the cnf seed (box-a 62% < 75%)" || fail "6. hub down: $out"

# 7. no box stats answer -> FATAL, non-zero, no pick line.
out="$(run STATS_DOWN=1 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL the hub did not answer the box stats read"* && -z "$(pick "$out")" ]] &&
  pass "7. no box stats: FATAL, exit $rc, no pick" || fail "7. stats down (rc=$rc): $out"

# 8. the hub calls: the target, then the window.
: >"$T/calls"; run >/dev/null 2>&1
[[ "$(cat "$T/calls")" == $'fleet-load get\nbox-stats list --since 15m\nbox-beat list --since 41m\nlane --fleet main' ]] &&
  pass "8. one fleet-load get, one box-stats list --since 15m, one box-beat list --since 41m, one lane read (the CI jobs)" || fail "8. calls: $(cat "$T/calls")"
out="$(run BOX_PICK_SINCE=yesterday 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL BOX_PICK_SINCE"* ]] && pass "8. a bad BOX_PICK_SINCE is refused" || fail "8. since: $out"

# 9. a per-box band (rdb 0134) overrides the fleet band for that box only.
#    box-a 40% is under the fleet low 50 but its own band is 20..35 -> full;
#    box-b 56% (fleet band, in band) takes the lane.
target 50 75 '["box-a","box-b"]' '{"box-a":{"low":20,"high":35}}'
stats "box-a:3.2:8" "box-b:4.5:8"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a  load5 3.2  cpus 8  40%  full  band 20..35 (box)$' <<<"$out" &&
  grep -q '1 per-box band(s)' <<<"$out" &&
  pass "9. box-a's own band 20..35 holds it at 40%; box-b on the fleet band takes the lane" || fail "9. per-box: $out"
# the low mark comes first: box-b under ITS low wins over box-a first in order.
target 50 75 '["box-a","box-b"]' '{"box-b":{"low":60,"high":90}}'
stats "box-a:4.5:8" "box-b:4.5:8"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q 'below its low mark (56% < 60%)' <<<"$out" &&
  pass "9. box-b 56% under its own low 60 wins over box-a in band" || fail "9. low first: $out"

# 10. ACCEPTANCE (owner HUM-10, t1 29b19f85 msg b339245d: "the load will be
#     distributed also between the boxes the way the admin desires"): place
#     lanes one by one, each adding 0.5 load5 to the box it picked, until
#     hold. The lanes split in the proportion of the bands the admin set.
#     BOX_PICK_OVERFLOW=100: hold at the high mark (the overflow is test 11).
#     sim BOXES_JSON -> "<lanes on box-a> <lanes on box-b> <order of picks>"
sim() {
  local la=0 lb=0 picks="" p
  target 50 75 '["box-a","box-b"]' "$1"
  for _ in $(seq 1 60); do
    stats "box-a:$(jq -n "$la * 0.5"):8" "box-b:$(jq -n "$lb * 0.5"):8"
    p="$(pick "$(run BOX_PICK_OVERFLOW=100)")"
    case "$p" in box-a) la=$((la + 1)) ;; box-b) lb=$((lb + 1)) ;; *) break ;; esac
    picks+="${p#box-}"
  done
  echo "$la $lb $picks"
}
# no override: both on 50..75 of 8 cores -> 12 lanes each (6.0 load5 = 75%).
read -r la lb picks <<<"$(sim '{}')"
[[ "$la $lb" == "12 12" ]] && pass "10. no per-box band: box-a $la, box-b $lb lanes (1:1)" || fail "10. fleet band: $la $lb $picks"
# box-a 20..40, box-b 60..90: box-a stops at 40% (7 lanes, 3.5 = 43%),
# box-b at 90% (15 lanes, 7.5 = 93%) -> 7:15, the 40:90 the admin set.
read -r la lb picks <<<"$(sim '{"box-a":{"low":20,"high":40},"box-b":{"low":60,"high":90}}')"
[[ "$la $lb" == "7 15" ]] && pass "10. bands 20..40 / 60..90: box-a $la, box-b $lb lanes (40:90)" || fail "10. per-box: $la $lb $picks"
# and every box reaches its own low before any box goes past its low:
# box-a takes 4 (to 25%, past 20), box-b then 10 (to 62%, past 60), then box-a again.
[[ "$picks" == aaaabbbbbbbbbbaaabbbbb ]] && pass "10. fill order: box-a to its low, box-b to its low, then each to its high ($picks)" ||
  fail "10. pick order: $picks"

# 11. spec 101 T001 (R1, lanes on the box with room): today's loads, the PC
#     box far above its cores (105 on 16) and box-b ~17 on 16, both past the
#     high mark, first in order the PC box. The weight, never a box name:
#     the box least past its band takes the lane. Control: loads swapped.
target 50 75 '["box-a","box-b"]'
stats "box-a:105:16" "box-b:17:16"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q 'every box is at or above its high mark; box-b is the least past its band (106% on high 75%, overflow 150%)' <<<"$out" &&
  pass "11. PC box 656%, box-b 106%: pick=box-b, though box-a is first in order" || fail "11. today's loads: $out"
stats "box-a:17:16" "box-b:105:16"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && pass "11. control, loads swapped: pick=box-a" || fail "11. control: $out"
# both past high, both under overflow: the smaller load% / high wins, not the order.
stats "box-a:14:16" "box-b:13:16"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && pass "11. box-a 87%, box-b 81%, both past high: pick=box-b (least past)" || fail "11. least past: $out"
# a per-box band weighs it: box-b 81% on its own high 60 (1.35 x) is further past than box-a 87% on 75 (1.17 x).
target 50 75 '["box-a","box-b"]' '{"box-b":{"low":40,"high":60}}'
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && pass "11. box-b 81% on its own high 60 is further past than box-a 87% on 75: pick=box-a" || fail "11. per-box weight: $out"

# 12. t1 3cfc236e: a DEGRADED box is never picked. The replay: box-a is the
#     PC box of 2026-10-11, its beats per 10 min from 00:30Z as measured on
#     prd box_beats (01:00..05:30Z), 60 before and after; box-b (the
#     satellite) beat 60 per 10 min all night. Beats evenly spread in each
#     10 min. box-a is first in order and both are under their low mark, so
#     the beats alone move the pick. One pick per 10 min, 01:10..06:50Z (n = 35).
beats() { jq -nc --arg b "$1" --argjson s "$2" --argjson c "[$3]" \
  '[range(0; $c | length) as $i | range(0; $c[$i]) as $k | {box: $b, e: ($s + $i * 600 + (($k + 0.5) * 600 / $c[$i] | floor))}]'; }
B0=1791678600  # 2026-10-11T00:30:00Z
NIGHT=60,60,60,61,60,61,60,62,23,16,10,15,11,16,3,4,9,2,5,5,8,8,2,1,2,2,0,1,0,16,60,60,60,60,60,60,60,60,60
jq -s add <(beats box-a $B0 "$NIGHT") <(beats box-b $B0 "$(printf '60,%.0s' {1..38})60") >"$T/beats.json"
target 50 75 '["box-a","box-b"]'
stats "box-a:1:8" "box-b:1:8"
bad=0 good=0 seq12=""
for i in $(seq 4 38); do
  now=$((B0 + i * 600)); out="$(run BEATS="$T/beats.json" HUB_NOW=$now)"; p="$(pick "$out")"
  seq12+="${p#box-}"
  # the 10 min before 02:00..05:30Z held under 30 beats: degraded
  if (( i >= 9 && i <= 30 )); then [[ "$p" == box-b ]] || bad=$((bad + 1)); else [[ "$p" == box-a ]] || good=$((good + 1)); fi
done
[[ $bad == 0 && $good == 0 && "$seq12" == aaaaabbbbbbbbbbbbbbbbbbbbbbaaaaaaaa ]] &&
  pass "12. replay of 2026-10-11 (n = 35 picks): the PC box never picked 02:00..05:30Z (22 picks), picked again from 05:40Z ($seq12)" ||
  fail "12. replay: $bad pick(s) on the degraded box, $good healthy pick(s) missed: $seq12"
out="$(run BEATS="$T/beats.json" HUB_NOW=$((B0 + 15 * 600)))"
grep -q '^BOX box-a .*DEGRADED (3 beats in 10m < 30, last beat .*s ago (max 120s))$' <<<"$out" &&
  pass "12. the per-box line says why: DEGRADED (3 beats in 10m < 30 ...)" || fail "12. line: $out"
# the gap rule alone: 40 beats in the last 10 min, but none in the last 150 s
jq -nc --argjson n $((B0 + 600)) '[range(0; 40) | {box: "box-a", e: ($n - 150 - . * 11)}] + [range(0; 60) | {box: "box-b", e: ($n - . * 10)}]' >"$T/gap.json"
[[ "$(pick "$(run BEATS="$T/gap.json" HUB_NOW=$((B0 + 600)))")" == box-b ]] &&
  pass "12. 40 beats but the last 150 s ago (> max_gap_s 120): degraded, pick=box-b" || fail "12. gap rule"
# every box degraded: the pick ignores the beats, with a WARN
jq -nc --argjson n $((B0 + 600)) '[range(0; 5) | {box: "box-a", e: ($n - . * 100)}, {box: "box-b", e: ($n - . * 100)}]' >"$T/all.json"
out="$(run BEATS="$T/all.json" HUB_NOW=$((B0 + 600)))"
[[ "$(pick "$out")" == box-a ]] && grep -q '^WARN every box with a load sample is degraded' <<<"$out" &&
  pass "12. every box degraded: the pick as before (box-a), with a WARN" || fail "12. all degraded: $out"
# CONTROL: the knob. BOX_HEALTH_MIN_BEAT_PCT=0 and MAX_GAP_S=99999 judge nobody degraded
[[ "$(pick "$(run BEATS="$T/beats.json" HUB_NOW=$((B0 + 15 * 600)) BOX_HEALTH_MIN_BEAT_PCT=0 BOX_HEALTH_MAX_GAP_S=99999)")" == box-a ]] &&
  pass "12. CONTROL: thresholds 0 / 99999 through the env knob -> box-a at 03:00Z" || fail "12. knob control"
# no beats answer: nobody judged, a WARN
out="$(run 2>&1)"
[[ "$(pick "$out")" == box-a ]] && grep -q 'WARN the hub did not answer the box beats read' <<<"$out" &&
  pass "12. no beats answer: a WARN, the pick as before" || fail "12. no beats: $out"

# 13. CI busy (owner HUM-10, t1 f67e3656 msg 565d9bbb): a box with a runner
#     job active takes fewer lanes. lanes BOX:CI:AGE_S ... -> the BOX-0 rows.
lanes() {
  local s b c a rows=""
  for s in "$@"; do
    IFS=: read -r b c a <<<"$s"
    rows+="{\"agent_id\":\"BOX-0\",\"agent_box\":\"$b\",\"state\":\"live\",\"age_s\":$a,\"scope\":\"mem_kb=1 ci=$c live=c-001\"},"
  done
  printf '{"fleet":"main","lanes":[{"agent_id":"c-100","agent_box":"box-a","state":"live","age_s":5,"scope":"ci=9 not a box row"},%s]}\n' "${rows%,}" >"$T/lanes.json"
}
target 50 75 '["box-a","box-b"]'
# box-a 40 % (under low) with 15 agents, box-b 45 % (under low) with 5
stats "box-a:3.2:8:15" "box-b:3.6:8:5"
lanes "box-b:0:60"
out="$(run LANES="$T/lanes.json")"
[[ "$(pick "$out")" == box-a ]] && ! grep -q 'ci busy' <<<"$out" &&
  pass "13. CONTROL: CI idle (and a lane row saying ci=9 is no box row) -> the normal band, box-a" || fail "13. idle: $out"
lanes "box-a:2:60" "box-b:0:60"
out="$(run LANES="$T/lanes.json")"
[[ "$(pick "$out")" == box-b ]] &&
  grep -q '^BOX box-a  load5 3.2  cpus 8  40%  in band  band 25..50 (fleet, ci busy)  ci busy: 2 jobs, cap 12 (agents 15), AT CAP: not picked$' <<<"$out" &&
  pass "13. CI busy on box-a with 15 agents >= cap 12 -> pick avoids it (box-b), the line says why" || fail "13. busy: $out"
out="$(run LANES="$T/lanes.json" BOX_CI_MAX_AGENTS=99)"
[[ "$(pick "$out")" == box-b ]] && grep -q 'ci busy: 2 jobs, cap 99 (agents 15)$' <<<"$out" &&
  pass "13. under the cap, box-a's lower band (25..50) puts its 40 % in band: box-b, under its low, first" || fail "13. band: $out"
stats "box-a:1.6:8:15" "box-b:3.6:8:5"
out="$(run LANES="$T/lanes.json" BOX_CI_MAX_AGENTS=16)"
[[ "$(pick "$out")" == box-a ]] &&
  pass "13. cap honoured both ways: 15 agents under a cap of 16 and 20 % under the CI low -> box-a" || fail "13. cap 16: $out"
stats "box-a:3.2:8:15" "box-b:3.6:8:5"
lanes "box-a:2:1200" "box-b:0:60"
[[ "$(pick "$(run LANES="$T/lanes.json")")" == box-a ]] &&
  pass "13. a BOX-0 row older than max_age_s (900) tells nothing: box-a" || fail "13. stale"
lanes "box-b:0:60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-a LANE_CI_CMD="echo 1")"
[[ "$(pick "$out")" == box-b ]] && grep -q 'ci busy: 1 jobs, cap 12 (agents 15), AT CAP' <<<"$out" &&
  pass "13. this box's own runner job (Runner.Worker count) counts before its row says so" || fail "13. here: $out"
stats "box-a:3.2:8:15" "box-b:13:8:5"
lanes "box-a:2:60"
out="$(run LANES="$T/lanes.json")"
[[ "$(pick "$out")" == hold ]] && grep -q 'or under its CI-busy agent cap' <<<"$out" &&
  pass "13. CI busy box at cap, the other past its overflow -> hold (queued, nothing killed)" || fail "13. hold: $out"
out="$(run 2>&1)"
[[ -n "$(pick "$out")" ]] && pass "13. no lane answer: the pick as before" || fail "13. no lanes: $out"

# 14. who yields when (the runner CPU budget, do_apply_gh_runner_cpu_budget):
#     jobs waiting while the budget parked runners here count as CI busy.
ci_jobs() {  # PS_OUTPUT [GATE_LINE] [PARKED_LINES]
  rm -rf "$T/ghrb"; mkdir -p "$T/ghrb"
  printf '%b' "$1" >"$T/ps.out"
  [ -n "${2:-}" ] && echo "$2" >"$T/ghrb/gate"
  [ -n "${3:-}" ] && printf '%b' "$3" >"$T/ghrb/parked"
  env -u LANE_CI_CMD LANE_CI_PS_CMD="cat $T/ps.out" CPU_BUDGET_STATE_DIR="$T/ghrb" bash -c '
    source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-ci.func.sh"; spl_box_ci_jobs'
}
NOW=$(date +%s)
[[ "$(ci_jobs 'bash\nRunner.Listener\nRunner.Worker\nRunner.Worker\n')" == 2 ]] &&
  pass "14. 2 Runner.Worker processes = 2 jobs; the idle Runner.Listener is none" || fail "14. ps count"
[[ "$(ci_jobs 'Runner.Listener\n' "$NOW 2" 'actions.runner.a.service\nactions.runner.b.service\nactions.runner.c.service\n')" == 2 ]] &&
  pass "14. no job running, 2 gate runs waiting, 3 runners parked by the budget -> 2 (CI waits for these cores)" || fail "14. waiting"
[[ "$(ci_jobs 'Runner.Worker\n' "$NOW 5" 'actions.runner.a.service\n')" == 2 ]] &&
  pass "14. 1 running + 5 waiting on 1 parked runner -> 2 (waiting counts at most the parked runners)" || fail "14. min parked"
[[ "$(ci_jobs 'Runner.Listener\n' "$NOW 2")" == 0 ]] &&
  pass "14. CONTROL runs waiting but no runner parked: their wait is not for this box's cores -> 0" || fail "14. no parked"
[[ "$(ci_jobs 'Runner.Listener\n' "$((NOW - 3600)) 2" 'actions.runner.a.service\n')" == 0 ]] &&
  pass "14. CONTROL a gate file an hour old (the budget cron stopped) -> 0" || fail "14. stale gate"

# 15. vendor CLI. clis BOX:CLI:AGE_S ... -> the BOX-0 rows with cli= ("" = none written)
clis() {
  local s b c a rows=""
  for s in "$@"; do
    IFS=: read -r b c a <<<"$s"
    rows+="{\"agent_id\":\"BOX-0\",\"agent_box\":\"$b\",\"state\":\"live\",\"age_s\":$a,\"scope\":\"mem_kb=1${c:+ cli=$c} live=c-001\"},"
  done
  printf '{"fleet":"main","lanes":[%s]}\n' "${rows%,}" >"$T/lanes.json"
}
target 50 75 '["box-a","box-b"]'
stats "box-a:3.2:8" "box-b:3.6:8"
ALL=claude,grok,agy,qwen,mistral
clis "box-b:$ALL:60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo claude,qwen" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  no agy CLI: not picked$' <<<"$out" &&
  pass "15. agy, this box (first, under low) without agy -> box-b, the line says why" || fail "15. here: $out"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == box-a ]] && pass "15. CONTROL this box with agy -> box-a" || fail "15. control: $out"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo claude,qwen")"
[[ "$(pick "$out")" == box-a ]] && pass "15. CONTROL no BOX_PICK_KIND -> the pick as before (box-a)" || fail "15. no kind: $out"
clis "box-a:claude,qwen:60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == box-b ]] && pass "15. another box's cli= without agy -> not picked (box-b)" || fail "15. row: $out"
clis "box-a:-:60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == box-b ]] && pass "15. cli=- (measured none) -> not picked" || fail "15. none: $out"
clis "box-a::60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == box-a ]] && pass "15. CONTROL a row with no cli= is unknown: box-a stays in" || fail "15. unknown: $out"
clis "box-a:claude:60" "box-b:claude:60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == nokind ]] && grep -q '^pick=nokind reason=.*agy CLI.*box-a box-b' <<<"$out" &&
  pass "15. no box with agy -> pick=nokind (not hold: queueing would not help)" || fail "15. nokind: $out"
clis "box-a:claude:4000"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy)"
[[ "$(pick "$out")" == box-a ]] && pass "15. a BOX-0 row over an hour old tells nothing: box-a" || fail "15. stale: $out"

# 16. weekly quota. wk BOX:WK:AGE_S ... -> the BOX-0 rows with wk= ("" = none
# written). box-a is first in order and under its low mark: the old pick.
wk() {
  local s b w a rows=""
  for s in "$@"; do
    IFS=: read -r b w a <<<"${s//claude:/claude=}"
    rows+="{\"agent_id\":\"BOX-0\",\"agent_box\":\"$b\",\"state\":\"live\",\"age_s\":$a,\"scope\":\"mem_kb=1 cli=$ALL${w:+ wk=${w//=/:}} live=c-001\"},"
  done
  printf '{"fleet":"main","lanes":[%s]}\n' "${rows%,}" >"$T/lanes.json"
}
target 50 75 '["box-a","box-b"]'
stats "box-a:2:8" "box-b:4.4:8"
wk "box-a:claude:96:60" "box-b:claude:40:60"
q() { run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" "$@"; }
out="$(q BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  claude weekly 96% >= 90%: not picked$' <<<"$out" &&
  grep -q '^BOX box-b .*  claude weekly 40%  <- pick$' <<<"$out" &&
  pass "16a. box-a at 96 %, box-b at 40 % -> box-b; box-a's line names vendor, usage and threshold" || fail "16a. $out"
out="$(q)"
[[ "$(pick "$out")" == box-a ]] &&
  pass "16d. RED CONTROL the same loads with no kind (the pick before SPL-2035) -> box-a at 96 %" || fail "16d. $out"
out="$(q BOX_PICK_KIND=grok)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: grok weekly usage unknown' <<<"$out" &&
  pass "16. CONTROL another vendor's usage: a grok lane still takes box-a" || fail "16. grok: $out"
wk "box-a:claude:96:60" "box-b:claude:91:60"
out="$(q BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == hold ]] && grep -q '^pick=hold reason=waiting: claude weekly >= 90% on box-a, box-b: queue the lane' <<<"$out" &&
  pass "16b. both over -> not placed, pick=hold with the waiting reason" || fail "16b. $out"
wk "box-a::60" "box-b:claude:40:60"
out="$(q BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown .*placed anyway$' <<<"$out" &&
  grep -q '^BOX box-a .*  claude weekly unknown  <- pick$' <<<"$out" &&
  pass "16c. no reading on box-a -> unknown, not 0: placed, with an INFO line" || fail "16c. $out"
wk "box-a:claude:96:4000" "box-b:claude:40:60"
out="$(q BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" &&
  pass "16c. a BOX-0 row over an hour old -> unknown: placed, logged" || fail "16c. stale: $out"
wk "box-a::60" "box-b:claude:40:60"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_CMD="echo grok:10,claude:95" BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-b ]] && pass "16. this box read live (claude:95 from its panes) -> box-b" || fail "16. here: $out"
wk "box-a:claude:96:60" "box-b:claude:40:60"
printf '    quota:\n      weekly_max_pct: 97\n' >>"$T/cnf.yaml"
out="$(q BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-a ]] && pass "16. cnf env.box.quota.weekly_max_pct 97 -> box-a at 96 % is picked" || fail "16. cnf: $out"
out="$(q BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90)"
[[ "$(pick "$out")" == box-b ]] && pass "16. BOX_QUOTA_WEEKLY_MAX_PCT overrides the cnf" || fail "16. env: $out"

# 16. the reading: the banner as a pane footer shows it (spl_box_quota_parse)
parse() { bash -c 'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_parse "$@"' _ "$@"; }
N=$(date -u -d 2026-10-15T19:00:00Z +%s)
B="You've used 96% of your weekly limit · resets Oct 17, 11am (Europe/Helsinki) · /usage-credits to keep going"
[[ "$(printf '>\n %40s%s\n' '' "$B" | parse claude "$N")" == 96 ]] && pass "16. claude banner -> 96" || fail "16. banner"
[[ -z "$(printf '● the pane said %s\n' "$B" | parse claude "$N")" ]] && pass "16. CONTROL a quoted banner mid-line is no reading" || fail "16. quoted"
[[ -z "$(printf '  %s\n' "${B/Oct 17/Oct 8}" | parse claude "$N")" ]] && pass "16. a reset date in the past -> no reading" || fail "16. stale reset"
[[ "$(printf "  You've used 86%% of your weekly limit · resets 8pm (Europe/Helsinki)\n" | parse claude "$N")" == 86 ]] &&
  pass "16. a reset time alone is the next one -> 86" || fail "16. time only"
[[ "$(printf "  ⎿  You've hit your weekly limit · resets Oct 17, 11am (Europe/Helsinki)\n" | parse claude "$N")" == 100 ]] &&
  pass "16. hit your weekly limit -> 100" || fail "16. hit"
[[ "$(printf ' Weekly limit left: 4%%\n' | parse grok "$N")" == 96 ]] && pass "16. grok footer left 4% -> 96" || fail "16. grok"
# grok's limit screen draws no footer (b04-03): its framed line reads 100
G="$(printf '  ┃  You hit your weekly limit.\n  ┃  1 (○) Buy more credits\n  ┃  2 (○) Try Again\n')"
[[ "$(printf '%s\n' "$G" | parse grok "$N")" == 100 ]] &&
  pass "16. RED CONTROL (FAILs on 7df27968f) grok limit screen -> 100" || fail "16. grok limit screen"
[[ -z "$(printf '● the pane said: you hit your weekly limit\n' | parse grok "$N")" ]] &&
  pass "16. CONTROL grok: a quoted limit mid-sentence is no reading" || fail "16. grok quoted"
[[ "$(printf '%s\n Weekly limit left: 4%%\n' "$G" | parse grok "$N")" == 96 ]] &&
  pass "16. grok: the newer of screen and footer wins (footer -> 96)" || fail "16. grok newer footer"
[[ "$(printf ' Weekly limit left: 4%%\n%s\n' "$G" | parse grok "$N")" == 100 ]] &&
  pass "16. grok: the newer of footer and screen wins (screen -> 100)" || fail "16. grok newer screen"

# 16e. the limit the panes no longer show (SPL-2196): a box read "claude weekly
# unknown <- pick" at its limit (c-001 msg 5c025d6e), no claude pane showed a
# banner. The CLI's own "<synthetic>" transcript entry reads 100 until its
# reset, unless a real answer is newer. this box = box-a, panes faked.
L="$T/projects/-opt-x"; mkdir -p "$L"
RS="$(date -u -d '+2 days' '+%b %-d, %-l%P') (UTC)"
ent() {  # MODEL TEXT AGE_S -> one transcript line
  jq -nc --arg m "$1" --arg t "$2" --arg ts "$(date -u -d "-$3 seconds" +%Y-%m-%dT%H:%M:%S.000Z)" \
    '{type: "assistant", timestamp: $ts, message: {model: $m, role: "assistant", content: [{type: "text", text: $t}]}}'
}
ent "<synthetic>" "You've hit your weekly limit · resets $RS" 3600 >"$L/s1.jsonl"
wk "box-a::60" "box-b:claude:40:60"
lq() { run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_CMD= LANE_PANES_CMD=true \
  LANE_QUOTA_LOG_DIR="$T/projects" BOX_PICK_KIND=claude; }
out="$(lq)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  claude weekly 100% >= 9[0-9]%: not picked$' <<<"$out" &&
  pass "16e. RED CONTROL (FAILs on 8b427556c) a limit-reached transcript entry, no banner in a pane -> box-a at 100 %, skipped" ||
  fail "16e. limit entry: $out"
ent "claude-x" "Done. You've hit your weekly limit · resets $RS, it said." 60 >"$L/q1.jsonl"
out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_CMD= LANE_PANES_CMD=true \
  LANE_QUOTA_LOG_DIR="$T/projects" LANE_QUOTA_LOG_MIN=0 BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" &&
  pass "16e. CONTROL an entry older than LANE_QUOTA_LOG_MIN -> unknown, placed" || fail "16e. window: $out"
out="$(lq)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" &&
  pass "16e. a real answer newer than the limit entry (lifted) -> unknown, placed with the INFO line" || fail "16e. lifted: $out"
rm -f "$L/q1.jsonl"
ent "<synthetic>" "You've hit your weekly limit · resets ${RS/$(date -u -d '+2 days' +%b)/$(date -u -d '-40 days' +%b)}" 3600 >"$L/s1.jsonl"
out="$(lq)"
[[ "$(pick "$out")" == box-a ]] && pass "16e. a limit entry whose reset has passed -> unknown, placed" || fail "16e. reset passed: $out"
ent "claude-x" "You've hit your weekly limit · resets $RS" 3600 >"$L/s1.jsonl"
out="$(lq)"
[[ "$(pick "$out")" == box-a ]] && pass "16e. CONTROL the text in a real model answer (an agent quoting it) is no reading" || fail "16e. quoted: $out"

# 17. sat alone panel row 01 (SPL-2629): a CORDONED box (do_spl_box_cordon,
#     <spool root>/dispatch/cordon/<box> with until=<epoch>) is never picked,
#     not even by the every-box-degraded fallback; an expired cordon is none.
#     box-a is first in order and under its low mark, so the cordon alone
#     moves the pick. n = 10 picks.
mkdir -p "$T/spool/dispatch/cordon"
target 50 75 '["box-a","box-b"]'
stats "box-a:1:8" "box-b:1:8"
printf 'until=%s at=2026-10-20T00:00:00Z by=test min=240\n' $(( $(date +%s) + 3600 )) >"$T/spool/dispatch/cordon/box-a"
bad=0
for i in $(seq 1 10); do [[ "$(pick "$(run)")" == box-b ]] || bad=$((bad + 1)); done
out="$(run)"
[[ $bad == 0 ]] && grep -q '^BOX box-a .*  CORDONED (until 20[0-9-]*T[0-9:]*Z)$' <<<"$out" &&
  pass "17. RED CONTROL (FAILs on 691e2cdd6) a cordoned box-a is never picked (n = 10 picks, pick=box-b), its line says CORDONED" ||
  fail "17. cordon: $bad of 10 picks took box-a: $out"
out="$(run BEATS="$T/all.json" HUB_NOW=$((B0 + 600)))"
[[ "$(pick "$out")" == box-b ]] && pass "17. every box degraded: the fallback still skips the cordoned box-a (pick=box-b)" ||
  fail "17. degraded fallback: $out"
printf 'until=%s\n' $(( $(date +%s) + 3600 )) >"$T/spool/dispatch/cordon/box-b"
out="$(run)"
grep -q '^pick=hold reason=every box with a sample is CORDONED (box-a box-b)' <<<"$out" &&
  pass "17. every box cordoned -> pick=hold, spawn nothing" || fail "17. all cordoned: $out"
printf 'until=%s\n' $(( $(date +%s) - 1 )) >"$T/spool/dispatch/cordon/box-a"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && ! grep -q '^BOX box-a .*CORDONED' <<<"$out" &&
  pass "17. an expired cordon is none: box-a picked again" || fail "17. expired: $out"
rm -f "$T/spool/dispatch/cordon/box-a" "$T/spool/dispatch/cordon/box-b"
[[ "$(pick "$(run)")" == box-a ]] && pass "17. CONTROL no cordon file -> box-a, the pick as before" || fail "17. no cordon"

# 18. disk headroom (SPL-3179). dstats BOX:LOAD5:CPUS:DISKS_JSON ... (one
#     older sample first, as stats() writes it: the latest one is read)
dstats() {
  local rows="" s b l c d
  for s in "$@"; do
    IFS=: read -r b l c d <<<"$s"
    rows+="{\"box\":\"$b\",\"at\":\"2026-10-04T10:00:00Z\",\"load5\":99,\"cpus\":$c,\"disks\":[]},"
    rows+="{\"box\":\"$b\",\"at\":\"2026-10-04T10:05:00Z\",\"load5\":$l,\"cpus\":$c,\"disks\":$d},"
  done
  printf '{"since":"x","rows":[%s],"hours":[]}\n' "${rows%,}" >"$T/stats.json"
}
# dk MOUNT USED_PCT -> one disk row of 100000 kB, used + avail = total
dk() { printf '{"mount":"%s","total_kb":100000,"avail_kb":%s,"used_kb":%s}' "$1" $((100000 - $2 * 1000)) $(($2 * 1000)); }
ROOT40="$(dk / 40)"
target 50 75 '["box-a","box-b"]'
# box-a is first in order and under its low mark: only the disk moves the pick
dstats "box-a:1:8:[$ROOT40,$(dk /mnt/data 91)]" "box-b:1:8:[$(dk / 30)]"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  DISK /mnt/data 91% >= 85%: not picked$' <<<"$out" &&
  pass "18. RED CONTROL (FAILs on 9d389a1ff) box-a's /mnt/data at 91% is not picked, its line names the mount and the %; box-b takes it" ||
  fail "18. one box full: $out"
dstats "box-a:1:8:[$ROOT40,$(dk /mnt/data 84)]" "box-b:1:8:[$(dk / 30)]"
[[ "$(pick "$(run)")" == box-a ]] && pass "18. edge: /mnt/data at 84% is under the mark, box-a picked" || fail "18. edge 84"
dstats "box-a:1:8:[$ROOT40,$(dk /mnt/data 85)]" "box-b:1:8:[$(dk / 30)]"
[[ "$(pick "$(run)")" == box-b ]] && pass "18. edge: /mnt/data at 85% (the mark) is not picked" || fail "18. edge 85"
dstats "box-a:1:8:[$(dk / 90),$(dk /mnt/data 50)]" "box-b:1:8:[$(dk / 30)]"
[[ "$(pick "$(run)")" == box-a ]] && pass "18. the data mount is /mnt/data where the sample lists it: / at 90% does not count" || fail "18. data mount"
dstats "box-a:1:8:[$(dk / 88)]" "box-b:1:8:[$(dk / 30)]"
[[ "$(pick "$(run)")" == box-b ]] && pass "18. no /mnt/data: / is the data mount, 88% -> not picked" || fail "18. root mount"
out="$(run DISK_HEADROOM_BLOCK_PCT=95)"
[[ "$(pick "$out")" == box-a ]] && pass "18. the mark is the guard's DISK_HEADROOM_BLOCK_PCT (95: 88% picked)" || fail "18. env mark: $out"
# both over -> hold, the row keeps its place
dstats "box-a:1:8:[$ROOT40,$(dk /mnt/data 91)]" "box-b:1:8:[$(dk / 87)]"
out="$(run)"
grep -q '^pick=hold reason=every box with a sample is at or over the disk headroom mark 85% (box-a /mnt/data 91%, box-b / 87%): queue the lane, spawn nothing$' <<<"$out" &&
  pass "18. every box over the mark -> pick=hold naming each box, mount and %" || fail "18. hold: $out"
out="$(run BEATS="$T/all.json" HUB_NOW=$((B0 + 600)))"
[[ "$(pick "$out")" == hold ]] && pass "18. every box degraded too: the fallback does not take a disk-full box (hold)" || fail "18. degraded: $out"
dstats "box-a:1:8:[$ROOT40,$(dk /mnt/data 91)]" "box-b:1:8:[$(dk / 30)]"
out="$(run BEATS="$T/all.json" HUB_NOW=$((B0 + 600)))"
[[ "$(pick "$out")" == box-b ]] && pass "18. every box degraded: the fallback skips the disk-full box-a (pick=box-b)" || fail "18. degraded one: $out"
printf 'until=%s\n' $(( $(date +%s) + 3600 )) >"$T/spool/dispatch/cordon/box-b"
out="$(run)"
grep -q '^pick=hold reason=every box with a sample is at or over the disk headroom mark 85% (box-a /mnt/data 91%)' <<<"$out" &&
  pass "18. box-b cordoned, box-a disk-full -> hold, the reason names the disk" || fail "18. cordon + disk: $out"
rm -f "$T/spool/dispatch/cordon/box-b"
# no sample: disks [] (before rdb 0121, df unreadable) or none of the mounts
dstats "box-a:1:8:[]" "box-b:1:8:[$(dk / 30)]"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && ! grep -q 'DISK' <<<"$out" && pass "18. no disk sample (disks []) -> judged as before, box-a picked" || fail "18. no sample: $out"
dstats "box-a:1:8:[$(dk /boot/efi 99)]" "box-b:1:8:[$(dk / 30)]"
[[ "$(pick "$(run)")" == box-a ]] && pass "18. a sample without /mnt/data or / -> unknown, box-a picked" || fail "18. other mount only"
stats "box-a:1:8" "box-b:1:8"
[[ "$(pick "$(run)")" == box-a ]] && pass "18. CONTROL samples with no disks field -> the pick as before (box-a)" || fail "18. no field"
# a stubbed df through the real sample code: the % is df's Capacity
cat >"$T/df" <<'DF'
Filesystem     1024-blocks     Used Available Capacity Mounted on
/dev/sda1         30723076 18168444  11181772      62% /
/dev/sda15          126678     9104    117574       8% /boot/efi
/dev/sdb         102626232 93390000   9236232      92% /mnt/data
DF
disks="$(LANE_DF_CMD="cat $T/df" PROJ_PATH=/x/csi-spl-orc bash -c '
  do_log() { :; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-map.func.sh"; spl_lane_box_disks')"
dstats "box-a:1:8:$disks" "box-b:1:8:[$(dk / 30)]"
got="$(source "$PROJ_ROOT/lib/bash/funcs/spl-box-disk.func.sh"; spl_box_disk_from_stats "$(cat "$T/stats.json")")"
[[ "$got" == '{"box-a":{"mount":"/mnt/data","pct":92},"box-b":{"mount":"/","pct":30}}' ]] &&
  pass "18. stubbed df -> spl_lane_box_disks -> /mnt/data 92%, df's own Capacity" || fail "18. df: $disks -> $got"
[[ "$(pick "$(run)")" == box-b ]] && pass "18. that box at 92% is not picked" || fail "18. df pick"

echo "spl-box-pick: $fails failure(s)"
[ "$fails" -eq 0 ]
