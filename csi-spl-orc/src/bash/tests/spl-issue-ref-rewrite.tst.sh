#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_ref_rewrite (SPL-3821, owner HUM-10 csitea 26a21b5a,
#          msg 642a2179) applies do_spl_issue_ref_scan's plan, offline (no
#          cloud call, no hub):
#   1. the planner routes each field: edit (this desk box), other-box, human
#      (box-wui), no-pin (revoked box), issue, done (already new), stale
#      (text changed, or the key moved), gone (deleted)
#   2. the new text changes ONLY the plan's keys: the planted t1 key and the
#      ambiguous one next to them stay byte for byte
#   3. work.tsv holds only the edit and issue routes, with author and box
#   4. a plan to another prefix, or with a doc field, is refused (exit 2)
#   5. the action refuses DRY_RUN=2, a bad TENANT_ID, a missing plan and a
#      plan id that is not a uuid / number before any cloud call (CONTROL:
#      the stub log is empty); its SQL is one SELECT, READ ONLY, tenant-scoped
#   6. through a stubbed proxy: DRY_RUN=1 calls no edit path; DRY_RUN=0
#      calls do_spl_desk_edit once per edit field as its author and
#      do_spl_issue_update only with ISSUE_AGENT; a failed edit is counted and
#      does not stop the rest
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PY="$PROJ_ROOT/src/bash/scripts/issue-ref-rewrite.py"
U1=11111111-1111-4111-8111-111111111111 U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333 U4=44444444-4444-4444-8444-444444444444
U5=55555555-5555-4555-8555-555555555555 U6=66666666-6666-4666-8666-666666666666
U7=77777777-7777-4777-8777-777777777777

T1_TEXT='The fix is SPL-42 (csitea); t1 has SPL-3528 and the spool-hub project SPL-44.'
row() { python3 -c 'import json,sys; r={"src":sys.argv[1],"id":sys.argv[2],"field":sys.argv[3],"text":sys.argv[4]}
if len(sys.argv) > 5: r["box"], r["from"] = sys.argv[5], sys.argv[6]
print(json.dumps(r, ensure_ascii=False))' "$@"; }
{
  echo '{"src":"meta","tenant":"csitea","prefix":"CSI","pins":["box-wui","box-b","box-a"]}'
  row msg $U1 body "$T1_TEXT" box-a c-002
  row msg $U2 body 'Готово: SPL-3 в Issues' box-b c-003
  row msg $U3 body 'Please look at SPL-40' box-wui HUM-10
  row msg $U4 body 'Epic SPL-2 is finance' box-desk CLE-002
  row msg $U5 body 'Already CSI-7 here' box-a c-002
  row msg $U6 body 'Edited later: SPL-8 moved' box-a c-002
  row issue 45 description 'Parent SPL-43, see t1 SPL-2398'
} >"$T/rows.jsonl"
python3 - "$T/plan.json" <<EOF
import json, sys
t1 = "$T1_TEXT"
f = lambda src, i, text_len, edits: {"src": src, "id": i, "field": "description" if src == "issue" else "body", "text_len": text_len,
     "edits": [{"offset": o, "old": "SPL-%d" % n, "new": "CSI-%d" % n, "reason": "plain"} for o, n in edits]}
json.dump({"tenant": "csitea", "old": "SPL", "new": "CSI", "fields": [
  f("msg", "$U1", len(t1), [(11, 42)]),
  f("msg", "$U2", 22, [(8, 3)]),
  f("msg", "$U3", 21, [(15, 40)]),
  f("msg", "$U4", 21, [(5, 2)]),
  f("msg", "$U5", 18, [(8, 7)]),
  f("msg", "$U6", 25, [(15, 8)]),
  f("msg", "$U7", 10, [(0, 9)]),
  f("issue", 45, 30, [(7, 43)]),
]}, open(sys.argv[1], "w"), ensure_ascii=False)
EOF
mkdir -p "$T/out"
out=$(python3 "$PY" --plan "$T/plan.json" --box box-a --out "$T/out" <"$T/rows.jsonl"); rc=$?
[[ $rc == 0 ]] && pass "planner exit 0" || fail "planner rc=$rc: $out"
has() { grep -qF -- "$1" <<<"$out" && pass "$2" || fail "$2 (no line: $1)"; }

# --- 1. routes --------------------------------------------------------------------
has "EDIT edit msg:$U1:body @11 SPL-42 -> CSI-42 [box-a c-002]" "own-box message is route edit"
has "EDIT other-box msg:$U2:body @8 SPL-3 -> CSI-3 [box-b c-003]" "another live box is route other-box"
has "EDIT human msg:$U3:body @15 SPL-40 -> CSI-40 [box-wui HUM-10]" "a WUI message is route human"
has "EDIT no-pin msg:$U4:body @5 SPL-2 -> CSI-2 [box-desk CLE-002]" "a revoked box is route no-pin"
has "EDIT issue issue:45:description @7 SPL-43 -> CSI-43" "an issue field is route issue"
has "SKIP done msg:$U5:body" "already rewritten is done"
has "SKIP stale msg:$U6:body" "a key no longer at its offset is stale"
has "SKIP gone msg:$U7:body" "a deleted message is gone"
has "COUNT edit 1 1" "count edit"
has "COUNT stale 1 1" "count stale"
has "  after:  Готово: CSI-3 в Issues" "before/after keeps non-ASCII text"

# --- 2. only the plan's keys change -----------------------------------------------
f1=$(awk -F'\t' -v id=$U1 '$3 == id {print $7}' "$T/out/work.tsv")
[[ "$(cat "$f1")" == 'The fix is CSI-42 (csitea); t1 has SPL-3528 and the spool-hub project SPL-44.' ]] \
  && pass "only the planned key changed; t1 SPL-3528 and ambiguous SPL-44 stay" || fail "new text: $(cat "$f1")"
f2=$(awk -F'\t' '$2 == "issue" {print $7}' "$T/out/work.tsv")
[[ "$(cat "$f2")" == 'Parent CSI-43, see t1 SPL-2398' ]] && pass "issue text: only the planned key changed" || fail "issue text: $(cat "$f2")"

# --- 3. work.tsv ------------------------------------------------------------------
[[ $(wc -l <"$T/out/work.tsv") == 2 ]] && pass "work.tsv holds only the edit and issue routes" || fail "work: $(cat "$T/out/work.tsv")"
grep -qP "^edit\tmsg\t$U1\tbody\tc-002\tbox-a\t" "$T/out/work.tsv" && pass "edit line carries the author and box" || fail "work: $(cat "$T/out/work.tsv")"

# --- 4. bad plans -----------------------------------------------------------------
sed 's/"new": "CSI"/"new": "XYZ"/' "$T/plan.json" >"$T/bad1.json"
o=$(python3 "$PY" --plan "$T/bad1.json" --box box-a --out "$T/out" <"$T/rows.jsonl"); rc=$?
[[ $rc == 2 && "$o" == *"FATAL the plan does not rewrite"* ]] && pass "a plan to another prefix is refused" || fail "bad1 rc=$rc: $o"
sed 's/"src": "issue"/"src": "doc_item"/' "$T/plan.json" >"$T/bad2.json"
o=$(python3 "$PY" --plan "$T/bad2.json" --box box-a --out "$T/out" <"$T/rows.jsonl"); rc=$?
[[ $rc == 2 ]] && pass "a plan with a doc field is refused" || fail "bad2 rc=$rc: $o"

# --- 5. the action's refusals and SQL ---------------------------------------------
orc_stub 1 gcloud psql
act() { SNIPPET="$1" in_orc SPOOL_DESK_BOX=box-a "${@:2}" 2>&1; }
o=$(act 'do_spl_issue_ref_rewrite' TENANT_ID=csitea SCAN_PLAN="$T/plan.json" DRY_RUN=2); rc=$?
[[ $rc != 0 && "$o" == *"DRY_RUN must be 0 or 1"* ]] && pass "DRY_RUN=2 is refused" || fail "dry rc=$rc: $o"
o=$(act 'do_spl_issue_ref_rewrite' "TENANT_ID=csitea'; drop" SCAN_PLAN="$T/plan.json"); rc=$?
[[ $rc != 0 && "$o" == *"TENANT_ID must be a tenant slug"* ]] && pass "bad TENANT_ID is refused" || fail "tenant rc=$rc: $o"
o=$(act 'do_spl_issue_ref_rewrite' TENANT_ID=csitea SCAN_PLAN="$T/none.json"); rc=$?
[[ $rc != 0 && "$o" == *"SCAN_PLAN must be the readable plan"* ]] && pass "a missing plan is refused" || fail "plan rc=$rc: $o"
sed "s/$U1/x') OR true --/" "$T/plan.json" >"$T/inj.json"
o=$(act 'do_spl_issue_ref_rewrite' TENANT_ID=csitea SCAN_PLAN="$T/inj.json"); rc=$?
[[ $rc != 0 && "$o" == *"is not a csitea plan of msg uuids and issue numbers"* ]] && pass "a non-uuid plan id is refused" || fail "inj rc=$rc: $o"
o=$(act 'do_spl_issue_ref_rewrite' TENANT_ID=t1 SCAN_PLAN="$T/plan.json"); rc=$?
[[ $rc != 0 && "$o" == *"is not a t1 plan"* ]] && pass "another workspace's plan is refused" || fail "tenant plan rc=$rc: $o"
[[ ! -s "$T/calls.log" ]] && pass "CONTROL: no cloud call before the refusals" || fail "calls: $(cat "$T/calls.log")"
sql=$(act "spl_issue_ref_rewrite_sql csitea $T/plan.json")
grep -qiE '\b(insert|update|delete|truncate|drop|alter|grant|create)\b' <<<"$sql" && fail "the SQL holds a write verb: $sql" || pass "the SQL holds no write verb"
[[ $(grep -c "tenant_id = 'csitea'" <<<"$sql") == 5 ]] && pass "every read is scoped to the tenant" || fail "tenant scope: $sql"
grep -q "msg_id IN ('$U1','$U2'," <<<"$sql" && grep -q "number IN (45)" <<<"$sql" && pass "the SQL reads the plan's ids" || fail "ids: $sql"
grep -q "BEGIN TRANSACTION READ ONLY" "$PROJ_ROOT/src/bash/run/spl-issue-ref-rewrite.func.sh" && pass "the read runs in a READ ONLY transaction" || fail "no READ ONLY"

# --- 6. through a stubbed proxy ---------------------------------------------------
STUBS='do_spl_cloud_cnf() { SPL_CNF=x; }; do_gcp_pin_account() { GCP_ACCOUNT=sa; }; do_gcp_require_live_account() { :; }
  spl_via_proxy() { shift; cat "$ROWS" >"$1"; }
  do_spl_desk_edit() { echo "DESK $DESK_AGENT $DESK_BOX $MSG_ID $DRY_RUN $(cat "$DESK_BODY_FILE")" >>"$STUB_LOG"; [[ "$MSG_ID" != "${FAIL_ID:-}" ]]; }
  do_spl_issue_update() { echo "ISSUE $DESK_AGENT $DESK_BOX $ISSUE_REF $DRY_RUN $(cat "$ISSUE_DESCRIPTION_FILE")" >>"$STUB_LOG"; }'
o=$(act "$STUBS; do_spl_issue_ref_rewrite" TENANT_ID=csitea ROWS="$T/rows.jsonl" SCAN_PLAN="$T/plan.json"); rc=$?
[[ $rc == 0 && "$o" == *"OK DRY_RUN nothing was edited in csitea"* && ! -s "$T/calls.log" ]] \
  && pass "DRY_RUN=1 reports and calls no edit path" || fail "dry rc=$rc: $o / $(cat "$T/calls.log" 2>/dev/null)"
o=$(act "$STUBS; do_spl_issue_ref_rewrite" TENANT_ID=csitea ROWS="$T/rows.jsonl" SCAN_PLAN="$T/plan.json" DRY_RUN=0); rc=$?
[[ $rc == 0 && "$(cat "$T/calls.log")" == "DESK c-002 box-a $U1 0 The fix is CSI-42 (csitea); t1 has SPL-3528 and the spool-hub project SPL-44." \
  && "$o" == *"rewrote 1 field(s) in csitea, 0 failed, 1 issue field(s) left"* ]] \
  && pass "DRY_RUN=0 edits only this box's message, as its author; issues wait for ISSUE_AGENT" || fail "apply rc=$rc: $o / $(cat "$T/calls.log")"
: >"$T/calls.log"
o=$(act "$STUBS; do_spl_issue_ref_rewrite" TENANT_ID=csitea ROWS="$T/rows.jsonl" SCAN_PLAN="$T/plan.json" DRY_RUN=0 ISSUE_AGENT=c-002 FAIL_ID=$U1); rc=$?
[[ $rc != 0 && "$o" == *"rewrote 1 field(s) in csitea, 1 failed"* ]] && grep -qx "ISSUE c-002 box-a CSI-45 0 Parent CSI-43, see t1 SPL-2398" "$T/calls.log" \
  && pass "with ISSUE_AGENT the issue is updated by key; a failed edit is counted and the rest still runs" || fail "issue rc=$rc: $o / $(cat "$T/calls.log")"

[[ $fails == 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAIL"; exit 1; }
