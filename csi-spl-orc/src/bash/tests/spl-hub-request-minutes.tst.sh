#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_request_minutes and do_spl_hub_run_metrics are READ-ONLY
# reads of one window of the hub's Cloud Run log / metrics (SPL-1981). Offline:
#   1. bad REQ_SINCE / REQ_MINUTES / REQ_LIMIT / REQ_TOP are refused BEFORE
#      gcloud is called. CONTROL: the stub log records a call
#   2. the only cloud calls are `gcloud logging read` (pinned with --account)
#      and the Monitoring timeSeries GET; no write-capable call
#   3. spl_hub_request_minutes_table gives one row per minute (req, 2xx, 429,
#      4xx, 5xx, ws, "no available instance", callers, top routes) and the
#      callers; REQ_JSON_IN summarises a saved read with no gcloud call
#   4. spl_hub_run_metrics_table prints one column per series
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-hub-request-minutes.func.sh"
FM="$PROJ_ROOT/src/bash/run/spl-hub-run-metrics.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\nexit 1\n' >"$T/stub/gcloud"
chmod +x "$T/stub/gcloud"

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
for act in do_spl_hub_request_minutes do_spl_hub_run_metrics; do
  for kv in REQ_SINCE= REQ_SINCE=yesterday REQ_SINCE=2026-10-15T07:15 "REQ_MINUTES=0 REQ_SINCE=2026-10-15T07:15:00Z" \
            "REQ_MINUTES=361 REQ_SINCE=2026-10-15T07:15:00Z"; do
    : >"$T/calls.log"
    # shellcheck disable=SC2086
    SNIPPET=$act in_orc $kv >"$T/o" 2>&1 && fail "$act $kv: ran" || pass "$act $kv: refused"
    grep -q FATAL "$T/o" && pass "$act $kv: the refusal is FATAL and named" || fail "$act $kv: refusal text: $(cat "$T/o")"
    [[ ! -s "$T/calls.log" ]] && pass "$act $kv: no gcloud call" || fail "$act $kv: called: $(cat "$T/calls.log")"
  done
done
for kv in REQ_LIMIT=0 REQ_LIMIT=300000 REQ_TOP=0; do
  : >"$T/calls.log"
  SNIPPET=do_spl_hub_request_minutes in_orc REQ_SINCE=2026-10-15T07:15:00Z "$kv" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no gcloud call" || fail "$kv: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. read-only, pinned -------------------------------------------------------------
[[ $(grep -cE '^\s*gcloud ' "$FN") == 1 ]] && grep -qE '^\s*gcloud logging read ' "$FN" &&
  pass "the one gcloud call is logging read" || fail "gcloud calls other than logging read"
grep -q -- '--account="\$GCP_ACCOUNT"' "$FN" && pass "it is pinned with --account" || fail "no --account pin"
grep -qE '^\s*curl |gcloud (run|sql|config|logging (write|delete|sinks))' "$FN" && fail "a write-capable call" || pass "no curl, no write-capable gcloud"
grep -qE -- '-X [A-Z]|--data-(raw|binary)|--data ' "$FM" || ! grep -qE 'curl .* -G ' "$FM" && fail "metrics: a non-GET curl" || pass "metrics: GET only (-G, urlencoded query)"
grep -q 'print-access-token --account="\$GCP_ACCOUNT"' "$FM" && pass "metrics: token for the pinned SA" || fail "metrics: token not pinned"
grep -qE 'gcloud (run|sql|config|logging)' "$FM" && fail "metrics: a write-capable gcloud" || pass "metrics: no other gcloud"

# --- 3. the per-minute table ----------------------------------------------------------
e() { # minute url status ip ua latency
  printf '{"timestamp":"2026-10-15T07:%s:01Z","httpRequest":{"requestMethod":"GET","requestUrl":"https://api.example.com%s","status":%s,"remoteIp":"%s","userAgent":"%s","latency":"%ss"}}' "$@"
}
BODY="[$(e 31 /v1/ws 101 10.0.0.1 Go-http-client/1.1 0.03),$(e 31 /v1/pins 200 10.0.0.1 Go-http-client/2.0 0.004),
$(e 32 /v1/pins 429 10.0.0.1 Go-http-client/2.0 0.0),$(e 32 /v1/ws 429 10.0.0.2 Go-http-client/1.1 0.0),
$(e 32 /v1/view/topics/11111111-2222-3333-4444-555555555555 200 10.0.0.3 Mozilla/5.0 0.120),
{\"timestamp\":\"2026-10-15T07:32:02Z\",\"textPayload\":\"The request was aborted because there was no available instance.\"}]"
printf '%s' "$BODY" >"$T/read.json"
: >"$T/calls.log"
OUT=$(SNIPPET=do_spl_hub_request_minutes in_orc REQ_SINCE=2026-10-15T07:30:00Z REQ_JSON_IN="$T/read.json" 2>&1)
[[ ! -s "$T/calls.log" ]] && pass "REQ_JSON_IN: no gcloud call" || fail "REQ_JSON_IN called: $(cat "$T/calls.log")"
row() { awk -v m="$1" '$1 == m' <<<"$OUT"; }
read -r _ req ok r429 _ _ ws ni ips _ <<<"$(row 07:31)"
[[ "$req $ok $r429 $ws $ni $ips" == "2 2 0 1 0 1" ]] && pass "07:31: 2 req, 2 ok, 1 ws, 1 caller" || fail "07:31 row: $(row 07:31)"
read -r _ req ok r429 _ _ ws ni ips _ <<<"$(row 07:32)"
[[ "$req $ok $r429 $ws $ni $ips" == "3 1 2 1 1 3" ]] && pass "07:32: 3 req, 2 x 429, 1 no-instance, 3 callers" || fail "07:32 row: $(row 07:32)"
grep -q '/v1/view/topics/{id}' <<<"$OUT" && pass "ids are folded" || fail "ids not folded: $OUT"
grep -qE '^ +3 +1 +1 +10\.0\.0\.1 +go-http-client' <<<"$OUT" && pass "callers: ip + agent class, 429 and ws counted" || fail "callers: $OUT"
grep -q 'no log entries' <<<"$(SNIPPET='spl_hub_request_minutes_table 3' in_orc <<<'[]' 2>&1)" && pass "empty read said plainly" || fail "empty read"
grep -q 'no data' <<<"$(SNIPPET='spl_hub_request_minutes_table 3' in_orc <<<'oops' 2>&1)" && pass "non-JSON said plainly" || fail "non-JSON"
grep -q TRUNCATED <<<"$(SNIPPET='spl_hub_request_minutes_table 3 6' in_orc <"$T/read.json" 2>&1)" && pass "a read at the limit says TRUNCATED" || fail "no TRUNCATED at the limit"

# --- 4. the metrics table -------------------------------------------------------------
TS='{"timeSeries":[{"metric":{"labels":{"state":"active"}},"resource":{"labels":{"revision_name":"r-1"}},"points":[{"interval":{"endTime":"2026-10-15T07:33:00Z"},"value":{"int64Value":"2"}}]},{"metric":{"labels":{"state":"idle"}},"resource":{"labels":{}},"points":[{"interval":{"endTime":"2026-10-15T07:33:00Z"},"value":{"int64Value":"0"}}]}]}'
MT=$(SNIPPET='spl_hub_run_metrics_table state' in_orc <<<"$TS" 2>&1)
grep -qE 'active +idle' <<<"$MT" && grep -qE '^07:33 +2\.00 +0\.00' <<<"$MT" && pass "metrics: one column per series" || fail "metrics table: $MT"
SNIPPET='spl_hub_run_metrics_table state' in_orc <<<'{"error":{"message":"denied"}}' >"$T/o" 2>&1 && fail "metrics error: rc 0" || pass "metrics error: rc 1"
grep -q 'error: denied' "$T/o" && pass "metrics error is printed" || fail "metrics error text: $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
