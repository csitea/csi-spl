#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_unanswered_sweep_measure (api perf round d-02) is a READ-ONLY
# latency probe of the sweep's hub statement. Offline:
#   1. a bad ENV / MEASURE_N / SWEEP_DAYS / MEASURE_REF_SQL is refused BEFORE
#      gcloud or psql is called. CONTROL: the stub log records a call
#   2. the script is one READ ONLY operator transaction that is rolled back,
#      measures the sweep's OWN text (_spl_sweep_rows_sql), n samples each,
#      interleaved with MEASURE_REF_SQL, and writes nothing
#   3. the summary reads Postgres' Execution Time: p50 / p95 / max per name
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
orc_stub 1 gcloud psql

# --- 1. bad arguments never reach the cloud ----------------------------------------
for bad in ENV=stg MEASURE_N=2 MEASURE_N=51 MEASURE_N=x SWEEP_DAYS=0 "MEASURE_REF_SQL=$T/none.sql"; do
  : >"$T/calls.log"
  SNIPPET=do_spl_unanswered_sweep_measure in_orc "$bad" >"$T/o" 2>&1 && fail "$bad: ran" || pass "$bad: refused"
  grep -q FATAL "$T/o" && pass "$bad: the refusal is FATAL" || fail "$bad: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$bad: no gcloud/psql call" || fail "$bad: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. the script ---------------------------------------------------------------------
printf 'SELECT 1 AS ref_marker;\n' >"$T/ref.sql"
sql=$(SNIPPET="spl_sweep_measure_sql 3 $T/ref.sql 1" in_orc 2>&1)
[[ "$(sed -n 2,3p <<<"$sql")" == $'BEGIN READ ONLY;\nSET LOCAL app.rls_scope = \'operator\';' && "$(tail -1 <<<"$sql")" == "ROLLBACK;" ]] &&
  pass "one READ ONLY operator transaction, rolled back" || fail "frame: $(sed -n 1,3p <<<"$sql") ... $(tail -1 <<<"$sql")"
bad=0
for verb in INSERT UPDATE DELETE TRUNCATE DROP ALTER CREATE GRANT REVOKE VACUUM REINDEX COMMIT 'SET ROLE'; do
  grep -qiE "^[[:space:]]*$verb([[:space:]]|;|\$)" <<<"$sql" && { fail "a statement starts with $verb"; bad=1; }
done
(( bad == 0 )) && pass "no statement starts with a write verb"
own=$(SNIPPET='_spl_sweep_rows_sql' in_orc 2>&1 | sed -n 1p)
[[ -n "$own" ]] && grep -qF "EXPLAIN (ANALYZE, FORMAT JSON) $own" <<<"$sql" &&
  pass "it measures the sweep's own statement text" || fail "the sweep's text is not measured"
[[ "$(grep -c '^\\echo @@ sweep$' <<<"$sql") $(grep -c '^\\echo @@ ref$' <<<"$sql") $(grep -c '^\\echo @@plan ' <<<"$sql")" == "3 3 2" ]] &&
  pass "3 samples each, interleaved with the reference, one plan each" || fail "samples: $(grep '^\\echo' <<<"$sql" | tr '\n' ' ')"
grep -q 'EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1 AS ref_marker;' <<<"$sql" && pass "the reference text is measured as given" ||
  fail "reference text missing"

# --- 3. the summary --------------------------------------------------------------------
out=$({ for t in 5 1 3; do echo "@@ sweep"; echo "[{\"Plan\": {}, \"Execution Time\": $t}]"; done
        echo "@@plan ref"; echo "Seq Scan on x"; echo "@@ ref"; echo '[{"Execution Time": 9.5}]'; } |
      SNIPPET='spl_sweep_measure_summary' in_orc 2>&1)
grep -qx 'sweep n=3 p50=3.0 p95=5.0 max=5.0 ms' <<<"$out" && pass "p50 / p95 / max per statement" || fail "summary: $out"
grep -qx 'ref n=1 p50=9.5 p95=9.5 max=9.5 ms' <<<"$out" && grep -qx 'Seq Scan on x' <<<"$out" &&
  pass "a plan block passes through, its name keeps its own samples" || fail "summary: $out"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
