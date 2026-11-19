#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_set_priority (SPL-5978, rounds rulebook 5.5 F4) against
# a stub hub: a bad topic id or priority (0, 6, x) is refused before any hub
# call; the dry run (default) reads the linked issues and writes nothing; a
# good call sends priority 2 to each open issue that links the topic, and only
# to those, then reads them back; a topic no issue links is refused, nothing
# written. RED CONTROL: without the range check TOPIC_PRIORITY 0, 6 and x
# reach the hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

A=0f8fad5b-d9cb-469f-a165-70867728950e B=1f8fad5b-d9cb-469f-a165-70867728950e
# The hub's open issues, one per line: key, priority, linked topic.
STUBS='spl_issue_list_fetch() {
  echo "list" >>"$DESK_LOG"
  python3 -c "import json, sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
print(json.dumps({\"result\": {\"issues\": [{\"key\": k, \"priority\": int(p), \"discussions\": [{\"task_id\": t}]} for k, p, t in rows]}}))" "$ISSUES"
}
spl_desk_issue_run() {
  printf "%s|" "$@" >>"$DESK_LOG"; echo >>"$DESK_LOG"
  [[ "$1" == update ]] && sed -i "s/^$3 [0-9]/$3 $5/" "$ISSUES"
  echo "{\"op\":\"$1\"}"
}
'
run() {
  : >"$T/desk.log"
  printf '%s\n' "SPL-7 3 $A" "SPL-8 4 $A" "SPL-9 3 $B" >"$T/issues"
  SNIPPET="${STUBS}do_spl_topic_set_priority" in_orc DESK_LOG="$T/desk.log" ISSUES="$T/issues" \
    TENANT_ID=t-test DESK_AGENT=c-001 "$@" >"$T/o" 2>&1
  RC=$?
}
writes() { grep -c '^update|' "$T/desk.log"; }

run TOPIC_ID="$A" TOPIC_PRIORITY=2 DRY_RUN=0
[[ $RC -eq 0 ]] && grep -qx "update|--ref|SPL-7|--priority|2|" "$T/desk.log" &&
  grep -qx "update|--ref|SPL-8|--priority|2|" "$T/desk.log" && [[ "$(writes)" == 2 ]] &&
  grep -q "OK SPL-8 priority 4 -> 2" "$T/o" && grep -q "^SPL-9 3 " "$T/issues" &&
  pass "priority 2 to each issue linking the topic, read back, the other issue untouched" ||
  fail "send (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"

run TOPIC_ID="$A" TOPIC_PRIORITY=2
[[ $RC -eq 0 && "$(writes)" == 0 ]] && grep -q "would set SPL-7 priority 3 -> 2" "$T/o" &&
  pass "the dry run (default) lists what it would set and writes nothing" || fail "dry run (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"

run TOPIC_ID=2f8fad5b-d9cb-469f-a165-70867728950e TOPIC_PRIORITY=2 DRY_RUN=0
[[ $RC -eq 1 && "$(writes)" == 0 ]] && grep -q "FATAL no linked issue: set it in the WUI" "$T/o" &&
  pass "a topic no open issue links: refused, nothing written" || fail "no link (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"

for bad in "TOPIC_ID=" "TOPIC_ID=not-a-topic" "TOPIC_ID=$A;x" "TOPIC_PRIORITY=0" "TOPIC_PRIORITY=6" "TOPIC_PRIORITY=x" "TOPIC_PRIORITY="; do
  run TOPIC_ID="$A" TOPIC_PRIORITY=2 DRY_RUN=0 "$bad"
  [[ $RC -eq 1 && ! -s "$T/desk.log" ]] && grep -q FATAL "$T/o" &&
    pass "$bad: refused before any hub call" || fail "$bad (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
done

echo "spl-topic-set-priority: $fails failure(s)"
[[ $fails -eq 0 ]]
