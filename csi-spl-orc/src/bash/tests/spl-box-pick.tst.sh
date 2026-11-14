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
#          LANE_QUOTA_LOG_MIN or a quote by a model -> no reading. SPL-4608: the
#          last measured % is kept until its reset (16f-16k); a kept 100 drops
#          once the login answers or probes ok after it (SPL-4702, 16l).
#          16n. (SPL-4965) a kept reading states its source and read time and
#          lapses unless re-read; a banner still on screen is no re-read; a
#          real limit that is re-read still holds; the hold line names both.
#          17. a CORDONED box (do_spl_box_cordon, sat alone panel row 01)
#          is never picked, not by the every-box-degraded fallback either;
#          every box cordoned -> hold; an expired cordon is none.
#          18. disk headroom (SPL-3179): a box whose agent data mount (the
#          first of /mnt/data, / its sample lists) is at or over the headroom
#          guard's HIGH mark (85) is never picked, not by the degraded
#          fallback either; every box over -> hold; a sample without that
#          mount is unknown and placed as before; the % from a stubbed df
#          (spl_lane_box_disks) is df's Capacity.
#          19. the AIM (t1 f456ecd5): a box past its aim, below its high,
#          takes a lane only when no box is under its aim; no aim = high.
#          20. a box in its RECOVERING hold (SPL-5138) is benched: not picked,
#          review seats included; a row pinned to it waits and says why; both
#          are released when the hold ends; every box recovering -> the
#          fallback places with its WARN, a recovering box before a degraded one.
#          the bench removed the last box that could take the lane -> pick=hold
#          naming the hold, never nokind or the plain overflow reason.
#          21. a vendor's own weekly mark (SPL-5432): grok 95 -> 94 % places,
#          95 % waits, no reading waits; RED CONTROLs without the mark (90 holds
#          94, unknown places); grok's reading from its CLI's billing log.
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
  # the 10 min before 02:00..05:30Z held under 30 beats: degraded; then the hold (SPL-5138)
  if (( i >= 9 && i <= 33 )); then [[ "$p" == box-b ]] || bad=$((bad + 1)); else [[ "$p" == box-a ]] || good=$((good + 1)); fi
done
[[ $bad == 0 && $good == 0 && "$seq12" == aaaaabbbbbbbbbbbbbbbbbbbbbbbbbaaaaa ]] &&
  pass "12. replay of 2026-10-11 (n = 35 picks): the PC box never picked 02:00..06:00Z (25 picks: 22 degraded, 3 in its hold), picked again from 06:10Z ($seq12)" ||
  fail "12. replay: $bad pick(s) on the degraded box, $good healthy pick(s) missed: $seq12"
out="$(run BEATS="$T/beats.json" HUB_NOW=$((B0 + 15 * 600)))"
grep -q '^BOX box-a .*DEGRADED (3 beats in 10m < 30, last beat [0-9]*s ago)$' <<<"$out" &&
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
[[ "$(pick "$out")" == hold ]] && grep -q '^pick=hold reason=waiting: claude weekly >= 90% on box-a, box-b \[box-a 96% source not stated; box-b 91% source not stated\]: queue the lane' <<<"$out" &&
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

# 16d. a logged review seat (SPL-4966): BOX_PICK_REVIEW_SEAT=1 holds at
# review_seat_max_pct, clamped to weekly_max_pct..99, so 100% always holds
sq() { q BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90 BOX_PICK_REVIEW_SEAT=1 "$@"; }
wk "box-a:claude:96:60" "box-b:claude:91:60"
out="$(sq)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: claude weekly >= 90% on box-a, box-b' <<<"$out" &&
  pass "16d. seat, no review_seat_max_pct anywhere: the weekly mark, no pass" || fail "16d. unset: $out"
out="$(sq BOX_QUOTA_REVIEW_SEAT_MAX_PCT=nonsense)"
[[ "$(pick "$out")" == hold ]] && pass "16d. seat, a mark that is no number: no pass" || fail "16d. nonsense: $out"
printf '      review_seat_max_pct: 97\n' >>"$T/cnf.yaml"
out="$(q BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90)"
[[ "$(pick "$out")" == hold ]] && pass "16d. CONTROL the cnf key set, no seat: an ordinary lane still holds at 90" || fail "16d. control: $out"
out="$(sq)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^BOX box-a .*  claude weekly 96%  <- pick$' <<<"$out" &&
  pass "16d. seat, cnf mark 97: box-a at 96% is picked" || fail "16d. pass: $out"
wk "box-a:claude:97:60" "box-b:claude:91:60"
out="$(sq)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  claude weekly 97% >= 97%: not picked$' <<<"$out" &&
  pass "16d. seat: a box AT the mark is skipped, the next one under it is picked" || fail "16d. at mark: $out"
wk "box-a:claude:97:60" "box-b:claude:100:60"
out="$(sq)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: claude weekly >= 97% on box-a, box-b' <<<"$out" &&
  pass "16d. seat: every box at or over the mark -> hold" || fail "16d. all over: $out"
wk "box-a:claude:100:60" "box-b:claude:100:60"
out="$(sq BOX_QUOTA_REVIEW_SEAT_MAX_PCT=100)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: claude weekly >= 99% on' <<<"$out" &&
  pass "16d. seat at 100%, the mark set to 100: clamped to 99, it holds" || fail "16d. 100: $out"
wk "box-a:claude:99:60" "box-b:claude:99:60"
out="$(sq BOX_QUOTA_REVIEW_SEAT_MAX_PCT=500)"
[[ "$(pick "$out")" == hold ]] && pass "16d. seat at 99%, the mark set to 500: clamped to 99, it holds" || fail "16d. 500: $out"
wk "box-a:claude:91:60" "box-b:claude:91:60"
out="$(sq BOX_QUOTA_REVIEW_SEAT_MAX_PCT=50)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: claude weekly >= 90% on' <<<"$out" &&
  pass "16d. a mark under weekly_max_pct: raised to it, a seat is never stricter" || fail "16d. low: $out"
wk "box-a:claude:100:60" "box-b:claude:100:60"
out="$(sq BOX_QUOTA_REVIEW_SEAT_MAX_PCT=18446744073709551711)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: claude weekly >= 90% on' <<<"$out" &&
  pass "16d. a mark that wraps in bash arithmetic (2^64+95): no pass" || fail "16d. wrap: $out"
out="$(sq BOX_QUOTA_WEEKLY_MAX_PCT=120)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: claude weekly >= 99% on' <<<"$out" &&
  pass "16d. weekly_max_pct 120: the seat's mark is still 99, at 100% it holds" || fail "16d. wk120: $out"
wk "box-a:claude:94:60" "box-b:claude:94:60"
out="$(sq BOX_QUOTA_REVIEW_SEAT_MAX_PCT=095 2>&1)"
[[ "$(pick "$out")" == box-a ]] && ! grep -q 'value too great' <<<"$out" &&
  pass "16d. a mark with a leading zero reads in base 10" || fail "16d. 095: $out"
wk "box-a:claude:96:60" "box-b:claude:40:60"
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
# a year-less reset date (SPL-4155): read as this year, "resets Jan 2" on Dec 30
# was 363 days past and a box at its limit read free every year-end
H="  You've hit your weekly limit · resets"
[[ "$(printf '%s Jan 2, 12am (UTC)\n' "$H" | parse claude "$(date -u -d 2026-12-30T12:00:00Z +%s)")" == 100 ]] &&
  pass "16. RED CONTROL (FAILs on 63bd3899a) Dec 30 + resets Jan 2 -> next year, 100" || fail "16. year-end reset"
[[ -z "$(printf '%s Jan 1, 12am (UTC)\n' "$H" | parse claude "$(date -u -d 2027-01-05T12:00:00Z +%s)")" ]] &&
  pass "16. Jan 5 + resets Jan 1 -> passed, no reading" || fail "16. new-year stale"
[[ -z "$(printf '%s Dec 30, 12am (UTC)\n' "$H" | parse claude "$(date -u -d 2027-01-01T12:00:00Z +%s)")" ]] &&
  pass "16. Jan 1 + resets Dec 30 -> last year, passed, no reading" || fail "16. last-year stale"
[[ "$(printf '%s Nov 2, 12am (UTC)\n' "$H" | parse claude "$(date -u -d 2026-10-29T12:00:00Z +%s)")" == 100 ]] &&
  pass "16. Oct 29 + resets Nov 2 -> 100" || fail "16. same-year reset"
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
# a reset two days ago: a year-less date is the latest one at most 8 days
# ahead (SPL-4155), so a pinned "Jan 1" would read next year's from Dec 24
ent "<synthetic>" "You've hit your weekly limit · resets $(date -u -d '-2 days' '+%b %-d, %-l%P') (UTC)" 3600 >"$L/s1.jsonl"
out="$(lq)"
[[ "$(pick "$out")" == box-a ]] && pass "16e. a limit entry whose reset has passed -> unknown, placed" || fail "16e. reset passed: $out"
ent "claude-x" "You've hit your weekly limit · resets $RS" 3600 >"$L/s1.jsonl"
out="$(lq)"
[[ "$(pick "$out")" == box-a ]] && pass "16e. CONTROL the text in a real model answer (an agent quoting it) is no reading" || fail "16e. quoted: $out"

# 16f-16k. the last measured reading is kept until its reset (SPL-4608): the
#     alert measured claude 95 % on a banner, the next pane tail shows none and
#     the pick read "unknown, placed anyway". The alert's own call records it.
KEPT="$T/kept.tsv"; rm -f "$KEPT"
FUT=$(( $(date +%s) + 3 * 86400 )); PAST=$(( $(date +%s) - 60 ))
wk "box-a::60" "box-b:claude:40:60"
kq() { run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_STATE="$KEPT" BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90; }
# here READING: one read of this box as the alert reads it (BOX_QUOTA_RESET=1)
here() {
  BOX_QUOTA_RESET=1 LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CMD="echo $1" bash -c \
    'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_here'
}
# known [VAR=VALUE ...]: the kept answer with no live reading
known() {
  env LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CMD=echo "$@" bash -c \
    'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_known'
}
out="$(kq)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" &&
  pass "16f. CONTROL a box never measured stays unknown: placed, with the INFO line" || fail "16f. never: $out"
[[ "$(here "claude:95@$FUT")" == "claude:95@$FUT" ]] &&
  pass "16f. the alert's read still prints the live reading" || fail "16f. the alert's read changed"
out="$(kq)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  claude weekly 95% >= 90%: not picked$' <<<"$out" &&
  pass "16f. RED CONTROL (FAILs on c088efd3c) measured 95 % by the alert's read, banner gone -> not picked, pick=box-b" ||
  fail "16f. kept: $out"
wk "box-a::60" "box-b:claude:96:60"
out="$(kq)"
grep -q '^pick=hold reason=waiting: claude weekly >= 90% on box-a, box-b' <<<"$out" &&
  pass "16f. both boxes over, this one on its kept reading -> pick=hold" || fail "16f. hold: $out"
wk "box-a::60" "box-b:claude:40:60"
out="$(LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CMD=echo bash -c \
  'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_here')"
[[ -z "$out" ]] && pass "16f. spl_box_quota_here stays the live read: nothing shows now -> empty" || fail "16f. here: $out"
[[ "$(known)" == "claude:95@$FUT" ]] && pass "16f. spl_box_quota_known prints the % and its reset" || fail "16f. known: $(known)"
# 16g. the reset passed: the reading says nothing, the row is gone
printf 'claude\t95\t%s\t%s\n' "$PAST" "$(date +%s)" >"$KEPT"
out="$(kq)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" && ! grep -q '^claude' "$KEPT" &&
  pass "16g. RED CONTROL a kept reading whose reset passed -> unknown, placed, row dropped" || fail "16g. past: $out"
# 16h. within one reset week the % only climbs; another reset is another week
rm -f "$KEPT"; here "claude:95@$FUT" >/dev/null; here "claude:40@$FUT" >/dev/null
[[ "$(known)" == "claude:95@$FUT" ]] && pass "16h. a lower reading of the same week (an older CLI cache) does not lower it" || fail "16h. same: $(known)"
here "claude:40@$(( FUT + 3600 ))" >/dev/null
[[ "$(known)" == "claude:95@$(( FUT + 3600 ))" ]] && pass "16h. a banner's rounded reset (under a day apart) is the same week" || fail "16h. rounded: $(known)"
here "claude:3@$(( FUT + 2 * 86400 ))" >/dev/null
[[ "$(known)" == "claude:3@$(( FUT + 2 * 86400 ))" ]] && pass "16h. RED CONTROL another reset (a new week, another login) replaces it" || fail "16h. new: $(known)"
# 16i. a reading with no reset (grok prints none): the newest, for LANE_QUOTA_KEEP_S
rm -f "$KEPT"; here "grok:91" >/dev/null; here "grok:12" >/dev/null
[[ "$(known)" == "grok:12" ]] && pass "16i. no reset: the newest reading wins" || fail "16i. newest: $(known)"
here "grok:91" >/dev/null
[[ "$(known)" == "grok:91" ]] && pass "16i. CONTROL still known inside LANE_QUOTA_KEEP_S" || fail "16i. in: $(known)"
printf 'grok\t91\t\t%s\n' $(( $(date +%s) - 86401 )) >"$KEPT"
[[ -z "$(known)" ]] && pass "16i. RED CONTROL no reset, older than a day (default LANE_QUOTA_KEEP_S) -> unknown again" || fail "16i. old: $(known)"
printf 'grok\t91\t\t%s\n' $(( $(date +%s) - 86401 )) >"$KEPT"
[[ "$(known LANE_QUOTA_KEEP_S=90000)" == "grok:91" ]] && pass "16i. LANE_QUOTA_KEEP_S overrides the default" || fail "16i. env"
# 16j. another box's row: wk= carries the reset, an hour-old row keeps a reset ahead
rm -f "$KEPT"
wk "box-a:claude:96@$FUT:60" "box-b:claude:40:60"
[[ "$(pick "$(q BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90)")" == box-b ]] && pass "16j. RED CONTROL (FAILs on c088efd3c) wk=claude:96@<epoch> reads as 96" || fail "16j. suffix"
wk "box-a:claude:96@$PAST:60" "box-b:claude:40:60"
[[ "$(pick "$(q BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90)")" == box-a ]] && pass "16j. wk= whose reset passed -> unknown, placed" || fail "16j. past"
wk "box-a:claude:96@$FUT:4000" "box-b:claude:40:60"
[[ "$(pick "$(q BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90)")" == box-b ]] && pass "16j. a row over an hour old still counts while its reset is ahead" || fail "16j. old row"
# 16k. no write access: the live reading still answers, nothing dies
out="$(BOX_QUOTA_RESET=1 LANE_QUOTA_STATE=/proc/nope/kept.tsv LANE_QUOTA_CMD="echo claude:95@$FUT" bash -c \
  'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_known' 2>&1)"
[[ "$out" == "claude:95@$FUT" ]] && pass "16k. a state file that cannot be written -> the live reading, no noise" || fail "16k. $out"
# 16k2. (SPL-5257) RED CONTROL for 16k's flake: CI ignores SIGPIPE, so a feeder
#     printf of spl_box_quota_note_lapsed still writing when the FILE.lapsed
#     redirect fails printed "printf: write error: Broken pipe" (52 of 300 16k
#     runs). Rows over the 64 KiB pipe buffer make the feeder block, so the old
#     code failed it 20 of 20 times; it must stay silent.
for i in $(seq 20000); do printf 'k%d\t10\t0\t0\n' "$i"; done >"$T/big-rows.tsv"
out="$(bash -c 'trap "" PIPE; source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"
  b="$(cat "$1")"; spl_box_quota_note_lapsed /proc/nope/kept.tsv "$b" "$b" 0 ""; echo "rc=$?"' _ "$T/big-rows.tsv" 2>&1)"
[[ "$out" == "rc=0" ]] && pass "16k2. RED CONTROL unwritable .lapsed, SIGPIPE ignored, rows over a pipe buffer -> rc 0, no noise" || fail "16k2. $out"
# 16l. a kept 100 % drops once the login is measured with quota after it
#     (SPL-4702): 2026-11-03 the login was swapped at 08:56Z, sat held claude
#     lanes on its 07:57Z 100 % until the Nov 7 reset. A real answer newer
#     than the kept read, or the login probe's "ok" after it, lifts it; a real
#     limit (no answer since, the probe says limited) still holds. this box =
#     box-a, the kept read 2 h ago, the new login's reset 2 h after the old one.
L="$T/projects/-opt-x"; rm -rf "$T/projects"; mkdir -p "$L"
NOW=$(date +%s); RS2=$(( FUT + 7200 ))
kept100() { printf 'claude\t100\t%s\t%s\n' "$FUT" $(( NOW - ${1:-7200} )) >"$KEPT"; }
lk() { known LANE_QUOTA_LOG_DIR="$T/projects" LANE_QUOTA_PROBE_FILE="$T/probe" "$@"; }
LIMIT="You've hit your weekly limit · resets $(date -u -d "@$FUT" '+%b %-d, %-l%P') (UTC)"
ent "<synthetic>" "$LIMIT" 7300 >"$L/s1.jsonl"; ent "claude-x" "done" 600 >"$L/r1.jsonl"
kept100; [[ "$(lk LANE_QUOTA_CMD="echo claude:5@$RS2")" == "claude:5@$RS2" ]] &&
  pass "16l. RED CONTROL (FAILs on 35bc30aca: claude:100) a swap: the new login's 5 % (its reset under a day from the kept one), a real answer after the kept read -> 5 %" ||
  fail "16l. swap: $(kept100; lk LANE_QUOTA_CMD="echo claude:5@$RS2")"
kept100; [[ -z "$(lk)" ]] && ! grep -q '^claude' "$KEPT" &&
  pass "16l. RED CONTROL (FAILs on 35bc30aca) a real answer after the kept 100, no reading now -> unknown, row dropped" || fail "16l. no reading: $(kept100; lk)"
kept100; out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_STATE="$KEPT" BOX_PICK_KIND=claude \
  BOX_QUOTA_WEEKLY_MAX_PCT=90 LANE_QUOTA_LOG_DIR="$T/projects" LANE_QUOTA_PROBE_FILE="$T/probe")"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" &&
  pass "16l. the pick: box-a placed again (unknown), not held on the old 100" || fail "16l. pick: $out"
rm -f "$L/r1.jsonl"; printf '%s ok ok\n' $(( NOW - 60 )) >"$T/probe"
kept100; [[ -z "$(lk)" ]] && pass "16l. RED CONTROL (FAILs on 35bc30aca) the login probe said ok after the kept read, no transcripts -> unknown" || fail "16l. probe ok: $(kept100; lk)"
printf '%s ok ok\n' $(( NOW - 7300 )) >"$T/probe"
kept100; [[ "$(lk)" == "claude:100@$FUT" ]] && pass "16l. CONTROL a probe ok OLDER than the kept read lifts nothing -> 100" || fail "16l. old probe: $(kept100; lk)"
printf '%s limited You have hit your weekly limit\n' $(( NOW - 60 )) >"$T/probe"
kept100; [[ "$(lk)" == "claude:100@$FUT" ]] && pass "16l. CONTROL the probe says limited after the kept read -> 100 holds" || fail "16l. limited: $(kept100; lk)"
ent "claude-x" "earlier" 7400 >"$L/r1.jsonl"; ent "<synthetic>" "$LIMIT" 180 >"$L/s1.jsonl"
kept100 120; [[ "$(lk)" == "claude:100@$FUT" ]] && pass "16l. CONTROL a real limit: kept 2 min ago, the limit entry 3 min ago, no answer since -> 100 holds" || fail "16l. real: $(kept100 120; lk)"
printf 'claude\t95\t%s\t%s\n' "$FUT" $(( NOW - 7200 )) >"$KEPT"; ent "claude-x" "done" 600 >"$L/r1.jsonl"
[[ "$(lk LANE_QUOTA_CMD="echo claude:40@$FUT")" == "claude:95@$FUT" ]] &&
  pass "16l. CONTROL a kept 95 is no limit: an answer since does not lower it (16h holds)" || fail "16l. 95: $(lk)"
rm -rf "$T/projects" "$T/probe"
rm -f "$KEPT"
# 16m. a login or limit change lifts a kept claude reading of any %, an old
#     cache never does (SPL-4932). The case, sat 2026-11-06: the credential
#     changed at 13:57:05Z, the kept row read claude 97 at 13:58:08Z, the CLI
#     fetched 0 % at 13:58:09Z under the old account's tag while oauthAccount
#     names the new one, the probe said ok at 16:06:06Z, and new lanes stayed
#     refused until the row was removed by hand at 16:12Z. Kept read 2 h ago.
NOW=$(date +%s); KS=$(( NOW - 7200 )); A=old-login; B=new-login; CJ="$T/cj-kept.json"
kept() { printf 'claude\t%s\t%s\t%s%s\n' "$1" "$FUT" "$KS" "${2:+$'\t'$2}" >"$KEPT"; }
# cj OAUTH TAG FETCHED_AT PCT: the agent user's ~/.claude.json
cj() {
  jq -n --arg o "$1" --arg t "$2" --argjson f "$(( $3 * 1000 ))" --argjson p "$4" \
    --arg r "$(date -u -d "@$FUT" +%Y-%m-%dT%H:%M:%S).652617+00:00" \
    '{oauthAccount: {accountUuid: $o}, cachedUsageUtilization: {accountUuid: $t, fetchedAtMs: $f,
      utilization: {seven_day: {utilization: $p, resets_at: $r}}}}' >"$CJ"
}
ck() { known LANE_QUOTA_CLAUDE_JSON="$CJ" "$@"; }
kept 97; cj "$B" "$A" $(( KS + 1 )) 0
[[ -z "$(ck)" ]] && ! grep -q '^claude' "$KEPT" &&
  pass "16m. RED CONTROL the sat case: a row kept before the login change, 0 % fetched 1 s later under the old tag -> unknown, row dropped" || fail "16m. sat: $(kept 97; ck)"
kept 97; out="$(run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_STATE="$KEPT" BOX_PICK_KIND=claude \
  BOX_QUOTA_WEEKLY_MAX_PCT=90 LANE_QUOTA_CLAUDE_JSON="$CJ")"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown' <<<"$out" &&
  pass "16m. RED CONTROL the pick: box-a placed again (unknown), not held on the kept 97" || fail "16m. pick: $out"
# the row names the login it was read under; another login lifts any %
rm -f "$KEPT"; cj "$A" "$A" "$NOW" 95
[[ "$(BOX_QUOTA_RESET=1 LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CMD="echo claude:95@$FUT" LANE_QUOTA_CLAUDE_JSON="$CJ" bash -c \
  'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_known')" == "claude:95@$FUT" ]] &&
  [[ "$(cut -f5 "$KEPT")" == "$A" ]] && pass "16m. RED CONTROL a new row names its login" || fail "16m. stamp: $(cat "$KEPT")"
for p in 95 100; do
  kept "$p" "$A"; cj "$B" "$A" $(( KS - 60 )) "$p"
  [[ -z "$(ck)" ]] && pass "16m. RED CONTROL kept $p under another login, no fresher fetch, no probe -> unknown" || fail "16m. login $p: $(kept "$p" "$A"; ck)"
done
kept 97 "$A"; cj "$B" "$A" $(( KS - 60 )) 0
[[ "$(ck LANE_QUOTA_CMD="echo claude:4@$FUT")" == "claude:4@$FUT" ]] && [[ "$(cut -f5 "$KEPT")" == "$B" ]] &&
  pass "16m. RED CONTROL another login: its own reading stands alone, the row names the new login" || fail "16m. new: $(cat "$KEPT")"
# the same login: a fetch after the kept read that shows less = the limit moved
kept 97 "$A"; cj "$A" "$A" $(( KS + 60 )) 30
[[ "$(ck LANE_QUOTA_CMD="echo claude:30@$FUT")" == "claude:30@$FUT" ]] &&
  pass "16m. RED CONTROL a raised limit: same login, 30 % fetched after the kept 97 -> 30" || fail "16m. raised: $(cat "$KEPT")"
KS=$(( NOW - 7 * 3600 )); kept 97 "$A"; cj "$A" "$A" $(( NOW - 13 * 1800 )) 30
[[ -z "$(ck)" ]] && pass "16m. RED CONTROL the fetch that lifts is over LANE_QUOTA_CACHE_MAX_S old: still newer than the row -> unknown" || fail "16m. aged: $(cat "$KEPT")"
KS=$(( NOW - 7200 ))
# what must not lift
kept 97 "$A"; cj "$A" "$A" $(( KS - 60 )) 30
[[ "$(ck LANE_QUOTA_CMD="echo claude:30@$FUT")" == "claude:97@$FUT" ]] &&
  pass "16m. CONTROL an old cache (fetched before the kept read) does not lower it" || fail "16m. old cache: $(cat "$KEPT")"
kept 97; cj "$A" "$A" $(( KS - 60 )) 30
[[ "$(ck)" == "claude:97@$FUT" ]] && [[ "$(cut -f5 "$KEPT")" == "$A" ]] &&
  pass "16m. CONTROL a row with no login, an old cache -> holds, and now names the login" || fail "16m. legacy: $(cat "$KEPT")"
kept 97 "$A"; cj "$A" "$B" $(( KS + 60 )) 0
[[ "$(ck)" == "claude:97@$FUT" ]] &&
  pass "16m. CONTROL the row's own login still current, a fresher cache under another tag lifts nothing" || fail "16m. tag: $(cat "$KEPT")"
kept 97 "$A"; cj "$A" "$A" $(( KS + 60 )) 98
[[ "$(ck LANE_QUOTA_CMD="echo claude:98@$FUT")" == "claude:98@$FUT" ]] && pass "16m. CONTROL a fresher, higher reading climbs" || fail "16m. climb: $(cat "$KEPT")"
kept 100 "$A"; cj "$A" "$A" $(( KS + 60 )) 30
[[ "$(ck)" == "claude:100@$FUT" ]] &&
  pass "16m. CONTROL a kept 100 of the same login: the banner's limit, a lower cache lifts nothing (the probe or an answer does, 16l)" || fail "16m. 100: $(cat "$KEPT")"
kept 97 "$A"; echo 'not json' >"$CJ"
[[ "$(ck)" == "claude:97@$FUT" ]] && [[ "$(cut -f5 "$KEPT")" == "$A" ]] &&
  pass "16m. CONTROL an unreadable ~/.claude.json lifts nothing, the row keeps its login" || fail "16m. unreadable: $(cat "$KEPT")"
rm -f "$KEPT"; here "grok:91" >/dev/null
[[ "$(awk -F'\t' '{ print NF }' "$KEPT")" == 4 ]] && pass "16m. CONTROL a grok row carries no login" || fail "16m. grok: $(cat "$KEPT")"
rm -f "$KEPT" "$CJ"

# 16n. a kept reading lapses unless re-read, and says where it came from
#     (SPL-4965). 2026-11-06: a kept 97 % held the placer for 2 h 15 while the
#     alert read 0 %. SPL-4608 kept the reading because lanes were placed past
#     the limit, so both directions: a stale row goes, a real limit holds.
#     LAPSE is the default 10 h, 12 h past it and 6 h and 9 h under it.
NOW=$(date +%s); H=3600; BAN="$T/banners"; CJ="$T/cj-lapse.json"; A=one-login
keptn() { printf 'claude\t%s\t%s\t%s\t%s\t%s\n' "$1" "$FUT" "$(( NOW - $2 * H ))" "$A" "${3:-cache}" >"$KEPT"; }
banners() { printf 'cat %s' "$BAN"; }
scr() { rm -f "$KEPT.banners"; : >"$BAN"; [[ $# -eq 0 ]] || printf 'claude\tc-001\t%s\n' "$1" >"$BAN"; }
sighted() { printf 'claude/c-001\t%s\t%s\n' "$1" "$(( NOW - $2 * H ))" >"$KEPT.banners"; }
lapk() { known LANE_QUOTA_CMD= LANE_PANES_CMD=true LANE_QUOTA_LOG_DIR="$T/none" LANE_QUOTA_CLAUDE_JSON="$CJ" \
  LANE_QUOTA_PROBE_FILE="$T/probe" LANE_QUOTA_BANNERS_CMD="$(banners)" "$@"; }
rm -f "$T/probe"; cj "$A" "$A" 1000 0; scr
keptn 97 12; [[ -z "$(lapk)" ]] && ! grep -q '^claude' "$KEPT" &&
  pass "16n. RED CONTROL a kept 97 not re-read for 12 h -> unknown, row dropped (FAILs before SPL-4965: claude:97)" || fail "16n. lapse: $(cat "$KEPT")"
keptn 97 6; [[ "$(lapk)" == "claude:97@$FUT" ]] &&
  pass "16n. CONTROL a real limit: kept 97, 6 h old, no re-read yet -> still holds" || fail "16n. 6 h: $(cat "$KEPT")"
keptn 97 9; [[ "$(lapk)" == "claude:97@$FUT" ]] &&
  pass "16n. CONTROL a real limit: kept 97, 9 h old -> holds (a real climb on the main box took 8.33 h, n=6)" || fail "16n. 9 h: $(cat "$KEPT")"
keptn 97 12; [[ "$(lapk LANE_QUOTA_LAPSE_S=0)" == "claude:97@$FUT" ]] &&
  pass "16n. CONTROL LANE_QUOTA_LAPSE_S=0 keeps it to the reset" || fail "16n. off: $(cat "$KEPT")"
# a real limit that goes on being read holds past the lapse
keptn 97 12; cj "$A" "$A" $(( NOW - H )) 97; [[ "$(lapk)" == "claude:97@$FUT" ]] && [[ "$(cut -f4,6 "$KEPT")" == "$(( NOW - H ))"$'\t'cache ]] &&
  pass "16n. CONTROL a real limit re-read: the CLI fetched the same 97 an hour ago -> holds, read time is the fetch's" || fail "16n. re-read: $(cat "$KEPT")"
cj "$A" "$A" 1000 0
# a banner still on screen is not a re-read (the gap SPL-4932 named)
scr "97@$FUT"; sighted "97@$FUT" 12; keptn 97 12 banner; [[ -z "$(lapk)" ]] && ! grep -q '^claude' "$KEPT" &&
  pass "16n. RED CONTROL the same banner on screen, first seen 12 h ago -> no re-read, unknown (FAILs before SPL-4965: refreshed every tick)" || fail "16n. static: $(cat "$KEPT")"
scr "97@$FUT"; sighted "97@$FUT" 2; keptn 97 2 banner; [[ "$(lapk)" == "claude:97@$FUT" ]] && [[ "$(cut -f4 "$KEPT")" == "$(( NOW - 2 * H ))" ]] &&
  pass "16n. CONTROL the same banner, first seen 2 h ago -> holds, and its read time stays 2 h ago" || fail "16n. static 2 h: $(cat "$KEPT")"
scr "98@$FUT"; sighted "97@$FUT" 12; keptn 97 12 banner; [[ "$(lapk)" == "claude:98@$FUT" ]] && [[ "$(cut -f6 "$KEPT")" == banner ]] && (( $(cut -f4 "$KEPT") >= NOW )) &&
  pass "16n. CONTROL a real limit: a NEW banner (98 %) on that pane is a fresh read -> holds at 98" || fail "16n. new banner: $(cat "$KEPT")"
rm -f "$KEPT"; scr "97@$FUT"; [[ "$(lapk)" == "claude:97@$FUT" ]] && [[ "$(cut -f1,3 "$KEPT.banners")" == "claude/c-001"$'\t'* ]] &&
  pass "16n. CONTROL a banner first seen now, no state before -> kept, its first sighting recorded" || fail "16n. first: $(cat "$KEPT" "$KEPT.banners")"
scr; lapk >/dev/null; [[ ! -s "$KEPT.banners" || -z "$(tr -d '[:space:]' <"$KEPT.banners")" ]] &&
  pass "16n. CONTROL a banner gone from the screen is forgotten" || fail "16n. forget: $(cat "$KEPT.banners")"
# an old banner must not re-keep what a newer fetch overruled
keptn 97 2 banner; scr "97@$FUT"; sighted "97@$FUT" 2; cj "$A" "$A" $(( NOW - 60 )) 0
[[ "$(lapk)" == "claude:0@$FUT" ]] && [[ "$(cut -f6 "$KEPT")" == cache ]] &&
  pass "16n. RED CONTROL the SPL-4932 gap: limit raised, 0 % fetched after a banner still on screen -> 0, not re-kept at 97" || fail "16n. gap: $(cat "$KEPT")"
keptn 97 2 banner; scr "97@$FUT"; sighted "97@$FUT" 0; cj "$A" "$A" $(( NOW - H )) 80
[[ "$(lapk)" == "claude:97@$FUT" ]] &&
  pass "16n. CONTROL a real limit: the banner is newer than the 80 % fetch -> holds at 97" || fail "16n. banner newer: $(cat "$KEPT")"
cj "$A" "$A" 1000 0; scr
# a kept 100 shows on no screen: the login probe is its re-read
keptfull() { printf 'claude\t100\t%s\t%s\t%s\tlog\n' "$FUT" "$(( NOW - $1 * H ))" "$A" >"$KEPT"; }
keptfull 12; printf '%s limited limited\n' "$(( NOW - 120 ))" >"$T/probe"; [[ "$(lapk)" == "claude:100@$FUT" ]] && [[ "$(cut -f6 "$KEPT")" == probe ]] &&
  pass "16n. CONTROL a real limit: a kept 100, 12 h old, the probe says limited now -> holds, source probe" || fail "16n. probe: $(cat "$KEPT")"
rm -f "$T/probe"; keptfull 12; [[ -z "$(lapk)" ]] &&
  pass "16n. RED CONTROL a kept 100, 12 h old, nothing re-reads it -> unknown (FAILs before SPL-4965)" || fail "16n. 100: $(cat "$KEPT")"
# R7 W2 (c-992): the climb from under 100 with no screen, the probe says limited
printf '%s limited limited\n' "$(( NOW - 60 ))" >"$T/probe"
keptn 97 12; [[ "$(lapk)" == "claude:97@$FUT" ]] && [[ "$(cut -f4,6 "$KEPT")" == "$(( NOW - 60 ))"$'\t'probe ]] &&
  pass "16n. RED CONTROL W2: a kept 97, 12 h old, the probe says limited -> holds, source probe" || fail "16n. W2: $(cat "$KEPT")"
keptn 97 12; [[ "$(lapk LANE_QUOTA_CMD="echo claude:98@$FUT~banner~$(( NOW - H ))")" == "claude:98@$FUT" ]] &&
  pass "16n. CONTROL W2: a higher live reading is not read as lower than the probe's" || fail "16n. W2 higher: $(cat "$KEPT")"
keptn 80 12; [[ -z "$(lapk)" ]] &&
  pass "16n. CONTROL W2: a kept 80 is no hold, limited does not re-keep it" || fail "16n. W2 80: $(cat "$KEPT")"
keptn 97 12; printf '%s limited limited\n' "$(( NOW - 13 * H ))" >"$T/probe"; [[ -z "$(lapk)" ]] &&
  pass "16n. CONTROL W2: a limited older than the row re-reads nothing" || fail "16n. W2 old: $(cat "$KEPT")"
keptn 97 12; printf '%s ok ok\n' "$(( NOW - 60 ))" >"$T/probe"; [[ -z "$(lapk)" ]] &&
  pass "16n. CONTROL W2: a probe that says ok re-reads nothing" || fail "16n. W2 ok: $(cat "$KEPT")"
printf 'claude\t97\t%s\t%s\t%s\tcache\n' "$PAST" "$(( NOW - 2 * H ))" "$A" >"$KEPT"; printf '%s limited limited\n' "$(( NOW - 60 ))" >"$T/probe"; [[ -z "$(lapk)" ]] &&
  pass "16n. CONTROL W2: a kept 97 past its reset is no hold, a short limit does not carry it into the new week" || fail "16n. W2 reset: $(cat "$KEPT")"
rm -f "$T/probe"
# R7 W1 (c-992): a lapsed highest token must not take the fresh one with it
rm -f "$KEPT"; [[ "$(lapk LANE_QUOTA_CMD="echo claude:100@$FUT~log~$(( NOW - 12 * H )),claude:99@$FUT~cache~$(( NOW - H ))")" == "claude:99@$FUT" ]] && [[ "$(cut -f6 "$KEPT")" == cache ]] &&
  pass "16n. RED CONTROL W1: a limit entry 12 h old and a fetch of 99 an hour old -> holds on the 99" || fail "16n. W1: $(cat "$KEPT")"
rm -f "$KEPT"; [[ "$(lapk LANE_QUOTA_CMD="echo claude:100@$FUT~log~$(( NOW - 12 * H )),claude:96@$FUT~banner~$NOW")" == "claude:96@$FUT" ]] &&
  pass "16n. RED CONTROL W1: a new banner 96 behind a lapsed 100 -> holds on the 96" || fail "16n. W1 banner: $(cat "$KEPT")"
rm -f "$KEPT"; [[ "$(lapk LANE_QUOTA_CMD="echo claude:100@$FUT~log~$(( NOW - 7 * H )),claude:99@$FUT~cache~$(( NOW - H ))")" == "claude:100@$FUT" ]] &&
  pass "16n. CONTROL W1: a limit entry 7 h old still is the reading" || fail "16n. W1 7 h: $(cat "$KEPT")"
rm -f "$KEPT"; [[ -z "$(lapk LANE_QUOTA_CMD="echo claude:100@$FUT~log~$(( NOW - 12 * H ))")" ]] &&
  pass "16n. CONTROL W1: a lapsed limit entry alone -> unknown" || fail "16n. W1 alone: $(cat "$KEPT")"
keptn 97 12; [[ "$(lapk LANE_QUOTA_CMD="echo claude:100@$FUT~log~$(( NOW - 12 * H )),claude:5@$FUT~cache~$(( NOW - 60 ))")" == "claude:5@$FUT" ]] &&
  pass "16n. CONTROL W1: both lapsed, a fresh 5 -> reads 5, no hold" || fail "16n. W1 5: $(cat "$KEPT")"
# R7 W1 through the real read: a real transcript entry and a real cache
LW="$T/l-w1"; mkdir -p "$LW"; ent "<synthetic>" "You've hit your weekly limit · resets $RS" $(( 12 * H )) >"$LW/s.jsonl"; touch "$LW/s.jsonl"
rm -f "$KEPT"; cj "$A" "$A" $(( NOW - H )) 99; v="$(lapk LANE_QUOTA_LOG_DIR="$LW")"; [[ "$v" == "claude:99@"* ]] && [[ "$(cut -f6 "$KEPT")" == cache ]] &&
  pass "16n. RED CONTROL W1 end to end: limit entry 12 h old, CLI fetch 99 an hour old -> holds on the 99, not unknown" || fail "16n. W1 real: $v, $(cat "$KEPT")"
rm -rf "$LW"; cj "$A" "$A" 1000 0
# R7 N2 (c-992): a hold that lapses says so, once
lapsed() { [[ -s "$KEPT.lapsed" ]] && cut -f1-3 "$KEPT.lapsed" | tr '\t' ' '; }
rm -f "$KEPT.lapsed"; keptn 97 12; lapk >/dev/null; [[ "$(lapsed)" == "claude 97 cache" ]] &&
  pass "16n. RED CONTROL N2: a hold that lapses leaves its row for the alarm" || fail "16n. N2: $(lapsed)"
lapk >/dev/null; [[ "$(grep -c . "$KEPT.lapsed")" == 1 ]] && pass "16n. N2: the next tick adds nothing" || fail "16n. N2 again: $(cat "$KEPT.lapsed")"
n2_none() { [[ ! -s "$KEPT.lapsed" ]] && pass "16n. CONTROL N2: $1" || fail "16n. N2 $1: $(cat "$KEPT.lapsed")"; rm -f "$KEPT.lapsed"; }
rm -f "$KEPT.lapsed"; keptn 97 6; lapk >/dev/null; n2_none "6 h old, still holding"
keptn 80 12; lapk >/dev/null; n2_none "a kept 80 was no hold"
keptn 97 12; lapk LANE_QUOTA_LAPSE_S=0 >/dev/null; n2_none "no lapse configured"
keptn 97 12; lapk LANE_QUOTA_CMD="echo claude:95@$FUT~cache~$(( NOW - H ))" >/dev/null; n2_none "a reading over the threshold replaced it"
printf 'claude\t97\t%s\t%s\t%s\tcache\n' "$PAST" "$(( NOW - 12 * H ))" "$A" >"$KEPT"; lapk >/dev/null; n2_none "its reset passed"
keptn 97 12; cj other other $(( NOW - 60 )) 0; lapk >/dev/null; n2_none "the login changed: a lift, not a lapse"; cj "$A" "$A" 1000 0
keptn 97 12; lapk LANE_QUOTA_CMD="echo claude:40@$FUT~cache~$(( NOW - H ))" >/dev/null; [[ "$(lapsed)" == "claude 97 cache" ]] &&
  pass "16n. N2: a reading under the threshold after it: the hold still lapsed, alarm" || fail "16n. N2 40: $(lapsed)"; rm -f "$KEPT.lapsed"
# two readings that disagree
dis() { env LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CMD=echo bash -c 'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_disagree 90'; }
keptfull 2; lapk LANE_QUOTA_CMD="echo claude:5@$FUT~cache~$(( NOW - 60 ))" >/dev/null
[[ "$(dis | cut -f1,2,3,5,6)" == "claude"$'\t'"100"$'\t'"log"$'\t'"5"$'\t'"cache" ]] &&
  pass "16n. RED CONTROL a kept 100 and a newer 5 % -> disagree, both sources named" || fail "16n. disagree: $(cat "$KEPT"); $(dis)"
keptfull 2; lapk LANE_QUOTA_CMD="echo claude:5@$FUT~cache~$(( NOW - 3 * H ))" >/dev/null; [[ -z "$(dis)" ]] &&
  pass "16n. CONTROL the lower reading is OLDER than the kept one: only lag, no alarm" || fail "16n. lag: $(dis)"
keptfull 2; lapk LANE_QUOTA_CMD="echo claude:95@$FUT~cache~$(( NOW - 60 ))" >/dev/null; [[ -z "$(dis)" ]] &&
  pass "16n. CONTROL a newer lower reading still over the threshold changes no decision: no alarm" || fail "16n. over: $(dis)"
lapk LANE_QUOTA_CMD="echo claude:100@$FUT~log~$NOW" >/dev/null; [[ -z "$(dis)" ]] &&
  pass "16n. CONTROL a fresh re-read clears the disagreement" || fail "16n. clear: $(dis)"
# the hold line: this box from its kept file, another from its row's wkr=
rm -f "$T/probe"
printf 'claude\t97\t%s\t%s\t%s\tcache\n' "$FUT" "$(( NOW - 2 * H - 900 ))" "$A" >"$KEPT"
jq --arg s "mem_kb=1 wk=claude:96@$FUT wkr=claude:banner:$(( NOW - 300 )) live=" \
  '.lanes = [{agent_id: "BOX-0", agent_box: "box-b", state: "live", age_s: 60, scope: $s}]' "$T/lanes.json" >"$T/lanes2.json"
out="$(run LANES="$T/lanes2.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_CMD=echo LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CLAUDE_JSON="$CJ" BOX_QUOTA_WEEKLY_MAX_PCT=90 BOX_PICK_KIND=claude)"
grep -q "^pick=hold reason=waiting: claude weekly >= 90% on box-a, box-b \[box-a 97% cache read 2h1[45]m ago; box-b 96% banner read [45]m ago\]: queue the lane" <<<"$out" &&
  pass "16n. RED CONTROL the hold line states each box's %, source and age (FAILs before SPL-4965)" || fail "16n. line: $out"
keptn 97 12; out="$(run LANES="$T/lanes2.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_CMD=echo LANE_QUOTA_STATE="$KEPT" LANE_QUOTA_CLAUDE_JSON="$CJ" BOX_QUOTA_WEEKLY_MAX_PCT=90 BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: claude weekly usage unknown .*it lapsed with no re-read' <<<"$out" &&
  pass "16n. the pick: a lapsed row -> box-a placed again, the INFO line says it may have lapsed" || fail "16n. pick: $out"
rm -f "$KEPT" "$KEPT.banners" "$KEPT.lapsed" "$CJ" "$BAN"

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

# 19. the AIM (owner HUM-10, t1 f456ecd5 msg 61cd77e7): box-a's band 70..90
#     aims at 80, box-b's 40..60 has no aim (= its high). Between its aim and
#     its high, box-a takes a lane only when no box is under its aim.
#     RED CONTROL (FAILs before SPL-3876): box-a at 85 %, box-b at 50 % ->
#     box-b, where the pick without the aim took box-a (first below high).
target 50 75 '["box-a","box-b"]' '{"box-a":{"low":70,"high":90,"aim":80},"box-b":{"low":40,"high":60}}'
stats "box-a:6.8:8" "box-b:4:8"
out="$(run)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a  load5 6.8  cpus 8  85%  in band  band 70..90 aim 80 (box)$' <<<"$out" &&
  pass "19. RED CONTROL (FAILs before SPL-3876) box-a past its aim (85% >= 80%), box-b under its own (50% < 60%) -> pick=box-b" ||
  fail "19. aim: $out"
stats "box-a:6:8" "box-b:4:8"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && grep -q 'reason=box-a is the first box in order below its aim (75% < 80%)' <<<"$out" &&
  pass "19. box-a under its aim (75% < 80%) comes first in order -> pick=box-a, the reason names the aim" || fail "19. under aim: $out"
stats "box-a:6.8:8" "box-b:5.2:8"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && grep -q 'below its high mark (85% < 90%)' <<<"$out" &&
  pass "19. no box under its aim (box-b 65% is full) -> box-a between aim and high takes it" || fail "19. between: $out"
target 50 75 '["box-a","box-b"]' '{"box-a":{"low":70,"high":90},"box-b":{"low":40,"high":60}}'
stats "box-a:6.8:8" "box-b:4:8"
out="$(run)"
[[ "$(pick "$out")" == box-a ]] && grep -q 'band 70..90 (box)  <- pick$' <<<"$out" &&
  pass "19. CONTROL: the same loads with no aim -> box-a, first below its high, as before" || fail "19. no aim: $out"

# 20. SPL-5138 (ruling c1e9bd5f): a box in its RECOVERING hold is benched like
#     a degraded one. boxa's beats stop for 200 s (> max_gap_s 120) and resume
#     at G1, boxb beats on; both idle, boxa first. Beats every 10 s, so the
#     read's newest beat is HUB_NOW. Names without a dash: a hand-<box>- slug
#     takes [a-z0-9]+ only.
G1=1791700000
# hbeats BOX LAST_BEAT GAP(0|1): every 10 s from G1 - 4000 to LAST_BEAT, GAP
# leaves out (G1 - 200, G1)
hbeats() { jq -nc --arg b "$1" --argjson g "$G1" --argjson l "$2" --argjson gap "$3" \
  '[range($g - 4000; $l + 1; 10) | select($gap == 0 or . <= $g - 200 or . >= $g) | {box: $b, e: .}]'; }
END20=$((G1 + 4000))
jq -s add <(hbeats boxa $END20 1) <(hbeats boxb $END20 0) >"$T/rec1.json"
jq -s add <(hbeats boxa $END20 1) <(hbeats boxb $END20 1) >"$T/rec2.json"
jq -s add <(hbeats boxa $((G1 + 250)) 0) <(hbeats boxb $END20 1) >"$T/deg1.json"
target 50 75 '["boxa","boxb"]'
stats "boxa:1:8" "boxb:1:8"
out20="$(run BEATS="$T/rec1.json" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out20")" == boxb ]] && grep -q '^BOX boxa .*  RECOVERING (healthy for 400s < hold 1800s)' <<<"$out20" &&
  pass "20. a box 400 s into its hold is not picked and its line says why (pick=boxb)" || fail "20. recovering: $out20"
out="$(run BEATS="$T/rec1.json" HUB_NOW=$((G1 + 400)) BOX_PICK_REVIEW_SEAT=1)"
[[ "$(pick "$out")" == boxb ]] && pass "20. a review seat (BOX_PICK_REVIEW_SEAT=1) is not placed on it either" || fail "20. review seat: $out"
out="$(run BEATS="$T/rec1.json" HUB_NOW=$((G1 + 1790)))"
[[ "$(pick "$out")" == boxb ]] && pass "20. still benched 10 s before the hold ends (+1790 s)" || fail "20. +1790: $out"
out21="$(run BEATS="$T/rec1.json" HUB_NOW=$((G1 + 1800)))"
[[ "$(pick "$out21")" == boxa ]] && ! grep -q 'RECOVERING' <<<"$out21" &&
  pass "20. released when the hold ends (+1800 s): pick=boxa, no RECOVERING" || fail "20. release: $out21"
out="$(run BEATS="$T/rec2.json" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out")" == boxa ]] && grep -q '^WARN every box with a load sample is degraded or recovering' <<<"$out" &&
  pass "20. every box recovering (a hub stall): the fallback still places (boxa), with its WARN" || fail "20. all recovering: $out"
out="$(run BEATS="$T/deg1.json" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out")" == boxb ]] && grep -q '^BOX boxa .*DEGRADED' <<<"$out" && grep -q '^WARN every box' <<<"$out" &&
  pass "20. boxa degraded, boxb recovering: the fallback takes the recovering box, not the first in order" || fail "20. mixed: $out"

# 20. W1 (c-429): the bench removed the last box that could take the lane ->
#     pick=hold naming the hold, never nokind (spawn-window exit 13, a
#     launch-failed blocker per placer retry).
LOST='^pick=hold reason=.*in its recovering hold \(boxa healthy for 400s < hold 1800s\)'
clis "boxa:agy,claude:60" "boxb:claude:60"
K20=(LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_KIND=agy BEATS="$T/rec1.json")
out="$(run "${K20[@]}" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out")" == hold ]] && grep -qE "$LOST" <<<"$out" &&
  pass "20. only the benched box has the CLI: pick=hold naming the hold, not nokind" || fail "20. benched CLI: $out"
out="$(run "${K20[@]}" HUB_NOW=$((G1 + 1800)))"
[[ "$(pick "$out")" == boxa ]] && pass "20. CONTROL the same lane goes to boxa when the hold ends" || fail "20. CLI release: $out"
clis "boxa:claude:60" "boxb:claude:60"
out="$(run "${K20[@]}" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out")" == nokind ]] && pass "20. CONTROL the benched box lacks the CLI too: still nokind, waiting would not help" || fail "20. both no CLI: $out"
stats "boxa:1:8" "boxb:24:8"
out="$(run BEATS="$T/rec1.json" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out")" == hold ]] && grep -qE "$LOST" <<<"$out" &&
  pass "20. the healthy box is past its overflow mark: the hold reason names the bench" || fail "20. overflow: $out"
stats "boxa:24:8" "boxb:24:8"
out="$(run BEATS="$T/rec1.json" HUB_NOW=$((G1 + 400)))"
[[ "$(pick "$out")" == hold ]] && grep -q 'reason=no box with a sample is below its overflow mark' <<<"$out" &&
  pass "20. CONTROL the benched box is past its overflow mark too: the plain overflow hold" || fail "20. both over: $out"
stats "boxa:1:8" "boxb:1:8"

# 20. the placer: a row pinned to the box waits, says why, and is released.
# pin20 PICK_OUT -> the rows left after spl_spawn_place_pin_hold
mkdir -p "$T/asks"
pin20() {
  printf '%s\n' "$1" >"$T/pick.out"
  ASKS="$T/asks" SPAWN_PLACE_PICK_CMD="cat $T/pick.out" bash -c '
    do_log() { :; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-spawn-place.func.sh"
    spool_asks_dir() { echo "$ASKS"; }
    spl_spawn_place_pin_hold "[{\"ask_id\":\"aaaaaaaa-0001\",\"state\":\"queued\",\"_l\":true,\"placement\":\"claude:hand-boxa-fix\"}]"'
}
left="$(pin20 "$out20")"
wait20="$(cat "$T/asks/.place.wait" 2>/dev/null)"
[[ "$left" == "[]" && "$wait20" == *"pinned to boxa: box boxa is RECOVERING (healthy for 400s < hold 1800s): no new lanes until its hold ends"* ]] &&
  pass "20. a hand-boxa row waits in the hold, its .place.wait line says why" || fail "20. pin hold: left=$left wait=$wait20"
left="$(pin20 "$out21")"
[[ "$(jq -r '.[0].ask_id' <<<"$left")" == aaaaaaaa-0001 && ! -s "$T/asks/.place.wait" ]] &&
  pass "20. the same row is released when the hold ends, its wait line gone" || fail "20. pin release: left=$left wait=$(cat "$T/asks/.place.wait")"

# 21. a vendor's own weekly mark (SPL-5432, owner t1 b122105a: "start
#     utilizing grok once again and stop when its usage is at 95% on weekly
#     limit"): env.box.quota.vendor_weekly_max_pct.grok 95 replaces
#     weekly_max_pct for grok lanes, and a grok lane never goes to a box with
#     no grok reading. The counting test: 94 places, 95 waits, unknown waits.
target 50 75 '["box-a","box-b"]'
stats "box-a:2:8" "box-b:4.4:8"
printf 'env:\n  box:\n    fleet_load:\n      box_order: [box-a, box-b]\n    quota:\n      weekly_max_pct: 90\n' >"$T/cnf21-plain.yaml"
cp "$T/cnf21-plain.yaml" "$T/cnf21.yaml"
printf '      vendor_weekly_max_pct:\n        grok: 95\n' >>"$T/cnf21.yaml"
g21() { run LANES="$T/lanes.json" LANE_BOX=box-desk SPOOL_VENDOR_CLIS_CMD="echo $ALL" BOX_PICK_CNF="$T/cnf21.yaml" BOX_PICK_KIND=grok "$@"; }
for c in 94:box-a 95:box-b 96:box-b; do
  wk "box-a:grok=${c%%:*}:60" "box-b:grok=40:60"
  out="$(g21)"
  [[ "$(pick "$out")" == "${c#*:}" ]] && pass "21. grok mark 95, box-a at ${c%%:*} % -> pick=${c#*:}" || fail "21. grok ${c%%:*}: $out"
done
grep -q '^BOX box-a .*  grok weekly 96% >= 95%: not picked$' <<<"$out" && pass "21. box-a's line names grok's own mark, 95" || fail "21. line: $out"
wk "box-a:grok=94:60" "box-b:grok=40:60"
out="$(g21 BOX_PICK_CNF="$T/cnf21-plain.yaml")"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  grok weekly 94% >= 90%: not picked$' <<<"$out" &&
  pass "21. RED CONTROL no vendor mark (before SPL-5432): grok at 94 % holds at weekly_max_pct 90" || fail "21. plain 94: $out"
wk "box-a:grok=95:60" "box-b:grok=99:60"
out="$(g21)"
[[ "$(pick "$out")" == hold ]] && grep -q '^pick=hold reason=waiting: grok weekly >= 95% on box-a, box-b \[box-a 95% source not stated; box-b 99% source not stated\]' <<<"$out" &&
  pass "21. every box at or over 95 -> pick=hold, waiting on grok's mark" || fail "21. all over: $out"
wk "box-a::60" "box-b::60"
out="$(g21)"
[[ "$(pick "$out")" == hold ]] && grep -q '^BOX box-a .*  grok weekly unknown, its own mark 95%: not picked$' <<<"$out" &&
  grep -q '^pick=hold reason=waiting: grok weekly >= 95% or unknown on box-a, box-b \[box-a unknown (no reading); box-b unknown (no reading)\]' <<<"$out" &&
  pass "21. no grok reading anywhere, a mark set -> unknown waits (pick=hold), the line says why" || fail "21. unknown: $out"
out="$(g21 BOX_PICK_CNF="$T/cnf21-plain.yaml")"
[[ "$(pick "$out")" == box-a ]] && grep -q '^INFO box-a: grok weekly usage unknown' <<<"$out" &&
  pass "21. RED CONTROL no vendor mark: unknown is placed, as before SPL-5432" || fail "21. plain unknown: $out"
wk "box-a::60" "box-b:grok=40:60"
out="$(g21)"
[[ "$(pick "$out")" == box-b ]] && pass "21. box-a unknown, box-b at 40 % -> box-b" || fail "21. one unknown: $out"
wk "box-a:grok=94:4000" "box-b::60"
out="$(g21)"
[[ "$(pick "$out")" == hold ]] && pass "21. a 94 % on an hour-old row with no reset is unknown -> waits" || fail "21. stale: $out"
wk "box-a:claude=94:60" "box-b:claude=40:60"
out="$(g21 BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  claude weekly 94% >= 90%: not picked$' <<<"$out" &&
  pass "21. CONTROL claude has no own mark: a claude lane still holds at 90 %" || fail "21. claude: $out"
wk "box-a::60" "box-b::60"
out="$(g21 BOX_PICK_KIND=claude)"
[[ "$(pick "$out")" == box-a ]] && pass "21. CONTROL claude unknown is still placed (no own mark)" || fail "21. claude unknown: $out"
wk "box-a:grok=96:60" "box-b:grok=40:60"
out="$(g21 BOX_QUOTA_WEEKLY_MAX_PCT_GROK=97)"
[[ "$(pick "$out")" == box-a ]] && pass "21. BOX_QUOTA_WEEKLY_MAX_PCT_GROK=97 overrides the cnf: box-a at 96 % is picked" || fail "21. env: $out"
out="$(g21 BOX_QUOTA_WEEKLY_MAX_PCT_GROK=x9)"
[[ "$(pick "$out")" == box-b ]] && pass "21. a vendor mark that is no number falls back to the cnf's 95" || fail "21. bad env: $out"
wk "box-a:grok=95:60" "box-b:grok=95:60"
out="$(g21 BOX_PICK_REVIEW_SEAT=1 BOX_QUOTA_REVIEW_SEAT_MAX_PCT=91)"
[[ "$(pick "$out")" == hold ]] && grep -q 'waiting: grok weekly >= 95% on' <<<"$out" &&
  pass "21. a review seat's mark is never under the vendor's own (91 -> 95)" || fail "21. seat: $out"

# 21. the grok reading: its CLI's billing log (spl_box_quota_grok_read)
gl() {  # TS_AGE_S PCT PERIOD_END_OFFSET_S [TYPE] -> one unified.jsonl billing line
  jq -nc --arg ts "$(date -u -d "-$1 seconds" +%Y-%m-%dT%H:%M:%S.123Z)" --argjson p "$2" \
    --arg end "$(date -u -d "+$3 seconds" +%Y-%m-%dT%H:%M:%S.581549+00:00)" --arg ty "${4:-USAGE_PERIOD_TYPE_WEEKLY}" \
    '{ts: $ts, src: "shell", lvl: "info", msg: "billing: fetched credits config",
      ctx: {config: {creditUsagePercent: $p, currentPeriod: {type: $ty, start: "2026-11-07T06:30:07.5+00:00", end: $end}}}}'
}
gread() { bash -c 'source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-box-quota.func.sh"; spl_box_quota_grok_read' 2>&1; }
GL="$T/grok-unified.jsonl"
{ echo '{"ts":"2026-11-13T02:23:03.331Z","msg":"other"}'; gl 7200 15 86400; gl 600 27.6 86400; echo '{"msg":"later, not billing"}'; } >"$GL"
r="$(gread <"$GL")"
[[ "$r" =~ ^27@[0-9]+~billing~[0-9]+$ ]] && pass "21. the newest billing entry -> $r (27.6 floored)" || fail "21. read: '$r'"
[[ -z "$(gl 600 27 -60 | gread)" ]] && pass "21. a week that ended -> no reading" || fail "21. ended"
[[ -z "$(gl 40000 27 86400 | gread)" ]] && pass "21. an entry older than the lapse (11 h) -> no reading" || fail "21. old"
[[ "$(gl 40000 27 86400 | LANE_QUOTA_GROK_LOG_MAX_S=50000 gread)" == 27@* ]] && pass "21. LANE_QUOTA_GROK_LOG_MAX_S widens it" || fail "21. max"
[[ -z "$(gl 600 27 86400 USAGE_PERIOD_TYPE_MONTHLY | gread)" ]] && pass "21. a period that is not weekly -> no reading" || fail "21. monthly"
[[ "$(gl 600 130 86400 | gread)" == 100@* ]] && pass "21. over 100 reads 100" || fail "21. 130"
[[ -z "$(echo '{"msg":"nothing here"}' | gread)" ]] && pass "21. no billing entry -> no reading" || fail "21. none"
# this box's live reading: the log read through spl_box_quota_read -> wk=, the pick
gq() { run LANES="$T/lanes.json" LANE_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo $ALL" LANE_QUOTA_CMD= LANE_PANES_CMD=true \
  LANE_QUOTA_LOG_DIR="$T/none" LANE_QUOTA_STATE="$T/kept21.tsv" LANE_QUOTA_GROK_LOG="$GL" BOX_PICK_CNF="$T/cnf21.yaml" BOX_PICK_KIND=grok; }
wk "box-a::60" "box-b:grok=40:60"
gl 300 94 86400 >"$GL"; rm -f "$T/kept21.tsv"
out="$(gq)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^BOX box-a .*  grok weekly 94%  <- pick$' <<<"$out" &&
  pass "21. this box's grok log at 94 % -> box-a picked" || fail "21. live 94: $out"
gl 60 95 86400 >"$GL"
out="$(gq)"
[[ "$(pick "$out")" == box-b ]] && grep -q '^BOX box-a .*  grok weekly 95% >= 95%: not picked$' <<<"$out" &&
  grep -q $'^grok\t95\t' "$T/kept21.tsv" && pass "21. this box's grok log at 95 % -> not picked, kept with its source" || fail "21. live 95: $out $(cat "$T/kept21.tsv")"
grep -q 'billing' "$T/kept21.tsv" && pass "21. the kept row names its source, billing" || fail "21. src: $(cat "$T/kept21.tsv")"

echo "spl-box-pick: $fails failure(s)"
[ "$fails" -eq 0 ]
