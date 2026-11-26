#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_owner_question_diss (owner db5ed497) against a stub
# read and a stub desk. An owner question nobody but agents touched is MOVEd;
# one the owner changed or commented is KEPT; one another mover owns is
# SKIPped. A dry run writes nothing. DRY_RUN=0 comments the owner's reason and
# sets diss on each MOVE item, leaves one that is done or diss by now alone,
# deletes none and writes a 0600 undo file. The SQL carries every filter.
# One copy of the comment-then-diss step (r90-02): the action calls the
# blocker-RCA closer's spl_issue_brc_one and loads it when sourced alone.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev"
printf 'SPL-1351\ttodo\t0\t0\tRotate the key?\nSPL-1352\ttodo\t1\t0\tReopened by the owner\nSPL-1353\ttodo\t0\t2\tThe owner answered\nSPL-1354\ttodo\t0\t0\tc-340 owns it\nSPL-1355\ttodo\t0\t0\tc-340 closed it meanwhile\n' >"$T/rows.tsv"
printf 'SPL-1354\n' >"$T/skip.keys"

STUBS='spl_issue_oq_read() { cat "$ROWS"; }
spl_desk_issue_once() { :; }
spl_desk_issue_run() {
  echo "$*" >>"$DESK_LOG"
  if [[ "$1" == get ]]; then
    local s=todo; [[ "$3" == SPL-1355 ]] && s=diss
    printf "{\"result\":{\"key\":\"%s\",\"status\":\"%s\"}}\n" "$3" "$s"
  fi
}
'
base=(ROWS="$T/rows.tsv" DESK_LOG="$T/desk.log" TENANT_ID=t1 DESK_AGENT=c-002 OWNER_ID=HUM-10
  ISSUE_CREATED_DAY=2026-10-11 ISSUE_NUM_FROM=1351 ISSUE_NUM_TO=1471 ISSUE_SKIP_KEYS_FILE="$T/skip.keys")

# run [VAR=value]...: into $T/o, the plan at $T/plan.tsv.
run() {
  : >"$T/desk.log"
  SNIPPET="${STUBS}do_spl_issue_owner_question_diss" in_orc "${base[@]}" ISSUE_PLAN="$T/plan.tsv" "$@" >"$T/o" 2>&1
  RC=$?
}
verdict() { awk -F'\t' -v k="$1" '$1 == k { print $3 }' "$T/plan.tsv"; }

run
[[ $RC -eq 0 && "$(verdict SPL-1351)" == MOVE && "$(verdict SPL-1352)" == KEEP && "$(verdict SPL-1353)" == KEEP &&
  "$(verdict SPL-1354)" == SKIP && "$(verdict SPL-1355)" == MOVE && ! -s "$T/desk.log" ]] &&
  pass "dry run: untouched = MOVE, owner changed/commented = KEEP, another mover's key = SKIP; no desk call" ||
  fail "dry run (rc=$RC): $(cat "$T/plan.tsv") / $(cat "$T/o") / $(cat "$T/desk.log")"
[[ "$(stat -c %a "$T/plan.tsv")" == 600 ]] && grep -q 'MOVE=2' "$T/o" && grep -q 'KEEP=2' "$T/o" &&
  pass "the plan is 0600 and the log counts the verdicts" || fail "plan mode/counts: $(cat "$T/o")"

run ISSUE_SKIP_KEYS_FILE=
[[ "$(verdict SPL-1354)" == MOVE ]] && pass "control: with no skip file the other mover's key is planned" ||
  fail "control skip: $(cat "$T/plan.tsv")"

run DRY_RUN=0 ISSUE_UNDO="$T/undo.sh"
diss=$(grep -c -- '^update --ref SPL-1351 --status diss$' "$T/desk.log")
[[ $RC -eq 0 && $diss -eq 1 ]] && grep -q '^comment --ref SPL-1351 --body owner question, not an issue (owner db5ed497)' "$T/desk.log" &&
  ! grep -qE -- '--ref SPL-135[234]( |$)' <(grep -v '^get' "$T/desk.log") && ! grep -q '^delete' "$T/desk.log" &&
  pass "a real run comments the owner's reason and sets diss on the MOVE item only; KEEP and SKIP untouched; no delete" ||
  fail "real run (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"
! grep -qE '^(comment|update) --ref SPL-1355' "$T/desk.log" && grep -q 'SPL-1355 is diss already' "$T/o" &&
  pass "an item closed by someone else since the plan is left alone (one move per issue)" ||
  fail "already closed: $(cat "$T/o") / $(cat "$T/desk.log")"
[[ "$(stat -c %a "$T/undo.sh")" == 600 && "$(grep -c do_spl_issue_update "$T/undo.sh")" -eq 1 ]] &&
  grep -q 'ISSUE_REF=SPL-1351 ISSUE_STATUS=todo DRY_RUN=0' "$T/undo.sh" &&
  pass "the undo file is 0600, one command per moved item, back to its old status" ||
  fail "undo: $(cat "$T/undo.sh" 2>/dev/null)"

run OWNER_ID="x'; DROP TABLE issues; --"
[[ $RC -ne 0 ]] && grep -q 'OWNER_ID must be' "$T/o" && pass "a bad OWNER_ID is refused before any read" || fail "bad owner (rc=$RC): $(cat "$T/o")"
run ISSUE_NUM_FROM=1471 ISSUE_NUM_TO=1351
[[ $RC -ne 0 ]] && grep -q 'ISSUE_NUM_FROM..ISSUE_NUM_TO' "$T/o" && pass "a reversed range is refused" || fail "range (rc=$RC): $(cat "$T/o")"

own=$(grep -n 'spl_issue_oq_one' "$PROJ_ROOT/src/bash/run/spl-issue-owner-question-diss.func.sh")
[[ -z "$own" ]] && grep -q 'if spl_issue_brc_one "$key" "$why"; then' "$PROJ_ROOT/src/bash/run/spl-issue-owner-question-diss.func.sh" &&
  pass "r90-02: one copy of the step: no spl_issue_oq_one, the apply calls spl_issue_brc_one" ||
  fail "r90-02: own copy left: $own"
run DRY_RUN=0 ISSUE_UNDO="$T/undo2.sh" IN_ORC_RUN=spl-issue-owner-question-diss
[[ $RC -eq 0 ]] && grep -q '^update --ref SPL-1351 --status diss$' "$T/desk.log" &&
  grep -q '^comment --ref SPL-1351 --body owner question, not an issue (owner db5ed497)' "$T/desk.log" &&
  pass "r90-02 sourced alone: the action loads spl_issue_brc_one, a real run comments and sets SPL-1351 diss" ||
  fail "r90-02 sourced alone (rc=$RC): $(cat "$T/o") / $(cat "$T/desk.log")"

sql=$(SNIPPET='spl_issue_oq_sql' in_orc "${base[@]}" 2>&1)
grep -q "assignee = 'HUM-10'" <<<"$sql" && grep -q "'blocker' = ANY (i.labels)" <<<"$sql" &&
  grep -q "NOT IN ('done', 'diss')" <<<"$sql" && grep -q "BETWEEN 1351 AND 1471" <<<"$sql" &&
  grep -q "DATE '2026-10-11'" <<<"$sql" && grep -q "e.event <> 'created'" <<<"$sql" && grep -q "m.from_id = 'HUM-10'" <<<"$sql" &&
  pass "the SQL carries owner, label, open status, range, day, the owner's events and comments" || fail "sql: $sql"

# --- r04-01 shared helpers delegation and standalone lazy-source ----------------
oq_f="$PROJ_ROOT/src/bash/run/spl-issue-owner-question-diss.func.sh"
own_r04="$(grep -nE 'spl_issue_oq_plan_path|OK DRY_RUN nothing was moved\. PLAN|FATAL read-only query on' "$oq_f" || true)"
[[ -z "$own_r04" ]] &&
  grep -q '_spl_issue_brc_run_plan "$dry" "$plan" spl_issue_oq_read spl_issue_oq_verdicts spl_issue_oq_apply' "$oq_f" &&
  grep -q 'spl_issue_brc_plan_path issue-owner-question' "$oq_f" &&
  grep -q '_spl_issue_brc_query spl_issue_oq_sql' "$oq_f" &&
  pass "r04-01 one copy: spl-issue-owner-question-diss.func.sh delegates plan_path, run_plan and query to brc helpers" ||
  fail "r04-01 oq one copy: own=[$own_r04]"

: >"$T/desk.log"
SNIPPET="${STUBS}do_spl_issue_owner_question_diss" in_orc "${base[@]}" IN_ORC_RUN=spl-issue-owner-question-diss \
  SPL_STATE_DIR="$T/state/oq-solo" >"$T/o" 2>&1; rc=$?
p_solo="$(ls "$T/state/oq-solo/issue-owner-question/"t1-*.plan.tsv 2>/dev/null || true)"
[[ $rc -eq 0 && -n "$p_solo" && "$(stat -c %a "$T/state/oq-solo/issue-owner-question")" == 700 &&
  "$(stat -c %a "$p_solo")" == 600 ]] && grep -q "OK DRY_RUN nothing was moved. PLAN $p_solo" "$T/o" &&
  pass "r04-01 standalone dry run: loads brc helpers and writes 0600 plan under issue-owner-question (0700)" ||
  fail "r04-01 oq solo dry (rc=$rc): $(cat "$T/o")"

out=$(env PROJ_ROOT="$PROJ_ROOT" "${base[@]}" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }
  spl_psql_ro(){ printf "DSN=%s SQL=%s\n" "$1" "$2"; }
  spl_sql_proxy_stop(){ echo "STOPPED"; }
  source "$PROJ_ROOT/src/bash/run/spl-issue-owner-question-diss.func.sh"
  dsn=pg://local _spl_issue_oq_query' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"STOPPED"* && "$out" == *"DSN=pg://local"* && "$out" == *"assignee = 'HUM-10'"* && "$out" != *"command not found"* ]] &&
  pass "r04-01 standalone query: _spl_issue_oq_query lazy-loads _spl_issue_brc_query and passes spl_issue_oq_sql" ||
  fail "r04-01 oq solo query (rc=$rc): $out"

(umask 022; : >"$T/plan.tsv"; chmod 644 "$T/plan.tsv")
run
[[ $RC -eq 0 && "$(stat -c %a "$T/plan.tsv")" == 600 ]] &&
  pass "r04-01 plan mode: an existing 0644 ISSUE_PLAN is tightened to 0600" ||
  fail "r04-01 existing plan mode (rc=$RC): $(stat -c %a "$T/plan.tsv")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
