#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_perf_budget and perf-budget.py. No cloud call.
#   1. pct interpolates, so a short run does not report its maximum as p95
#   2. a JS file the document does not name is not in the initial gzip, and
#      a repeated src= plus modulepreload counts once
#   3. the ceiling check FAILS when a number is over, when a required number
#      was not measured, and when the initial set is empty — and PASSES when
#      the number is equal to the ceiling. The over case is the control that
#      a green run is not a check that cannot fail
#   4. live against a stub hub: one sign-in, the three view reads, no password,
#      no cookie and no response body in the output. A refused sign-in exits 2.
#      A view that answers 500 exits non-zero. A ceiling of -1 exits 1
#   5. the action dry run fetches nothing. DRY_RUN=0 without a password file
#      is refused. DRY_RUN=0 against the stub records a report
#   6. the committed ceilings are above the basis that was measured when they
#      were written, and they name every key the CI and live checks require
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
PY="$PROJ_ROOT/src/bash/scripts/perf-budget.py"
BUD="$APP_ROOT/csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json"
T=$(mktemp -d)
fails=0
SRV=""
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

[[ -f "$PY" ]] && pass "perf-budget.py ships with the action" || fail "perf-budget.py is missing"

# --- 1. percentile -----------------------------------------------------------------
got="$(python3 - "$PY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("perf_budget", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
xs = list(range(1, 101))
p50, p95 = m.pct(xs, 50), m.pct(xs, 95)
print("interp" if 94.0 < p95 < 96.0 and p95 != max(xs) else "p95=%r" % p95,
      "median" if p50 == 50.5 else "p50=%r" % p50,
      "empty" if m.pct([], 50) is None else "empty=%r" % m.pct([], 50),
      "single" if m.pct([7], 95) == 7 else "single=%r" % m.pct([7], 95))
PY
)" || got="ERR"
case "$got" in
  "interp median empty single") pass "pct interpolates, and is safe on an empty and a single sample" ;;
  *) fail "pct is not a percentile: got '$got'" ;;
esac

# --- 2/3. bundle set and the ceiling control --------------------------------------
mkdir -p "$T/pub/_nuxt"
# Incompressible bodies, so dropping the unnamed chunk changes the 0.1 KB figure.
python3 -c 'import os; p=os.sys.argv[1];
[open(p+"/_nuxt/"+n,"wb").write(os.urandom(8000)) for n in ("app.js","lazy.js","orphan.js")]' "$T/pub"
cat >"$T/pub/200.html" <<'HTML'
<!doctype html>
<script type="module" src="/_nuxt/app.js"></script>
<link rel="modulepreload" href="/_nuxt/app.js">
<script type="module" src="/_nuxt/lazy.js"></script>
HTML
setline="$(python3 - "$PY" "$T/pub" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("perf_budget", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
pub = sys.argv[2]
kb, n = m.bundle_dir(pub)
app = open(pub + "/_nuxt/app.js", "rb").read()
lazy = open(pub + "/_nuxt/lazy.js", "rb").read()
want = m.kb_of(m.gzip_len(app) + m.gzip_len(lazy))
orphan = m.kb_of(m.gzip_len(app) + m.gzip_len(lazy) + m.gzip_len(open(pub + "/_nuxt/orphan.js", "rb").read()))
print("set" if n == 2 and kb == want and kb != orphan else "bad %s %s %s %s" % (n, kb, want, orphan))
PY
)"
[[ "$setline" == set ]] && pass "initial gzip is the named chunks once, not every file on disk" || fail "bundle set: $setline"

printf '%s\n' '{"ceilings":{"ci_initial_gzip_kb":0}}' >"$T/over.json"
printf '%s\n' '{"ceilings":{"ci_initial_gzip_kb":99999}}' >"$T/under.json"
python3 "$PY" bundle --pub "$T/pub" --budgets "$T/over.json" >"$T/bout" 2>&1
rc=$?
[[ $rc -eq 1 ]] && grep -q '^FAIL ci_initial_gzip_kb ' "$T/bout" \
  && pass "CONTROL: initial gzip over the ceiling exits 1" || fail "CONTROL over: rc=$rc $(cat "$T/bout")"
python3 "$PY" bundle --pub "$T/pub" --budgets "$T/under.json" >"$T/bout" 2>&1
rc=$?
[[ $rc -eq 0 ]] && grep -q '^PASS ci_initial_gzip_kb ' "$T/bout" \
  && pass "initial gzip under the ceiling exits 0" || fail "under: rc=$rc $(cat "$T/bout")"

mkdir -p "$T/empty/_nuxt"
printf 'console.log("orphan")\n' >"$T/empty/_nuxt/orphan.js"
printf '<!doctype html><p>no scripts</p>\n' >"$T/empty/200.html"
python3 "$PY" bundle --pub "$T/empty" --budgets "$T/under.json" >"$T/bout" 2>&1
rc=$?
[[ $rc -eq 1 ]] && grep -q 'initial JS set is empty' "$T/bout" \
  && pass "CONTROL: an empty initial set fails even under a huge ceiling" || fail "CONTROL empty: rc=$rc $(cat "$T/bout")"

printf '%s\n' '{"metrics":{"ci_initial_gzip_kb":9}}' >"$T/eqrep.json"
printf '%s\n' '{"ceilings":{"ci_initial_gzip_kb":9}}' >"$T/eqbud.json"
python3 "$PY" check --report "$T/eqrep.json" --budgets "$T/eqbud.json" --require ci >"$T/bout" 2>&1
rc=$?
[[ $rc -eq 0 ]] && grep -q '^PASS ci_initial_gzip_kb 9 <= 9$' "$T/bout" \
  && pass "a value equal to its ceiling passes" || fail "equal: rc=$rc $(cat "$T/bout")"
printf '%s\n' '{"metrics":{"ci_initial_gzip_kb":9.1}}' >"$T/eqrep.json"
python3 "$PY" check --report "$T/eqrep.json" --budgets "$T/eqbud.json" --require ci >"$T/bout" 2>&1
rc=$?
[[ $rc -eq 1 ]] && grep -q '^FAIL ci_initial_gzip_kb 9.1 > 9$' "$T/bout" \
  && pass "CONTROL: 0.1 over the ceiling exits 1" || fail "CONTROL 0.1: rc=$rc $(cat "$T/bout")"
printf '%s\n' '{"metrics":{"ci_initial_gzip_kb":1}}' >"$T/rep.json"
printf '%s\n' '{"ceilings":{"ci_initial_gzip_kb":5,"first_load_p95_ms":5}}' >"$T/both.json"
python3 "$PY" check --report "$T/rep.json" --budgets "$T/both.json" --require live >"$T/bout" 2>&1
rc=$?
[[ $rc -eq 1 ]] && grep -q 'first_load_p95_ms was not measured' "$T/bout" \
  && pass "CONTROL: a report that omits a required number fails" || fail "CONTROL missing: rc=$rc $(cat "$T/bout")"

# --- 4. live stub --------------------------------------------------------------------
cat >"$T/stub.py" <<'PY'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
T = sys.argv[1]
LOCK = threading.Lock()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _hit(self):
        with LOCK:
            with open(os.path.join(T, "hits"), "a") as f:
                f.write(self.command + " " + self.path.split("?")[0] + "\n")
    def _send(self, code, body, cookie=False, typ="application/json"):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(raw)))
        if cookie:
            self.send_header("Set-Cookie", "spool_session_dev=tok-secret-cookie; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(raw)
    def do_POST(self):
        self._hit()
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        open(os.path.join(T, "login.json"), "w").write(json.dumps(body))
        if self.path == "/api/v1/auth/login" and body.get("password") == "pw-secret-not-for-logs":
            return self._send(200, {}, cookie=True)
        self._send(401, {"error": "unauthenticated"})
    def do_GET(self):
        self._hit()
        path = self.path.split("?")[0]
        if path == "/build.json":
            return self._send(200, {"commit": "abc123abc123abc123abc123abc123abc123abcd", "built_at": "t"})
        if path == "/version":
            return self._send(200, {"commit": "def456def456def456def456def456def456def4", "version": "0.0.0"})
        if path == "/":
            html = b'<!doctype html><script type="module" src="/_nuxt/app.js"></script>'
            return self._send(200, html, typ="text/html")
        if path == "/_nuxt/app.js":
            return self._send(200, b'console.log("app")\n', typ="text/javascript")
        if path.startswith("/v1/view/"):
            if self.headers.get("Cookie") != "spool_session_dev=tok-secret-cookie":
                return self._send(401, {"error": "view_door"})
            if path == "/v1/view/roster" and os.path.exists(os.path.join(T, "roster-500")):
                return self._send(500, {"error": "boom", "secret_marker": "BODY-SECRET"})
            return self._send(200, {"ok": True, "secret_marker": "BODY-SECRET", "path": path})
        self._send(404, {"error": "not_found"})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 "$T/stub.py" "$T" & SRV=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
[[ -s "$T/port" ]] && pass "the stub hub is listening" || fail "the stub hub did not start"
umask 077
printf '%s\n' 'pw-secret-not-for-logs' >"$T/pw"
PORT="$(cat "$T/port")"
BASE="http://127.0.0.1:$PORT"
cat >"$T/hi.json" <<'JSON'
{"ceilings":{"dev_initial_gzip_kb":99999,"first_load_p95_ms":99999,"view_me_p95_ms":99999,"view_channels_p95_ms":99999,"view_roster_p95_ms":99999}}
JSON
cat >"$T/neg.json" <<'JSON'
{"ceilings":{"dev_initial_gzip_kb":-1,"first_load_p95_ms":-1,"view_me_p95_ms":-1,"view_channels_p95_ms":-1,"view_roster_p95_ms":-1}}
JSON
live() {
  PERF_WUI_URL="$BASE" PERF_API_URL="$BASE" PERF_EMAIL=m@example.com PERF_PW_FILE="$T/pw" \
    PERF_TENANT=t1 PERF_N=8 PERF_WARMUP=0 PERF_TREE=abc PERF_ENV=dev \
    python3 "$PY" live --budgets "$1" --require live --out "$T/report.json" >"$T/out" 2>&1
}
: >"$T/hits"
live "$T/hi.json"
rc=$?
[[ $rc -eq 0 ]] && grep -q '^PASS dev_initial_gzip_kb ' "$T/out" && grep -q '^PASS view_roster_p95_ms ' "$T/out" \
  && pass "live stub: three view reads and the bundle pass under a high ceiling" || fail "live hi: rc=$rc $(cat "$T/out")"
grep -q 'pw-secret-not-for-logs\|tok-secret-cookie\|BODY-SECRET' "$T/out" "$T/report.json" \
  && fail "password, cookie or response body was printed" || pass "neither the password, the cookie nor a response body is printed"
once="$(python3 - "$T/hits" "$T/login.json" <<'PY'
import json, sys
hits = open(sys.argv[1]).read().splitlines()
login = json.load(open(sys.argv[2]))
posts = [h for h in hits if h.startswith("POST /api/v1/auth/login")]
views = [h for h in hits if h.startswith("GET /v1/view/")]
need = {"GET /v1/view/me", "GET /v1/view/channels", "GET /v1/view/roster"}
ok = len(posts) == 1 and need <= set(views) and login.get("tenant") == "t1"
print("once" if ok else "posts=%s views=%s tenant=%s" % (len(posts), sorted(set(views)), login.get("tenant")))
PY
)"
[[ "$once" == once ]] && pass "one sign-in, then all three view paths" || fail "sign-in shape: $once"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["samples"]; sys.exit(0 if len(s["first_load_ms"])==8 and len(s["view_me_ms"])==8 and d["n"]==8 else 1)' "$T/report.json" \
  && pass "n=8 samples are in the report" || fail "sample count $(python3 -c 'import json;print(json.load(open("'"$T/report.json"'"))["samples"].keys())')"

: >"$T/hits"
printf '%s\n' 'wrong' >"$T/pw-bad"
PERF_WUI_URL="$BASE" PERF_API_URL="$BASE" PERF_EMAIL=m@example.com PERF_PW_FILE="$T/pw-bad" \
  PERF_TENANT=t1 PERF_N=8 PERF_WARMUP=0 \
  python3 "$PY" live --budgets "$T/hi.json" --require live --out "$T/bad.json" >"$T/out" 2>&1
rc=$?
[[ $rc -eq 2 ]] && grep -q 'sign-in failed' "$T/out" \
  && pass "a refused sign-in exits 2" || fail "bad login: rc=$rc $(cat "$T/out")"

printf '%s\n' 'pw-secret-not-for-logs' >"$T/pw"
touch "$T/roster-500"
live "$T/hi.json"
rc=$?
[[ $rc -ne 0 ]] && grep -q '/v1/view/roster' "$T/out" && ! grep -q '^PASS view_roster_p95_ms ' "$T/out" \
  && pass "CONTROL: a 500 from a view read fails and is not reported as a p95" || fail "CONTROL 500: rc=$rc $(cat "$T/out")"
rm -f "$T/roster-500"
grep -q 'BODY-SECRET' "$T/out" && fail "the 500 body was printed" || pass "the 500 body was not printed"

live "$T/neg.json"
rc=$?
[[ $rc -eq 1 ]] && grep -q '^FAIL dev_initial_gzip_kb ' "$T/out" && grep -q '^FAIL view_me_p95_ms ' "$T/out" \
  && pass "CONTROL: a ceiling below the measurement exits 1" || fail "CONTROL neg: rc=$rc $(cat "$T/out")"

# --- 5. the action -------------------------------------------------------------------
: >"$T/hits"
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_perf_budget' >"$T/aout" 2>&1 </dev/null
}
act TENANT_ID='BAD TENANT'
rc=$?
[[ $rc -ne 0 ]] && grep -q 'TENANT_ID must be a tenant slug' "$T/aout" \
  && pass "the action refuses a bad tenant" || fail "bad tenant: rc=$rc $(cat "$T/aout")"
act TENANT_ID=t1 PERF_WUI_URL="$BASE" PERF_API_URL="$BASE"
rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN nothing was fetched' "$T/aout" \
  && pass "the dry run says what it would measure" || fail "dry: rc=$rc $(cat "$T/aout")"
[[ ! -s "$T/hits" ]] && pass "the dry run made no request" || fail "the dry run hit the stub: $(cat "$T/hits")"
act TENANT_ID=t1 DRY_RUN=0 PERF_PW_FILE="$T/missing" PERF_WUI_URL="$BASE" PERF_API_URL="$BASE"
rc=$?
[[ $rc -ne 0 ]] && grep -q 'no readable password file' "$T/aout" \
  && pass "DRY_RUN=0 without a password file is refused" || fail "no pw: rc=$rc $(cat "$T/aout")"
act TENANT_ID=t1 DRY_RUN=0 PERF_PW_FILE="$T/pw" PERF_EMAIL=m@example.com PERF_N=8 PERF_WARMUP=0 \
  PERF_WUI_URL="$BASE" PERF_API_URL="$BASE" PERF_BUDGETS="$T/hi.json" PERF_OUT="$T/action-report.json"
rc=$?
[[ $rc -eq 0 ]] && grep -q '^PASS view_channels_p95_ms ' "$T/aout" && [[ -s "$T/action-report.json" ]] \
  && pass "the action records a report against the stub" || fail "action live: rc=$rc $(cat "$T/aout")"
grep -q 'pw-secret-not-for-logs\|tok-secret-cookie\|BODY-SECRET' "$T/aout" "$T/action-report.json" \
  && fail "the action printed a secret" || pass "the action output has no password, cookie or body"

# --- 6. the committed ceilings --------------------------------------------------------
if [[ ! -f "$BUD" ]]; then
  fail "committed ceilings missing: $BUD"
else
  shape="$(python3 - "$BUD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("ceilings") or {}
b = (d.get("basis") or {}).get("metrics") or {}
keys = ["ci_initial_gzip_kb", "dev_initial_gzip_kb", "first_load_p95_ms",
        "view_me_p95_ms", "view_channels_p95_ms", "view_roster_p95_ms"]
for k in keys:
    if not isinstance(c.get(k), (int, float)) or float(c[k]) <= 0:
        print("ceiling " + k); raise SystemExit
    if k not in b or float(b[k]) > float(c[k]):
        print("basis " + k); raise SystemExit
print("ok")
PY
)"
  [[ "$shape" == ok ]] && pass "committed ceilings sit at or above the recorded basis" || fail "ceilings: $shape"
fi

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
