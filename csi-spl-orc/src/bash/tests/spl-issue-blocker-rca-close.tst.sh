#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_blocker_rca_close (RCA SPL-4850, section 3 B1) against
# a stub read and a stub desk. An open from_agent: blocker is MOVEd, one closed
# already is SKIPped. A dry run writes nothing. DRY_RUN=0 needs the owner's
# go, comments the RCA reason citing it and sets diss on each MOVE item,
# leaves one that is done or diss by now alone, deletes none and writes a 0600
# undo file. A re-run on the moved rows changes nothing. The SQL reads the
# epic's open from_agent: children plus the extra numbers, nothing else.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev"
printf 'SPL-1555\tdiss\tfrom_agent: c-001@box-a\nSPL-4480\ttodo\tfrom_agent: c-001@box-a\nSPL-4682\ttodo\tfrom_agent: c-001@box-b\nSPL-4783\ttodo\tfrom_agent: c-001@box-a\n' >"$T/rows.tsv"
GO=70d39d81-241b-4137-aecf-399228fc2f52

STUBS='spl_issue_brc_read() { cat "$ROWS"; }
spl_desk_issue_once() { :; }
spl_desk_issue_run() {
  echo "$*" >>"$DESK_LOG"
  if [[ "$1" == get ]]; then
    local s=todo; [[ "$3" == SPL-4783 ]] && s=diss
    printf "{\"result\":{\"key\":\"%s\",\"status\":\"%s\"}}\n" "$3" "$s"
  fi
}
'
base=(ROWS="$T/rows.tsv" DESK_LOG="$T/desk.log" TENANT_ID=t1 DESK_AGENT=c-996)

# run [VAR=value]...: into $T/o, the plan at $T/plan.tsv.
run() {
  : >"$T/desk.log"
  SNIPPET="${STUBS}do_spl_issue_blocker_rca_close" in_orc "${base[@]}" ISSUE_PLAN="$T/plan.tsv" "$@" >"$T/o" 2>&1
  RC=$?
}
verdict() { awk -F'\t' -v k="$1" '$1 == k { print $3 }' "$T/plan.tsv"; }

run
[[ $RC -eq 0 && "$(verdict SPL-1555)" == SKIP && "$(verdict SPL-4480)" == MOVE && "$(verdict SPL-4682)" == MOVE &&
  "$(verdict SPL-4783)" == MOVE && ! -s "$T/desk.log" ]] &&
  pass "dry run (the default): open = MOVE, diss already = SKIP; no desk call" ||
  fail "dry run (rc=$RC): $(cat "$T/plan.tsv") / $(cat "$T/o") / $(cat "$T/desk.log")"
[[ "$(stat -c %a "$T/plan.tsv")" == 600 ]] && grep -q 'MOVE=3' "$T/o" && grep -q 'SKIP=1' "$T/o" &&
  pass "the plan is 0600 and the log counts the verdicts" || fail "plan mode/counts: $(cat "$T/o")"

run DRY_RUN=0
[[ $RC -ne 0 ]] && grep -q 'needs ISSUE_OWNER_GO' "$T/o" && [[ ! -s "$T/desk.log" ]] &&
  pass "DRY_RUN=0 without the owner's go is refused before any desk call" || fail "no go (rc=$RC): $(cat "$T/o")"
run DRY_RUN=0 ISSUE_OWNER_GO=70d39d81
[[ $RC -ne 0 ]] && grep -q 'needs ISSUE_OWNER_GO' "$T/o" && pass "a short go id is refused" || fail "short go (rc=$RC): $(cat "$T/o")"

run DRY_RUN=0 ISSUE_OWNER_GO=$GO ISSUE_UNDO="$T/undo.sh"
[[ $RC -eq 0 && $(grep -c -- '--status diss$' "$T/desk.log") -eq 2 ]] &&
  grep -q '^update --ref SPL-4480 --status diss$' "$T/desk.log" && grep -q '^update --ref SPL-4682 --status diss$' "$T/desk.log" &&
  grep -q "^comment --ref SPL-4480 --body Closed as diss by the RCA .*SPL-4850.*rca-blocker-issues-from-agent.md.*owner go $GO" "$T/desk.log" &&
  ! grep -qE '^(comment|update) --ref SPL-1555' "$T/desk.log" && ! grep -q '^delete' "$T/desk.log" &&
  pass "a real run comments the RCA reason with the go and sets diss on the open items only; the closed one untouched; no delete" ||
  fail "real run (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
! grep -qE '^(comment|update) --ref SPL-4783' "$T/desk.log" && grep -q 'SPL-4783 is diss already' "$T/o" &&
  pass "an item closed by someone else since the plan is left alone (one move per issue)" ||
  fail "already closed: $(cat "$T/o") / $(cat "$T/desk.log")"
[[ "$(stat -c %a "$T/undo.sh")" == 600 && "$(grep -c do_spl_issue_update "$T/undo.sh")" -eq 2 ]] &&
  grep -q 'ISSUE_REF=SPL-4480 ISSUE_STATUS=todo DRY_RUN=0' "$T/undo.sh" &&
  pass "the undo file is 0600, one command per moved item, back to its old status" ||
  fail "undo: $(cat "$T/undo.sh" 2>/dev/null)"

sed 's/\ttodo\t/\tdiss\t/' "$T/rows.tsv" >"$T/rows2.tsv"
run DRY_RUN=0 ISSUE_OWNER_GO=$GO ROWS="$T/rows2.tsv" ISSUE_UNDO="$T/undo2.sh"
[[ $RC -eq 0 ]] && ! grep -qE '^(comment|update)' "$T/desk.log" && grep -q 'OK moved 0 items' "$T/o" &&
  pass "idempotent: a re-run once all are diss changes nothing" || fail "re-run (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"

run TENANT_ID="t1'; DROP TABLE issues; --"
[[ $RC -ne 0 ]] && grep -q 'TENANT_ID must be' "$T/o" && pass "a bad TENANT_ID is refused before any read" || fail "bad tenant (rc=$RC): $(cat "$T/o")"
run ISSUE_EXTRA_NUMS='1555) OR (true'
[[ $RC -ne 0 ]] && grep -q 'ISSUE_EXTRA_NUMS must be' "$T/o" && pass "a bad ISSUE_EXTRA_NUMS is refused" || fail "extra (rc=$RC): $(cat "$T/o")"

sql=$(SNIPPET='spl_issue_brc_sql' in_orc "${base[@]}" 2>&1)
grep -q "i.tenant_id = 't1'" <<<"$sql" && grep -q "i.parent_number = 2394 AND i.status = 'todo' AND i.title LIKE 'from_agent:%'" <<<"$sql" &&
  grep -q "OR i.number IN (1555)" <<<"$sql" && grep -q "i.deleted_at IS NULL AND i.archived_at IS NULL" <<<"$sql" &&
  pass "the SQL reads the epic's open from_agent: children plus SPL-1555, live rows only" || fail "sql: $sql"
sql=$(SNIPPET='spl_issue_brc_sql' in_orc "${base[@]}" ISSUE_EXTRA_NUMS= 2>&1)
grep -q "OR i.number IN (NULL)" <<<"$sql" && pass "control: ISSUE_EXTRA_NUMS='' adds no number" || fail "sql no extra: $sql"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
