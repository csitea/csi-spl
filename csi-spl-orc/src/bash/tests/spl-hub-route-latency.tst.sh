#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_route_latency is a READ-ONLY Cloud Run request-log
# report. Offline:
#   1. bad ROUTE_HOURS / ROUTE_TOP / ROUTE_LIMIT / ROUTE_SINCE are refused
#      BEFORE gcloud is called. CONTROL: the stub log records a call
#   2. the only cloud call is `gcloud logging read`, pinned with --account
#   3. spl_hub_route_latency_table folds ids into one route, gives
#      n / p50 / p95 / max / 4xx / 5xx / KB, lists websockets apart, and says
#      so plainly on an empty or non-JSON body
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-hub-route-latency.func.sh"
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
for kv in ROUTE_HOURS=0 ROUTE_HOURS=169 ROUTE_HOURS=x ROUTE_TOP=0 ROUTE_LIMIT=0 ROUTE_LIMIT=300000 \
          ROUTE_SINCE=yesterday "ROUTE_SINCE=2026-09-27 21:00:00"; do
  : >"$T/calls.log"
  SNIPPET=do_spl_hub_route_latency in_orc "$kv" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && pass "$kv: the refusal is FATAL and named" || fail "$kv: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no gcloud call" || fail "$kv: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. read-only, pinned -------------------------------------------------------------
[[ $(grep -cE '^\s*gcloud ' "$FN") == 1 ]] && grep -qE '^\s*gcloud logging read ' "$FN" &&
  pass "the one gcloud call is logging read" || fail "gcloud calls other than logging read"
grep -q -- '--account="\$GCP_ACCOUNT"' "$FN" && pass "it is pinned with --account" || fail "no --account pin"
grep -qE 'curl|gcloud (run|sql|config|logging (write|delete|sinks))' "$FN" && fail "a write-capable call" || pass "no curl, no write-capable gcloud"

# --- 3. the summariser ---------------------------------------------------------------
table() { SNIPPET='spl_hub_route_latency_table 10' in_orc <<<"$1" 2>&1; }
e() { # method url latency_s status bytes
  printf '{"timestamp":"2026-09-27T21:0%s:00Z","resource":{"labels":{"revision_name":"rev-1"}},"httpRequest":{"requestMethod":"%s","requestUrl":"https://api.example.com%s","latency":"%ss","status":%s,"responseSize":"%s"}}' \
    "$6" "$1" "$2" "$3" "$4" "$5"
}
BODY="[$(e GET /v1/view/topics/11111111-2222-3333-4444-555555555555 0.010 200 2048 1),
$(e GET '/v1/view/topics/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee?x=1' 0.030 200 4096 2),
$(e GET /v1/view/topics/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 0.020 404 100 3),
$(e GET /v1/files/0123456789abcdef0123456789abcdef0123 0.100 200 10240 4),
$(e PUT /v1/issues/SPL-12 0.005 500 10 5),
$(e GET /v1/wui/ws 1800 101 0 6),
$(e GET /v1/wui/ws 0.001 401 188 7)]"
out=$(table "$BODY")
row() { grep -E "^ *[0-9]+ $1 +$2 " <<<"$out"; }
r=$(row GET '/v1/view/topics/\{id\}')
[[ -n "$r" ]] && awk '{exit !($1==3 && $4=="20.0" && $5=="30.0" && $7==1 && $8==0 && $9=="2.0" && $10=="4.0")}' <<<"$r" &&
  pass "uuids fold into one route: n=3, p50 20 ms, p95 30 ms, one 4xx, KB (nearest rank) of the 200s only" || fail "topic row: $r / $out"
[[ -n "$(row GET '/v1/files/\{hash\}')" && -n "$(row PUT '/v1/issues/\{key\}')" ]] &&
  pass "file hashes and issue keys fold" || fail "hash/key fold: $out"
awk '/\/v1\/issues\/\{key\}/{exit !($8==1)}' <<<"$out" && pass "a 5xx is counted" || fail "5xx: $out"
ws_line=$(grep -n 'websockets' <<<"$out" | cut -d: -f1); ws_row=$(grep -n '/v1/wui/ws' <<<"$out" | cut -d: -f1)
[[ -n "$ws_line" && -n "$ws_row" && $ws_row -gt $ws_line ]] && awk '/\/v1\/wui\/ws/{exit !($1==2 && $7==1)}' <<<"$out" &&
  pass "websockets are listed apart, the refused upgrade is a 4xx" || fail "ws section: $out"
grep -q 'revisions=rev-1' <<<"$out" && pass "the revisions in the window are named" || fail "revisions: $out"
grep -q 'no request log entries' <<<"$(table '[]')" && pass "empty window said plainly" || fail "empty window"
grep -q 'no data' <<<"$(table 'not json')" && pass "non-JSON body said plainly" || fail "non-JSON"

((fails == 0)) && echo "OK spl-hub-route-latency: all checks passed" || { echo "FAIL spl-hub-route-latency: $fails check(s)"; exit 1; }
