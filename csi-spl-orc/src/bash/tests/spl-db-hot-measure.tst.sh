#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_hot_measure is a READ-ONLY latency probe. Offline:
#   1. bad TENANT_ID / READER / MEASURE_N / MEASURE_JIT / MEASURE_ONLY /
#      MEASURE_PLAN_CACHE / MEASURE_LOBBY are refused BEFORE gcloud or psql is
#      called. CONTROL: the stub log records a call
#   2. the script writes nothing: no statement starts with a write verb, every
#      measured statement is an EXPLAIN of a PREPAREd read, and the session
#      takes the TENANT scope (never the operator scope)
#   3. by default each statement runs under the hub's OWN settings for it (the
#      walks under the walk scope, the rest under the plain tenant scope);
#      MEASURE_JIT=both, MEASURE_ONLY, MEASURE_PLANS and the overrides
#   4. the DRIFT GATE (api perf ap-00): the statements are the builders' printed
#      copy (spl-db-hot-measure.stmt.sql), every text has the sha256 its builder
#      printed (CONTROL: a one-byte edit is refused), and, where Go is on the
#      box, the builders print that copy byte for byte today
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
           MEASURE_PLAN_CACHE=sometimes MEASURE_PLAN_CACHE=both MEASURE_TIMEOUT_MS=50 MEASURE_BITMAPSCAN=maybe \
           MEASURE_SORT=maybe "MEASURE_LOBBY=x';drop" MEASURE_ONLY=walk_all_pre; do
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

# --- 3. the hub's own settings per statement, and the overrides ------------------------
stmts="walk_all walk_dm thread flow_counts ch_counts ch_marked ch_hidden"
# settings <script> <name> <tag> -> the four SETs just before name.tag's first sample
settings() { awk -v at="\\echo @@ $2$3" '/^SET /{s[++k]=$0} $0 == at {for (i = k - 3; i <= k; i++) print s[i]; exit}' <<<"$1"; }
def=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 hub "" 0' in_orc 2>&1)
for name in $stmts; do
  grep -q "^\\\\echo @@ $name.hub$" <<<"$def" || fail "$name is not measured by default"
done
pass "every statement is measured by default, tagged .hub"
for name in walk_all walk_dm; do
  [[ "$(settings "$def" $name .hub)" == $'SET jit = off;\nSET enable_bitmapscan = off;\nSET enable_sort = off;\nSET plan_cache_mode = force_custom_plan;' ]] &&
    pass "$name runs under the walk scope (pgScopeTenantNoJIT)" || fail "$name settings: $(settings "$def" $name .hub)"
done
for name in thread flow_counts ch_counts ch_marked ch_hidden; do
  [[ "$(settings "$def" $name .hub)" == $'SET jit = DEFAULT;\nSET enable_bitmapscan = DEFAULT;\nSET enable_sort = DEFAULT;\nSET plan_cache_mode = DEFAULT;' ]] &&
    pass "$name runs under the plain tenant scope (the server's defaults)" || fail "$name settings: $(settings "$def" $name .hub)"
done
grep -q "plan_cache_mode', " <<<"$def" && fail "the session pins a plan cache mode for every statement" || pass "no session-wide plan cache mode"

sql=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 both "" 1' in_orc 2>&1)
for name in $stmts; do
  grep -q "^\\\\echo @@ $name.jit_on$" <<<"$sql" && grep -q "^\\\\echo @@ $name.jit_off$" <<<"$sql" ||
    fail "$name is not measured under both jit settings"
done
pass "MEASURE_JIT=both measures every statement under jit on and off"
[[ "$(settings "$sql" flow_counts .jit_on)" == $'SET jit = on;\nSET enable_bitmapscan = DEFAULT;\nSET enable_sort = DEFAULT;\nSET plan_cache_mode = DEFAULT;' ]] &&
  pass "an override changes only its own setting" || fail "override: $(settings "$sql" flow_counts .jit_on)"
[[ $(grep -c '^\\echo @@ walk_all.jit_on$' <<<"$sql") == 3 ]] && pass "MEASURE_N=3 gives 3 samples" || fail "sample count"
[[ $(grep -c '^EXPLAIN (ANALYZE, BUFFERS)' <<<"$sql") == 14 ]] && pass "MEASURE_PLANS=1: one plan per statement per jit" || fail "plan count"
one=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 off walk_dm 0' in_orc 2>&1)
grep -q '@@ walk_dm.jit_off$' <<<"$one" && ! grep -qE '@@ (walk_all|thread|flow_counts|ch_[a-z]+)\.' <<<"$one" &&
  ! grep -q 'jit_on' <<<"$one" && [[ $(grep -c '^PREPARE ' <<<"$one") == 1 ]] &&
  pass "MEASURE_ONLY=walk_dm MEASURE_JIT=off narrows to one, and prepares only it" || fail "narrowing: $one"
pc=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 hub flow_counts 0' in_orc MEASURE_PLAN_CACHE=force_custom_plan MEASURE_BITMAPSCAN=both MEASURE_SORT=on 2>&1)
grep -q '^\\echo @@ flow_counts.bitmap_on.sort_on.pc_custom_plan$' <<<"$pc" && grep -q '^\\echo @@ flow_counts.bitmap_off.sort_on.pc_custom_plan$' <<<"$pc" &&
  [[ "$(settings "$pc" flow_counts .bitmap_off.sort_on.pc_custom_plan)" == $'SET jit = DEFAULT;\nSET enable_bitmapscan = off;\nSET enable_sort = on;\nSET plan_cache_mode = force_custom_plan;' ]] &&
  pass "MEASURE_PLAN_CACHE / MEASURE_BITMAPSCAN=both / MEASURE_SORT override and tag" || fail "overrides: $pc"
lob=$(SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 hub ch_hidden 0 00000000-0000-4000-8000-000000000001' in_orc 2>&1)
grep -q "^\\\\set lobby '00000000-0000-4000-8000-000000000001'$" <<<"$lob" && grep -q "EXECUTE ch_hidden(.*:'lobby'[,)]" <<<"$lob" &&
  pass "the lobby task is bound where the builder binds it" || fail "lobby: $lob"

# --- 4. the drift gate: the builders' printed copy -------------------------------------
F="$PROJ_ROOT/src/bash/run/spl-db-hot-measure.stmt.sql"
[[ "$(awk '/^-- @@stmt /{printf "%s ", $3}' "$F")" == "$stmts " ]] && pass "the copy holds the 7 hot statements" || fail "copy names: $(awk '/^-- @@stmt /{printf "%s ", $3}' "$F")"
SNIPPET='spl_db_hot_measure_check' in_orc >"$T/o" 2>&1 && pass "every text has the sha256 its builder printed" || fail "sha256 check: $(cat "$T/o")"
for name in $stmts; do
  first=$(SNIPPET="spl_db_hot_measure_body $name" in_orc 2>&1); first=${first%%$'\n'*}
  grep -qF "PREPARE $name AS $first" <<<"$sql" || fail "$name is not prepared from the copy"
done
pass "each PREPARE is the copy's text"
grep -q "^PREPARE [a-z_]* (" <<<"$sql" && fail "a PREPARE declares parameter types (pgx does not)" || pass "untyped PREPAREs, as pgx's Parse"
grep -q 'archived_at' <<<"$(SNIPPET='spl_db_hot_measure_body walk_dm' in_orc 2>&1)" &&
  pass "walk_dm carries the archived-topic probe (the SPL-984 copy had none)" || fail "walk_dm lacks the archived probe"
grep -q "^\\\\set pub '{lobby,alerts,feedback,issues,tasks}'$" <<<"$sql" && pass "the public channels come from the copy" || fail "pub: $(grep set\ pub <<<"$sql")"
python3 - "$F" "$T/edited.sql" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index("WITH RECURSIVE")
open(sys.argv[2], "w").write(s[:i] + s[i:].replace("LIMIT 1", "LIMIT 2", 1))
PY
SNIPPET='spl_db_hot_measure_sql t1 HUM-10 3 hub "" 0' in_orc SPL_HOT_STMT_FILE="$T/edited.sql" >"$T/o" 2>&1 &&
  fail "CONTROL: a hand-edited copy ran" || { grep -q "walk_all's text .* is not its builder's" "$T/o" && pass "CONTROL: a one-byte hand edit is refused" || fail "CONTROL text: $(cat "$T/o")"; }
# The builders print the copy byte for byte today. The api suite's
# TestHotStmtCopyCurrent is the same gate; this leg runs it from here when Go is on the box.
GO_BIN=$(command -v go || true); [[ -x /usr/local/go1.25.14/bin/go ]] && GO_BIN=/usr/local/go1.25.14/bin/go
API="$APP_ROOT/csi-spl-api/src/go/spool-hub-api"
if [[ -n "$GO_BIN" && -d "$API" ]]; then
  if (cd "$API" && SPL_STMT_PRINT="$T/printed.sql" GOFLAGS="${GOFLAGS:--mod=mod}" timeout 60 "$GO_BIN" test -count=1 -run '^TestHotStmtPrint$' ./internal/store/ >"$T/go.log" 2>&1); then
    cmp -s "$T/printed.sql" "$F" && pass "the builders print the copy byte for byte" ||
      fail "the copy drifted from the builders: regenerate it (stmt_print_test.go says how)"
  else
    echo "SKIP: the Go printer did not run here ($(tail -1 "$T/go.log")); the api suite's TestHotStmtCopyCurrent gates it"
  fi
else
  echo "SKIP: no Go on this box; the api suite's TestHotStmtCopyCurrent gates the copy"
fi

(( fails == 0 )) && echo "OK spl-db-hot-measure: all checks passed" || { echo "FAIL spl-db-hot-measure: $fails check(s)"; exit 1; }
