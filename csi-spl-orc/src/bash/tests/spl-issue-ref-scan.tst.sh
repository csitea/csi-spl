#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_ref_scan (SPL-3570, owner HUM-10 csitea 26a21b5a) sorts
#          a workspace's old-prefix keys, offline (no cloud call):
#   1. a planted t1 key (n above the workspace's counter) is keep/not-ours and
#      is NOT in the plan, also inside a csitea text full of csitea keys
#   2. an issues link on the workspace's host (and its markdown label, and a
#      relative /issues?issue= link) is rewrite/link; the same small n on
#      another host (t1, apex) is keep/other-link
#   3. a live small n in a text with no t1-range key is rewrite/plain; the
#      line naming the workspace is rewrite/named
#   4. ambiguous, never in the plan: mixed (the text also holds a t1-range
#      key), names-other (t1 / the spool-hub project / on dev), commit
#      ("(orc, SPL-n)", "Closes: SPL-n"), deleted (allocated, no live issue)
#   5. XSPL-3, SPL-3a, a path /x/SPL-3 and SPL-03 are not keys
#   6. the plan's offsets point at the old key; applied, every planted t1
#      key is still there and every rewrite reads CSI-n
#   7. the action refuses DRY_RUN=0, a bad TENANT_ID and a bad OLD_PREFIX
#      before any cloud call (CONTROL: the stub log is empty); its SQL is
#      one SELECT in a READ ONLY transaction with no write verb; through a
#      stubbed proxy it prints the report and writes SCAN_PLAN
#   8. the classifier refuses a workspace that still uses the old prefix
#   9. a would-be rewrite key in an archived or deleted issue is archived,
#      listed apart and NOT in the plan (SPL-3821: the hub answers not_found
#      for csitea's archived CSI-20); a live issue's same key is rewrite.
#      The scan SQL flags archived_at / deleted_at on both issue fields
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PY="$PROJ_ROOT/src/bash/scripts/issue-ref-scan.py"

META='{"src":"meta","tenant":"csitea","prefix":"CSI","last_number":49,"numbers":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,37,39,40,41,42,43,44,45,46,47,48,49]}'
row() { python3 -c 'import json,sys; print(json.dumps({"src":sys.argv[1],"id":sys.argv[2],"field":sys.argv[3],"text":sys.argv[4]}))' "$@"; }
{
  echo "$META"
  row msg m-plain body $'The bank invoice is SPL-42, under the epic SPL-43.'
  row msg m-t1 body $'Lane c-1 has SPL-3528 (commit landed); the fix is SPL-1687.'
  row msg m-link body $'The issue is [SPL-35](https://csitea.example.test/issues?issue=SPL-35). See also /issues?issue=SPL-37 and https://csitea.example.test/en/issues?issue=SPL-40'
  row msg m-other-link body $'Lane m-423 has [SPL-12](https://t1.example.test/issues?issue=SPL-12) and https://example.test/issues?issue=SPL-14'
  row msg m-mixed body $'| GRK-3522 | SPL-14 omnibox handle not a tab stop |\n| GRK-3523 | SPL-76 import the spec tasks |'
  row msg m-named body $'Issue SPL-40 in csitea, status wip.\nAlso SPL-1694.'
  row msg m-names-t1 body $'csitea\'s old SPL-44 and the spool-hub project\'s own SPL-44 (in t1) differ.'
  row msg m-dev body $'live on dev: a blocker became issue SPL-1 at 14:07Z'
  row msg m-commit body $'Landed as feat(orc, SPL-21): x\n\nCloses: SPL-22'
  row msg m-deleted body $'A second copy, SPL-36, was filed. I am deleting SPL-36.'
  row msg m-notkeys body $'XSPL-3 SPL-3a /x/SPL-3 SPL-03 spl-3'
  row issue 45 description $'Mirrors SPL-2398: every issue has an epic. First issue: SPL-23. Source: /t/64ce3bf5'
  row doc_item d-1 body $'# Plan\nSPL-2 is the finance epic.'
  echo '{"src":"issue","id":20,"field":"description","text":"Предишна стъпка: SPL-3","archived":true}'
  echo '{"src":"issue","id":21,"field":"description","text":"Предишна стъпка: SPL-3","archived":false}'
} >"$T/rows.jsonl"

out=$(python3 "$PY" --old SPL --samples 50 --plan "$T/plan.json" <"$T/rows.jsonl"); rc=$?
[[ $rc == 0 ]] && pass "classifier exit 0" || fail "classifier rc=$rc: $out"
has() { grep -qF -- "$1" <<<"$out" && pass "$2" || fail "$2 (no line: $1)"; }

# --- 1. planted t1 keys stay ------------------------------------------------------
has "SAMPLE keep not-ours SPL-3528 msg:m-t1" "t1 key SPL-3528 is keep/not-ours"
has "SAMPLE keep not-ours SPL-1687 msg:m-t1" "t1 key SPL-1687 is keep/not-ours"
has "SAMPLE keep not-ours SPL-1694 msg:m-named" "t1 key next to a csitea one is keep/not-ours"
has "SAMPLE keep not-ours SPL-76 msg:m-mixed" "t1 key in a lane table is keep/not-ours"
# --- 2. links ---------------------------------------------------------------------
[[ $(grep -c '^SAMPLE rewrite link SPL-35 msg:m-link' <<<"$out") == 2 ]] && pass "own-host link and its label are rewrite/link" || fail "own link: $out"
has "SAMPLE rewrite link SPL-37 msg:m-link" "relative /issues?issue= link is rewrite/link"
has "SAMPLE rewrite link SPL-40 msg:m-link" "locale-prefixed own link is rewrite/link"
[[ $(grep -c '^SAMPLE keep other-link SPL-12 msg:m-other-link' <<<"$out") == 2 ]] && pass "t1-host link and its label are keep/other-link" || fail "t1 link: $out"
has "SAMPLE keep other-link SPL-14 msg:m-other-link" "apex-host link is keep/other-link"
# --- 3. plain / named -------------------------------------------------------------
has "SAMPLE rewrite plain SPL-42 msg:m-plain" "live small key is rewrite/plain"
has "SAMPLE rewrite plain SPL-43 msg:m-plain" "second live small key is rewrite/plain"
has "SAMPLE rewrite named SPL-40 msg:m-named" "line naming csitea is rewrite/named, even with a t1 key in the text"
has "SAMPLE rewrite plain SPL-2 doc_item:d-1" "doc item key is rewrite/plain"
# --- 4. ambiguous -----------------------------------------------------------------
has "AMBIGUOUS mixed SPL-14 msg:m-mixed" "small key in a text with t1 keys is ambiguous/mixed"
[[ $(grep -c '^AMBIGUOUS names-other SPL-44 msg:m-names-t1' <<<"$out") == 2 ]] && pass "line naming t1 is ambiguous/names-other" || fail "names t1: $out"
has "AMBIGUOUS names-other SPL-1 msg:m-dev" "line saying 'on dev' is ambiguous/names-other"
has "AMBIGUOUS commit SPL-21 msg:m-commit" "commit scope is ambiguous/commit"
has "AMBIGUOUS commit SPL-22 msg:m-commit" "Closes: trailer is ambiguous/commit"
[[ $(grep -c '^AMBIGUOUS deleted SPL-36 msg:m-deleted' <<<"$out") == 2 ]] && pass "allocated but gone is ambiguous/deleted" || fail "deleted: $out"
has "AMBIGUOUS mixed SPL-23 issue:45" "issue description key is classified too"
# --- 5. not keys ------------------------------------------------------------------
grep -q 'msg:m-notkeys' <<<"$out" && fail "a non-key matched: $(grep m-notkeys <<<"$out")" || pass "XSPL-3, SPL-3a, /x/SPL-3, SPL-03, spl-3 are not keys"
has "COUNT total 9 8 9 1" "totals: 9 rewrite, 8 keep, 9 ambiguous, 1 archived"
has "COUNT msg 7 7 8 0" "msg counts"

# --- 6. the plan ------------------------------------------------------------------
applied=$(python3 - "$T/plan.json" "$T/rows.jsonl" <<'EOF'
import json, sys
plan = json.load(open(sys.argv[1]))
rows = {(r["src"], str(r["id"]), r["field"]): r["text"] for r in map(json.loads, open(sys.argv[2])) if r["src"] != "meta"}
bad = 0
for f in plan["fields"]:
    t = rows[(f["src"], str(f["id"]), f["field"])]
    assert f["text_len"] == len(t)
    for e in sorted(f["edits"], key=lambda e: -e["offset"]):
        if t[e["offset"]:e["offset"] + len(e["old"])] != e["old"]:
            bad += 1
        t = t[:e["offset"]] + e["new"] + t[e["offset"] + len(e["old"]):]
    rows[(f["src"], str(f["id"]), f["field"])] = t
print("BAD", bad, plan["old"], plan["new"], plan["tenant"])
for k, t in sorted(rows.items()):
    print("TEXT", k[1], t.replace("\n", " | "))
EOF
)
grep -qx 'BAD 0 SPL CSI csitea' <<<"$applied" && pass "every plan offset points at its old key" || fail "plan offsets: $applied"
for k in SPL-3528 SPL-1687 SPL-1694 SPL-76 SPL-12 SPL-14 SPL-44 SPL-1 SPL-21 SPL-22 SPL-36 SPL-23; do
  grep -q -- "$k\b" <<<"$applied" || fail "after the plan, $k is gone"
done
pass "after the plan every keep and ambiguous key is still there"
grep -qF 'TEXT m-plain The bank invoice is CSI-42, under the epic CSI-43.' <<<"$applied" && pass "plain keys read CSI-n" || fail "plain: $applied"
grep -qF '[CSI-35](https://csitea.example.test/issues?issue=CSI-35)' <<<"$applied" && pass "link label and url read CSI-n" || fail "link: $applied"
grep -qF 'TEXT m-named Issue CSI-40 in csitea, status wip. | Also SPL-1694.' <<<"$applied" && pass "named rewritten, its t1 neighbour kept" || fail "named: $applied"

# --- 7. the action ----------------------------------------------------------------
orc_stub 1 gcloud psql
act() { SNIPPET="$1" in_orc "${@:2}" 2>&1; }
o=$(act 'do_spl_issue_ref_scan' TENANT_ID=csitea DRY_RUN=0); rc=$?
[[ $rc != 0 && "$o" == *"read-only: DRY_RUN must be 1"* ]] && pass "DRY_RUN=0 is refused" || fail "DRY_RUN=0 rc=$rc: $o"
o=$(act 'do_spl_issue_ref_scan' "TENANT_ID=csitea'; drop"); rc=$?
[[ $rc != 0 && "$o" == *"TENANT_ID must be a tenant slug"* ]] && pass "bad TENANT_ID is refused" || fail "tenant rc=$rc: $o"
o=$(act 'do_spl_issue_ref_scan' TENANT_ID=csitea "OLD_PREFIX=SPL'"); rc=$?
[[ $rc != 0 && "$o" == *"OLD_PREFIX must be an issue prefix"* ]] && pass "bad OLD_PREFIX is refused" || fail "prefix rc=$rc: $o"
[[ ! -s "$T/calls.log" ]] && pass "CONTROL: no cloud call before the refusals" || fail "calls: $(cat "$T/calls.log")"
sql=$(act 'spl_issue_ref_scan_sql csitea SPL')
grep -qiE '\b(insert|update|delete|truncate|drop|alter|grant|create)\b' <<<"$sql" && fail "the scan SQL holds a write verb: $sql" || pass "the scan SQL holds no write verb"
[[ $(grep -c "tenant_id = 'csitea'" <<<"$sql") == 10 ]] && pass "every read is scoped to the tenant" || fail "tenant scope: $sql"
grep -q "BEGIN TRANSACTION READ ONLY" "$PROJ_ROOT/src/bash/run/spl-issue-ref-scan.func.sh" && pass "the read runs in a READ ONLY transaction" || fail "no READ ONLY"
o=$(act 'do_spl_cloud_cnf() { SPL_CNF=x; }; do_gcp_pin_account() { GCP_ACCOUNT=sa; }; do_gcp_require_live_account() { :; }
  spl_via_proxy() { shift; cat "$ROWS" >"$1"; }; do_spl_issue_ref_scan' TENANT_ID=csitea ROWS="$T/rows.jsonl" SCAN_PLAN="$T/plan2.json"); rc=$?
[[ $rc == 0 && "$o" == *"COUNT total 9 8 9 1"* && "$o" == *"nothing written; rewrite plan $T/plan2.json"* && -s "$T/plan2.json" ]] \
  && pass "through a stubbed proxy the action reports and writes SCAN_PLAN" || fail "action rc=$rc: $o"

# --- 9. archived / deleted issues -----------------------------------------------
has "ARCHIVED plain SPL-3 issue:20@17" "a rewrite key in an archived issue is listed as archived"
has "COUNT issue 1 1 1 1" "issue counts: the live copy rewrite, the archived one archived"
python3 - "$T/plan.json" <<'EOF_PY' && pass "the archived issue is not in the plan; the live one is" || fail "plan: $(cat "$T/plan.json")"
import json, sys
ids = {(f["src"], str(f["id"])) for f in json.load(open(sys.argv[1]))["fields"]}
sys.exit(0 if ("issue", "21") in ids and ("issue", "20") not in ids else 1)
EOF_PY
[[ $(grep -c "'archived', archived_at IS NOT NULL OR deleted_at IS NOT NULL" <<<"$sql") == 2 ]] \
  && pass "the scan SQL flags archived and deleted issues" || fail "archived flag: $sql"

# --- 8. still on the old prefix ---------------------------------------------------
o=$(sed 's/"prefix":"CSI"/"prefix":"SPL"/' "$T/rows.jsonl" | python3 "$PY" --old SPL); rc=$?
[[ $rc == 2 && "$o" == *"still uses prefix SPL"* ]] && pass "a workspace still on the old prefix is refused" || fail "same prefix rc=$rc: $o"

[[ $fails == 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAIL"; exit 1; }
