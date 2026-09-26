#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the search scale actions (specs/022 §9, CLE-34992), offline:
#   1. do_spl_search_seed and do_spl_search_seed_purge refuse prd and any tenant
#      not named seed-*, BEFORE gcloud or psql is called. CONTROL: the same
#      action with valid knobs is accepted
#   2. the seed SQL: one INSERT per batch, resumable, only the seed- tenant
#   3. the purge SQL deletes only with DRY_RUN=0, guarded by LIKE 'seed-%'
#   4. the measure session is read-only (default_transaction_read_only), in the
#      TENANT scope (never the operator scope), starts no statement with a write verb, pairs every
#      topic query before/after, and refuses an unknown MEASURE_ONLY
#   5. the summary turns Execution Time lines into p50 / p95 / max
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud psql docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. refusals before any cloud call ----------------------------------------------
: >"$T/calls.log"
for c in "ENV=prd:do_spl_search_seed" "ENV=prd:do_spl_search_seed_purge" \
  "ENV=dev SEED_TENANT=t1:do_spl_search_seed" "ENV=dev SEED_TENANT=t1:do_spl_search_seed_purge" \
  "ENV=dev SEED_MSGS=0:do_spl_search_seed" "ENV=dev SEED_BATCH=5:do_spl_search_seed" \
  "ENV=dev SEED_TENANT=seed-x;rm:do_spl_search_seed"; do
  envs="${c%%:*}" fn="${c#*:}"
  # shellcheck disable=SC2086
  out=$(env $envs DRY_RUN=0 PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    '"$fn"'; echo "rc=$?"' 2>&1)
  grep -q "FATAL" <<<"$out" && grep -q "rc=1" <<<"$out" && pass "$envs $fn refused" || fail "$envs $fn not refused: $out"
done
[[ ! -s "$T/calls.log" ]] && pass "no gcloud / psql call on a refusal" || fail "a refusal called out: $(cat "$T/calls.log")"
# CONTROL: the same action with valid knobs is accepted (so rc=1 above is the
# refusal, not a broken harness)
out=$(SNIPPET='do_spl_search_seed; echo rc=$?' in_orc ENV=dev DRY_RUN=1 2>&1)
grep -q "rc=0" <<<"$out" && grep -q "nothing written" <<<"$out" && pass "dry run seeds nothing" || fail "dry run: $out"

# --- 2. the seed SQL ------------------------------------------------------------------
sql=$(SNIPPET='spl_search_seed_args && spl_search_seed_sql' in_orc ENV=dev SEED_MSGS=250000 SEED_BATCH=100000 2>&1)
[[ $(grep -c "^INSERT INTO messages" <<<"$sql") == 3 ]] && pass "250000 rows / 100000 = 3 INSERTs" || fail "batches: $(grep -c '^INSERT INTO messages' <<<"$sql")"
# the row number is bigint: i * 7919 overflows int4 past i = 271k (measured on
# dev: "integer out of range" in the 4th batch of the first 1M run)
grep -q "generate_series(0::bigint, 99999::bigint)" <<<"$sql" && pass "row numbers are bigint" || fail "row numbers are int4"
[[ $(grep -c "ON CONFLICT (tenant_id, msg_id) DO NOTHING" <<<"$sql") == 3 ]] && pass "every batch is resumable" || fail "ON CONFLICT missing"
grep -q "generate_series(200000::bigint, 249999::bigint)" <<<"$sql" && pass "the last batch stops at SEED_MSGS-1" || fail "last batch bounds"
ten=$(grep -oE "(VALUES \(|SELECT |tenant_id = )'[a-z0-9-]+'" <<<"$sql" | sed -E "s/.*'([a-z0-9-]+)'/\1/" | sort -u)
[[ "$ten" == "seed-search" ]] && pass "every tenant position in the seed SQL is seed-search" || fail "tenant literals: $ten"

# --- 3. the purge SQL -----------------------------------------------------------------
dry=$(SNIPPET='spl_search_seed_purge_sql seed-search 1' in_orc 2>&1)
wet=$(SNIPPET='spl_search_seed_purge_sql seed-search 0' in_orc 2>&1)
! grep -q DELETE <<<"$dry" && pass "dry purge deletes nothing" || fail "dry purge has a DELETE"
grep -q "DELETE FROM tenants WHERE tenant_id = 'seed-search' AND tenant_id LIKE 'seed-%';" <<<"$wet" &&
  pass "purge deletes only the seed- tenant row (cascade)" || fail "purge SQL: $wet"

# --- 4. the measure SQL ---------------------------------------------------------------
m=$(SNIPPET='spl_search_measure_sql seed-search 3 "" 0' in_orc 2>&1)
grep -q "PGOPTIONS='-c default_transaction_read_only=on'" "$PROJ_ROOT/src/bash/run/spl-search-measure.func.sh" &&
  pass "the measure session is read-only (Postgres refuses writes)" || fail "measure session not read-only"
grep -q "set_config('app.tenant_id', 'seed-search', false)" <<<"$m" && grep -q "set_config('statement_timeout', '5000', false)" <<<"$m" && ! grep -q "rls_scope" <<<"$m" &&
  pass "measure runs in the tenant scope, never the operator scope" || fail "measure scope"
bad=0
for verb in INSERT UPDATE DELETE TRUNCATE DROP ALTER CREATE GRANT COMMIT; do
  grep -qiE "^[[:space:]]*$verb([[:space:]]|;|\$)" <<<"$m" && { fail "measure has a statement starting with $verb"; bad=1; }
done
((bad == 0)) && pass "no measure statement starts with a write verb"
for q in common rare prefix_rare; do
  b=$(grep -A1 "^\\\\echo @@ topic_${q}_before$" <<<"$m" | tail -1)
  a=$(grep -A1 "^\\\\echo @@ topic_${q}_after$" <<<"$m" | tail -1)
  ! grep -q "task_id IN (SELECT k.task_id" <<<"$b" && grep -q "task_id IN (SELECT k.task_id" <<<"$a" &&
    pass "topic_$q: before is the full aggregate, after carries the prefilter" || fail "topic_$q pair"
done
[[ $(grep -c '^\\echo @@ msg_common$' <<<"$m") == 3 ]] && pass "MEASURE_N samples per query" || fail "sample count"
out=$(SNIPPET='spl_search_measure_sql seed-search 3 nope 0; echo rc=$?' in_orc 2>&1)
grep -q "rc=1" <<<"$out" && pass "an unknown MEASURE_ONLY is refused" || fail "MEASURE_ONLY nope: $out"

# --- 5. the summary -------------------------------------------------------------------
sum=$(printf '@@ q1\n Execution Time: 10.0 ms\n@@ q1\n Execution Time: 30.0 ms\n@@ q1\n Execution Time: 20.0 ms\n' |
  SNIPPET='spl_search_measure_summary' in_orc 2>&1)
grep -qE "^q1 +3 +20\.0 +30\.0 +30\.0 +0$" <<<"$sum" && pass "summary: n=3 p50 20.0 p95 30.0 max 30.0" || fail "summary: $sum"
sum=$(printf '@@ q2\n Execution Time: 10.0 ms\n@@ q2\nERROR:  canceling statement due to statement timeout\n@@ q2\n Execution Time: 20.0 ms\n' |
  SNIPPET='spl_search_measure_summary' in_orc 2>&1)
sum3=$(printf '@@ q3\n Execution Time: 10.0 ms\n@@plan q4\n Execution Time: 999.0 ms\n@@ q4\n Execution Time: 5.0 ms\n' |
  SNIPPET='spl_search_measure_summary' in_orc 2>&1)
grep -qE "^q3 +1 +10\.0 " <<<"$sum3" && grep -qE "^q4 +1 +5\.0 " <<<"$sum3" && pass "a plan run is not counted as a sample" || fail "plan attribution: $sum3"
grep -qE "^q2 +3 +20\.0 +>timeout +>timeout +1$" <<<"$sum" && pass "a statement timeout counts as a sample" || fail "timeout summary: $sum"

echo
((fails == 0)) && { echo "PASS: all spl-search-seed.tst.sh assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
