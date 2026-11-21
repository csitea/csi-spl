#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a gate run stopped by a signal, or one whose orc part goes red, ends
#          with a verdict on stdout AND in pre-push.log (SPL-6213). Two
#          PRE_PUSH_TIER=full runs on sat (n=2, 2026-11-21) ended right after
#          the orc suite's `--- sum over 701 files` line with no PART line, no
#          later part and no summary: the author's pane rotation signalled the
#          gate, bash ran the INT/TERM/HUP trap once the orc suite returned, and
#          the trap cleaned up and exited without a word.
#   A fixture repo, a stub orc runner that waits for a go file, and the real
#   do_check_pre_push with two planned parts, orc then a stub api.
#     1. TERM while the orc part runs -> rc 143; stdout `PART orc INTERRUPTED
#        (signal TERM)`; log PART orc INTERRUPTED, PART api SKIP-interrupted,
#        PART tree INTERRUPTED part=orc; the FATAL line; the api part never
#        runs; the pidfile is gone
#     2. HUP the same -> rc 129, the same lines with HUP
#     3. no signal, orc red on the tree and green on the base -> PART orc FAIL,
#        the api part still runs (PASS), the summary, one FATAL verdict, rc 1,
#        no INTERRUPTED line
#   Red control: PP_FUNC_FROM=<check-pre-push.func.sh before SPL-6213> runs the
#   cases on that file: 1 and 2 FAIL (no line after the suite's own), 3 PASSes.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
has() { grep -qE -- "$2" "$3" && pass "$1" || fail "$1" "no /$2/ in $(basename "$3"): $(cat "$3")"; }
hasnt() { grep -qE -- "$2" "$3" && fail "$1" "/$2/ in $(basename "$3")" || pass "$1"; }

T=$(mktemp -d); gp=""
cleanup() { [[ -n "$gp" ]] && kill -KILL "$gp" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
# the red control: the old gate file, with the run dir it sources around it
if [[ -n "${PP_FUNC_FROM:-}" ]]; then
  cp -r "$PROJ_ROOT/src/bash/run" "$T/run"; cp "$PP_FUNC_FROM" "$T/run/check-pre-push.func.sh"
  FUNC="$T/run/check-pre-push.func.sh"
fi

# The fixture: the base commit has a stub orc runner that passes; HEAD adds
# `red`, which makes it fail b.tst.sh. The runner waits for $STUB_GO.
R="$T/repo"; mkdir -p "$R/csi-spl-orc/src/bash/tests" "$R/csi-spl-iac/src/bash/tests"
cat >"$R/csi-spl-orc/src/bash/tests/run-all-tests.sh" <<'E2'
echo "orc stub: start"; : >"$STUB_STARTED"
i=0; while [[ ! -e "$STUB_GO" && $i -lt 300 ]]; do sleep 0.1; i=$((i + 1)); done
[[ -e red ]] || { echo "=== 2/2 test files passed"; exit 0; }
echo "FAILED: b.tst.sh"; echo "=== 1/2 test files passed"; echo "--- sum over 2 files: wall 3 s"; exit 1
E2
echo 'echo cleancode-ok' >"$R/csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh"
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
g init -q; g add -A; g commit -qm base; : >"$R/red"; g add red; g commit -qm red

cat >"$T/run.sh" <<E3
set -uo pipefail
do_log() { echo "\$*"; }
. "$FUNC"
_pp_plan_parts() { all="orc api"; parts="orc api"; changed=""; lint=""; }
_pp_part_api() { echo "api stub ran"; }
_pp_missing_tools() { :; }  # the stub parts need no go or pnpm: the gate's own run of this file has none on PATH
_pp_budgets_load() { :; }; _pp_b_default=60
export PRE_PUSH_TREE="$R" PRE_PUSH_TIER=full PRE_PUSH_MODE=full PRE_PUSH_LINT=0 PRE_PUSH_BASE=HEAD~1
export PRE_PUSH_LOG="$T/pre-push.log" PRE_PUSH_CACHE="$T/green" PRE_PUSH_PIDFILE="$T/pid"
do_check_pre_push
E3
export STUB_STARTED="$T/started" STUB_GO="$T/go"

# One gate run; <sig> is sent once the orc stub has started ("none": not sent).
gate() {  # <sig> -> sets rc; $T/out, $T/pre-push.log
  local i=0
  rm -f "$T/started" "$T/go" "$T/pre-push.log" "$T/green"
  bash "$T/run.sh" >"$T/out" 2>&1 </dev/null &
  gp=$!
  while [[ ! -e "$T/started" && $i -lt 300 ]]; do sleep 0.1; i=$((i + 1)); done
  # kill returns with the signal pending at the gate; bash runs its trap once
  # the orc suite (waiting on the go file) returns
  [[ "$1" != none ]] && kill -s "$1" "$gp"
  : >"$T/go"
  rc=0; wait "$gp" || rc=$?; gp=""
  touch "$T/pre-push.log"
}

for sig in TERM HUP; do
  n=1; want=143; [[ "$sig" == HUP ]] && { n=2; want=129; }
  gate "$sig"
  [[ "$rc" -eq "$want" ]] && pass "$n. $sig: rc $want" || fail "$n. $sig: rc $want" "rc=$rc"
  has "$n. $sig: stdout PART orc INTERRUPTED" "^PART orc INTERRUPTED \(signal $sig\)$" "$T/out"
  has "$n. $sig: log PART orc INTERRUPTED" " PART orc INTERRUPTED [0-9]+s .* signal=$sig$" "$T/pre-push.log"
  has "$n. $sig: log PART api SKIP-interrupted" " PART api SKIP-interrupted 0s .* signal=$sig$" "$T/pre-push.log"
  has "$n. $sig: log overall tree INTERRUPTED" " PART tree INTERRUPTED [0-9]+s .* signal=$sig part=orc$" "$T/pre-push.log"
  has "$n. $sig: one FATAL INTERRUPTED verdict" "^FATAL pre-push: INTERRUPTED \(signal $sig\) in part orc" "$T/out"
  hasnt "$n. $sig: the api part never runs" "api stub ran" "$T/out"
  [[ ! -e "$T/pid" ]] && pass "$n. $sig: the pidfile is dropped" || fail "$n. $sig: the pidfile is dropped" "$(cat "$T/pid")"
done

gate none
[[ "$rc" -eq 1 ]] && pass "3. orc red, no signal: rc 1" || fail "3. orc red, no signal: rc 1" "rc=$rc"
has "3. log PART orc FAIL (new on the tree)" " PART orc FAIL [0-9]+s .*trunk=[0-9a-f]+-green" "$T/pre-push.log"
has "3. the api part still runs" "^api stub ran$" "$T/out"
has "3. log PART api PASS" " PART api PASS " "$T/pre-push.log"
has "3. the summary is printed" "pre-push summary \(mode=full tier=full\)" "$T/out"
has "3. one overall FATAL verdict" "^FATAL pre-push: 1 part\(s\) FAILED" "$T/out"
hasnt "3. no INTERRUPTED line" "INTERRUPTED" "$T/pre-push.log"

echo ""
[[ "$fails" -eq 0 ]] && { echo "ALL PASSED"; exit 0; }
echo "$fails FAILED"; exit 1
