#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_inherit_priority (SPL-5147) against a stub desk: the
# spool command it builds, a dry run sends nothing, a bad topic id is refused
# before any desk call. RED CONTROL: without the uuid check the bad ids reach
# the desk.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

A=0f8fad5b-d9cb-469f-a165-70867728950e B=1f8fad5b-d9cb-469f-a165-70867728950e
STUBS='spl_desk_issue_run() {
  printf "%s|" "$@" >>"$DESK_LOG"; echo >>"$DESK_LOG"
  echo "{\"op\":\"$1\"}"
}
'
run() {
  : >"$T/desk.log"
  SNIPPET="${STUBS}do_spl_topic_inherit_priority" in_orc DESK_LOG="$T/desk.log" TENANT_ID=t-test DESK_AGENT=c-001 "$@" >"$T/o" 2>&1
  RC=$?
}

run PRIORITY_FROM="$A" PRIORITY_TO="$B" DRY_RUN=0
[[ $RC -eq 0 ]] && grep -qx "inherit-priority|--from|$A|--to|$B|" "$T/desk.log" &&
  pass "spool issue inherit-priority --from --to" || fail "send (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
run PRIORITY_FROM="$A" PRIORITY_TO="$B"
[[ $RC -eq 0 && ! -s "$T/desk.log" ]] && pass "the dry run (default) sends nothing" || fail "dry run (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
for bad in "PRIORITY_FROM=" "PRIORITY_FROM=not-a-topic" "PRIORITY_TO=$A;x" "PRIORITY_TO="; do
  run PRIORITY_FROM="$A" PRIORITY_TO="$B" DRY_RUN=0 "$bad"
  [[ $RC -eq 1 && ! -s "$T/desk.log" ]] && grep -q FATAL "$T/o" &&
    pass "$bad: refused before any desk call" || fail "$bad (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
done

echo "spl-topic-inherit-priority: $fails failure(s)"
[[ $fails -eq 0 ]]
