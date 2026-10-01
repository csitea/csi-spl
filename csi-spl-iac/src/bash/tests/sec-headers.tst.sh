#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_headers fails closed, its negative control can fail, and a
#          response missing headers reddens the gate. Uses local mock servers;
#          the real check runs from .github/workflows/68_dast.yml against dev.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/sec-headers.func.sh"
WF="$APP_ROOT/.github/workflows/68_dast.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it" \
  || { echo "FAIL: no $FUNC"; exit 1; }
command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "FAIL: curl+python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-headers.func.sh
source "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"; jobs -p | xargs -r kill 2>/dev/null' EXIT

# Each mock binds port 0 itself and writes the port it got to <portfile> once
# listening; _sec_headers_wait_port (the action's own helper) polls for it with a
# bounded wait. No fixed sleep and no pick-then-bind port race: under box load
# (~55+) the old `sleep 1` let curl hit a server that was not up yet.
SERVE_TAIL='srv=http.server.HTTPServer(("127.0.0.1",0),H)
with open(sys.argv[1]+".tmp","w") as f: f.write(str(srv.server_address[1]))
os.rename(sys.argv[1]+".tmp",sys.argv[1])
srv.serve_forever()'
# serve <script> <var>: start it as a job of THIS shell (so the EXIT trap's
# `jobs -p` reaps it) and set <var> to its port once it is listening.
serve() {
  local p
  python3 "$1" "$1.port" >/dev/null 2>&1 &
  p=$(_sec_headers_wait_port "$1.port" "$!") || { echo "FAIL: mock $1 never listened"; exit 1; }
  printf -v "$2" '%s' "$p"
}

# Start a server that emits ALL required headers (a "good" target).
cat >"$T/good.py" <<'PY'
import os,sys,http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        for k,v in [("Strict-Transport-Security","max-age=63072000"),
                    ("X-Content-Type-Options","nosniff"),
                    ("Referrer-Policy","strict-origin"),
                    ("Content-Security-Policy","default-src 'self'")]:
            self.send_header(k,v)
        self.end_headers()
    def do_GET(self): self.do_HEAD()
    def log_message(self,*a): pass
PY
echo "$SERVE_TAIL" >>"$T/good.py"
serve "$T/good.py" port

# --- CONTROL only (built-in header-less mock) passes -> control fires --------
set +e
out=$(SEC_HEADERS_SKIP_SCAN=1 do_sec_headers 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'control flagged' <<<"$out" \
  && pass "control flags a header-less mock" || { fail "control did not fire (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- scan against a good server passes --------------------------------------
set +e
out=$(SEC_HEADERS_URL="http://127.0.0.1:$port" do_sec_headers 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'all required headers present' <<<"$out" \
  && pass "a target with all headers passes" || { fail "good target did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- scan against a header-less target fails --------------------------------
cat >"$T/bad.py" <<'PY'
import os,sys,http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200); self.send_header("X-Content-Type-Options","nosniff"); self.end_headers()
    def do_GET(self): self.do_HEAD()
    def log_message(self,*a): pass
PY
echo "$SERVE_TAIL" >>"$T/bad.py"
serve "$T/bad.py" badport
set +e
out=$(SEC_HEADERS_URL="http://127.0.0.1:$badport" do_sec_headers 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'missing on' <<<"$out" \
  && pass "a target missing headers fails the gate" || fail "missing-headers target did not fail (rc=$rc)"

# --- an unreachable target fails closed -------------------------------------
deadport=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
set +e
out=$(SEC_HEADERS_URL="http://127.0.0.1:$deadport" do_sec_headers 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'could not be fetched' <<<"$out" \
  && pass "an unreachable target fails closed" || fail "unreachable target did not fail closed (rc=$rc)"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  grep -qF 'do_sec_headers' "$WF" && grep -qE 'BASE_DOMAIN|dev\.' "$WF" \
    && pass "68_dast.yml runs the headers check against the dev host (derived from cnf)" \
    || fail "68_dast.yml missing do_sec_headers/dev target"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-headers.tst.sh assertions"
exit "$fails"
