#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_pick (owner HUM-10, t1 c13e8023) prints the box a new
#          lane starts on: the first box in the fill order below its HIGH
#          mark (load5 / cpus); every box at or above HIGH -> hold. The band
#          and the order come from the hub (`spool fleet-load get`, rdb 0118);
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

# target LOW HIGH ORDER_JSON
target() { printf '{"low":%s,"high":%s,"box_order":%s,"source":"hub"}\n' "$1" "$2" "$3" >"$T/target.json"; }
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

# 1. band edges on box-a (8 cores): 49% and 50% pick it, 75% and 76% pass it on.
target 50 75 '["box-a","box-b"]'
for c in 3.92:box-a 4:box-a 6:box-b 6.08:box-b; do
  stats "box-a:${c%%:*}:8" "box-b:1:8"
  out="$(run)"; got="$(pick "$out")"
  [[ "$got" == "${c#*:}" ]] && pass "1. box-a load5 ${c%%:*} / 8 cores -> pick=$got" || fail "1. edge ${c%%:*}: $out"
done
grep -q '^BOX box-a  load5 6.08  cpus 8  76%  full$' <<<"$out" && pass "1. the per-box line says 76% full" || fail "1. line: $out"

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

# 3. every box at or above HIGH -> hold.
stats "box-a:6:8" "box-b:16:16"
out="$(run)"; rc=$?
[[ $rc -eq 0 && "$(pick "$out")" == hold ]] && pass "3. every box at or above HIGH -> pick=hold, exit 0" || fail "3. hold (rc=$rc): $out"

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
[[ "$(pick "$out")" == box-b ]] && grep -q '20..40 % of cores (source hub), order box-a box-b (cnf seed)' <<<"$out" &&
  pass "5. hub band 20..40: box-a 43% is full, box-b 37% takes it; empty hub order = cnf seed" || fail "5. band: $out"

# 6. hub unreachable for the target: defaults 50 / 75 + cnf seed, with a WARN.
stats "box-a:5:8" "box-b:1:8"
out="$(run TARGET_DOWN=1 2>&1)"
[[ "$(pick "$out")" == box-a ]] && grep -q '^WARN the hub did not answer the fleet load target' <<<"$out" &&
  grep -q '50..75 % of cores (source built-in default), order box-a box-b (cnf seed)' <<<"$out" &&
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

echo "spl-box-pick: $fails failure(s)"
[ "$fails" -eq 0 ]
