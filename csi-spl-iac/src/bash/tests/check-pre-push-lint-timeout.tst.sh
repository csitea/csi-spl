#!/usr/bin/env bash
# test-timeout: 90
#------------------------------------------------------------------------------
# Purpose: a lint part that hangs is cut by the same hard timeout as the
#          other parts (SPL-5529). timeout cannot run a shell function, so
#          the part runs in a forked process group and GNU timeout bounds
#          the wait. A scanner that sleeps past PRE_PUSH_PART_TIMEOUT
#          returns 124, the gate logs TIMED OUT, and that group (including
#          a child whose comm is go) is dead. rc 0 stays PASS. rc 127 stays
#          a missing-command FAIL, with no baseline re-check. A lint part
#          has no own budget variable: with PRE_PUSH_PART_TIMEOUT unset the
#          budget is the part default, 300.
#   RED CONTROL: on the tree before the wrapper, the hang leg is still
#   running past the budget, the log has no TIMED OUT line, and the go
#   child is alive. See the commit body.
#------------------------------------------------------------------------------
set -uo pipefail
# A gate that runs this file may export PRE_PUSH_TIER=full. Drop it so the
# sourced default stays 300 and only this file's legs set a budget.
for v in $(compgen -e); do [[ "$v" == PRE_PUSH_* ]] && unset "$v"; done
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$(cd "$TEST_DIR/../run" && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d)
D="$T/pids"
mkdir -p "$D"
export LINT_TO_DIR="$D" LINT_TO_MODE=hang
cleanup() {
  local f pid
  for f in part go; do
    [[ -f "$D/$f.pid" ]] || continue
    pid="$(cat "$D/$f.pid" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" ]] && continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf "$T"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

do_log() { echo "$*"; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/check-pre-push.func.sh
. "$RUN_DIR/check-pre-push.func.sh"

# The part calls this. A PATH stub that exits 127 is rewritten to 1 by the
# scanner's control check, so the missing-command leg returns 127 from here.
# The shellcheck binary must still be on PATH or the part is skipped as a missing tool.
do_sec_shellcheck() {
  case "${LINT_TO_MODE:-hang}" in
    pass) return 0 ;;
    missing) return 127 ;;
    hang)
      echo "$BASHPID" >"$LINT_TO_DIR/part.pid"
      # ubuntu 26.04's /usr/bin/sleep is the uutils multicall binary. A copy
      # named go exits at once, so the comm file stays empty (comm=missing on
      # the hosted runner). GNU sleep on this box keeps running under the new
      # name. A bash child sets its own comm and stays that process; bash
      # would otherwise exec a trailing sleep and the name would become sleep.
      bash -c 'printf %s go >/proc/self/comm; : >"$1"; while :; do sleep 1; done' \
        _ "$LINT_TO_DIR/go.ready" </dev/null >/dev/null 2>&1 &
      echo $! >"$LINT_TO_DIR/go.pid"
      _i=0
      while [[ "$_i" -lt 20 && ! -f "$LINT_TO_DIR/go.ready" ]]; do
        sleep 0.05
        _i=$((_i + 1))
      done
      tr -d '[:space:]' <"/proc/$!/comm" >"$LINT_TO_DIR/go.comm" 2>/dev/null || true
      sleep 45
      return 0
      ;;
  esac
  echo "unknown LINT_TO_MODE=${LINT_TO_MODE:-}" >&2
  return 1
}

STUB="$T/stub"
mkdir -p "$STUB"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$STUB/shellcheck"
chmod +x "$STUB/shellcheck"
BASE_PATH="$STUB:/usr/local/bin:/usr/bin:/bin"

# 0. a lint part has no own variable: unset -> 300, set -> that value.
unset PRE_PUSH_PART_TIMEOUT
got="$(_pp_budget _pp_part_lint_shellcheck)"
[[ "$got" == 300 ]] && pass "0. unset budget is the part default 300" \
  || fail "0. default budget" "got $got"
export PRE_PUSH_PART_TIMEOUT=2
got="$(_pp_budget _pp_part_lint_shellcheck)"
why="$(_pp_budget_why _pp_part_lint_shellcheck)"
[[ "$got" == 2 && "$why" == PRE_PUSH_PART_TIMEOUT ]] \
  && pass "0. PRE_PUSH_PART_TIMEOUT=2 is the lint budget and the note names it" \
  || fail "0. override budget" "got $got why=$why"
unset PRE_PUSH_PART_TIMEOUT

R="$T/repo"
SH="csi-spl-iac/src/bash/run"
mkdir -p "$R/$SH"
git -C "$R" init -q -b main
printf '%s\n' 'seed' >"$R/README"
git -C "$R" add -A
git -C "$R" commit -qm seed
git -C "$R" branch -f base
printf '%s\n' '#!/bin/bash' 'echo ok' >"$R/$SH/new.sh"
git -C "$R" add -A
git -C "$R" commit -qm add-sh

LOG="$T/pre-push.log"
lint() {
  : >"$LOG"
  local out rc=0
  out="$(PATH="$BASE_PATH" PRE_PUSH_EXTRA_PATH='' PRE_PUSH_ONLY=lint \
    PRE_PUSH_LINT_ONLY=lint-shellcheck PRE_PUSH_PART_TIMEOUT=2 \
    PRE_PUSH_TREE="$R" PRE_PUSH_BASE=base PRE_PUSH_LOG="$LOG" \
    PRE_PUSH_NO_CACHE=1 PRE_PUSH_CACHE="$T/cache" \
    PRE_PUSH_PIDFILE="$T/pre-push.pid" \
    do_check_pre_push 2>&1)" || rc=$?
  printf '%s\n' "$out" >"$T/out"
  echo "$rc"
}
verdict() { sed -nE "s/.* PART $1 ([A-Za-z-]+) .*/\\1/p" "$LOG" | tail -n 1; }
gone() {  # <pidfile>
  local pid
  [[ -f "$1" ]] || return 1
  pid="$(cat "$1")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

# 1. a hang past the budget is TIMED OUT, and the go child is dead.
rm -f "$D/part.pid" "$D/go.pid" "$D/go.comm"
LINT_TO_MODE=hang
echo "HANG_MARK dir=$D log=$LOG"
t0=$(date +%s)
rc="$(lint)"
el=$(( $(date +%s) - t0 ))
comm="$(tr -d '[:space:]' <"$D/go.comm" 2>/dev/null || true)"
if [[ "$rc" == 1 && "$(verdict lint-shellcheck)" == FAIL && "$el" -lt 12 && "$comm" == go ]] \
  && grep -q 'TIMED OUT after 2s (PRE_PUSH_PART_TIMEOUT)' "$T/out" \
  && grep -q 'timed out on your tree and passed on' "$T/out" \
  && gone "$D/part.pid" && gone "$D/go.pid"
then
  pass "1. a hung lint part TIMED OUT in ${el}s and its go child is dead"
else
  fail "1. hung lint part" "rc=$rc verdict=$(verdict lint-shellcheck) el=${el}s comm=${comm:-missing} part_gone=$(gone "$D/part.pid" && echo yes || echo no) go_gone=$(gone "$D/go.pid" && echo yes || echo no)"
fi

# 2. a clean scanner is a PASS and the gate does not say TIMED OUT.
LINT_TO_MODE=pass
rc="$(lint)"
if [[ "$rc" == 0 && "$(verdict lint-shellcheck)" == PASS ]] \
  && ! grep -q 'TIMED OUT' "$T/out"
then
  pass "2. a passing scanner stays PASS"
else
  fail "2. pass leg" "rc=$rc verdict=$(verdict lint-shellcheck)"
fi

# 3. rc 127 is a missing command, not a timeout and not a baseline re-check.
LINT_TO_MODE=missing
rc="$(lint)"
if [[ "$rc" == 1 && "$(verdict lint-shellcheck)" == FAIL ]] \
  && grep -q 'rc=127' "$T/out" \
  && ! grep -q 'TIMED OUT' "$T/out" \
  && ! grep -q 're-checking it on' "$T/out"
then
  pass "3. rc 127 stays a missing-command FAIL"
else
  fail "3. missing-command leg" "rc=$rc verdict=$(verdict lint-shellcheck)"
fi

echo "--- fails=$fails ---"
[[ "$fails" -eq 0 ]]
