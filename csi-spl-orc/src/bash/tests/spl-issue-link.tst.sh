#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_link (SPL-2284) against a stub desk (no network): the
# spool command it builds for link and unlink (a /t/<uuid> link passes as
# given), a dry run sends nothing, and a bad MODE, a bad uuid, a missing
# ISSUE_DISCUSSION or a bad key are refused before any desk call.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e
STUBS='spl_desk_issue_run() {
  printf "%s|" "$@" >>"$DESK_LOG"; echo >>"$DESK_LOG"
  echo "{\"op\":\"$1\",\"result\":{\"issue\":{\"key\":\"$3\"}}}"
}
'
run() {
  : >"$T/desk.log"
  SNIPPET="${STUBS}do_spl_issue_link" in_orc DESK_LOG="$T/desk.log" TENANT_ID=t-test DESK_AGENT=c-001 "$@" >"$T/o" 2>&1
  RC=$?
}

run ISSUE_REF=SPL-1 ISSUE_DISCUSSION="$TOPIC" DRY_RUN=0
[[ $RC -eq 0 ]] && grep -qx "link|--ref|SPL-1|--discussion|$TOPIC|" "$T/desk.log" && grep -q '"op":"link"' "$T/o" &&
  pass "link (the default MODE): spool issue link --ref --discussion, its JSON line printed" ||
  fail "link (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
run ISSUE_REF=SPL-1 ISSUE_DISCUSSION="/t/$TOPIC" MODE=unlink DRY_RUN=0
[[ $RC -eq 0 ]] && grep -qx "unlink|--ref|SPL-1|--discussion|/t/$TOPIC|" "$T/desk.log" &&
  pass "MODE=unlink: spool issue unlink, a /t/<uuid> link passed as given" ||
  fail "unlink (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
run ISSUE_REF=SPL-1 ISSUE_DISCUSSION="$TOPIC"
[[ $RC -eq 0 && ! -s "$T/desk.log" ]] && grep -q 'DRY_RUN would: spool issue link --as c-001 --ref SPL-1 --discussion' "$T/o" &&
  pass "the dry run (default) says what it would send and sends nothing" ||
  fail "dry run (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
for bad in "ISSUE_DISCUSSION=0f8fad5b-d9cb-469f-a165-7086772895" "ISSUE_DISCUSSION=not/a/topic" "ISSUE_DISCUSSION=$TOPIC;x" \
           "ISSUE_DISCUSSION=" "MODE=relink" "ISSUE_REF=SPL-1;x"; do
  run ISSUE_REF=SPL-1 ISSUE_DISCUSSION="$TOPIC" DRY_RUN=0 "$bad"
  [[ $RC -eq 1 && ! -s "$T/desk.log" ]] && grep -q FATAL "$T/o" &&
    pass "$bad: refused before any desk call" || fail "$bad (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
done

exit $fails
