#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_load_test (SPL-2138) is a bounded, dev-only load test of
# the deployed hub. Hermetic: a local stub hub on a free loopback port.
#   1. RED CONTROLS first: a stub that answers 5xx, one that sleeps past the
#      p95 threshold, and one that refuses the sign-in each FAIL the action
#   2. a healthy stub PASSES, with every request a 200 and a session cookie
#   3. ENV=prd (and any env but dev) is refused before the stub sees a request
#   4. the caps hold in the action AND in the driver; a non-loopback
#      SPL_HUB_LOAD_URL is refused
#   5. the password is never printed, never on a command line
#   6. the Cloud Run read runs after the load, for the run's window, and a
#      failed read never changes the verdict
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-hub-load-test.func.sh"
DRIVER="$PROJ_ROOT/src/bash/scripts/hub-load-test.py"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PW='stub-pw-Zq81'
printf '%s\n' "$PW" >"$T/pw"; chmod 600 "$T/pw"

# The stub hub: POST /api/v1/auth/login sets spool_session (or 401 in mode
# nologin); GET answers 200 with the session, 401 without, 503 in mode 5xx,
# and sleeps 300 ms first in mode slow. Every request is a line in $T/hits.
cat >"$T/stub.py" <<'PY'
import http.server, sys, time
mode, port_file, hits = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def hit(self):
        with open(hits, "a") as f: f.write(self.command + " " + self.path + "\n")
    def answer(self, code, cookie=False):
        self.send_response(code)
        if cookie: self.send_header("Set-Cookie", "spool_session_dev=s1; Path=/; HttpOnly")
        self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def do_POST(self):
        self.hit(); self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.answer(401) if mode == "nologin" else self.answer(200, cookie=True)
    def do_GET(self):
        self.hit()
        if mode == "slow": time.sleep(0.3)
        if mode == "5xx": return self.answer(503)
        self.answer(200 if "spool_session_dev=s1" in self.headers.get("Cookie", "") else 401)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY

# start_stub <mode> -> STUB_URL; the stub ends by itself (timeout), so the
# test never kills by a computed pid
start_stub() {
  : >"$T/hits"; rm -f "$T/port"
  timeout 40 python3 "$T/stub.py" "$1" "$T/port" "$T/hits" >/dev/null 2>&1 &
  local _; for _ in $(seq 1 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
  STUB_URL="http://127.0.0.1:$(cat "$T/port")"
}

# the action with the cnf and Cloud Run read stubbed; small, fast load
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_ORG_APP=csi-spl STUB_LOG="$T/calls.log" \
    LOAD_EMAIL=probe@example.com LOAD_PW_FILE="$T/pw" LOAD_RPS=20 LOAD_SECONDS=1 LOAD_METRICS=0 \
    "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; SPL_STATE_DIR=/nonexistent; }
    do_spl_hub_run_metrics() { echo "METRICS ENV=$ENV SINCE=$REQ_SINCE MIN=$REQ_MINUTES" >>"$STUB_LOG"; return "${METRICS_RC:-0}"; }
    sleep() { :; }
    do_spl_hub_load_test'
}
gets() { grep -c '^GET ' "$T/hits"; }

# --- 1. red controls: each bad hub fails the action --------------------------------
start_stub 5xx
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" >"$T/o" 2>&1 && fail "5xx stub: passed" || pass "RED CONTROL: a 5xx stub fails the action"
grep -q 'error rate 100.0 % > 1 %' "$T/o" && pass "5xx: the error rate names the cause" || fail "5xx: $(tail -3 "$T/o")"
grep -q '"503": 20' "$T/o" && pass "5xx: the status counts show 20 x 503" || fail "5xx counts: $(grep TOTAL "$T/o")"

start_stub slow
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" LOAD_MAX_P95_MS=100 >"$T/o" 2>&1 && fail "slow stub: passed" || pass "RED CONTROL: a stub slower than the p95 threshold fails the action"
grep -qE 'p95 [0-9.]+ ms > 100 ms' "$T/o" && pass "slow: the p95 names the cause" || fail "slow: $(tail -3 "$T/o")"

start_stub nologin
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" >"$T/o" 2>&1 && fail "nologin: passed" || pass "RED CONTROL: a refused sign-in fails the action"
[[ $(gets) == 0 ]] && pass "nologin: no load was sent without a session" || fail "nologin: $(gets) GETs sent"

# --- 2. a healthy hub passes ---------------------------------------------------------
start_stub ok
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" >"$T/o" 2>&1 && pass "a healthy stub passes" || fail "healthy: $(tail -5 "$T/o")"
grep -q '"200": 20' "$T/o" && pass "healthy: 20 x 200 with the session cookie" || fail "healthy counts: $(grep TOTAL "$T/o")"
grep -qE '^TOTAL +20 ' "$T/o" && grep -q 'p50' "$T/o" && grep -q '"verdict": "PASS"' "$T/o" &&
  pass "healthy: per-path and TOTAL rows, JSON verdict" || fail "healthy table: $(cat "$T/o")"
[[ $(grep -c '^POST /api/v1/auth/login' "$T/hits") == 1 ]] && pass "one sign-in per run" || fail "sign-ins: $(grep -c POST "$T/hits")"
grep -qvE '^(GET|POST) ' "$T/hits" && fail "a write method reached the hub: $(grep -vE '^(GET|POST) ' "$T/hits")" || pass "read-only: GET only after the sign-in"
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" LOAD_PATHS=/a,/b >"$T/o" 2>&1
grep -qE '^/a +10 ' "$T/o" && grep -qE '^/b +10 ' "$T/o" && pass "LOAD_PATHS round-robin, one row per path" || fail "paths: $(cat "$T/o")"

# --- 3. dev only ---------------------------------------------------------------------
for e in prd lde ''; do
  : >"$T/hits"
  in_orc ENV="$e" SPL_HUB_LOAD_URL="$STUB_URL" >"$T/o" 2>&1 && fail "ENV='$e': ran" || pass "ENV='$e': refused"
  grep -q 'FATAL .*ENV=dev only' "$T/o" && pass "ENV='$e': the refusal is FATAL and named" || fail "ENV='$e': $(cat "$T/o")"
  [[ ! -s "$T/hits" ]] && pass "ENV='$e': the hub saw no request" || fail "ENV='$e': hits $(cat "$T/hits")"
done

# --- 4. caps ---------------------------------------------------------------------------
for kv in LOAD_RPS=51 LOAD_RPS=0 LOAD_RPS=x LOAD_CONCURRENCY=51 LOAD_SECONDS=901 LOAD_METRICS_WAIT=301 \
          LOAD_METRICS=2 LOAD_MAX_P95_MS=fast; do
  : >"$T/hits"
  in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" "$kv" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && [[ ! -s "$T/hits" ]] && pass "$kv: FATAL before any request" || fail "$kv: $(cat "$T/o")"
done
for kv in LOAD_RPS=51 LOAD_CONCURRENCY=51 LOAD_SECONDS=901; do
  env LOAD_URL="$STUB_URL" LOAD_PATHS=/a "$kv" python3 "$DRIVER" >/dev/null 2>"$T/e"
  [[ $? == 2 ]] && grep -q FATAL "$T/e" && pass "driver: $kv refused (exit 2)" || fail "driver: $kv: $(cat "$T/e")"
done
for u in https://dev.api.example.com http://10.0.0.5:8080 http://127.0.0.1.example.com:80; do
  in_orc ENV=dev SPL_HUB_LOAD_URL="$u" >"$T/o" 2>&1 && fail "SPL_HUB_LOAD_URL=$u: ran" || pass "SPL_HUB_LOAD_URL=$u: refused (loopback only)"
done

# --- 5. the password stays secret ------------------------------------------------------
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" >"$T/o" 2>&1
grep -qF "$PW" "$T/o" && fail "the password was printed" || pass "the password is never printed"
grep -qE '^\s*env .*login\[@\]' "$FN" && fail "the login words are passed on a command line" || pass "the login is exported, never on a command line"
chmod 644 "$T/pw"
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" >"$T/o" 2>&1 && fail "a 0644 password file was read" || pass "a password file readable by others is refused"
chmod 600 "$T/pw"

# --- 6. the Cloud Run read --------------------------------------------------------------
: >"$T/calls.log"
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" LOAD_METRICS=1 >"$T/o" 2>&1 && pass "LOAD_METRICS=1 passes" || fail "metrics run: $(tail -3 "$T/o")"
grep -qE '^METRICS ENV=dev SINCE=[0-9-]{10}T[0-9:]{8}Z MIN=[0-9]+$' "$T/calls.log" &&
  pass "the Cloud Run read runs on dev for the run's window" || fail "metrics call: $(cat "$T/calls.log")"
in_orc ENV=dev SPL_HUB_LOAD_URL="$STUB_URL" LOAD_METRICS=1 METRICS_RC=1 >"$T/o" 2>&1 &&
  grep -q 'WARN Cloud Run metrics not read' "$T/o" && pass "a failed Cloud Run read is a WARN, the verdict stands" || fail "metrics rc: $(tail -3 "$T/o")"

echo "----"
(( fails == 0 )) && { echo "ALL PASS (spl-hub-load-test)"; exit 0; }
echo "$fails FAILED (spl-hub-load-test)"; exit 1
