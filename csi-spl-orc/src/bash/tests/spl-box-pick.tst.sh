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
esac
STUB
chmod +x "$T/bin/hub"
printf 'env:\n  box:\n    fleet_load:\n      box_order: [box-a, box-b]\n' >"$T/cnf.yaml"

# target LOW HIGH ORDER_JSON [BOXES_JSON]
target() { printf '{"low":%s,"high":%s,"box_order":%s,"boxes":%s,"source":"hub"}\n' "$1" "$2" "$3" "${4:-{\}}" >"$T/target.json"; }
# stats BOX:LOAD5:CPUS ... (one older sample of every box first, which the latest overrides)
stats() {
  local rows="" s b l c
  for s in "$@"; do
    IFS=: read -r b l c <<<"$s"
    rows+="{\"box\":\"$b\",\"at\":\"2026-10-04T10:00:00Z\",\"load5\":99,\"cpus\":$c},"
    rows+="{\"box\":\"$b\",\"at\":\"2026-10-04T10:05:00Z\",\"load5\":$l,\"cpus\":$c},"
  done
  printf '{"since":"x","rows":[%s],"hours":[]}\n' "${rows%,}" >"$T/stats.json"
}

run() {
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=box-desk LANE_FLEET=main LANE_HUB_CMD="$T/bin/hub" \
    CALLS="$T/calls" TARGET="$T/target.json" STATS="$T/stats.json" BOX_PICK_CNF="$T/cnf.yaml" \
    PROJ_PATH=/x/csi-spl-orc APP_PATH=/x "$@" bash -c '
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
[[ "$(cat "$T/calls")" == $'fleet-load get\nbox-stats list --since 15m' ]] &&
  pass "8. one fleet-load get, one box-stats list --since 15m" || fail "8. calls: $(cat "$T/calls")"
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

echo "spl-box-pick: $fails failure(s)"
[ "$fails" -eq 0 ]
