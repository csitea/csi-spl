#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_status (SPL-1813), the hub read the /exit-clean issue
# gate makes when a lane landed nothing, against a stub desk (no network): one
# `issue-status<TAB>key<TAB>status` line from either answer shape; a failed
# read, an answer with no status and a bad key exit 1 and print no such line.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

STUBS='spl_lane_issue_desk() { echo "desk $*" >>"$DESK_LOG"; }
spl_desk_issue_run() {
  echo "$*" >>"$DESK_LOG"
  case "$ANSWER" in
    down) echo "FATAL spool issue get: hub unreachable"; return 1 ;;
    nested) printf "{\"result\":{\"issue\":{\"key\":\"%s\",\"status\":\"done\"}}}\n" "$3" ;;
    flat) printf "{\"result\":{\"key\":\"%s\",\"status\":\"wip\"}}\n" "$3" ;;
    *) echo "{\"result\":{\"issue\":{}}}" ;;
  esac
}
'
run() {
  : >"$T/desk.log"
  SNIPPET="${STUBS}do_spl_issue_status" in_orc DESK_LOG="$T/desk.log" SPOOL_ROOT="$T/spool" "$@" >"$T/o" 2>&1
  RC=$?
}

run ISSUE_REF=SPL-12 ANSWER=nested
[[ $RC -eq 0 ]] && grep -qxP 'issue-status\tSPL-12\tdone' "$T/o" && grep -qx 'get --ref SPL-12' "$T/desk.log" &&
  grep -qx "desk $T/spool 0" "$T/desk.log" &&
  pass "the hub's issue.status, one line; read as the lease's desk of SPOOL_ROOT" || fail "nested (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
run ISSUE_REF=SPL-12 ANSWER=flat
[[ $RC -eq 0 ]] && grep -qxP 'issue-status\tSPL-12\twip' "$T/o" &&
  pass "a flat answer's status" || fail "flat (rc=$RC): $(cat "$T/o")"
run ISSUE_REF=SPL-12 ANSWER=down
[[ $RC -eq 1 ]] && ! grep -q '^issue-status' "$T/o" &&
  pass "the hub unreachable: exit 1, no status line" || fail "down (rc=$RC): $(cat "$T/o")"
run ISSUE_REF=SPL-12 ANSWER=empty
[[ $RC -eq 1 ]] && ! grep -q '^issue-status' "$T/o" && grep -q 'no status for SPL-12' "$T/o" &&
  pass "an answer with no status: exit 1, no status line" || fail "empty (rc=$RC): $(cat "$T/o")"
run ISSUE_REF='SPL-12; x' ANSWER=nested
[[ $RC -eq 1 && ! -s "$T/desk.log" ]] &&
  pass "a bad key: refused before any desk call" || fail "bad key (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"

exit $fails
