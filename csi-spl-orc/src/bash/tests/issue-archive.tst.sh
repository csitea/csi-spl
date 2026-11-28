#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_archive pages a stub hub, archives exactly the issues
# in the closed status asked for (done or diss), refuses an open or unknown
# status, skips an open issue and a closed epic that still has an open child,
# writes nothing on the default dry run, and do_spl_issue_unarchive restores
# the journal.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
cat >"$T/page1.json" <<'JSON'
{"issues":[
  {"key":"SPL-1","kind":"issue","status":"done"},
  {"key":"SPL-2","kind":"issue","status":"todo"},
  {"key":"SPL-10","kind":"epic","status":"done"},
  {"key":"SPL-11","kind":"epic","status":"done"},
  {"key":"SPL-4","kind":"issue","status":"diss"},
  {"key":"SPL-12","kind":"epic","status":"diss"},
  {"key":"SPL-13","kind":"feature","status":"diss"}
],"epics":[
  {"key":"SPL-10","kind":"epic","status":"done","total":1,"done":1,"counts":{"done":1}},
  {"key":"SPL-11","kind":"epic","status":"done","total":2,"done":1,"counts":{"done":1,"todo":1}},
  {"key":"SPL-12","kind":"epic","status":"diss","total":2,"done":1,"canceled":1,"counts":{"done":1,"diss":1}},
  {"key":"SPL-13","kind":"feature","status":"diss","total":2,"done":0,"canceled":1,"counts":{"diss":1,"wip":1}}
],"next_cursor":"p2"}
JSON
cat >"$T/page2.json" <<'JSON'
{"issues":[{"key":"SPL-3","kind":"issue","status":"done"}],"epics":[],"next_cursor":""}
JSON
cat >"$T/fakeissue" <<'FAKE'
#!/bin/sh
{
  flock 9
  printf '%s|' "$@" >>"$FAKE_LOG"
  echo >>"$FAKE_LOG"
} 9>>"$FAKE_LOG.lock"
op=$2
cursor=""
ref=""
epic=""
prev=""
for a in "$@"; do
  if [ "$prev" = --cursor ]; then cursor=$a; fi
  if [ "$prev" = --ref ]; then ref=$a; fi
  if [ "$prev" = --epic ]; then epic=$a; fi
  prev=$a
done
if [ "$op" = list ]; then
  if [ -n "$epic" ]; then
    if [ "$epic" = SPL-11 ]; then
      echo '{"issues":[{"key":"SPL-2","kind":"issue","status":"todo"}],"next_cursor":""}'
    elif [ "$epic" = SPL-12 ]; then
      echo '{"issues":[{"key":"SPL-5","kind":"issue","status":"diss"},{"key":"SPL-6","kind":"issue","status":"done"}],"next_cursor":""}'
    elif [ "$epic" = SPL-13 ]; then
      echo '{"issues":[{"key":"SPL-7","kind":"issue","status":"diss"},{"key":"SPL-8","kind":"issue","status":"wip"}],"next_cursor":""}'
    elif [ "$epic" = SPL-20 ]; then
      echo '{"issues":[],"next_cursor":""}'
    else
      echo '{"issues":[{"key":"SPL-1","kind":"issue","status":"done"}],"next_cursor":""}'
    fi
    exit 0
  fi
  if [ -n "$cursor" ]; then cat "$PAGE2"; else cat "$PAGE1"; fi
  exit 0
fi
if [ "$op" = get ]; then
  if [ "$ref" = SPL-11 ]; then
    echo '{"issue":{"key":"SPL-11","kind":"epic","status":"done"}}'
  elif [ "$ref" = SPL-12 ] || [ "$ref" = SPL-13 ]; then
    echo '{"issue":{"key":"'"$ref"'","kind":"epic","status":"diss"}}'
  elif [ "$ref" = SPL-20 ]; then
    echo '{"issue":{"key":"SPL-20","kind":"feature","status":"done"}}'
  else
    echo '{"issue":{"key":"'"$ref"'","kind":"issue","status":"done"}}'
  fi
  exit 0
fi
echo '{"issue":{"key":"'"$ref"'"}}'
FAKE
chmod +x "$T/fakeissue"
: >"$T/issue.log"
ISS='spl_host_spool() { SPL_SPOOL="$FAKE"; }; '
base=(FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" PAGE1="$T/page1.json" PAGE2="$T/page2.json" TENANT_ID=t1 DESK_AGENT=CLE-00)

SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" >"$T/o" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'set ISSUE_REF or ISSUE_STATUS' "$T/o" && pass "archive refuses a call with no ref and no status" ||
  fail "missing selector (rc=$rc): $(cat "$T/o")"

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_STATUS=done ISSUE_ARCHIVE_JOBS=2 >"$T/o" 2>&1
rc=$?
[[ $rc -eq 0 ]] && grep -q 'count=3' "$T/o" && grep -q 'issue SPL-1' "$T/o" && grep -q 'issue SPL-3' "$T/o" &&
  grep -q 'epic SPL-10' "$T/o" && ! grep -q 'SPL-2' "$T/o" && ! grep -q 'SPL-11' "$T/o" &&
  ! grep -q '|archive|' "$T/issue.log" && [[ ! -e "$T/keys" ]] &&
  [[ "$(grep -c '|list|' "$T/issue.log")" -eq 2 ]] && grep -q '|--cursor|p2|' "$T/issue.log" &&
  pass "dry run pages the done list, prints 3 keys, archives nothing" ||
  fail "dry run (rc=$rc): $(cat "$T/o") / $(cat "$T/issue.log")"

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_STATUS=done ISSUE_ARCHIVE_JOBS=2 \
  ISSUE_JOURNAL="$T/keys" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
got=$(grep '|archive|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|.*/\1/p' | sort | tr '\n' ' ')
[[ $rc -eq 0 && "$got" == "SPL-1 SPL-10 SPL-3 " ]] && [[ "$(sort "$T/keys" | tr '\n' ' ')" == "SPL-1 SPL-10 SPL-3 " ]] &&
  grep -q "JOURNAL $T/keys" "$T/o" && ! grep -q '|--ref|SPL-2|' "$T/issue.log" && ! grep -q '|--ref|SPL-11|' "$T/issue.log" &&
  pass "bulk archives the done issue and the safe epic, skips the open issue and the open-child epic" ||
  fail "bulk (rc=$rc) archived '$got' journal '$(cat "$T/keys" 2>/dev/null)': $(cat "$T/o") / $(cat "$T/issue.log")"

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_unarchive" in_orc "${base[@]}" ISSUE_KEYS_FILE="$T/keys" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
ugot=$(grep '|unarchive|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|.*/\1/p' | sort | tr '\n' ' ')
[[ $rc -eq 0 && "$ugot" == "SPL-1 SPL-10 SPL-3 " ]] && pass "unarchive restores the journal" ||
  fail "unarchive (rc=$rc) '$ugot': $(cat "$T/o") / $(cat "$T/issue.log")"

calls=$(grep -c '|unarchive|' "$T/issue.log")
SNIPPET="${ISS}do_spl_issue_unarchive" in_orc "${base[@]}" ISSUE_KEYS_FILE="$T/keys" >"$T/o" 2>&1
rc=$?
[[ $rc -eq 0 ]] && grep -q 'count=3' "$T/o" && [[ "$(grep -c '|unarchive|' "$T/issue.log")" -eq "$calls" ]] &&
  pass "unarchive dry run restores nothing" || fail "unarchive dry run (rc=$rc): $(cat "$T/o")"

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_REF=SPL-11 ISSUE_JOURNAL="$T/epic.keys" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ! grep -q '|archive|' "$T/issue.log" && [[ ! -s "$T/epic.keys" ]] &&
  pass "a named done epic with an open child is skipped" ||
  fail "named epic (rc=$rc): $(cat "$T/o") / $(cat "$T/issue.log")"

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_STATUS=diss >"$T/o" 2>&1
rc=$?
plan=$(grep -E '^(issue|epic) ' "$T/o" | sort | tr '\n' ' ')
[[ $rc -eq 0 ]] && grep -q 'count=2' "$T/o" && [[ "$plan" == "epic SPL-12 issue SPL-4 " ]] &&
  grep -q '|--status|diss|' "$T/issue.log" && ! grep -q '|archive|' "$T/issue.log" &&
  pass "diss plans its diss issue and the diss epic whose children are diss and done, not the one with a wip child" ||
  fail "diss dry run (rc=$rc) plan '$plan': $(cat "$T/o") / $(cat "$T/issue.log")"

: >"$T/issue.log"
rm -f "$T/diss.keys"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_STATUS=diss ISSUE_ARCHIVE_JOBS=2 \
  ISSUE_JOURNAL="$T/diss.keys" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
got=$(grep '|archive|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|.*/\1/p' | sort | tr '\n' ' ')
[[ $rc -eq 0 && "$got" == "SPL-12 SPL-4 " ]] && [[ "$(sort "$T/diss.keys" | tr '\n' ' ')" == "SPL-12 SPL-4 " ]] &&
  pass "diss archives only its diss rows" ||
  fail "diss bulk (rc=$rc) archived '$got': $(cat "$T/o") / $(cat "$T/issue.log")"

for st in todo wip qas bogus; do
  : >"$T/issue.log"
  SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_STATUS="$st" ISSUE_JOURNAL="$T/open.keys" DRY_RUN=0 >"$T/o" 2>&1
  rc=$?
  # An unknown status is refused earlier, by spl_issue_check_fields, naming every status.
  [[ $rc -ne 0 ]] && grep -q "FATAL ISSUE_STATUS must be .*got: '$st'" "$T/o" &&
    { [[ $st == bogus ]] || grep -q 'must be a closed status (done, diss)' "$T/o"; } &&
    ! grep -qE '^(issue|epic) ' "$T/o" && [[ ! -s "$T/issue.log" ]] && [[ ! -e "$T/open.keys" ]] &&
    pass "status $st is refused, names the allowed values, archives nothing" ||
    fail "status $st (rc=$rc): $(cat "$T/o") / $(cat "$T/issue.log")"
done

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_REF=SPL-12 ISSUE_JOURNAL="$T/e12.keys" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
got=$(grep '|archive|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|.*/\1/p' | sort | tr '\n' ' ')
[[ $rc -eq 0 && "$got" == "SPL-12 SPL-5 SPL-6 " ]] &&
  pass "a named epic with a diss child and a done child archives with them" ||
  fail "named SPL-12 (rc=$rc) archived '$got': $(cat "$T/o") / $(cat "$T/issue.log")"

: >"$T/issue.log"
SNIPPET="${ISS}do_spl_issue_archive" in_orc "${base[@]}" ISSUE_REF=SPL-13 ISSUE_JOURNAL="$T/e13.keys" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ! grep -q '|archive|' "$T/issue.log" && [[ ! -s "$T/e13.keys" ]] &&
  pass "a named epic with an open (wip) child is skipped" ||
  fail "named SPL-13 (rc=$rc): $(cat "$T/o") / $(cat "$T/issue.log")"

# ./run redirects this shell's stdout and stderr to tee process substitutions
# (run.sh main). A bare wait in the pool blocks on those until they exit,
# which they do not. The long sleep stands in for that tee.
run_under_procsub() {
  local s0=$SECONDS
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "${base[@]}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    exec > >(cat) 2> >(sleep 60)
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' >"$T/proc.out" 2>&1
  PROCSUB_RC=$?
  PROCSUB_DT=$((SECONDS - s0))
}

: >"$T/issue.log"
rm -f "$T/keys"
SNIPPET="${ISS}do_spl_issue_archive" \
  run_under_procsub ISSUE_STATUS=done ISSUE_ARCHIVE_JOBS=2 ISSUE_JOURNAL="$T/keys" DRY_RUN=0
got=$(grep '|archive|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|.*/\1/p' | sort | tr '\n' ' ')
[[ $PROCSUB_RC -eq 0 && $PROCSUB_DT -lt 15 && "$got" == "SPL-1 SPL-10 SPL-3 " ]] &&
  pass "bulk archive under a live process substitution finishes (${PROCSUB_DT}s)" ||
  fail "procsub bulk rc=$PROCSUB_RC ${PROCSUB_DT}s archived '$got': $(cat "$T/proc.out") / $(cat "$T/issue.log")"

: >"$T/issue.log"
rm -f "$T/feat.keys"
SNIPPET="${ISS}do_spl_issue_archive" \
  run_under_procsub ISSUE_REF=SPL-20 ISSUE_ARCHIVE_JOBS=1 ISSUE_JOURNAL="$T/feat.keys" DRY_RUN=0
[[ $PROCSUB_RC -eq 0 && $PROCSUB_DT -lt 15 && "$(cat "$T/feat.keys" 2>/dev/null)" == "SPL-20" ]] &&
  grep -q '|--ref|SPL-20|' "$T/issue.log" &&
  pass "a done feature with no children archives under a live process substitution (${PROCSUB_DT}s)" ||
  fail "feature procsub rc=$PROCSUB_RC ${PROCSUB_DT}s journal='$(cat "$T/feat.keys" 2>/dev/null)' log=$(cat "$T/issue.log") out=$(cat "$T/proc.out")"

echo "issue-archive: $fails failure(s)"
(( fails == 0 ))
