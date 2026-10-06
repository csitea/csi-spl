#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_period_count_check (specs/027 T040, rdb 0023) stays
#          read-only, injection-proof and honest about a mismatch, offline.
#   1. TENANT_ID must be a slug; a quote-carrying value is refused before any
#      SQL is built or any gcloud call is made
#   2. the SQL compares the counter SUM with COUNT(*) since the UTC period start
#      and reads only those two tables
#   3. spl_db_period_count_equal: true -> 0; false, garbage or empty -> non-zero
#      (CONTROL: a mismatch is never read as equal)
#   4. with no key readable, the action stops before gcloud
#   5. a Ctrl-C while gcloud runs still removes the throwaway CLOUDSDK_CONFIG
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy psql

# --- 1. tenant slug ----------------------------------------------------------------
printf '{}\n' >"$T/key.json"
for bad in "TENANT_ID=t1'--" "TENANT_ID=" "TENANT_ID=T1" "TENANT_ID=t1;drop"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_db_period_count_check in_orc SPL_SA_KEY="$T/key.json" "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  elif grep -q "TENANT_ID must be a tenant slug" "$T/o" && [[ ! -s "$T/calls.log" ]]; then
    pass "refuses $bad before any call"
  else
    fail "$bad: calls=$(cat "$T/calls.log") out=$(cat "$T/o")"
  fi
done

# --- 2. SQL ------------------------------------------------------------------------
sql=$(SNIPPET='spl_db_period_count_sql t1' in_orc 2>&1)
grep -q "FROM message_period_counts" <<<"$sql" && grep -q "COUNT(\*) AS n FROM messages" <<<"$sql" \
  && pass "SQL: counter SUM against messages COUNT(*)" || fail "SQL shape: $sql"
grep -q "date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'" <<<"$sql" \
  && pass "SQL: the UTC period start (billing.PeriodStart)" || fail "SQL period: $sql"
grep -qE "body|env|INSERT|UPDATE|DELETE" <<<"$sql" && fail "SQL reads a body or writes" || pass "SQL reads no body and writes nothing"

# --- 3. equal parse ------------------------------------------------------------------
eq() { SNIPPET="spl_db_period_count_equal '$1'" in_orc >/dev/null 2>&1; }
eq '{"tenant_id" : "t1", "counter" : 5, "rows" : 5, "equal" : true}' && pass "equal:true -> 0" || fail "equal:true not read as equal"
for bad in '{"counter" : 5, "rows" : 4, "equal" : false}' 'not json' '' '{"equal" : "true"}'; do
  eq "$bad" && fail "read as equal: '$bad'" || pass "not equal: '${bad:0:24}'"
done

# --- 4. no key -----------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_db_period_count_check in_orc TENANT_ID=t1 SPL_SA_KEY="$T/none.json" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "no service-account key" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "no key: refused, no gcloud call" \
  || fail "no key: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 5. Ctrl-C mid gcloud ------------------------------------------------------------
# CTRL_C <cmd...>: a Ctrl-C. It runs <cmd> in its own process group with SIGINT
# at its default (a runner may start tests with it ignored), so the stub's
# `kill -INT 0` reaches the whole action and nothing else.
CTRL_C=(python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])')
mkdir -p "$T/istub" "$T/tmp"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\nkill -INT 0\n' >"$T/istub/gcloud"; chmod +x "$T/istub/gcloud"
: >"$T/calls.log"; before=$(ls -A "$T/tmp")
SNIPPET=do_spl_db_period_count_check in_orc TENANT_ID=t1 SPL_SA_KEY="$T/key.json" PATH="$T/istub:$T/stub:$PATH" \
  TMPDIR="$T/tmp" "${CTRL_C[@]}" >"$T/o" 2>&1; rc=$?
after=$(ls -A "$T/tmp")
[[ $rc -ne 0 && -s "$T/calls.log" && -z "$before" && -z "$after" ]] \
  && pass "Ctrl-C mid gcloud: the throwaway config is removed (temp root empty before and after)" \
  || fail "Ctrl-C: rc=$rc calls=$(cat "$T/calls.log") temp root before='$before' after='$after' out=$(cat "$T/o")"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all period-count-check.tst.sh assertions"
else
  echo "FAIL: $fails period-count-check.tst.sh assertion(s)"
  exit 1
fi
