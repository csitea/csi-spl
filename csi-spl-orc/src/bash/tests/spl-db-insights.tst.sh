#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_insights is a READ-ONLY Query Insights report. Offline:
#   1. bad INSIGHTS_HOURS / INSIGHTS_TOP / INSIGHTS_WIDTH are refused BEFORE
#      gcloud or curl is called. CONTROL: the stub log records a call
#   2. the only network verb is a curl GET (-G) against monitoring.googleapis.com
#   3. spl_db_insights_table sums the distribution per (query, user), ranks by
#      total, mean and calls, and says so plainly on an error body, an empty
#      window or a non-JSON body
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-db-insights.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl; do
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
for kv in INSIGHTS_HOURS=0 INSIGHTS_HOURS=169 INSIGHTS_HOURS=x INSIGHTS_TOP=0 INSIGHTS_WIDTH=5; do
  : >"$T/calls.log"
  SNIPPET=do_spl_db_insights in_orc "$kv" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && pass "$kv: the refusal is FATAL and named" || fail "$kv: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no gcloud/curl call" || fail "$kv: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. read-only: GET against Monitoring, nothing else ----------------------------
grep -qE 'curl -s -G "https://monitoring.googleapis.com/v3/projects/' "$FN" &&
  pass "the one curl is a GET (-G) on the Monitoring v3 API" || fail "no Monitoring GET"
grep -qiE -- '(-X|--request)[[:space:]]*(POST|PUT|PATCH|DELETE)' "$FN" && fail "a write verb in curl" ||
  pass "no POST/PUT/PATCH/DELETE"
grep -qE 'gcloud (sql|config) ' "$FN" && fail "gcloud sql/config called" || pass "gcloud is used only for the token"
grep -q -- '--account="\$GCP_ACCOUNT"' "$FN" && pass "the token is pinned with --account" || fail "no --account pin"

# --- 3. the summariser ---------------------------------------------------------------
table() { SNIPPET='spl_db_insights_table 5 40' in_orc <<<"$1" 2>&1; }
BODY='{"timeSeries":[
 {"metric":{"labels":{"querystring":"SELECT  a\n FROM t","user":"spool_hub_rt"}},
  "points":[{"value":{"distributionValue":{"count":"10","mean":2000}}}]},
 {"metric":{"labels":{"querystring":"SELECT a FROM t","user":"spool_hub_rt"}},
  "points":[{"value":{"distributionValue":{"count":"10","mean":4000}}}]},
 {"metric":{"labels":{"querystring":"SELECT slow","user":"spool_hub_rt"}},
  "points":[{"value":{"distributionValue":{"count":"1","mean":90000}}}]},
 {"metric":{"labels":{"querystring":"SELECT never","user":"spool_hub_rt"}},
  "points":[{"value":{"distributionValue":{"count":"0"}}}]}]}'
o=$(table "$BODY")
grep -q "statements=2 calls=21 total_ms=150.0" <<<"$o" &&
  pass "same query after whitespace folding sums into one row; zero-call series dropped" || fail "totals: $o"
first_total=$(awk '/by total time/{getline; getline; print; exit}' <<<"$o")
[[ "$first_total" == *"SELECT slow"* ]] && pass "rank by total: 90 ms beats 60 ms" || fail "total rank: $first_total"
grep -qE '^ +20 +60\.0 +3\.00 ' <<<"$o" && pass "calls 20, total 60 ms, mean 3 ms for the folded query" || fail "row: $o"
first_calls=$(awk '/by calls/{getline; getline; print; exit}' <<<"$o")
[[ "$first_calls" == *"SELECT a FROM t"* ]] && pass "rank by calls" || fail "calls rank: $first_calls"
o=$(table '{"error":{"message":"permission denied"}}')
[[ "$o" == *"error: permission denied"* ]] && pass "an error body is reported" || fail "error body: $o"
o=$(table '{}')
[[ "$o" == *"no Query Insights points"* ]] && pass "an empty window says so" || fail "empty: $o"
o=$(table 'not json')
[[ "$o" == *"no data"* ]] && pass "a non-JSON body says so" || fail "garbage: $o"

(( fails == 0 )) && echo "OK spl-db-insights: all checks passed" || { echo "FAIL spl-db-insights: $fails check(s)"; exit 1; }
