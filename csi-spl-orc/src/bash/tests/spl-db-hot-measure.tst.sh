#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_hot_measure is a READ-ONLY latency probe. Offline:
#   1. bad TENANT_ID / READER / MEASURE_N / MEASURE_JIT / MEASURE_ONLY /
#      MEASURE_PLAN_CACHE are refused BEFORE gcloud or psql is called.
#      CONTROL: the stub log records a call
#   2. the script writes nothing: no statement starts with a write verb, every
#      measured statement is an EXPLAIN of a PREPAREd read, and the session
#      takes the TENANT scope (never the operator scope)
#   3. MEASURE_JIT=both / MEASURE_BITMAPSCAN=both measure each statement both ways,
#      MEASURE_ONLY narrows, MEASURE_PLANS adds one BUFFERS plan per statement
#   4. the walk texts are the store's shape (WITH RECURSIVE, LIMIT 1 steps,
#      the read door and the NoIssues probe, the first message as one row);
#      the defaults are the walk scope's settings (bitmap off, custom plans)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
for b in gcloud psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

# --- 1. bad arguments never reach the cloud ----------------------------------------
ok_args=(TENANT_ID=t1 READER=HUM-10)
for bad in "TENANT_ID=T1;drop" "READER=x'y" MEASURE_N=2 MEASURE_N=51 MEASURE_JIT=maybe MEASURE_ONLY=nonesuch \
           MEASURE_PLAN_CACHE=sometimes MEASURE_TIMEOUT_MS=50 MEASURE_BITMAPSCAN=maybe; do
  : >"$T/calls.log"
  SNIPPET=do_spl_db_hot_measure in_orc "${ok_args[@]}" "$bad" >"$T/o" 2>&1 && fail "$bad: ran" || pass "$bad: refused"
  grep -q FATAL "$T/o" && pass "$bad: the refusal is FATAL" || fail "$bad: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$bad: no gcloud/psql call" || fail "$bad: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. the script writes nothing ------------------------------------------------------
sql=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 both "" 1' in_orc 2>&1)
[[ -n "$sql" ]] && pass "a script is produced" || fail "no script"
bad=0
for verb in INSERT UPDATE DELETE TRUNCATE DROP ALTER CREATE GRANT REVOKE VACUUM ANALYZE REINDEX COMMIT 'SET ROLE'; do
  grep -qiE "^[[:space:]]*$verb([[:space:]]|;|\$)" <<<"$sql" && { fail "a statement starts with $verb"; bad=1; }
done
(( bad == 0 )) && pass "no statement starts with a write verb"
n_exec=$(grep -c '^EXPLAIN .*EXECUTE ' <<<"$sql"); n_explain=$(grep -c '^EXPLAIN' <<<"$sql")
(( n_exec > 0 && n_exec == n_explain )) && pass "every EXPLAIN runs a PREPAREd statement ($n_exec)" || fail "EXPLAIN/EXECUTE $n_explain/$n_exec"
grep -q "set_config('app.tenant_id', 't1', false)" <<<"$sql" && pass "the session takes the tenant scope" || fail "no tenant scope"
grep -qi "rls_scope" <<<"$sql" && fail "the script takes the operator scope" || pass "never the operator scope"
grep -q "default_transaction_read_only=on" "$PROJ_ROOT/src/bash/run/spl-db-hot-measure.func.sh" &&
  pass "the session is default_transaction_read_only=on" || fail "no read-only session default"

# --- 3. JIT pair, ONLY, PLANS ------------------------------------------------------------
for name in walk_all walk_dm thread channels issues file_door; do
  grep -q "^\\\\echo @@ $name.jit_on" <<<"$sql" && grep -q "^\\\\echo @@ $name.jit_off" <<<"$sql" ||
    fail "$name is not measured under both jit settings"
done
pass "MEASURE_JIT=both measures every statement under jit on and off"
[[ $(grep -c '^\\echo @@ walk_all.jit_on' <<<"$sql") == 3 ]] && pass "MEASURE_N=3 gives 3 samples" || fail "sample count"
[[ $(grep -c '^EXPLAIN (ANALYZE, BUFFERS)' <<<"$sql") == 14 ]] && pass "MEASURE_PLANS=1: one plan per statement per jit" || fail "plan count"
one=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 off walk_dm 0' in_orc 2>&1)
grep -q '@@ walk_dm.jit_off' <<<"$one" && ! grep -qE '@@ (walk_all|thread|channels|issues|file_door)\.' <<<"$one" &&
  ! grep -q 'jit_on' <<<"$one" && pass "MEASURE_ONLY=walk_dm MEASURE_JIT=off narrows to one" || fail "narrowing: $one"
grep -q "plan_cache_mode', 'force_custom_plan'" <<<"$one" && pass "plan_cache_mode defaults to force_custom_plan (the walk's scope, CLE-35061)" || fail "plan cache default"

bm=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 off walk_all 0' in_orc MEASURE_BITMAPSCAN=both 2>&1)
grep -q '@@ walk_all.jit_off$' <<<"$bm" && grep -q '@@ walk_all.jit_off.nobitmap$' <<<"$bm" &&
  grep -q '^SET enable_bitmapscan = off;' <<<"$bm" && pass "MEASURE_BITMAPSCAN=both measures with and without bitmap scans" || fail "bitmap pair: $bm"
so=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 off walk_all 0' in_orc MEASURE_SORT=both 2>&1)
grep -q '@@ walk_all.jit_off.nobitmap$' <<<"$so" && grep -q '@@ walk_all.jit_off.nobitmap.sort$' <<<"$so" &&
  grep -q '^SET enable_sort = on;' <<<"$so" && pass "MEASURE_SORT=both measures with and without sorts (CLE-77914)" || fail "sort pair: $so"
grep -q '^SET enable_sort = off;' <<<"$one" && ! grep -q '\.sort$' <<<"$one" && pass "the default turns enable_sort off (the walk's scope, CLE-77914)" || fail "sort default: $one"
SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 off walk_all 0' in_orc MEASURE_SORT=maybe >/dev/null 2>&1 && fail "MEASURE_SORT=maybe: ran" || pass "MEASURE_SORT=maybe: refused"
grep -q '^SET enable_bitmapscan = off;' <<<"$one" && grep -q '@@ walk_dm.jit_off.nobitmap$' <<<"$one" &&
  pass "the default measures without bitmap scans (the walk's scope, SPL-984)" || fail "bitmap default: $one"

# --- 4. the walk texts are the store's shape ------------------------------------------
for shape in all dm; do
  w=$(SNIPPET="spl_db_hot_measure_walk $shape" in_orc 2>&1)
  [[ "$w" == "WITH RECURSIVE w (task_id, received_at, n)"* ]] || fail "walk_$shape does not start as the store's walk"
  [[ $(grep -o 'LIMIT 1' <<<"$w" | wc -l) -ge 8 ]] || fail "walk_$shape lacks the LIMIT 1 probes"
  grep -q 'FROM issues i WHERE i.tenant_id = \$1 AND i.task_id = l.task_id LIMIT 1) IS NULL' <<<"$w" || fail "walk_$shape lacks NoIssues"
done
pass "both walk texts carry the recursive LIMIT-1 steps and the NoIssues probe"
# CLE-35061: the store reads a topic's first message as ONE row; walk_all_pre keeps the old aggregate as the control
for shape in all dm; do
  w=$(SNIPPET="spl_db_hot_measure_walk $shape" in_orc 2>&1)
  grep -q 'array_agg(m.msg' <<<"$w" && fail "walk_$shape still aggregates every message body"
  grep -q 'LEFT JOIN LATERAL ( SELECT COALESCE(m.channel' <<<"$w" || fail "walk_$shape lacks the first-row lateral"
done
grep -q 'array_agg(m.msg' <<<"$(SNIPPET='spl_db_hot_measure_walk all_pre' in_orc 2>&1)" &&
  pass "walk_all/walk_dm read the first message as one row; walk_all_pre is the old aggregate" || fail "walk_all_pre is not the old aggregate"
grep -q 'l.channel IS NULL' <<<"$(SNIPPET='spl_db_hot_measure_walk dm' in_orc 2>&1)" && pass "walk_dm is the DM walk" || fail "walk_dm lacks channel IS NULL"

(( fails == 0 )) && echo "OK spl-db-hot-measure: all checks passed" || { echo "FAIL spl-db-hot-measure: $fails check(s)"; exit 1; }
