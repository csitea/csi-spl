#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_health is a READ-ONLY report. Offline (no cloud call):
#   1. the SQL contains no write verb, and every section asks only catalog /
#      statistics views or a plain SELECT count
#   2. SECTION=all emits every section; a named section emits only that one
#   3. an unknown SECTION is refused BEFORE gcloud is called. CONTROL: the
#      stub log records a call when one is made
#   4. spl_psql_report wraps the script in BEGIN READ ONLY + ROLLBACK, takes
#      the operator RLS scope, and keeps the login out of argv
#   5. spl_db_health_series turns a Monitoring v3 body into one summary line,
#      and says so plainly on an error body or an empty window
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
for b in gcloud psql curl; do
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

# --- 1. the SQL writes nothing --------------------------------------------------
sql=$(SNIPPET='spl_db_health_sql all' in_orc 2>&1)
[[ -n "$sql" ]] && pass "SECTION=all produces SQL" || fail "no SQL for all"
bad=0
for verb in INSERT UPDATE DELETE TRUNCATE DROP ALTER CREATE GRANT REVOKE VACUUM ANALYZE REINDEX COMMIT 'SET ROLE'; do
  # the verb must not START a statement. The boundary matters: the report
  # SELECTs columns called vacuum_count and last_analyze, and an anchor without
  # it reads those as a VACUUM (measured while writing this test).
  grep -qiE "^[[:space:]]*$verb([[:space:]]|;|\$)" <<<"$sql" && { fail "SQL has a statement starting with $verb"; bad=1; }
done
(( bad == 0 )) && pass "no statement in the SQL starts with a write verb"
grep -q 'pg_stat_user_tables' <<<"$sql" && grep -q 'pg_settings' <<<"$sql" &&
  pass "SQL reads the statistics and settings views" || fail "SQL lacks the stats views"

# --- 2. section selection --------------------------------------------------------
for s in size load vacuum structure; do
  one=$(SNIPPET="spl_db_health_sql $s" in_orc 2>&1)
  grep -q -- "--- $s:" <<<"$one" || fail "SECTION=$s emits no $s block"
  for other in size load vacuum structure; do
    [[ "$other" == "$s" ]] && continue
    grep -q -- "--- $other:" <<<"$one" && fail "SECTION=$s also emitted $other"
  done
done
pass "each named section emits itself and nothing else"
for s in size load vacuum structure; do
  grep -q -- "--- $s:" <<<"$sql" || fail "SECTION=all is missing $s"
done
pass "SECTION=all emits every SQL section"
SNIPPET='spl_db_health_known_section cloudsql' in_orc >/dev/null 2>&1 && pass "cloudsql is a known section" || fail "cloudsql not known"
SNIPPET='spl_db_health_known_section nonesuch' in_orc >/dev/null 2>&1 && fail "nonesuch accepted" || pass "an unknown section is rejected"

# --- 3. a bad SECTION never reaches gcloud ---------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_db_health in_orc SECTION=nonesuch >"$T/o" 2>&1 && fail "ran with SECTION=nonesuch" || pass "SECTION=nonesuch: refused"
grep -q "SECTION must be all" "$T/o" && pass "the refusal names the valid sections" || fail "refusal text: $(cat "$T/o")"
[[ ! -s "$T/calls.log" ]] && pass "SECTION=nonesuch: no gcloud call" || fail "gcloud called: $(cat "$T/calls.log")"
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 4. the psql runner is read-only and keeps the login out of argv --------------
: >"$T/calls.log"
SNIPPET='spl_psql_report "postgres://spool:s3cr%40t@127.0.0.1:55499/spool?sslmode=disable" "SELECT 1;"' in_orc >/dev/null 2>&1
line=$(cat "$T/calls.log")
grep -q "s3cr@t" <<<"$line" && fail "the password reached psql argv: $line" || pass "the login never reaches psql argv"
grep -q -- "-X" <<<"$line" && pass "psql runs with -X (no user psqlrc)" || fail "psql argv: $line"
body=$(grep -n 'BEGIN READ ONLY' "$PROJ_ROOT/src/bash/run/spl-db-health.func.sh")
[[ -n "$body" ]] && pass "the runner opens BEGIN READ ONLY" || fail "no BEGIN READ ONLY in the runner"
grep -q "default_transaction_read_only=on" "$PROJ_ROOT/src/bash/run/spl-db-health.func.sh" &&
  pass "the session sets default_transaction_read_only=on" || fail "no read-only session default"
grep -q "SET LOCAL app.rls_scope" "$PROJ_ROOT/src/bash/run/spl-db-health.func.sh" &&
  grep -q "operator" "$PROJ_ROOT/src/bash/run/spl-db-health.func.sh" &&
  pass "the transaction takes the operator RLS scope" || fail "no operator RLS scope"
grep -q "ROLLBACK" "$PROJ_ROOT/src/bash/run/spl-db-health.func.sh" &&
  pass "the transaction ends in ROLLBACK" || fail "no ROLLBACK"

# --- 5. the Monitoring summariser ------------------------------------------------
series() { SNIPPET='spl_db_health_series' in_orc <<<"$1" 2>&1; }
BODY='{"timeSeries":[{"points":[
  {"interval":{"endTime":"2026-09-21T07:37:00Z"},"value":{"int64Value":"200"}},
  {"interval":{"endTime":"2026-09-21T06:37:00Z"},"value":{"int64Value":"100"}}]}]}'
o=$(series "$BODY")
[[ "$o" == *"n=2"* && "$o" == *"newest=200"* && "$o" == *"oldest=100"* && "$o" == *"delta_24h=100"* ]] &&
  pass "a timeSeries body summarises to n/newest/oldest/delta" || fail "series: $o"
o=$(series '{"error":{"message":"permission denied"}}')
[[ "$o" == *"error: permission denied"* ]] && pass "an error body is reported, not swallowed" || fail "error body: $o"
o=$(series '{"timeSeries":[]}')
[[ "$o" == *"no points"* ]] && pass "an empty window says so" || fail "empty body: $o"
o=$(series 'not json')
[[ "$o" == *"no data"* ]] && pass "a non-JSON body says so" || fail "garbage body: $o"

(( fails == 0 )) && echo "OK spl-db-health: all checks passed" || { echo "FAIL spl-db-health: $fails check(s)"; exit 1; }
