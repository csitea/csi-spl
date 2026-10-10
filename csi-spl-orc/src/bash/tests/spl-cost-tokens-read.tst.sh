#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_tokens_read (spec 123 section 4.3) on synthetic
# transcripts and spool agent records in a mktemp dir; no live file is read.
#   1. a bad DAY is refused (exit 2), nothing written
#   2. dedupe: one message id on 3 rows (output 100 each) counts once, the
#      MAX of each field kept; control: the same code with a per-row sum
#      reads 307, not 107
#   3. the exact sums of every kind, per agent, model and service_tier; a
#      row of another day is not counted
#   4. a <synthetic> zero-usage row is skipped and counted as skipped
#   5. an id listed in COST_METERED_IDS is skipped (counted once); without
#      the list it is counted
#   6. attribution: the agent record naming the session (a subagent file
#      too), else the -wt-<id> project dir
#   7. another vendor's agent seen that day gets one "unmetered" row, never
#      0; a claude agent in the day log gets none
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DAY=2026-10-09 R="$T/spool" P="$T/projects" S2=22222222-2222-2222-2222-222222222222
mkdir -p "$R/agents" "$R/dispatch" "$P/-opt-x-wt-c-101" "$P/-opt/$S2/subagents"
# row <ts> <model> <id> <in> <out> <cache_read> <cache_creation>
row() {
  printf '{"type":"assistant","timestamp":"%s","uuid":"u","message":{"id":"%s","model":"%s","content":[],"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"service_tier":"standard"}}}\n' \
    "$1" "$3" "$2" "$4" "$5" "$6" "$7"
}
{
  row "${DAY}T01:00:00.000Z" m-x msg_A 2 100 0 50
  row "${DAY}T01:00:01.000Z" m-x msg_A 2 100 500 50
  row "${DAY}T01:00:02.000Z" m-x msg_A 2 100 1000 50
  row "${DAY}T02:00:00.000Z" m-x msg_B 5 7 11 13
  row "${DAY}T03:00:00.000Z" "<synthetic>" msg_S 0 0 0 0
  row "${DAY}T04:00:00.000Z" m-x msg_M 1000 1000 1000 1000
  row "2026-10-08T23:59:59.000Z" m-x msg_OLD 9 9 9 9
  echo '{"type":"user","timestamp":"'"$DAY"'T01:00:00.000Z","message":{"role":"user","content":"x"}}'
} > "$P/-opt-x-wt-c-101/11111111-1111-1111-1111-111111111111.jsonl"
row "${DAY}T05:00:00.000Z" m-y msg_C 1 2 3 4 > "$P/-opt/$S2/subagents/agent-a1.jsonl"
printf '{\n "id": "c-102",\n "kind": "claude",\n "session_id": "%s",\n "updated_at": "%sT05:00:00Z"\n}\n' "$S2" "$DAY" > "$R/agents/c-102.json"
printf '{\n "id": "g-201",\n "kind": "grok",\n "session_id": null,\n "updated_at": "%sT06:00:00Z"\n}\n' "$DAY" > "$R/agents/g-201.json"
printf '{\n "id": "a-301",\n "kind": "agy",\n "updated_at": "2026-10-01T00:00:00Z"\n}\n' > "$R/agents/a-301.json"
printf '1791000000 a-301 run\n1791000000 c-101 run\n' > "$R/dispatch/agent-run-$DAY.log"
echo msg_M > "$T/metered"

# run_read <func file> [VAR=val...]: the action on the fixture; prints its output
run_read() {
  local f="$1"; shift
  env SPOOL_ROOT="$R" COST_TRANSCRIPT_DIRS="$P" COST_DAY_DIR="$T/cost" DAY="$DAY" "$@" bash -c '
    source "$0"; do_spl_cost_tokens_read' "$f" 2>&1
}
F="$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh"
OUT="$T/cost/tokens-$DAY.tsv"
units() { awk -F'\t' -v a="$1" -v k="$2" '$2 == a && $6 == k {print $7}' "$OUT"; }

out="$(run_read "$F" DAY=2026-13-01)"; rc=$?
[[ "$rc" == 2 && "$out" == *"FATAL DAY"* && ! -e "$T/cost" ]] && pass "1. a bad DAY is refused (exit 2), nothing written" || fail "1. rc=$rc $out"

run_read "$F" COST_METERED_IDS="$T/metered" >/dev/null
[[ "$(units c-101 output)" == 107 && "$(units c-101 cache_read)" == 1011 ]] &&
  pass "2. one message id on 3 rows counts once, the max of each field kept" || fail "2. dedupe: $(cat "$OUT")"
cp "$F" "$T/naive.func.sh"
python3 - "$T/naive.func.sh" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
old = 'if ($k > mx[$4, k]) mx[$4, k] = $k'
assert old in s; open(p, 'w').write(s.replace(old, 'mx[$4, k] += $k'))
EOF
run_read "$T/naive.func.sh" COST_METERED_IDS="$T/metered" >/dev/null
[[ "$(units c-101 output)" == 307 ]] && pass "2. control: a per-row sum reads 307 (the guard is what makes it 107)" || fail "2. control: $(units c-101 output)"

out="$(run_read "$F" COST_METERED_IDS="$T/metered")"
[[ "$(units c-101 input)" == 7 && "$(units c-101 cache_creation)" == 63 &&
   "$(awk -F'\t' '$2 == "c-101" && $6 == "output" {print $4, $5, $3}' "$OUT")" == "m-x standard claude" ]] &&
  pass "3. exact sums per agent, model, tier and kind; the other day's row is not counted" || fail "3. sums: $(cat "$OUT")"
[[ "$out" == *"rows=7 ids=3 synthetic_skipped=1 metered_skipped=1"* && "$out" == *"# output per_row=1309 per_id=109"* ]] &&
  pass "3. stats: rows, distinct ids, per-row vs per-id totals" || fail "3. stats: $out"
! grep -q '<synthetic>' "$OUT" && pass "4. a <synthetic> zero-usage row is skipped" || fail "4. synthetic: $(cat "$OUT")"

[[ "$out" == *"metered_skipped=1"* && "$(units c-101 output)" == 107 ]] &&
  pass "5. a metered message id is skipped" || fail "5. metered: $out"
run_read "$F" >/dev/null
[[ "$(units c-101 output)" == 1107 ]] && pass "5. control: without the metered list it is counted" || fail "5. control: $(units c-101 output)"

[[ "$(units c-102 output)" == 2 ]] && pass "6. a subagent file is attributed through its session's agent record" || fail "6. record: $(cat "$OUT")"
! grep -q 'unattributed' "$OUT" && pass "6. a -wt-<id> project dir names its agent" || fail "6. slug: $(cat "$OUT")"

[[ "$(units g-201 tokens)" == unmetered && "$(units a-301 tokens)" == unmetered &&
   "$(grep -c unmetered "$OUT")" == 2 && "$(grep -cP '\tclaude\t-\t' "$OUT")" == 0 ]] &&
  pass "7. other vendors (record updated that day, or in the day log) read unmetered, never 0; claude none" || fail "7. unmetered: $(cat "$OUT")"

echo "spl-cost-tokens-read: ${fails} failure(s)"
[ "$fails" -eq 0 ]
