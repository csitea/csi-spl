#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_consumer_lag (spec 059 §11.1 S4) stays read-only,
#          injection-proof and honest about dead boxes and alerts, offline.
#   1. LAG_ALERT_MIN / LAG_DEAD_HOURS must be bounded integers; anything else
#      is refused before any SQL is built or any gcloud call is made
#   2. the SQL counts sent-but-uncommitted (acked_at NULL) and queued rows per
#      box, joins the last hello, carries both thresholds, and writes nothing
#   3. spl_consumer_lag_summary: an alerting live box prints an ALERT line; a
#      dead box's rows are counted as lag (uncommitted_dead), never an alert;
#      CONTROL: no rows -> boxes=0, no ALERT; garbage -> non-zero
#   4. with no key readable, the action stops before gcloud
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy psql

# --- 1. thresholds -----------------------------------------------------------------
printf '{}\n' >"$T/key.json"
for bad in "LAG_ALERT_MIN=0" "LAG_ALERT_MIN=30'--" "LAG_ALERT_MIN=99999" "LAG_DEAD_HOURS=x" "LAG_DEAD_HOURS=0"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_consumer_lag in_orc ENV=dev SPL_SA_KEY="$T/key.json" "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  elif grep -qE "LAG_(ALERT_MIN|DEAD_HOURS) must be" "$T/o" && [[ ! -s "$T/calls.log" ]]; then
    pass "refuses $bad before any call"
  else
    fail "$bad: calls=$(cat "$T/calls.log") out=$(cat "$T/o")"
  fi
done

# --- 2. SQL ------------------------------------------------------------------------
sql=$(SNIPPET='spl_consumer_lag_sql 45 96' in_orc 2>&1)
grep -q "state = 'sent' AND d.acked_at IS NULL" <<<"$sql" && grep -q "d.state = 'queued' AND d.expires_at > now()" <<<"$sql" \
  && pass "SQL: uncommitted = sent with acked_at NULL, plus unexpired queued" || fail "SQL shape: $sql"
grep -q "LEFT JOIN boxes b" <<<"$sql" && grep -q "interval '96 hours'" <<<"$sql" && grep -q "interval '45 minutes'" <<<"$sql" \
  && pass "SQL: last hello joined, both thresholds carried" || fail "SQL thresholds: $sql"
grep -qE "m\.body|m\.env|INSERT|UPDATE|DELETE" <<<"$sql" && fail "SQL reads a body or writes" || pass "SQL reads no body and writes nothing"

# --- 3. summary ----------------------------------------------------------------------
sum_of() { SNIPPET="spl_consumer_lag_summary '$1'" in_orc 2>&1; }
rows='{"tenant_id" : "t1", "box" : "box-live", "uncommitted" : 2, "queued" : 1, "oldest_age_s" : 7200, "last_hello_at" : "2026-10-02T09:00:00Z", "dead" : false, "alert" : true}
{"tenant_id" : "t1", "box" : "box-ok", "uncommitted" : 0, "queued" : 3, "oldest_age_s" : 0, "last_hello_at" : "2026-10-02T09:00:00Z", "dead" : false, "alert" : false}
{"tenant_id" : "t1", "box" : "box-test-9", "uncommitted" : 70, "queued" : 0, "oldest_age_s" : 900000, "last_hello_at" : null, "dead" : true, "alert" : false}'
out=$(sum_of "$rows")
grep -q "^ALERT t1/box-live uncommitted=2 oldest_age_s=7200" <<<"$out" && pass "live box past the threshold: ALERT line" || fail "alert line: $out"
grep -q "ALERT t1/box-test-9" <<<"$out" && fail "a dead box raised an alert: $out" || pass "dead box: no alert"
grep -q "^SUMMARY boxes=3 live_lagging=1 dead=1 uncommitted=72 uncommitted_dead=70 queued=4 alerts=1$" <<<"$out" \
  && pass "summary: the dead box's 70 rows are reported as lag" || fail "summary: $out"
out=$(sum_of "")
grep -q "^SUMMARY boxes=0 live_lagging=0 dead=0 uncommitted=0 uncommitted_dead=0 queued=0 alerts=0$" <<<"$out" && ! grep -q '^ALERT' <<<"$out" \
  && pass "CONTROL: no rows -> zero summary, no alert" || fail "empty: $out"
SNIPPET="spl_consumer_lag_summary 'not json'" in_orc >/dev/null 2>&1 && fail "garbage parsed" || pass "garbage -> non-zero"

# --- 4. no key -----------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_consumer_lag in_orc ENV=dev SPL_SA_KEY="$T/none.json" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "no service-account key" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "no key: refused, no gcloud call" \
  || fail "no key: rc=$rc calls=$(cat "$T/calls.log") out=$out"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all consumer-lag.tst.sh assertions"
else
  echo "FAIL: $fails consumer-lag.tst.sh assertion(s)"
  exit 1
fi
