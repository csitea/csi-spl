#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_rollup_daily and the cost-source factory (spec 123
# sections 4.5, 4.6 and 8, build lane 4) on synthetic transcripts, lease-tick
# day logs and a fake iac estate reader in a mktemp dir. The hub is a stub
# that records every POST /v1/operator/cost/day body; no cloud is called.
#   1. no ENV and a bad DAY are refused, nothing posted
#   2. Source factory: a stub source registered by one function plus its cnf
#      entry is posted as stub.<box>; control: the rollup with a hard-coded
#      source list (the factory bypassed) never posts it
#   3. a listed source that is not registered is posted `missing` with the
#      reason, and the others still post
#   4. Rollup accuracy: the posted units are the exact fixture sums (tokens
#      per agent, model, kind.tier; agent-seconds); control: a body builder
#      that doubles the units fails the same check
#   5. Idempotency: a second run posts the same rows (the hub UPSERTs them,
#      store TestCostIngestIdempotent)
#   6. No double count: a turn in COST_METERED_IDS (the hub's metered turns)
#      is not posted from the transcript; control: without the list it is
#   7. Unmetered: another vendor's agent is posted as kind `unmetered`, never
#      a 0 count, and its day is `partial`; control: without the rule the day
#      reads ok (summed as whole)
#   8. Coverage: a source whose read fails (no lease-tick day log) is posted
#      `missing` with its reason and no line, the day summary is partial
#   9. Late GCP row: the gcp source re-reads the env.cost.reread_days window,
#      so a revised cost of day D-2 is written on night D; control: with
#      reread_days 1 it keeps the old cost
#  10. DRY_RUN=1 (default): every source read, nothing posted, no login, the
#      gcp reader runs dry
#  11. the output carries counts and states, never a token total
#  12. the box readers post their own day file with ENV and DRY_RUN=0 (as
#      <name>.<box>), and say "file only" without
#  13. the lease tick's day logs older than env.cost.day_log_keep_days are
#      pruned (by the day in the name, never the mtime); DRY_RUN prunes
#      nothing; control: the rollup without the prune keeps them all
#  14. Backfill (SPL-2086), no DAY given: (a) 10-14 missing from the post
#      ledger, 10-08..10-13 present -> posts 10-14, then yesterday 10-15;
#      (b) all present -> posts yesterday only
#  15. Backfill DRY_RUN=1: lists the days it would post, posts nothing
#  16. the hub login (gcloud SA key activation) fails twice, then works:
#      3 tries, waits 10 and 30 s, posts
#  17. it fails 3 times: FATAL names 'after 3 tries', nothing posted
#  18. RED CONTROL: the old action (before ac699baf1) on scenario (a) posts
#      only yesterday (10-14 stays a hole)
#  19. posting the same day twice is safe: a backfilled day is never
#      re-posted; an explicit DAY= re-post sends the same rows (the hub
#      UPSERTs them, store TestCostIngestIdempotent)
#  20. a failed backfill post: its day line says failed (reason), yesterday
#      still posts, the run fails, and the next run posts the day
#  21. a day posted `missing` is tried again the next night
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DAY=2026-10-09 R="$T/spool" P="$T/projects"
mkdir -p "$R/agents" "$R/dispatch" "$P/-opt-x-wt-c-101" "$T/iac"
row() {
  printf '{"type":"assistant","timestamp":"%s","uuid":"u","message":{"id":"%s","model":"%s","content":[],"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"service_tier":"standard"}}}\n' \
    "$1" "$3" "$2" "$4" "$5" "$6" "$7"
}
{
  row "${DAY}T01:00:00.000Z" m-x msg_A 2 100 0 50
  row "${DAY}T01:00:01.000Z" m-x msg_A 2 100 500 50
  row "${DAY}T01:00:02.000Z" m-x msg_A 2 100 1000 50
  row "${DAY}T02:00:00.000Z" m-x msg_B 5 7 11 13
  row "${DAY}T04:00:00.000Z" m-x msg_M 1000 1000 1000 1000
} > "$P/-opt-x-wt-c-101/11111111-1111-1111-1111-111111111111.jsonl"
printf '{\n "id": "g-201",\n "kind": "grok",\n "updated_at": "%sT06:00:00Z"\n}\n' "$DAY" > "$R/agents/g-201.json"
printf '900 c-101 run\n' > "$R/dispatch/agent-run-2026-10-08.log"
printf '1000 c-101 run\n1000 g-201 run\n1060 c-101 run\n1060 g-201 stop\n' > "$R/dispatch/agent-run-$DAY.log"
echo msg_M > "$T/metered"

# The cnf the rollup reads (env.cost), and a fake csi-spl-iac whose estate
# reader windows env.cost.reread_days days ending DAY over $T/export into $T/gcp.db.
cnf() { printf 'env:\n  cost:\n    reread_days: %s\n    sources: [%s]\n    day_log_keep_days: %s\n    backfill_days: %s\n' "$1" "$2" "${3:-}" "${4:-7}" > "$T/cnf.yaml"; }
cat > "$T/iac/run" <<'EOF'
#!/bin/bash
[[ "$2" == do_spl_estate_cost_read ]] || exit 9
echo "ENV=$ENV DAY=$DAY DRY_RUN=$DRY_RUN" >> "$FAKE_DIR/gcp.calls"
n="$(yq -r '.env.cost.reread_days' "$FAKE_DIR/cnf.yaml")"
for ((i = n - 1; i >= 0; i--)); do
  d="$(date -u -d "$DAY -$i day" +%F)"; c="$(awk -v d="$d" '$1 == d {print $2}' "$FAKE_DIR/export")"
  [[ -n "$c" && "$DRY_RUN" == 0 ]] || continue
  { grep -v "^$d " "$FAKE_DIR/gcp.db" 2>/dev/null; echo "$d $c"; } > "$FAKE_DIR/gcp.db.t"; mv "$FAKE_DIR/gcp.db.t" "$FAKE_DIR/gcp.db"
done
echo "OK fake window ending $DAY"
EOF
chmod +x "$T/iac/run"
: > "$T/export"

# run_rollup [VAR=val...]: the action on the fixture, every cloud edge
# stubbed; the posted bodies go to $T/posts.jsonl, the logins to $T/logins.
run_rollup() {
  local rollup="${ROLLUP_FILE:-$PROJ_ROOT/src/bash/run/spl-cost-rollup-daily.func.sh}"
  local factory="${FACTORY_FILE:-$PROJ_ROOT/lib/bash/funcs/spl-cost-source.func.sh}"
  local tokens="${TOKENS_FILE:-$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh}"
  env SPOOL_ROOT="$R" COST_TRANSCRIPT_DIRS="$P" COST_DAY_DIR="$T/cost" COST_BOX=box-a COST_IAC_DIR="$T/iac" \
    FAKE_DIR="$T" PROJ_PATH="$T/csi-spl-orc" DAY="$DAY" ENV=dev "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    spl_require_cloud_env() { [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { echo "FATAL ENV must be dev or prd"; return 1; }; }
    do_spl_cloud_cnf() { spl_require_cloud_env && SPL_CNF="$FAKE_DIR/cnf.yaml"; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { echo login >> "$FAKE_DIR/logins"; GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "$3" >> "$FAKE_DIR/posts.jsonl"; SPL_HUB_OP_STATUS=200
      SPL_HUB_OP_BODY="$(jq -c "{day, source, state: .coverage.state, lines: (.lines | length), written: (.lines | length), removed: 0}" <<<"$3")"
    }
    sleep() { echo "$1" >> "$FAKE_DIR/sleeps"; }
    spl_cost_source_stub() { printf "stubco\t-\t-\tstub_kind\t42\ttranscript\n" > "$2.lines"; printf "ok\n" > "$2.cov"; }
    source "$0"; source "$1"; source "$2"
    source "$3/src/bash/run/spl-cost-agent-hours-read.func.sh"; source "$3/lib/bash/funcs/spl-cost-source-gcp.func.sh"
    [[ -r "$FAKE_DIR/stubs.sh" ]] && source "$FAKE_DIR/stubs.sh"
    do_spl_cost_rollup_daily' "$rollup" "$factory" "$tokens" "$PROJ_ROOT" 2>&1
}
reset() { rm -f "$T/posts.jsonl" "$T/logins" "$T/gcp.calls" "$T/sleeps" "$T/stubs.sh"; }
# posted <source> <jq>: the jq of the last body posted for source
posted() { jq -c --arg s "$1" "select(.source == \$s) | $2" "$T/posts.jsonl" 2>/dev/null | tail -n 1; }
unit() { posted "$1" ".lines[] | select(.agent_id == \"$2\" and .kind == \"$3\") | .units"; }

cnf 5 "gcp, fleet_tokens, agent_hours"
reset
out="$(run_rollup ENV=)"; rc=$?
out2="$(run_rollup DAY=2026-10-32 DRY_RUN=0)"; rc2=$?
[[ "$rc" != 0 && "$rc2" != 0 && "$out" == *"FATAL ENV"* && "$out2" == *"FATAL DAY"* && ! -e "$T/posts.jsonl" ]] &&
  pass "1. no ENV and a bad DAY are refused, nothing posted" || fail "1. $rc $out / $rc2 $out2"

# 2. the factory -----------------------------------------------------------------
cnf 5 "fleet_tokens, stub"
reset
run_rollup DRY_RUN=0 >/dev/null
[[ "$(posted stub.box-a '.lines[0].units')" == 42 && "$(posted stub.box-a '.coverage.state')" == '"ok"' ]] &&
  pass "2. a stub source (a function + its cnf entry) is posted as stub.box-a" || fail "2. stub: $(cat "$T/posts.jsonl" 2>/dev/null)"
cp "$PROJ_ROOT/src/bash/run/spl-cost-rollup-daily.func.sh" "$T/hardcoded.func.sh"
python3 - "$T/hardcoded.func.sh" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
old = 'mapfile -t names < <(spl_cost_sources "$SPL_CNF")'
assert old in s; open(p, 'w').write(s.replace(old, 'names=(gcp fleet_tokens agent_hours)'))
EOF
reset
ROLLUP_FILE="$T/hardcoded.func.sh" run_rollup DRY_RUN=0 >/dev/null
[[ -z "$(posted stub.box-a '.source')" && -n "$(posted fleet_tokens.box-a '.source')" ]] &&
  pass "2. control: with a hard-coded source list the stub's rows are missing" || fail "2. control: $(cat "$T/posts.jsonl")"

# 3. a listed source nobody registered ---------------------------------------------
cnf 5 "nosuch, agent_hours"
reset
out="$(run_rollup DRY_RUN=0)"; rc=$?
[[ "$rc" == 0 && "$(posted nosuch.box-a '.coverage.state')" == '"missing"' && "$(posted nosuch.box-a '.coverage.reason')" == *"no cost source 'nosuch' is registered"* &&
   "$(posted nosuch.box-a '.lines | length')" == 0 && "$(posted agent_hours.box-a '.coverage.state')" == '"ok"' ]] &&
  pass "3. an unregistered source is posted missing with the reason; the others still post" || fail "3. rc=$rc $out"

# 4..7 the box sources ----------------------------------------------------------------
cnf 5 "gcp, fleet_tokens, agent_hours"
reset
out="$(run_rollup DRY_RUN=0 COST_METERED_IDS="$T/metered")"; rc=$?
[[ "$rc" == 0 && "$(unit fleet_tokens.box-a c-101 output.standard)" == 107 && "$(unit fleet_tokens.box-a c-101 cache_read.standard)" == 1011 &&
   "$(unit fleet_tokens.box-a c-101 input.standard)" == 7 && "$(unit fleet_tokens.box-a c-101 cache_creation.standard)" == 63 &&
   "$(posted fleet_tokens.box-a '.lines[] | select(.agent_id == "c-101" and .kind == "output.standard") | [.project_or_vendor, .model, .origin] | join(" ")')" == '"claude m-x transcript"' &&
   "$(unit agent_hours.box-a c-101 agent_seconds)" == 160 && "$(posted agent_hours.box-a '.lines[] | select(.agent_id == "c-101") | .origin')" == '"agent_run"' ]] &&
  pass "4. rollup accuracy: the exact fixture sums are posted (tokens per kind.tier, agent-seconds)" || fail "4. rc=$rc $out $(cat "$T/posts.jsonl")"
cp "$PROJ_ROOT/lib/bash/funcs/spl-cost-source.func.sh" "$T/double.func.sh"
python3 - "$T/double.func.sh" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
old = 'units: (.[4] | tonumber)'
assert old in s; open(p, 'w').write(s.replace(old, 'units: ((.[4] | tonumber) * 2)'))
EOF
cp "$T/posts.jsonl" "$T/posts.good"
reset
FACTORY_FILE="$T/double.func.sh" run_rollup DRY_RUN=0 COST_METERED_IDS="$T/metered" >/dev/null
[[ "$(unit fleet_tokens.box-a c-101 output.standard)" == 214 ]] &&
  pass "4. control: a body builder that doubles the units reads 214, not 107" || fail "4. control: $(unit fleet_tokens.box-a c-101 output.standard)"

reset
run_rollup DRY_RUN=0 COST_METERED_IDS="$T/metered" >/dev/null
norm() { jq -c 'del(.run_id)' "$1"; }
[[ -s "$T/posts.good" && "$(norm "$T/posts.jsonl")" == "$(norm "$T/posts.good")" ]] &&
  pass "5. idempotency: a second run posts the same rows (the hub UPSERTs them)" || fail "5. $(diff <(norm "$T/posts.good") <(norm "$T/posts.jsonl"))"

[[ "$(unit fleet_tokens.box-a c-101 output.standard)" == 107 ]] &&
  pass "6. no double count: the hub-metered turn is not posted from the transcript" || fail "6. $(unit fleet_tokens.box-a c-101 output.standard)"
reset
run_rollup DRY_RUN=0 >/dev/null
[[ "$(unit fleet_tokens.box-a c-101 output.standard)" == 1107 ]] &&
  pass "6. control: without the metered list the turn counts twice (1107)" || fail "6. control: $(unit fleet_tokens.box-a c-101 output.standard)"

[[ "$(posted fleet_tokens.box-a '.lines[] | select(.agent_id == "g-201") | [.project_or_vendor, .kind, .units] | join(" ")')" == '"grok unmetered 0"' &&
   "$(posted fleet_tokens.box-a '.coverage.state')" == '"partial"' && "$(posted fleet_tokens.box-a '.coverage.reason')" == *"1 agent(s) of another vendor unmetered"* ]] &&
  pass "7. unmetered: another vendor's agent is kind unmetered (no count) and the day is partial" || fail "7. $(posted fleet_tokens.box-a '.')"
cp "$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh" "$T/nounm.func.sh"
python3 - "$T/nounm.func.sh" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
old = '$7 == "unmetered" { print $3, $2, "-", "unmetered", 0, "transcript"; unm++; next }'
assert old in s; open(p, 'w').write(s.replace(old, '$7 == "unmetered" { next }'))
EOF
reset
TOKENS_FILE="$T/nounm.func.sh" run_rollup DRY_RUN=0 >/dev/null
[[ "$(posted fleet_tokens.box-a '.coverage.state')" == '"ok"' ]] &&
  pass "7. control: without the unmetered rule the day reads ok, summed as whole" || fail "7. control: $(posted fleet_tokens.box-a '.coverage')"

# 8. a source whose read fails ---------------------------------------------------------
mv "$R/dispatch/agent-run-$DAY.log" "$T/day.log.away"
reset
out="$(run_rollup DRY_RUN=0)"; rc=$?
mv "$T/day.log.away" "$R/dispatch/agent-run-$DAY.log"
[[ "$rc" == 0 && "$(posted agent_hours.box-a '.coverage.state')" == '"missing"' && "$(posted agent_hours.box-a '.coverage.reason')" == *"FATAL agent_hours: no day log"* &&
   "$(posted agent_hours.box-a '.lines | length')" == 0 && "$out" == *"missing=1"*"day_state=partial"* ]] &&
  pass "8. coverage: a failed read is posted missing with its reason, no line; the day is partial" || fail "8. rc=$rc $out"

# 9. the GCP re-read window ------------------------------------------------------------
late() { # <reread_days>: night 10-07 sees cost 1 for 10-07, the export revises it to 2, night 10-09 runs
  cnf "$1" "gcp"; rm -f "$T/gcp.db"; reset
  echo "2026-10-07 1" > "$T/export"; run_rollup DRY_RUN=0 DAY=2026-10-07 >/dev/null
  echo "2026-10-07 2" > "$T/export"; run_rollup DRY_RUN=0 DAY=2026-10-09 >/dev/null
  awk '$1 == "2026-10-07" {print $2}' "$T/gcp.db"
}
v5="$(late 5)"
[[ "$v5" == 2 && "$(tail -n 1 "$T/gcp.calls")" == "ENV=dev DAY=2026-10-09 DRY_RUN=0" && ! -e "$T/posts.jsonl" ]] &&
  pass "9. late GCP row: night 10-09 re-reads the 5-day window, 10-07 now holds the revised cost; gcp writes its own rows" || fail "9. got '$v5' $(cat "$T/gcp.calls")"
v1="$(late 1)"
[[ "$v1" == 1 ]] && pass "9. control: with reread_days 1 the revised 10-07 keeps the old cost" || fail "9. control: '$v1'"

# 10. DRY_RUN ---------------------------------------------------------------------------
cnf 5 "gcp, fleet_tokens, agent_hours"
reset
out="$(run_rollup)"; rc=$?
[[ "$rc" == 0 && ! -e "$T/posts.jsonl" && ! -e "$T/logins" && "$(cat "$T/gcp.calls")" == "ENV=dev DAY=$DAY DRY_RUN=1" &&
   "$out" == *"fleet_tokens.box-a $DAY state=partial lines="*"OK DRY_RUN read 3 source(s), posted nothing"* ]] &&
  pass "10. DRY_RUN=1: every source read, nothing posted, no login, gcp read dry" || fail "10. rc=$rc $out"

# 11. the data rule ---------------------------------------------------------------------
out="$(run_rollup DRY_RUN=0 COST_METERED_IDS="$T/metered")"
# the run id carries the clock (cost-rollup-<box>-<UTC stamp>-<pid>): on
# 2026-10-11 it held "1011", so the totals are looked for without it
nums="$(sed -E 's/cost-rollup-[^ )]*//g' <<<"$out")"
[[ "$nums" != *107* && "$nums" != *1011* && "$nums" != *" 160"* && "$out" == *"lines="* ]] &&
  pass "11. the output carries counts and states, never a token or seconds total" || fail "11. $out"

# 12. the readers post their own file ---------------------------------------------------
reader() { # <action> [VAR=val...]
  local a="$1"; shift
  env SPOOL_ROOT="$R" COST_TRANSCRIPT_DIRS="$P" COST_DAY_DIR="$T/cost" COST_BOX=box-a DAY="$DAY" FAKE_DIR="$T" "$@" bash -c '
    do_log() { echo "$*"; }
    do_spl_cloud_cnf() { SPL_CNF="$FAKE_DIR/cnf.yaml"; }
    spl_hub_operator_url() { :; }
    do_gcp_pin_account() { echo login >> "$FAKE_DIR/logins"; GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() { echo "$3" >> "$FAKE_DIR/posts.jsonl"; SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="{\"state\":\"ok\",\"lines\":1,\"written\":1,\"removed\":0}"; }
    source "$1/lib/bash/funcs/spl-cost-source.func.sh"
    source "$1/src/bash/run/spl-cost-tokens-read.func.sh"; source "$1/src/bash/run/spl-cost-agent-hours-read.func.sh"
    "$0"' "$a" "$PROJ_ROOT" 2>&1
}
reset
o1="$(reader do_spl_cost_tokens_read)"; o2="$(reader do_spl_cost_agent_hours_read ENV=prd)"
[[ "$o1" == *"file only, not posted"* && "$o2" == *"file only, not posted"* && ! -e "$T/posts.jsonl" ]] &&
  pass "12. without ENV and DRY_RUN=0 a reader writes its file only" || fail "12. $o1 / $o2"
o1="$(reader do_spl_cost_tokens_read ENV=prd DRY_RUN=0)"; o2="$(reader do_spl_cost_agent_hours_read ENV=prd DRY_RUN=0)"
[[ "$o1" == *"OK posted fleet_tokens.box-a $DAY"* && "$o2" == *"OK posted agent_hours.box-a $DAY"* &&
   "$(posted fleet_tokens.box-a '.run_id')" == *'"fleet_tokens-read-box-a-'* && "$(unit agent_hours.box-a c-101 agent_seconds)" == 160 ]] &&
  pass "12. with ENV and DRY_RUN=0 each reader posts its day as <name>.<box>" || fail "12. $o1 / $o2"

# 13. the day-log prune ---------------------------------------------------------------
D="$R/dispatch"
for d in 2026-08-01 2026-08-08 2026-08-09 2026-10-06 2026-10-07 2026-10-10; do echo "1000 c-101 run" > "$D/agent-run-$d.log"; done
touch "$D/agent-run-2026-08-01.log"; echo keep > "$D/agent-run.tsv"; echo keep > "$D/agent-run-notaday.log"
logs() { (cd "$D" && ls agent-run* | tr '\n' ' '); }
before="$(logs)"
cnf 5 "agent_hours" 3
out="$(run_rollup)"
[[ "$(logs)" == "$before" && "$out" == *"DRY_RUN would remove 4 before 2026-10-07 (keep 3 days), kept 4"* ]] &&
  pass "13. DRY_RUN: the 4 logs before the 3-day window are counted, none removed" || fail "13. dry: $out"
cp "$PROJ_ROOT/src/bash/run/spl-cost-rollup-daily.func.sh" "$T/noprune.func.sh"
python3 - "$T/noprune.func.sh" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
old = '  spl_cost_prune_day_logs "$day"'
assert old in s; open(p, 'w').write(s.replace(old, '  : spl_cost_prune_day_logs "$day"'))
PY
ROLLUP_FILE="$T/noprune.func.sh" run_rollup DRY_RUN=0 >/dev/null
[[ "$(logs)" == "$before" ]] && pass "13. control: without the prune every day log stays" || fail "13. control: $(logs)"
cnf 5 "agent_hours" 62
out="$(run_rollup DRY_RUN=0)"
[[ ! -e "$D/agent-run-2026-08-01.log" && ! -e "$D/agent-run-2026-08-08.log" && -e "$D/agent-run-2026-08-09.log" && "$out" == *"removed 2 before 2026-08-09 (keep 62 days)"* ]] &&
  pass "13. keep 62 (cnf): the logs before 2026-08-09 go (a fresh mtime does not save one), 08-09 stays" || fail "13. 62: $out $(logs)"
cnf 5 "agent_hours" 3
out="$(run_rollup DRY_RUN=0)"
[[ "$(logs)" == "agent-run-2026-10-07.log agent-run-2026-10-08.log agent-run-2026-10-09.log agent-run-2026-10-10.log agent-run-notaday.log agent-run.tsv " &&
   "$(posted agent_hours.box-a '.coverage.state')" == '"ok"' ]] &&
  pass "13. keep 3: the window ending DAY, the newer day and the other files stay; the read of DAY still works" || fail "13. 3: $out $(logs)"
cnf 5 "agent_hours" 1
out="$(run_rollup DRY_RUN=0)"
[[ "$(logs)" == *"agent-run-2026-10-08.log"* && "$out" == *"must be 2 or more"* ]] &&
  pass "13. keep 1 is refused (the read of DAY needs the day before), nothing pruned" || fail "13. 1: $out"

# 14..21 the backfill (SPL-2086) -------------------------------------------------------
# The night of 2026-10-16 with no DAY: yesterday is 10-15, the backfill window
# (backfill_days 7) is 10-08..10-14. The post ledger is $T/cost/posted-dev.tsv.
L="$T/cost/posted-dev.tsv"
for d in 2026-10-07 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13 2026-10-14 2026-10-15; do
  echo "1000 c-101 run" > "$D/agent-run-$d.log"
done
ledger() { rm -f "$L"; mkdir -p "$T/cost"; local d; for d; do printf '%s\tagent_hours.box-a\tok\tr0\t-\n' "$d" >> "$L"; done; }
days() { jq -r '.day' "$T/posts.jsonl" 2>/dev/null | tr '\n' ' '; }
night() { run_rollup DAY= COST_TODAY=2026-10-16 DRY_RUN=0 "$@"; }
body() { jq -c --arg d "$1" 'select(.day == $d) | del(.run_id)' "$2" 2>/dev/null; }
cnf 5 "agent_hours" 62 7

ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13
reset
out="$(night)"; rc=$?
[[ "$rc" == 0 && "$(days)" == "2026-10-14 2026-10-15 " && "$out" == *"INFO day 2026-10-14 agent_hours.box-a: posted (state=ok)"* &&
   "$out" == *"INFO day 2026-10-15 agent_hours.box-a: posted (state=ok)"* && "$(grep -c ': already present (ledger state=ok)' <<<"$out")" == 6 ]] &&
  pass "14. (a) backfill: 10-14 missing, 10-13 present -> posts 10-14, then yesterday 10-15" || fail "14. (a) rc=$rc days=$(days) $out"
ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13 2026-10-14
reset
out="$(night)"; rc=$?
[[ "$rc" == 0 && "$(days)" == "2026-10-15 " && "$(grep -c ': already present (ledger state=ok)' <<<"$out")" == 7 &&
   "$out" == *"posted 0, already present 7, failed 0"* ]] &&
  pass "14. (b) backfill: all 7 days present -> posts yesterday only" || fail "14. (b) rc=$rc days=$(days) $out"

ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13
reset
out="$(run_rollup DAY= COST_TODAY=2026-10-16)"; rc=$?
[[ "$rc" == 0 && ! -e "$T/posts.jsonl" && ! -e "$T/logins" && "$(wc -l < "$L")" == 6 &&
   "$out" == *"INFO day 2026-10-14 agent_hours.box-a: DRY_RUN would post (not in the ledger)"* && "$out" == *"DRY_RUN would post 1"* ]] &&
  pass "15. backfill DRY_RUN=1: lists the day it would post, posts nothing, no login, the ledger unchanged" || fail "15. rc=$rc $out"

# a do_gcp_pin_account that fails its first FAIL_LOGINS calls (the 10-15 02:00Z night)
cat > "$T/flaky.sh" <<'STUB'
do_gcp_pin_account() {
  echo login >> "$FAKE_DIR/logins"
  (( $(wc -l < "$FAKE_DIR/logins") > FAIL_LOGINS )) || { echo "FATAL gcloud could not activate the SA key (stub)"; return 1; }
  GCP_ACCOUNT=sa@example.iam.gserviceaccount.com
}
STUB
ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13 2026-10-14
reset; cp "$T/flaky.sh" "$T/stubs.sh"
out="$(night FAIL_LOGINS=2)"; rc=$?
[[ "$rc" == 0 && "$(wc -l < "$T/logins")" == 3 && "$(tr '\n' ' ' < "$T/sleeps")" == "10 30 " && "$(days)" == "2026-10-15 " &&
   "$out" == *"failed on try 1/3, next try in 10 s"* && "$out" == *"worked on try 3/3"* ]] &&
  pass "16. the login fails twice, then works: 3 tries, waits 10 and 30 s, yesterday posted" || fail "16. rc=$rc $(cat "$T/sleeps" 2>/dev/null) $out"
cp "$PROJ_ROOT/src/bash/run/spl-cost-rollup-daily.func.sh" "$T/onetry.func.sh"
python3 - "$T/onetry.func.sh" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
old = 'local tries=3 try wait'
assert old in s; open(p, 'w').write(s.replace(old, 'local tries=1 try wait'))
PY
reset; cp "$T/flaky.sh" "$T/stubs.sh"
out="$(ROLLUP_FILE="$T/onetry.func.sh" night FAIL_LOGINS=2)"; rc=$?
[[ "$rc" != 0 && ! -e "$T/posts.jsonl" ]] &&
  pass "16. control: with one try the same flaky login posts nothing" || fail "16. control: rc=$rc $out"

reset; cp "$T/flaky.sh" "$T/stubs.sh"
out="$(night FAIL_LOGINS=3)"; rc=$?
[[ "$rc" != 0 && ! -e "$T/posts.jsonl" && "$(wc -l < "$T/logins")" == 3 && "$(tr '\n' ' ' < "$T/sleeps")" == "10 30 " &&
   "$out" == *"FATAL the dev hub login (the SA key activation) failed after 3 tries"* ]] &&
  pass "17. the login fails 3 times: FATAL 'after 3 tries', nothing posted" || fail "17. rc=$rc $out"

# 18. RED CONTROL: the action as it was before ac699baf1 (no backfill). The
# cron calls it with no DAY, so on the night of 10-16 it reads DAY=10-15.
git -C "$PROJ_ROOT" show ac699baf1~1:csi-spl-orc/src/bash/run/spl-cost-rollup-daily.func.sh > "$T/old.func.sh" 2>/dev/null; old="before ac699baf1"
if ! grep -q '^do_spl_cost_rollup_daily()' "$T/old.func.sh"; then
  old="the action with its backfill cut (no git history here)"
  python3 - "$PROJ_ROOT/src/bash/run/spl-cost-rollup-daily.func.sh" "$T/old.func.sh" <<'PY'
import sys; s = open(sys.argv[1]).read()
old = '    spl_cost_backfill "$day"'
assert old in s; open(sys.argv[2], 'w').write(s.replace(old, '    : spl_cost_backfill "$day"'))
PY
fi
ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13
reset
out="$(ROLLUP_FILE="$T/old.func.sh" run_rollup DAY=2026-10-15 DRY_RUN=0)"; rc=$?
[[ "$rc" == 0 && "$(days)" == "2026-10-15 " && "$out" != *"2026-10-14"* ]] &&
  pass "18. red control: the old action ($old) on scenario (a) posts only 10-15; 10-14 stays a hole" || fail "18. rc=$rc days=$(days) $out"

# 19. the same day twice ---------------------------------------------------------------
ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13
reset
night >/dev/null; cp "$T/posts.jsonl" "$T/posts.first"
reset
out="$(night)"; rc=$?
[[ "$rc" == 0 && "$(days)" == "2026-10-15 " && "$out" == *"INFO day 2026-10-14 agent_hours.box-a: already present (ledger state=ok)"* &&
   -n "$(body 2026-10-15 "$T/posts.first")" && "$(body 2026-10-15 "$T/posts.jsonl")" == "$(body 2026-10-15 "$T/posts.first")" ]] &&
  pass "19. the second night does not re-post the backfilled 10-14; yesterday is re-sent with the same rows" || fail "19. rc=$rc days=$(days) $out"
reset
run_rollup DAY=2026-10-14 DRY_RUN=0 >/dev/null
[[ -n "$(body 2026-10-14 "$T/posts.first")" && "$(body 2026-10-14 "$T/posts.jsonl")" == "$(body 2026-10-14 "$T/posts.first")" ]] &&
  pass "19. an explicit DAY=10-14 re-post sends the same rows (the hub UPSERTs: TestCostIngestIdempotent)" || fail "19. explicit: $(cat "$T/posts.jsonl")"
mv "$D/agent-run-2026-10-14.log" "$T/day14.away"
reset
night >/dev/null
[[ "$(days)" == "2026-10-15 " ]] &&
  pass "19. 10-14's day log gone: the present day is not re-read, so it is never re-posted missing" || fail "19. away: $(days)"
cp "$PROJ_ROOT/src/bash/run/spl-cost-rollup-daily.func.sh" "$T/noledger.func.sh"
python3 - "$T/noledger.func.sh" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
old = '  [[ -r "$f" ]] || return 1\n'
assert old in s; open(p, 'w').write(s.replace(old, '  return 1\n'))
PY
reset
ROLLUP_FILE="$T/noledger.func.sh" night >/dev/null
[[ "$(posted agent_hours.box-a 'select(.day == "2026-10-14") | .coverage.state')" == '"missing"' ]] &&
  pass "19. control: without the ledger the posted 10-14 is re-posted missing over its ok day" || fail "19. control: $(cat "$T/posts.jsonl")"
mv "$T/day14.away" "$D/agent-run-2026-10-14.log"

# 20. a failed backfill post -----------------------------------------------------------
cat > "$T/hub500.sh" <<'STUB'
spl_hub_operator_call() {
  if [[ "$(jq -r .day <<<"$3")" == 2026-10-14 ]]; then SPL_HUB_OP_STATUS=500; SPL_HUB_OP_BODY='{"error":"boom"}'; return 0; fi
  echo "$3" >> "$FAKE_DIR/posts.jsonl"; SPL_HUB_OP_STATUS=200
  SPL_HUB_OP_BODY="$(jq -c "{day, source, state: .coverage.state, lines: (.lines | length), written: (.lines | length), removed: 0}" <<<"$3")"
}
STUB
ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13
reset; cp "$T/hub500.sh" "$T/stubs.sh"
out="$(night)"; rc=$?
[[ "$rc" != 0 && "$(days)" == "2026-10-15 " && "$out" == *"INFO day 2026-10-14 agent_hours.box-a: failed (the hub answered http 500)"* &&
   "$out" == *"FATAL 1 source day(s) were not posted to the dev hub"* ]] &&
  pass "20. a refused backfill post: its line says failed (http 500), yesterday still posts, the run fails" || fail "20. rc=$rc days=$(days) $out"
reset
out="$(night)"; rc=$?
[[ "$rc" == 0 && "$(days)" == "2026-10-14 2026-10-15 " ]] &&
  pass "20. the next night posts the failed 10-14, then yesterday" || fail "20. next: rc=$rc days=$(days) $out"

# 21. a missing post is tried again ----------------------------------------------------
ledger 2026-10-08 2026-10-09 2026-10-10 2026-10-11 2026-10-12 2026-10-13
printf '2026-10-14\tagent_hours.box-a\tmissing\tr0\t-\n' >> "$L"
reset
out="$(night)"; rc=$?
[[ "$rc" == 0 && "$(days)" == "2026-10-14 2026-10-15 " ]] &&
  pass "21. a day posted missing is read and posted again the next night" || fail "21. rc=$rc days=$(days) $out"

echo "spl-cost-rollup-daily: ${fails} failure(s)"
[ "$fails" -eq 0 ]
