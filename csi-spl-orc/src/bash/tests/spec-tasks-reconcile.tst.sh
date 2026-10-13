#!/usr/bin/env bash
# Hermetic plan for do_spl_spec_tasks_reconcile: a fixture tasks.md
# (ticked, unticked, gone, not imported), each with a control.
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FIX="$TEST_DIR/fixtures/spec-tasks-reconcile"
PY="$PROJ_ROOT/src/bash/scripts/spec-import-issues.py"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$PROJ_ROOT/src/bash/run/spl-spec-tasks-reconcile.func.sh" ]] && pass "action is present" || fail "action missing"
[[ -f "$PROJ_ROOT/src/bash/scripts/spec-tasks-reconcile.py" ]] && pass "planner is present" || fail "planner missing"
bash -n "$PROJ_ROOT/src/bash/run/spl-spec-tasks-reconcile.func.sh" && pass "action parses" || fail "action syntax"
python3 -m py_compile "$PROJ_ROOT/src/bash/scripts/spec-tasks-reconcile.py" && pass "planner compiles" || fail "planner compile"

# shellcheck disable=SC1091
do_log() { printf '%s\n' "$*"; }
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}
# shellcheck disable=SC1090
source "$PROJ_ROOT/src/bash/run/spl-spec-tasks-reconcile.func.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LIST="$TMP/list.json"
CALLS="$TMP/calls.tsv"
export CALLS

python3 - "$PY" "$FIX" "$LIST" <<'PY' || { fail "could not build the fixture list"; exit 1; }
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("imp", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
plan = mod.parse_tree(Path(sys.argv[2]))
items = {(i["spec"], i["id"]): i for i in plan["items"]}

def row(key, spec, tid, status):
    it = items[(spec, tid)]
    return {"key": key, "title": it["title"], "status": status, "labels": it["labels"]}

issues = [
    {"key": "SPL-16", "title": "Spec 001 - sample", "status": "wip", "labels": ["epic"]},
    row("SPL-1", "001", "T001", "wip"),
    row("SPL-21", "001", "T001", "wip"),
    row("SPL-2", "001", "T002", "done"),
    row("SPL-3", "001", "T003", "done"),
    row("SPL-4", "001", "T004", "eval"),
    {"key": "SPL-5", "title": "[001 T999] removed from the list", "status": "wip", "labels": ["task"]},
    {"key": "SPL-6", "title": "T001 Copy the runner from the donor.", "status": "wip", "labels": ["task"]},
    {"key": "SPL-7", "title": "[001 doc-spec.md] spec.md - Sample", "status": "done", "labels": ["doc"]},
    row("SPL-8", "001", "T008", "eval"),
    row("SPL-9", "001", "T006", "diss"),
    {"key": "SPL-10", "title": "[001 T010] fenced and not a task", "status": "wip", "labels": ["task"]},
    row("SPL-11", "001", "T005", "done"),
    row("SPL-13", "001", "T007", "wip"),
    row("SPL-14", "001", "T007.s1", "wip"),
    row("SPL-15", "001", "T007.s2", "done"),
    {"key": "SPL-17", "title": "[999 T001] other spec", "status": "wip", "labels": ["task"]},
]
if "T010" in {i["id"] for i in plan["items"]}:
    print("fixture parser kept the fenced T010", file=sys.stderr)
    raise SystemExit(1)
json.dump({"result": {"issues": issues, "labels": [{"id": "task"}]}}, open(sys.argv[3], "w"))
PY
pass "fixture list built, fenced T010 is not a task"

cell() { awk -F '\t' -v k="$1" -v c="$2" 'NR>1 && $3==k { print $c; exit }' "$TABLE"; }

OUT="$TMP/dry.out"
TABLE="$TMP/table.tsv"
(
  trap - RETURN
  unset DRY_RUN ISSUE_TITLE ISSUE_DESCRIPTION_FILE
  SPEC_RECONCILE_OFFLINE=1 SPEC_DIR="$FIX" SPEC_RECONCILE_SHA=fixture-sha \
    SPEC_RECONCILE_LIST="$LIST" SPEC_RECONCILE_OUT="$TABLE" PROJ_PATH="$PROJ_ROOT" \
    do_spl_spec_tasks_reconcile
) >"$OUT" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && pass "dry-run exits 0" || { fail "dry-run exit $rc"; sed -n 1,40p "$OUT"; }
grep -q 'COUNTS close=4 report=5 gone=2 aligned=2 not_imported=4' "$OUT" \
  && pass "counts: 4 close, 5 report, 2 gone, 2 aligned, 4 not imported" \
  || { fail "counts"; grep COUNTS "$OUT" || true; }
grep -q 'OK DRY_RUN nothing was written' "$OUT" && pass "dry-run writes nothing" || fail "dry-run log"
[[ -s "$TABLE" ]] && pass "table file kept" || fail "table file missing"
traps=$(trap -p RETURN)
[[ -z "$traps" ]] && pass "RETURN trap is reset" || fail "RETURN trap leaked"

# ticked + open -> close. Control: the same tick on an issue already done is not closed.
[[ "$(cell SPL-1 4)" == close && "$(cell SPL-1 5)" == ticked-open ]] && pass "T001 open is closed" || fail "T001 $(cell SPL-1 4) $(cell SPL-1 5)"
[[ "$(cell SPL-21 4)" == close ]] && pass "a second open issue with the same prefix is closed too" || fail "duplicate prefix dropped"
[[ "$(cell SPL-2 4)" == aligned && "$(cell SPL-2 5)" == ticked-done ]] \
  && pass "control: ticked and already done is not closed" || fail "T002 control $(cell SPL-2 4)"
# unticked + done -> report, never reopen. Control: unticked + open is aligned.
[[ "$(cell SPL-3 4)" == report && "$(cell SPL-3 5)" == unticked-done ]] && pass "unticked done issue is report only" || fail "T003 $(cell SPL-3 4) $(cell SPL-3 5)"
[[ "$(cell SPL-4 4)" == aligned && "$(cell SPL-4 5)" == unticked-open ]] \
  && pass "control: unticked and open is not a reopen report" || fail "T004 control $(cell SPL-4 4)"
# gone. Control: a task that is still in the file is not gone.
[[ "$(cell SPL-5 4)" == gone && "$(cell SPL-5 5)" == task-gone ]] && pass "removed T999 is gone, report only" || fail "T999 $(cell SPL-5 4)"
[[ "$(cell SPL-1 4)" != gone ]] && pass "control: a live task is not gone" || fail "T001 marked gone"
# not imported. Control: the imported ticked issue is in the table.
[[ -z "$(cell SPL-6 4)" && -z "$(cell SPL-7 4)" && -z "$(cell SPL-16 4)" && -z "$(cell SPL-17 4)" ]] \
  && pass "no bracket, a doc import, an epic and another spec are not in the table" \
  || fail "not-imported leaked into the table"
[[ -n "$(cell SPL-1 4)" ]] && pass "control: an imported ticked issue is in the table" || fail "imported row missing"
# further controls on the only write rule: a checkbox x.
[[ "$(cell SPL-8 4)" == report && "$(cell SPL-8 5)" == marked-done-open ]] \
  && pass "control: Implemented on a heading is not a close" || fail "T008 $(cell SPL-8 4) $(cell SPL-8 5)"
[[ "$(cell SPL-9 4)" == report && "$(cell SPL-9 5)" == ticked-not-open ]] \
  && pass "control: a discarded issue is not set to done" || fail "T006 $(cell SPL-9 4) $(cell SPL-9 5)"
[[ "$(cell SPL-10 4)" == gone ]] && pass "control: a checkbox inside a fence is not a task" || fail "T010 $(cell SPL-10 4)"
[[ "$(cell SPL-11 4)" == report && "$(cell SPL-11 5)" == partial-done ]] \
  && pass "control: a partial task is not reopened" || fail "T005 $(cell SPL-11 4) $(cell SPL-11 5)"
[[ "$(cell SPL-13 4)" == close && "$(cell SPL-14 4)" == close ]] && pass "ticked parent and .sN child are closed" || fail "subtask close"
[[ "$(cell SPL-15 4)" == report && "$(cell SPL-15 5)" == unticked-done ]] && pass "unticked .sN child is report only" || fail "T007.s2 $(cell SPL-15 4)"

t001_line=$(awk '/^- \[x\] T001 / { print NR; exit }' "$FIX/001-sample/tasks.md")
[[ "$(cell SPL-1 7)" == "$t001_line" && -n "$t001_line" ]] && pass "close names the checkbox line ($t001_line)" || fail "T001 line $(cell SPL-1 7) != $t001_line"
s1_line=$(awk '/confirm the child is ticked too/ { print NR; exit }' "$FIX/001-sample/tasks.md")
[[ "$(cell SPL-14 7)" == "$s1_line" ]] && pass "subtask close names its own line" || fail "s1 line $(cell SPL-14 7) != $s1_line"
want="closed by tasks.md reconcile (001-sample/tasks.md:${t001_line}, fixture-sha)"

# DRY_RUN stays the default: an explicit 2 is refused, a missing list is refused.
bad=$(DRY_RUN=2 SPEC_RECONCILE_OFFLINE=1 SPEC_DIR="$FIX" SPEC_RECONCILE_LIST="$LIST" PROJ_PATH="$PROJ_ROOT" \
  do_spl_spec_tasks_reconcile 2>&1) && fail "DRY_RUN=2 was accepted" || pass "DRY_RUN=2 is refused"
[[ "$bad" == *DRY_RUN* ]] && pass "DRY_RUN=2 names the variable" || fail "DRY_RUN=2 log: $bad"
bad=$(SPEC_RECONCILE_OFFLINE=1 SPEC_DIR="$FIX" PROJ_PATH="$PROJ_ROOT" do_spl_spec_tasks_reconcile 2>&1) \
  && fail "missing list was accepted" || pass "offline without a list is refused"

# Apply. Stubs record the writes. A leaked ISSUE_* must not ride along.
do_spl_issue_comment() {
  printf 'comment\t%s\t%s\n' "$ISSUE_REF" "$ISSUE_BODY" >>"$CALLS"
  [[ -z "${ISSUE_STATUS+x}" ]] || { echo "STATUS leaked into the comment" >>"$CALLS"; return 1; }
}
do_spl_issue_update() {
  printf 'update\t%s\t%s\n' "$ISSUE_REF" "$ISSUE_STATUS" >>"$CALLS"
  [[ -z "${ISSUE_BODY+x}" && -z "${ISSUE_TITLE+x}" && -z "${ISSUE_DESCRIPTION_FILE+x}" ]] \
    || { echo "field leaked into the update" >>"$CALLS"; return 1; }
}
: >"$CALLS"
STATE="$TMP/state"
UNDO_OUT="$TMP/apply.out"
(
  trap - RETURN
  ISSUE_TITLE=LEAK ISSUE_DESCRIPTION_FILE="$TMP/does-not-exist" \
  DRY_RUN=0 SPEC_RECONCILE_OFFLINE=1 SPEC_RECONCILE_INTERVAL=0 \
    SPEC_DIR="$FIX" SPEC_RECONCILE_SHA=fixture-sha SPEC_RECONCILE_LIST="$LIST" \
    SPEC_RECONCILE_OUT="$TMP/apply.tsv" SPL_STATE_DIR="$STATE" PROJ_PATH="$PROJ_ROOT" \
    ENV=prd TENANT_ID=t1 DESK_AGENT=g-388 \
    do_spl_spec_tasks_reconcile
) >"$UNDO_OUT" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && pass "apply exits 0" || { fail "apply exit $rc"; sed -n 1,50p "$UNDO_OUT"; }
closed=$(awk -F '\t' '$1=="comment" { print $2 }' "$CALLS" | sort | paste -sd, -)
[[ "$closed" == "SPL-1,SPL-13,SPL-14,SPL-21" ]] && pass "apply comments only the four closes" || fail "comments: $closed"
updated=$(awk -F '\t' '$1=="update" { print $2 }' "$CALLS" | sort | paste -sd, -)
[[ "$updated" == "$closed" ]] && pass "apply sets done on exactly those issues" || fail "updates: $updated"
grep -q $'\tupdate\t.*\tdone$' "$CALLS" || awk -F '\t' '$1=="update" && $3!="done" { exit 1 }' "$CALLS" \
  && pass "every update is status done" || fail "a write was not done"
grep -q $'\tSPL-1\t'"$want"$ "$CALLS" && pass "SPL-1 comment is the line and the sha" || { fail "SPL-1 comment"; grep SPL-1 "$CALLS" || true; }
untouched=0
for k in SPL-2 SPL-3 SPL-4 SPL-5 SPL-6 SPL-7 SPL-8 SPL-9 SPL-10 SPL-11 SPL-15 SPL-16 SPL-17; do
  if grep -q $'\t'"$k"$'\t' "$CALLS"; then fail "control: $k was written"; else untouched=$((untouched + 1)); fi
done
[[ "$untouched" -eq 13 ]] && pass "control: report, gone, aligned and not-imported issues were not written" || fail "untouched=$untouched"
grep -q 'field leaked' "$CALLS" && fail "an ISSUE_* field leaked into the update" || pass "control: the update sets only the status"
undo=$(grep '^UNDO bash ' "$UNDO_OUT" | awk '{ print $3 }')
[[ -n "$undo" && -x "$undo" ]] && pass "one undo command: $undo" || fail "undo command missing ($undo)"
for k in SPL-1 SPL-13 SPL-14 SPL-21; do
  grep -q "ISSUE_REF=$k " "$undo" && grep -q "ISSUE_REF=$k ISSUE_STATUS=wip " "$undo" \
    && pass "undo restores $k to wip" || fail "undo missing $k"
done
for k in SPL-3 SPL-5 SPL-6 SPL-8 SPL-10; do
  grep -q "ISSUE_REF=$k " "$undo" && fail "control: undo names $k" || pass "control: undo omits $k"
done
journal=$(grep '^JOURNAL ' "$UNDO_OUT" | awk '{ print $2 }')
[[ -n "$journal" && "$(grep -c $'\t' "$journal")" -eq 5 ]] && pass "journal has a header and four closes" || fail "journal $journal"
# dry-run must not have left an undo of its own in a fresh state dir
DRY_STATE="$TMP/dry-state"
mkdir -p "$DRY_STATE"
DRY_RUN=1 SPEC_RECONCILE_OFFLINE=1 SPEC_DIR="$FIX" SPEC_RECONCILE_SHA=fixture-sha \
  SPEC_RECONCILE_LIST="$LIST" SPEC_RECONCILE_OUT="$TMP/dry2.tsv" SPL_STATE_DIR="$DRY_STATE" \
  PROJ_PATH="$PROJ_ROOT" do_spl_spec_tasks_reconcile >"$TMP/dry2.out" 2>&1 || fail "second dry-run failed"
found=$(find "$DRY_STATE" \( -name '*.undo.sh' -o -name '*.journal.tsv' \) -print -quit)
[[ -z "$found" ]] && pass "control: dry-run writes no journal and no undo" || fail "control: dry-run wrote a journal ($found)"

# origin/master, not the worktree: offline, one issue that cannot match.
SMOKE_LIST="$TMP/smoke.json"
printf '%s\n' '{"result":{"issues":[{"key":"SPL-0","title":"not-imported-smoke","status":"wip","labels":["task"]}]}}' >"$SMOKE_LIST"
SMOKE_OUT="$TMP/smoke.out"
SPEC_RECONCILE_OFFLINE=1 SPEC_RECONCILE_SHA=smoke-sha SPEC_RECONCILE_LIST="$SMOKE_LIST" \
  SPEC_RECONCILE_OUT="$TMP/smoke.tsv" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
  do_spl_spec_tasks_reconcile >"$SMOKE_OUT" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && grep -q 'COUNTS close=0 report=0 gone=0 aligned=0 not_imported=1' "$SMOKE_OUT" \
  && pass "origin/master read: a foreign issue is not imported and nothing is closed" \
  || { fail "origin/master smoke rc=$rc"; tail -n 20 "$SMOKE_OUT"; }

echo "=== $([[ $fails -eq 0 ]] && echo 'spec-tasks-reconcile: ALL PASS' || echo "$fails FAILED")"
[[ "$fails" -eq 0 ]]
