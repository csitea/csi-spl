#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_orch_load_report (spec 101 T005) prints r1's E6..E8 columns
#          from a spool root over a SINCE..UNTIL window, read only.
#   1. E6 on the fixture root: total (one per msg_id, UNTIL exclusive, a
#      fractional ts kept), per-hour median/max with an empty hour as 0, the
#      sender kinds (lane, dispatcher at any @box or legacy CLE-, orch, other)
#      and the message kinds
#   2. E7 + E8 on the fixture asks: dispatcher share, dead rate, re-raise share
#      and the wait per raised_n bucket (3+ pools 3, 5)
#   3. CONTROL: the same asks with no dispatcher sender -> dispatcher=0 (0.0%)
#      and dead_dispatcher=0; the fixture itself fires (section 2)
#   4. an empty spool root: zeros, no error
#   5. refusals: bad SINCE, SINCE not before UNTIL, no orch dir, bad ORCH_ID
#   6. default window: UNTIL=now, SINCE = UNTIL - 24 h
#   7. read only: the root is byte-identical after the runs
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-orch-load-report.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: no jq"; exit 1; }

cp -r "$TEST_DIR/fixtures/orch-load/root" "$T/root"
W='SINCE=2026-10-04 UNTIL=2026-10-04T04:00Z'

report() {
  env -u SINCE -u UNTIL -u ORCH_ID SPOOL_ROOT="$T/root" PROJ_PATH="$PROJ_ROOT" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/require-bin.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-orch-load-report.func.sh"
    do_spl_orch_load_report' >"$T/out" 2>"$T/err" </dev/null
}
has() { grep -qxF "$1" "$T/out"; }
expect() { has "$2" && pass "$1" || fail "$1: want '$2', got: $(cat "$T/out" "$T/err")"; }

bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
before="$(cd "$T/root" && find . -type f -exec md5sum {} + | sort)"

# --- 1. E6 ----------------------------------------------------------------------
report $W; rc=$?
[[ $rc -eq 0 ]] && pass "1. rc 0" || fail "1. rc=$rc $(cat "$T/err")"
expect "1. window line" "ORCH_LOAD window=2026-10-04T00:00:00Z..2026-10-04T04:00:00Z orch=c-001 root=$T/root"
expect "1. E6 total: dup msg_id once, UNTIL exclusive, empty hour 0" \
  "E6 msgs total=7 hours=4 per_hour_median=2.0 per_hour_max=3"
expect "1. E6 sender kinds" \
  "E6 sender lane=3 (42.9%) dispatcher=2 (28.6%) orch=1 (14.3%) other=1 (14.3%)"
expect "1. E6 message kinds" "E6 kind blocker=1 msg=1 note=2 reject=1 result=1 task=1"

# --- 2. E7 + E8 -----------------------------------------------------------------
expect "2. E7 dispatcher share and dead rate" \
  "E7 asks total=9 dispatcher=5 (55.6%) dead=2 (22.2%) dead_dispatcher=1"
expect "2. E8 re-raise share" "E8 done=6 reraised=4 (66.7%)"
expect "2. E8 wait raised_n=0" "E8 wait raised_n=0 n=2 median_min=15.0 p90_min=20.0"
expect "2. E8 wait raised_n=1" "E8 wait raised_n=1 n=1 median_min=30.0 p90_min=30.0"
expect "2. E8 wait raised_n=2" "E8 wait raised_n=2 n=1 median_min=90.0 p90_min=90.0"
expect "2. E8 wait raised_n=3+ pools 3 and 5" "E8 wait raised_n=3+ n=2 median_min=82.5 p90_min=120.0"

# --- 3. CONTROL: no dispatcher asks -> 0% -----------------------------------------
cp -r "$T/root" "$T/nodisp"
for f in "$T/nodisp/asks/"*.json; do
  jq -c '.from = "c-310"' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
done
report $W SPOOL_ROOT="$T/nodisp"
expect "3. CONTROL no dispatcher asks -> 0%" \
  "E7 asks total=9 dispatcher=0 (0.0%) dead=2 (22.2%) dead_dispatcher=0"

# --- 4. empty root ----------------------------------------------------------------
mkdir -p "$T/empty/c-001"
report $W SPOOL_ROOT="$T/empty"; rc=$?
[[ $rc -eq 0 ]] && has "E6 msgs total=0 hours=4 per_hour_median=0.0 per_hour_max=0" \
  && has "E6 kind none" && has "E7 asks total=0 dispatcher=0 (0.0%) dead=0 (0.0%) dead_dispatcher=0" \
  && has "E8 wait raised_n=0 n=0 median_min=- p90_min=-" \
  && pass "4. empty root: zeros" || fail "4. empty root: rc=$rc $(cat "$T/out" "$T/err")"

# --- 5. refusals --------------------------------------------------------------------
refuse() {
  local label="$1"; shift
  report "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/out" ]] && grep -q FATAL "$T/err" && pass "5. $label refused" \
    || fail "5. $label: rc=$rc $(cat "$T/out" "$T/err")"
}
refuse "free-text SINCE" 'SINCE=yesterday; rm -rf /' UNTIL=2026-10-04
refuse "impossible date" SINCE=2026-13-40 UNTIL=2026-10-04
refuse "SINCE not before UNTIL" SINCE=2026-10-04 UNTIL=2026-10-04
refuse "no orch dir" $W ORCH_ID=c-009
refuse "ORCH_ID with a path" $W ORCH_ID=../asks

# --- 6. default window --------------------------------------------------------------
report
win="$(sed -n 's/^ORCH_LOAD window=\([^ ]*\) .*/\1/p' "$T/out")"
s="$(date -u -d "${win%..*}" +%s 2>/dev/null)"; u="$(date -u -d "${win#*..}" +%s 2>/dev/null)"
now="$(date -u +%s)"
[[ -n "$s" && -n "$u" ]] && (( u - s == 86400 && now - u < 60 )) && has "E6 msgs total=0 hours=24 per_hour_median=0.0 per_hour_max=0" \
  && pass "6. default window is the last 24 h" || fail "6. default window: $(cat "$T/out" "$T/err")"

# --- 7. read only ---------------------------------------------------------------------
after="$(cd "$T/root" && find . -type f -exec md5sum {} + | sort)"
[[ "$before" == "$after" ]] && pass "7. the spool root is unchanged" || fail "7. the report wrote the spool root"

echo
(( fails == 0 )) && echo "orch-load-report: all passed" || { echo "orch-load-report: $fails failed"; exit 1; }
