#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a process a pre-push part leaves behind never holds the hook past
#          the part's budget (SPL-3907). A test's `setsid` child kept the write
#          end of the part's tee pipe open, so `_pp_capture` waited on tee
#          forever: 2h10m and 65 min lost on sat (n=2, 2026-10-27).
#   1. a part that forks `setsid sleep 600` holding its stdout and is killed
#      by its 2 s budget: _pp_run returns within budget + grace (bounded by
#      `timeout` here, 40 s)
#   2. the part is reported TIMED OUT
#   3. the orphan is gone
#   4. one WARN line names the orphan's pid
#   5. its output up to the budget is still captured (the FAIL line below)
#   6. a part that leaves nothing behind logs no orphan line and passes
#   RED CONTROL: with the old `_pp_capture` (`wait $!` on tee, no reap) case 1
#   runs into the 40 s bound and 2-4 fail.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d) opid=""
# the orphan is killed by its own recorded pid, never by a pattern
cleanup() {
  [[ -n "$opid" ]] && kill "$opid" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

# One run of _pp_run on a stub part, in its own bash bounded by `timeout`, so a
# hang reads as rc 124 here instead of hanging this test.
run_part() {  # <part body>
  cat >"$T/run.sh" <<EOF
set -uo pipefail
do_log() { echo "\$*" >>"$T/log"; }
. "$FUNC"
_pp_timeout=2 PRE_PUSH_ORPHAN_GRACE=1
_pp_fake_part() { $1; }
_PP_NAMES=() _PP_STAT=() _PP_SECS=() _PP_FAILED=0 _PP_BASE_WT=""
_pp_run fake _pp_fake_part "$T/tree" nobase
EOF
  : >"$T/log"
  local t0=$SECONDS rc=0
  timeout 40 bash "$T/run.sh" >"$T/out" 2>&1 </dev/null || rc=$?
  echo "$rc $((SECONDS - t0))"
}
mkdir -p "$T/tree"

# the stub part: prints a line, leaves a `setsid` child holding its stdout, then
# outlives its budget
cat >"$T/orphan-part.sh" <<'EOF2'
echo "FAIL: started"
setsid bash -c 'echo $$ >"$1"; exec sleep 600' _ "$2/orphan.pid" &
sleep 30
EOF2
orphan_part="timeout -k 1 2 bash $T/orphan-part.sh x $T"
read -r rc secs < <(run_part "$orphan_part")
opid="$(cat "$T/orphan.pid" 2>/dev/null)"
[[ "$rc" -eq 0 && "$secs" -le 15 ]] && pass "1. the hook returns within budget + grace (${secs}s)" \
  || fail "1. the hook returns within budget + grace" "rc=$rc after ${secs}s (124 = hung on the orphan's pipe)"
grep -q 'TIMED OUT after 2s' "$T/log" && pass "2. the part is reported TIMED OUT" \
  || fail "2. the part is reported TIMED OUT" "$(cat "$T/log")"
if [[ -n "$opid" ]] && ! kill -0 "$opid" 2>/dev/null; then pass "3. the orphan $opid is gone"
else fail "3. the orphan is gone" "pid '${opid}' still runs"; fi
[[ -n "$opid" ]] && grep -q "orphan pid $opid .*held the part's output pipe" "$T/log" \
  && pass "4. one WARN line names the orphan pid" || fail "4. one WARN line names the orphan pid" "$(cat "$T/log")"
grep -q 'FAIL: started' "$T/out" && pass "5. the part's output is still captured" \
  || fail "5. the part's output is still captured" "$(cat "$T/out")"

read -r rc secs < <(run_part "echo clean")
[[ "$rc" -eq 0 ]] && ! grep -q 'orphan' "$T/log" && grep -q '^INFO pre-push: PASS fake' "$T/log" \
  && pass "6. a clean part passes and logs no orphan (${secs}s)" || fail "6. a clean part passes and logs no orphan" "rc=$rc $(cat "$T/log")"

echo ""
[[ "$fails" -eq 0 ]] && { echo "ALL PASSED"; exit 0; }
echo "$fails FAILED"; exit 1
