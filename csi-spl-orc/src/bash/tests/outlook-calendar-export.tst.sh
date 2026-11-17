#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 180 FR-1 / FR-8 smoke test of
# csi-spl-orc/src/powershell/outlook-calendar-export.ps1 (no Outlook needed):
#   1. static: the export format string; read-only COM (no Save, Delete,
#      Send); no body and no attendees read; every formatted ToString passes
#      InvariantCulture, the Restrict filter's 'g' alone excepted
#   2. the script's -SelfTest (synthetic items under fi-FI with Windows' '.'
#      time separator: RFC 3339 times, all-day days, a cancelled meeting out),
#      run by pwsh when it is on PATH, else in the local
#      mcr.microsoft.com/powershell image (--pull never, no network). With
#      neither, part 2 does not run and the test says so in a NOTE line.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PS1="$PROJ_ROOT/src/powershell/outlook-calendar-export.ps1"
IMG=mcr.microsoft.com/powershell:lts-alpine-3.20

# --- 1. static ----------------------------------------------------------------
[[ -f "$PS1" ]] && pass "1. the script is in git" || fail "1. no $PS1"
grep -qF "'spool-hub-outlook-export/1'" "$PS1" && pass "1. it writes format spool-hub-outlook-export/1" || fail "1. no format string"
if grep -nE '\.(Save|Delete|Send|Move|Copy)\(|\.(Body|HTMLBody|RTFBody|Recipients|RequiredAttendees|OptionalAttendees|Organizer)\b' "$PS1"; then
  fail "1. the script writes to Outlook or reads a body or attendees (above)"
else
  pass "1. read-only, no body, no attendees"
fi
bad="$(grep -n '\.ToString(' "$PS1" | grep -v '\$Inv)' | grep -vF ".ToString('g')" || true)"
[[ -z "$bad" ]] && pass "1. every formatted ToString passes InvariantCulture" || fail "1. a ToString without InvariantCulture: $bad"

# --- 2. the self-test -----------------------------------------------------------
selftest() {
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$PS1" -SelfTest
  elif command -v docker >/dev/null 2>&1 && docker image inspect "$IMG" >/dev/null 2>&1; then
    docker run --rm --pull never --network none -v "$(dirname "$PS1")":/s:ro "$IMG" pwsh -NoProfile -File /s/outlook-calendar-export.ps1 -SelfTest
  else
    return 99
  fi
}
out="$(selftest 2>&1)"; rc=$?
if (( rc == 99 )); then
  echo "NOTE: part 2 (-SelfTest) did not run: no pwsh on PATH and no local $IMG image"
elif (( rc == 0 )) && ! grep -q '^FAIL' <<<"$out" && [[ "$(grep -c '^PASS' <<<"$out")" -ge 7 ]]; then
  pass "2. -SelfTest: $(grep -c '^PASS' <<<"$out") checks pass under fi-FI with a '.' time separator"
else
  fail "2. -SelfTest rc=$rc: $out"
fi

(( fails == 0 )) && echo "ALL PASS: outlook-calendar-export" || { echo "FAILED: $fails"; exit 1; }
