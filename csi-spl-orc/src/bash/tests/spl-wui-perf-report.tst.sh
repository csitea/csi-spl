#!/usr/bin/env bash
# do_spl_wui_perf_report (spec 066 L8), hermetic: a canned summary JSON in the
# route's shape (perf_summary.go), read through PERF_SUMMARY_FILE and through a
# stub hub on 127.0.0.1 that answers the login and GET /v1/admin/perf/summary.
# CONTROLS: a refused summary (403) and a body that is not the route's shape
# must fail the action, so neither can print as an empty report.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; SRV=""; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# Ranked by p75 desc, as the route answers; p95 absent under n = 50.
cat >"$T/one.json" <<'JSON'
{"days": 7, "rows": [
 {"metric": "send_ack", "device": "desktop", "view": "topic", "n": 120, "p50": 400, "p75": 1000, "p95": 2500, "failed": 2},
 {"metric": "load_messages", "device": "phone", "view": "flow", "n": 49, "p50": 150, "p75": 200, "failed": 0},
 {"metric": "switch_view", "device": "desktop", "view": "flow", "n": 300, "p50": 60, "p75": 90, "p95": 140, "failed": 0},
 {"metric": "inp", "device": "phone", "view": "topic", "n": 0, "p50": null, "p75": null, "failed": 1}]}
JSON
cat >"$T/ab.json" <<'JSON'
{"days": 7, "build": "1.3.4", "build_b": "1.3.5",
 "rows":   [{"metric": "send_ack", "device": "desktop", "view": "topic", "n": 200, "p50": 500, "p75": 800, "p95": 900, "failed": 0},
            {"metric": "load_rail", "device": "phone", "view": "flow", "n": 10, "p50": 20, "p75": 30, "failed": 0}],
 "rows_b": [{"metric": "send_ack", "device": "desktop", "view": "topic", "n": 150, "p50": 300, "p75": 600, "p95": 700, "failed": 0},
            {"metric": "inp", "device": "desktop", "view": "topic", "n": 60, "p50": 40, "p75": 48, "p95": 80, "failed": 0}]}
JSON
echo '{"error": "internal"}' >"$T/bad.json"

act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u TENANT_ID -u PERF_DAYS -u PERF_BUILD_A -u PERF_BUILD_B \
    -u PERF_SUMMARY_FILE -u PERF_API -u PERF_EMAIL -u PERF_PW_FILE HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || { echo "missing $b"; return 1; }; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_wui_perf_report' >"$T/out" 2>&1 </dev/null
}
has() { grep -qF -- "$1" "$T/out"; }

# 1. one window from the canned file
act PERF_SUMMARY_FILE="$T/one.json"; rc=$?
[[ $rc -eq 0 ]] && has 'OK GET /v1/admin/perf/summary on dev/t1: 4 group(s), 7 day(s)' \
  && pass "canned summary: OK, the workspace defaults to the cnf's wui_default_tenant (t1)" || fail "one: rc=$rc $(cat "$T/out")"
order="$(grep -E '^\| [0-9]' "$T/out" | awk -F'|' '{gsub(/ /, "", $3); printf "%s,", $3}')"
[[ "$order" == "send_ack,load_messages,switch_view,inp," ]] && pass "keeps the route's p75 ranking" || fail "order: $order"
has '| 1* | send_ack | desktop | topic | 120 | 400 | 1000 | 2500 | 2 |' && pass "row: n, p50, p75, p95, failed; * marks n >= 100" || fail "row 1: $(cat "$T/out")"
has '| 2 | load_messages | phone | flow | 49 | 150 | 200 | - | 0 |' && pass "p95 prints - under n = 50" || fail "row 2: $(cat "$T/out")"
has '| 4 | inp | phone | topic | 0 | - | - | - | 1 |' && pass "a failures-only group prints - for every percentile" || fail "row 4: $(cat "$T/out")"
has 'top 5 with n >= 100 (a round plans from these): send_ack/desktop/topic p75 1000 ms n 120, switch_view/desktop/flow p75 90 ms n 300' \
  && pass "top 5 lists only the n >= 100 rows, in p75 order" || fail "top: $(grep top "$T/out")"

# 2. build A / B compare
act PERF_SUMMARY_FILE="$T/ab.json" PERF_BUILD_A=1.3.4 PERF_BUILD_B=1.3.5; rc=$?
[[ $rc -eq 0 ]] && has '2 group(s), 7 day(s), build 1.3.4 vs 1.3.5: 2 group(s)' && has '## build 1.3.5, last 7 day(s), ranked by p75' \
  && pass "A/B: both rankings" || fail "ab: rc=$rc $(cat "$T/out")"
has '| send_ack | desktop | topic | 200 | 800 | 150 | 600 | -25.0 % |' && pass "A/B: p75 change in percent per group" || fail "ab change: $(cat "$T/out")"
has '| inp | desktop | topic | - | - | 60 | 48 | - |' && has '| load_rail | phone | flow | 10 | 30 | - | - | - |' \
  && pass "A/B: a group in one build only prints - for the other" || fail "ab one-sided: $(cat "$T/out")"

# 3. validation, before any read
for bad in "PERF_DAYS=0|PERF_DAYS must be 1..30" "PERF_DAYS=31|PERF_DAYS must be 1..30" "PERF_DAYS=week|PERF_DAYS must be 1..30" \
            "PERF_BUILD_A=a b|must be a build version" "PERF_BUILD_B=1.3.5|PERF_BUILD_B needs PERF_BUILD_A" "TENANT_ID=T_1|TENANT_ID must be a tenant slug"; do
  act "${bad%%|*}" PERF_SUMMARY_FILE="$T/one.json"; rc=$?
  [[ $rc -ne 0 ]] && has "${bad#*|}" && pass "refuses ${bad%%|*}" || fail "${bad%%|*}: rc=$rc $(cat "$T/out")"
done

# 4. CONTROL: a body that is not the summary must not print as an empty report
act PERF_SUMMARY_FILE="$T/bad.json"; rc=$?
[[ $rc -ne 0 ]] && has "is not the route's shape" && ! has 'OK GET' && pass "CONTROL: a non-summary body fails the action" || fail "bad shape: rc=$rc $(cat "$T/out")"

# 5. the live path against a stub hub
cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, st, body, cookie=False):
        raw = json.dumps(body).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        if cookie: self.send_header("Set-Cookie", "spool_session=tok; Path=/; HttpOnly")
        self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path != "/api/v1/auth/login": return self.reply(404, {"error": "not_found"})
        open(os.path.join(T, "login.json"), "w").write(json.dumps(b))
        self.reply(200, {}, cookie=b.get("password") == "pw-ok")
    def do_GET(self):
        open(os.path.join(T, "path"), "w").write(self.path)
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        if os.path.exists(os.path.join(T, "deny")): return self.reply(403, {"error": "forbidden", "permission": "tenant.settings"})
        self.reply(200, json.load(open(os.path.join(T, "ab.json" if "build_b=" in self.path else "one.json"))))
s = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$T/stub.py" "$T" & SRV=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
umask 077; echo pw-ok >"$T/pw"; echo wrong >"$T/pw-bad"
API="http://127.0.0.1:$(cat "$T/port")"

act TENANT_ID=e2e PERF_API="$API" PERF_PW_FILE="$T/pw" PERF_EMAIL=admin@example.com PERF_DAYS=07; rc=$?
[[ $rc -eq 0 ]] && has 'OK GET /v1/admin/perf/summary on dev/e2e: 4 group(s)' && [[ "$(cat "$T/path")" == "/v1/admin/perf/summary?days=7" ]] \
  && pass "live: signs in, GETs the summary for the window, prints the report" || fail "live: rc=$rc path=$(cat "$T/path" 2>/dev/null) $(cat "$T/out")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if (d["tenant"], d["email"]) == ("e2e", "admin@example.com") else 1)' "$T/login.json" \
  && pass "live: the login names the workspace and the member" || fail "login body $(cat "$T/login.json")"
! has 'pw-ok' && ! has 'spool_session' && pass "neither the password nor the cookie is printed" || fail "secret printed: $(cat "$T/out")"
act TENANT_ID=e2e PERF_API="$API" PERF_PW_FILE="$T/pw" PERF_BUILD_A=1.3.4 PERF_BUILD_B=1.3.5; rc=$?
[[ $rc -eq 0 && "$(cat "$T/path")" == "/v1/admin/perf/summary?days=7&build=1.3.4&build_b=1.3.5" ]] && has '-25.0 %' \
  && pass "live: PERF_BUILD_A / B go to the route as build / build_b" || fail "live ab: rc=$rc path=$(cat "$T/path") $(cat "$T/out")"

touch "$T/deny"
act TENANT_ID=e2e PERF_API="$API" PERF_PW_FILE="$T/pw"; rc=$?
[[ $rc -ne 0 ]] && has 'exit 3' && has 'lacks tenant.settings' && ! has 'OK GET' \
  && pass "CONTROL: a 403 (no tenant.settings) fails the action and names the permission" || fail "deny: rc=$rc $(cat "$T/out")"
rm -f "$T/deny"
act TENANT_ID=e2e PERF_API="$API" PERF_PW_FILE="$T/pw-bad"; rc=$?
[[ $rc -ne 0 ]] && has 'exit 2' && has '"step": "login"' && pass "a failed sign-in fails the action" || fail "bad login: rc=$rc $(cat "$T/out")"
act TENANT_ID=e2e PERF_API="$API" PERF_PW_FILE="$T/nope"; rc=$?
[[ $rc -ne 0 ]] && has 'no readable password file' && pass "refuses without a password file" || fail "no pw: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
