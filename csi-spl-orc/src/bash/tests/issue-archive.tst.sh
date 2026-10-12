#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_archive pages a stub hub, archives exactly the done
# issues, skips an open issue and a done epic that still has an open child,
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
  {"key":"SPL-11","kind":"epic","status":"done"}
],"epics":[
  {"key":"SPL-10","kind":"epic","status":"done","total":1,"done":1,"counts":{"done":1}},
  {"key":"SPL-11","kind":"epic","status":"done","total":2,"done":1,"counts":{"done":1,"todo":1}}
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

echo "issue-archive: $fails failure(s)"
(( fails == 0 ))
