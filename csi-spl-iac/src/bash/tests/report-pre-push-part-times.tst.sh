#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_report_pre_push_part_times (SPL-5574) reads the gate's PART
#          lines and prints p50 / p95 / max of the last N PASSed runs per part
#          and tier, the window's TIMED OUT count and p95 x 1.5 rounded up to
#          10 s.
#   1. 20 iac fast PASS runs 1..20 s -> n 20, p50 10, p95 19, max 20, budget 30
#   2. PASS-cached, SKIP-untouched, FAIL and untiered lines are not runs
#   3. a TIMED OUT inside the window counts in t/o, one before it does not
#   4. PRE_PUSH_TIMES_N=5 keeps the newest 5 PASS runs (16..20)
#   5. two logs merge by timestamp; a full-tier row stands apart
#   6. an unreadable log or a bad N -> rc 2
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
# shellcheck source=../run/report-pre-push-part-times.func.sh
. "$PROJ_ROOT/src/bash/run/report-pre-push-part-times.func.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
check() { [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "want '$2', got '$3'"; }
row() { awk -v p="$1" -v t="$2" '$1 == p && $2 == t { $1 = $1; print }' <<<"$3"; }

L="$T/a.log"
{ echo "2026-11-01T00:00:00Z a PART iac FAIL 300s tree=/x HEAD=1 tier=fast TIMED OUT after 300s (x)"
  for i in $(seq 1 20); do
    printf '2026-11-01T01:%02d:00Z a PART iac PASS %ss tree=/x HEAD=1 tier=fast\n' "$i" "$i"
  done
  echo "2026-11-01T01:10:30Z a PART iac FAIL 900s tree=/x HEAD=1 tier=fast TIMED OUT after 900s (x)"
  echo "2026-11-01T02:00:00Z a PART iac PASS-cached 0s tree=/x HEAD=1 tier=fast"
  echo "2026-11-01T02:00:01Z a PART iac SKIP-untouched 0s tree=/x HEAD=1 tier=fast"
  echo "2026-11-01T02:00:02Z a PART iac FAIL 999s tree=/x HEAD=1 tier=fast rc=1"
  echo "2026-11-01T02:00:03Z a PART iac PASS 999s tree=/x HEAD=1"
} >"$L"
out="$(PRE_PUSH_TIMES_LOGS="$L" do_report_pre_push_part_times)"
check "1+2+3. iac fast, 20 runs" "iac fast 20 10 19 20 1 30" "$(row iac fast "$out")"
out="$(PRE_PUSH_TIMES_LOGS="$L" PRE_PUSH_TIMES_N=5 do_report_pre_push_part_times)"
check "4. N=5 -> runs 16..20" "iac fast 5 18 20 20 0 30" "$(row iac fast "$out")"

L2="$T/b.log"
printf '2026-11-01T00:30:00Z b PART iac PASS 100s tree=/y HEAD=2 tier=full\n2026-11-01T01:30:00Z b PART iac PASS 21s tree=/y HEAD=2 tier=fast\n' >"$L2"
out="$(PRE_PUSH_TIMES_LOGS="$L $L2" do_report_pre_push_part_times)"
check "5. merged fast row" "iac fast 21 11 20 21 1 30" "$(row iac fast "$out")"
check "5. full row apart" "iac full 1 100 100 100 0 150" "$(row iac full "$out")"

PRE_PUSH_TIMES_LOGS="$T/missing.log" do_report_pre_push_part_times >/dev/null 2>&1; check "6. unreadable log -> rc 2" 2 "$?"
PRE_PUSH_TIMES_LOGS="$L" PRE_PUSH_TIMES_N=0 do_report_pre_push_part_times >/dev/null 2>&1; check "6. N=0 -> rc 2" 2 "$?"

echo "--- $((n - fails))/$n passed"
(( fails == 0 ))
