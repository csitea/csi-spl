#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_hot_measure is a READ-ONLY latency probe. Offline:
#   1. bad TENANT_ID / READER / MEASURE_N / MEASURE_JIT / MEASURE_ONLY /
#      MEASURE_PLAN_CACHE are refused BEFORE gcloud or psql is called.
#      CONTROL: the stub log records a call
#   2. the script writes nothing: no statement starts with a write verb, every
#      measured statement is an EXPLAIN of a PREPAREd read, and the session
#      takes the TENANT scope (never the operator scope)
#   3. MEASURE_JIT=both measures each statement under jit on AND off,
#      MEASURE_ONLY narrows, MEASURE_PLANS adds one BUFFERS plan per statement
#   4. the walk texts are the store's shape (WITH RECURSIVE, LIMIT 1 steps,
#      the read door and the NoIssues probe)
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
for b in gcloud psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. bad arguments never reach the cloud ----------------------------------------
ok_args=(TENANT_ID=t1 READER=HUM-10)
for bad in "TENANT_ID=T1;drop" "READER=x'y" MEASURE_N=2 MEASURE_N=51 MEASURE_JIT=maybe MEASURE_ONLY=nonesuch \
           MEASURE_PLAN_CACHE=sometimes MEASURE_TIMEOUT_MS=50; do
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
[[ $(grep -c '^EXPLAIN (ANALYZE, BUFFERS)' <<<"$sql") == 12 ]] && pass "MEASURE_PLANS=1: one plan per statement per jit" || fail "plan count"
one=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 off walk_dm 0' in_orc 2>&1)
grep -q '@@ walk_dm.jit_off' <<<"$one" && ! grep -qE '@@ (walk_all|thread|channels|issues|file_door)\.' <<<"$one" &&
  ! grep -q 'jit_on' <<<"$one" && pass "MEASURE_ONLY=walk_dm MEASURE_JIT=off narrows to one" || fail "narrowing: $one"
grep -q "plan_cache_mode', 'auto'" <<<"$one" && pass "plan_cache_mode defaults to auto (as pgx sees it)" || fail "plan cache default"

# --- 4. the walk texts are the store's shape ------------------------------------------
for shape in all dm; do
  w=$(SNIPPET="spl_db_hot_measure_walk $shape" in_orc 2>&1)
  [[ "$w" == "WITH RECURSIVE w (task_id, received_at, n)"* ]] || fail "walk_$shape does not start as the store's walk"
  [[ $(grep -o 'LIMIT 1' <<<"$w" | wc -l) -ge 8 ]] || fail "walk_$shape lacks the LIMIT 1 probes"
  grep -q 'FROM issues i WHERE i.tenant_id = \$1 AND i.task_id = l.task_id LIMIT 1) IS NULL' <<<"$w" || fail "walk_$shape lacks NoIssues"
done
pass "both walk texts carry the recursive LIMIT-1 steps and the NoIssues probe"
grep -q 'l.channel IS NULL' <<<"$(SNIPPET='spl_db_hot_measure_walk dm' in_orc 2>&1)" && pass "walk_dm is the DM walk" || fail "walk_dm lacks channel IS NULL"

(( fails == 0 )) && echo "OK spl-db-hot-measure: all checks passed" || { echo "FAIL spl-db-hot-measure: $fails check(s)"; exit 1; }
