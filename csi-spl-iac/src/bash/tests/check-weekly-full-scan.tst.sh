#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the weekly full scan (owner 2026-10-01: Friday 17:00) and its cron.
#   1. install, DRY_RUN=1: prints the crontab diff, leaves the crontab alone
#   2. install, DRY_RUN=0: ONE tagged line, Friday 17:00, from the desk-cron
#      checkout with DRY_RUN=0; every other line untouched
#   3. a line whose tag only STARTS like ours (…weekly-full-scan-prd) survives
#      install and remove: the tag is matched exactly at the end of the line
#   4. install again: nothing to change (idempotent)
#   5. an agent worktree as the cron source is refused
#   6. remove: the tagged line goes, the others stay
#   7. do_check_weekly_full_scan DRY_RUN=1 lists csi-spl + csi-web rows, scans nothing
#   8. DRY_RUN=0 (a csi-web row on a fixture repo, stub scanner): report, tsv
#      and summary; a second week shows the change vs last week
#   9. last Friday's report missing (box down) -> a one-line missed-week
#      alert; none when it exists, none on the very first run
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$(cd "$TEST_DIR/../run" && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
do_log() { echo "$*"; }
APP_PATH="$(cd "$TEST_DIR/../../.." && pwd)"
# shellcheck source=../run/install-weekly-full-scan-cron.func.sh
. "$RUN_DIR/install-weekly-full-scan-cron.func.sh"
# shellcheck source=../run/check-weekly-full-scan.func.sh
. "$RUN_DIR/check-weekly-full-scan.func.sh"

CT="$T/crontab"
cat >"$CT" <<'CRON'
*/3 * * * * echo desk # csi-spl:desk-reconcile
0 3 * * * echo other-prd # csi-spl:weekly-full-scan-prd
0 8 * * * echo unrelated
CRON
cp "$CT" "$T/orig"
SRC="$T/fake-desk-cron"
inst() { WEEKLY_SCAN_CRONTAB="$CT" WEEKLY_SCAN_CRON_SRC="$SRC" WEEKLY_SCAN_LOG_DIR="$T/log" do_install_weekly_full_scan_cron 2>&1; }

out="$(DRY_RUN=1 inst)"
cmp -s "$CT" "$T/orig" && grep -q '^+0 17 \* \* 5 ' <<<"$out" \
  && pass "1. DRY_RUN=1 prints the crontab diff and changes nothing" || fail "1. dry run" "$out"

DRY_RUN=0 inst >/dev/null
n="$(grep -c ' # csi-spl:weekly-full-scan$' "$CT")"
line="$(grep ' # csi-spl:weekly-full-scan$' "$CT")"
{ [[ "$n" == 1 ]] && [[ "$line" == "0 17 * * 5 "* ]] && [[ "$line" == *"cd $SRC && git fetch -q origin master && git checkout -q --detach origin/master;"* ]] \
  && [[ "$line" == *"DRY_RUN=0 $SRC/csi-spl-iac/src/bash/scripts/weekly-full-scan-cron.sh"* ]]; } \
  && pass "2. one tagged line: Friday 17:00, self-updating desk-cron checkout, DRY_RUN=0" || fail "2. install" "n=$n line=$line"
grep -qx '\*/3 \* \* \* \* echo desk # csi-spl:desk-reconcile' "$CT" && grep -qx '0 8 \* \* \* echo unrelated' "$CT" \
  && pass "2. ... every other line is untouched" || fail "2. others" "$(cat "$CT")"
grep -q 'weekly-full-scan-prd$' "$CT" && pass "3. a line tagged ...weekly-full-scan-prd survives install (exact match)" || fail "3. exact tag" "$(cat "$CT")"

out="$(DRY_RUN=0 inst)"; grep -q 'nothing to change' <<<"$out" && pass "4. install again: nothing to change" || fail "4. idempotent" "$out"

out="$(WEEKLY_SCAN_CRONTAB="$CT" WEEKLY_SCAN_CRON_SRC="/x/csi-spl-wt/CLE-1" DRY_RUN=0 do_install_weekly_full_scan_cron 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'agent worktree' <<<"$out" && pass "5. an agent worktree as the cron source is refused" || fail "5. wt refused" "rc=$rc"

WEEKLY_SCAN_CRON_ACTION=remove DRY_RUN=0 inst >/dev/null
! grep -q ' # csi-spl:weekly-full-scan$' "$CT" && cmp -s "$CT" "$T/orig" \
  && pass "6. remove: the tagged line goes, every other line (incl. -prd) stays" || fail "6. remove" "$(cat "$CT")"

out="$(DRY_RUN=1 WEEKLY_SCAN_DIR="$T/scan" do_check_weekly_full_scan 2>&1)"
{ grep -q 'spl-shellcheck' <<<"$out" && grep -q 'spl-gosec' <<<"$out" && grep -q 'spl-govulncheck' <<<"$out" \
  && grep -q 'web-shellcheck' <<<"$out" && [[ ! -e "$T/scan" ]]; } \
  && pass "7. DRY_RUN=1 lists the csi-spl and csi-web rows and scans nothing" || fail "7. plan" "$out"

# 8. a csi-web row on a fixture repo with a stub scanner
WEB="$T/csi-web"; mkdir -p "$WEB"; git -C "$WEB" init -q; echo x >"$WEB/a.md"; git -C "$WEB" add -A; git -C "$WEB" commit -qm s
mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "a.md:1:1: x\\na.md:2:1: y\\n"\nexit 2\n' >"$T/bin/typos"; chmod +x "$T/bin/typos"
PATH="$T/bin:$PATH" DRY_RUN=0 WEEKLY_SCAN_ROWS=web-typos WEEKLY_SCAN_WEB="$WEB" WEEKLY_SCAN_DIR="$T/scan" WEEKLY_SCAN_DATE=2026-10-02 \
  do_check_weekly_full_scan >/dev/null 2>&1
{ [[ -f "$T/scan/2026-10-02.md" ]] && grep -q '| csi-web | web-typos | FINDINGS | 2 | - |' "$T/scan/2026-10-02.md" \
  && grep -q '0/1 scanners clean' "$T/scan/2026-10-02.summary.txt"; } \
  && pass "8a. DRY_RUN=0 writes the report (one row per scanner) and the summary" || fail "8a. report" "$(cat "$T/scan/2026-10-02.md" 2>&1)"
printf '#!/bin/sh\nprintf "a.md:1:1: x\\na.md:2:1: y\\na.md:3:1: z\\n"\nexit 2\n' >"$T/bin/typos"
PATH="$T/bin:$PATH" DRY_RUN=0 WEEKLY_SCAN_ROWS=web-typos WEEKLY_SCAN_WEB="$WEB" WEEKLY_SCAN_DIR="$T/scan" WEEKLY_SCAN_DATE=2026-10-09 \
  do_check_weekly_full_scan >/dev/null 2>&1
grep -q '| csi-web | web-typos | FINDINGS | 3 | +1 |' "$T/scan/2026-10-09.md" \
  && pass "8b. the next week shows the change vs last week (+1)" || fail "8b. delta" "$(cat "$T/scan/2026-10-09.md" 2>&1)"

# 9. a skipped Friday: an earlier report exists, last week's is missing
S9="$T/scan9"; mkdir -p "$S9"; echo old >"$S9/2026-09-18.md"
PATH="$T/bin:$PATH" DRY_RUN=0 WEEKLY_SCAN_ROWS=web-typos WEEKLY_SCAN_WEB="$WEB" WEEKLY_SCAN_DIR="$S9" WEEKLY_SCAN_DATE=2026-10-02 \
  do_check_weekly_full_scan >/dev/null 2>&1
grep -q 'did NOT run on 2026-09-25' "$S9/2026-10-02.missed.txt" 2>/dev/null \
  && pass "9a. last Friday's report missing -> a one-line missed-week alert" || fail "9a. missed" "$(ls "$S9")"
[[ ! -e "$T/scan/2026-10-09.missed.txt" ]] \
  && pass "9b. last week's report present -> no alert" || fail "9b. false alarm"
S9b="$T/scan9b"
PATH="$T/bin:$PATH" DRY_RUN=0 WEEKLY_SCAN_ROWS=web-typos WEEKLY_SCAN_WEB="$WEB" WEEKLY_SCAN_DIR="$S9b" WEEKLY_SCAN_DATE=2026-10-02 \
  do_check_weekly_full_scan >/dev/null 2>&1
[[ ! -e "$S9b/2026-10-02.missed.txt" ]] \
  && pass "9c. the very first run (no earlier report) never alerts" || fail "9c. first run alerted"

echo "-- check-weekly-full-scan.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
