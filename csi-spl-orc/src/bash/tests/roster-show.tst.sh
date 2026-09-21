#!/usr/bin/env bash
# do_spl_roster_show / roster-show.py, hermetic: a stub hub on 127.0.0.1
# answers the login and GET /v1/view/roster with the boxes in $T/roster.json.
# CONTROL: a stub that refuses the roster (401 view_door) must fail the action,
# so an empty roster can never be mistaken for a clean one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/roster-show.py"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

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
        n = int(self.headers.get("Content-Length") or 0)
        b = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/v1/auth/login":
            open(os.path.join(T, "login.json"), "w").write(json.dumps(b))
            return self.reply(200, {}, cookie=b.get("password") == "pw-ok")
        self.reply(404, {"error": "not_found"})
    def do_GET(self):
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        if os.path.exists(os.path.join(T, "door-shut")): return self.reply(401, {"error": "view_door"})
        self.reply(200, json.load(open(os.path.join(T, "roster.json"))))
s = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
cat >"$T/roster.json" <<'JSON'
{"boxes": [{"box_id": "box-desk", "pubkey": "AAA=", "revoked": false,
            "last_hello_at": "2026-09-21T12:59:14Z", "online": true, "agents": ["CLE-00"]},
           {"box_id": "box-wui", "pubkey": "BBB=", "revoked": false,
            "last_hello_at": null, "online": false, "agents": []}],
 "humans": [{"human_id": "HUM-9", "avatar_file_id": null}]}
JSON
python3 "$T/stub.py" "$T" & SRV=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
umask 077; echo pw-ok >"$T/pw"; echo wrong >"$T/pw-bad"

show() { PROBE_API="http://127.0.0.1:$(cat "$T/port")" PROBE_TENANT=t1 PROBE_EMAIL=m@example.com \
  PROBE_PW_FILE="${PW:-$T/pw}" python3 "$PY" >"$T/out" 2>&1; }

show; rc=$?
[[ $rc -eq 0 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if [b["box_id"] for b in d["boxes"]] == ["box-desk", "box-wui"] else 1)' "$T/out" \
  && pass "prints the roster JSON verbatim (both boxes, parseable)" || fail "show: rc=$rc $(cat "$T/out")"
grep -q '"tenant": "t1"' "$T/login.json" && pass "login names the tenant (specs/026 active tenant)" || fail "login body $(cat "$T/login.json")"
grep -q 'pw-ok\|spool_session' "$T/out" && fail "password or cookie printed" || pass "neither the password nor the cookie is printed"

touch "$T/door-shut"; show; rc=$?
[[ $rc -eq 1 ]] && grep -q '"step": "roster"' "$T/out" && pass "CONTROL: a refused roster read exits 1, it does not print an empty roster" || fail "CONTROL door: rc=$rc $(cat "$T/out")"
rm -f "$T/door-shut"
PW="$T/pw-bad" show; rc=$?
[[ $rc -eq 2 ]] && grep -q '"step": "login"' "$T/out" && pass "a failed sign-in exits 2" || fail "bad login: rc=$rc $(cat "$T/out")"

# The action, sourced like the other orc tests (no ./run: no log file writes).
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_roster_show' >"$T/out" 2>&1 </dev/null
}
act TENANT_ID=T_1; rc=$?
[[ $rc -ne 0 ]] && grep -q "TENANT_ID must be a tenant slug" "$T/out" && pass "action refuses a bad TENANT_ID" || fail "action bad tenant: rc=$rc $(cat "$T/out")"
act TENANT_ID=t1 PROBE_PW_FILE="$T/nope"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no readable password file" "$T/out" && pass "action refuses without a password file" || fail "action no pw: rc=$rc $(cat "$T/out")"
act TENANT_ID=t1 PROBE_PW_FILE="$T/pw" PROBE_API="http://127.0.0.1:$(cat "$T/port")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK live GET /v1/view/roster on dev/t1: 2 box(es)' "$T/out" && grep -q '"box_id": "box-desk"' "$T/out" \
  && pass "action: prints the JSON and counts the boxes" || fail "action ok: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
