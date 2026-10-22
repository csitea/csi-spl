#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_window is a READ-ONLY read of one window of the hub's
# Cloud SQL instance (SPL-2880). Offline:
#   1. bad DBW_SINCE / DBW_MINUTES / DBW_STEP / DBW_PART / DBW_LOG_LIMIT are
#      refused BEFORE gcloud is called. CONTROL: the stub log records a call
#   2. the only cloud calls are `gcloud logging read` (pinned with --account),
#      the token for the pinned SA and the Monitoring timeSeries GET
#   3. spl_db_window_series summarises a series per label (n, min, p50, mean,
#      p95, max) and prints an API error instead of failing
#   4. spl_db_window_log gives the checkpoint p50/p95/max and the statement
#      timeouts per 10 minutes; DBW_JSON_IN reads a saved dir, no gcloud call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-db-window.func.sh"
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
OK=DBW_SINCE=2026-10-22T09:20:00Z
for kv in DBW_SINCE= DBW_SINCE=yesterday DBW_SINCE=2026-10-22T09:20 "$OK DBW_MINUTES=0" "$OK DBW_MINUTES=1441" \
          "$OK DBW_STEP=59" "$OK DBW_STEP=3601" "$OK DBW_PART=disk" "$OK DBW_LOG_LIMIT=0"; do
  : >"$T/calls.log"
  # shellcheck disable=SC2086
  SNIPPET=do_spl_db_window in_orc $kv >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && pass "$kv: the refusal is FATAL and named" || fail "$kv: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no gcloud call" || fail "$kv: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. read-only, pinned -------------------------------------------------------------
[[ $(grep -cE '^\s*gcloud ' "$FN") == 1 ]] && grep -qE '^\s*gcloud logging read ' "$FN" &&
  pass "the one gcloud command line is logging read" || fail "gcloud calls other than logging read"
grep -q -- '--account="\$GCP_ACCOUNT" --limit' "$FN" && pass "logging read is pinned with --account" || fail "no --account pin"
grep -q 'print-access-token --account="\$GCP_ACCOUNT"' "$FN" && pass "the token is for the pinned SA" || fail "token not pinned"
grep -qE 'curl .* -G ' "$FN" && ! grep -qE -- '-X [A-Z]|--data-(raw|binary)|--data ' "$FN" &&
  pass "curl is GET only (-G, urlencoded query)" || fail "a non-GET curl"
grep -qE 'gcloud (run|sql|config|logging (write|delete|sinks))' "$FN" && fail "a write-capable gcloud" || pass "no write-capable gcloud"

# --- 3. one series per label ------------------------------------------------------------
pt() { printf '{"interval":{"endTime":"2026-10-22T09:%s:00Z"},"value":{"doubleValue":%s}}' "$1" "$2"; }
SER='{"timeSeries":[{"metric":{"labels":{"wait_event_type":"CPU"}},"points":['"$(pt 21 1),$(pt 22 3),$(pt 23 11)"']},
{"metric":{"labels":{"wait_event_type":"IO"}},"points":['"$(pt 21 2)"']}]}'
OUT=$(SNIPPET='spl_db_window_series postgresql/backends_in_wait wait_event_type <<<"$SER"' SER="$SER" in_orc 2>&1)
read -r _ lab n lo p50 mean _ hi <<<"$(grep ' CPU ' <<<"$OUT")"
[[ "$lab $n $lo $p50 $hi" == "CPU 3 1.0000 3.0000 11" ]] && pass "CPU row: n=3 min=1 p50=3 max=11" || fail "CPU row: $OUT"
[[ "$mean" == 5.0000 ]] && pass "CPU row: mean=5" || fail "CPU mean: $mean"
grep -q ' IO .* 1 ' <<<"$OUT" && pass "IO is its own row, n=1" || fail "IO row: $OUT"
OUT=$(SNIPPET='spl_db_window_series swap/bytes_used - <<<"{\"error\":{\"message\":\"bad metric\"}}"' in_orc 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q 'error: bad metric' <<<"$OUT" && pass "an API error is printed, the report goes on" || fail "error: rc=$rc $OUT"
OUT=$(SNIPPET='spl_db_window_series cpu/utilization - <<<"{}"' in_orc 2>&1)
grep -q 'no points in the window' <<<"$OUT" && pass "an empty response says no points" || fail "empty: $OUT"

# --- 4. the checkpoint log and DBW_JSON_IN -----------------------------------------------
ck() { printf '{"timestamp":"2026-10-22T%s","textPayload":"LOG:  checkpoint complete: wrote %s buffers (1.2%%); 0 WAL file(s) added, 0 removed, 1 recycled; write=%s s, sync=%s s, total=%s s; sync files=40, longest=%s s, average=0.01 s; distance=900 kB, estimate=1000 kB"}' "$@"; }
mkdir -p "$T/saved"
printf '[%s,%s,%s,%s,%s]' "$(ck 09:41:00Z 100 30.0 0.014 32.0 0.005)" "$(ck 09:46:00Z 368 139.0 1.016 141.0 0.220)" \
  "$(ck 10:05:15Z 644 245.5 2.255 248.3 0.506)" \
  '{"timestamp":"2026-10-22T09:52:00Z","textPayload":"ERROR:  canceling statement due to statement timeout"}' \
  '{"timestamp":"2026-10-22T10:01:00Z","textPayload":"ERROR:  canceling statement due to statement timeout"}' >"$T/saved/log.json"
: >"$T/calls.log"
OUT=$(SNIPPET=do_spl_db_window in_orc "$OK" DBW_PART=log DBW_JSON_IN="$T/saved" 2>&1)
[[ ! -s "$T/calls.log" ]] && pass "DBW_JSON_IN: no gcloud call" || fail "DBW_JSON_IN called: $(cat "$T/calls.log")"
grep -q 'checkpoints n=3' <<<"$OUT" && pass "3 checkpoints parsed" || fail "checkpoint count: $OUT"
read -r _ p50 _ hi <<<"$(grep '^sync ' <<<"$OUT")"
[[ "$p50 $hi" == "1.016 2.255" ]] && pass "sync p50=1.016 max=2.255" || fail "sync row: $(grep '^sync' <<<"$OUT")"
grep -q 'worst by sync: 10:05:15 sync=2.255' <<<"$OUT" && pass "worst checkpoint first" || fail "worst: $OUT"
grep -q 'statement timeouts n=2 per 10 min: 09:50 1, 10:00 1' <<<"$OUT" && pass "timeouts per 10 min" || fail "timeouts: $OUT"
OUT=$(SNIPPET=do_spl_db_window in_orc "$OK" DBW_PART=metrics DBW_JSON_IN="$T/saved" 2>&1)
[[ $(grep -c 'no saved read' <<<"$OUT") == $(SNIPPET=spl_db_window_metrics in_orc | wc -l) ]] &&
  pass "every series without a saved read says so" || fail "missing reads: $OUT"

echo "fails=$fails"
[[ $fails == 0 ]]
