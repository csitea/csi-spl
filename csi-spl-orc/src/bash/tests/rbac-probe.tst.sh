#!/usr/bin/env bash
# specs/025 do_spl_rbac_probe / rbac-probe.py, hermetic: a stub hub on
# 127.0.0.1 answers the login, GET /v1/view/me and the two gate probes as the
# role in $T/role says. CONTROL: a stub that lies (a tester whose channel
# probe is 400 = the gate let it through) must fail the probe.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/rbac-probe.py"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T = sys.argv[1]
PERMS = {"developer": ["agents.command", "channels.manage", "notes.send", "threads.read"],
         "tester": ["notes.send", "threads.read"],
         "admin": ["channels.manage", "members.roles", "threads.read"]}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, st, body, cookie=False):
        raw = json.dumps(body).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        if cookie: self.send_header("Set-Cookie", "spool_session=tok; Path=/; HttpOnly")
        self.end_headers(); self.wfile.write(raw)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def state(self):
        role = open(os.path.join(T, "role")).read().strip()
        lie = os.path.exists(os.path.join(T, "lie"))
        return role, lie
    def do_POST(self):
        role, lie = self.state()
        b = self.body()
        if self.path == "/api/v1/auth/login":
            open(os.path.join(T, "login.json"), "w").write(json.dumps(b))
            return self.reply(200, {}, cookie=b.get("password") == "pw-ok")
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        if self.path == "/v1/channels":
            if "channels.manage" in PERMS[role] or lie: return self.reply(400, {"error": "bad_channel"})
            return self.reply(403, {"error": "forbidden", "permission": "channels.manage"})
    def do_PUT(self):
        role, _ = self.state(); self.body()
        if "members.roles" in PERMS[role]: return self.reply(404, {"error": "not_found"})
        return self.reply(403, {"error": "forbidden", "permission": "members.roles"})
    def do_GET(self):
        role, _ = self.state()
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        self.reply(200, {"human_id": "HUM-4", "tenant_id": "t1", "role": role, "tenant_owner": False, "permissions": PERMS[role]})
s = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
echo developer >"$T/role"
python3 "$T/stub.py" "$T" & SRV=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
umask 077; echo pw-ok >"$T/pw"; echo wrong >"$T/pw-bad"
probe() { PROBE_API="http://127.0.0.1:$(cat "$T/port")" PROBE_TENANT=t1 PROBE_EMAIL=m@example.com PROBE_PW_FILE="${PW:-$T/pw}" \
  PROBE_EXPECT_ROLE="${EXPECT:-}" python3 "$PY" >"$T/out" 2>&1; }

probe; rc=$?
[[ $rc -eq 0 ]] && grep -q '"role": "developer"' "$T/out" && grep -q '"channels.manage": {"agrees": true, "error": "bad_channel", "granted": true' "$T/out" \
  && pass "developer: channels gate lets it through (400 on the invalid name), members.roles refused" || fail "developer: rc=$rc $(cat "$T/out")"
grep -q '"tenant": "t1"' "$T/login.json" && pass "login names the tenant (specs/026 active tenant)" || fail "login body $(cat "$T/login.json")"
grep -q 'pw-ok\|spool_session' "$T/out" && fail "password or cookie printed" || pass "neither the password nor the cookie is printed"

echo tester >"$T/role"; EXPECT=tester probe; rc=$?
[[ $rc -eq 0 ]] && grep -q '"channels.manage": {"agrees": true, "error": "forbidden", "granted": false' "$T/out" \
  && pass "tester: channel gate refuses with 403 forbidden, as /v1/view/me says" || fail "tester: rc=$rc $(cat "$T/out")"
echo admin >"$T/role"; probe; rc=$?
[[ $rc -eq 0 ]] && grep -q '"members.roles": {"agrees": true, "error": "not_found", "granted": true' "$T/out" \
  && pass "admin: members.roles gate passes (404 on HUM-0)" || fail "admin: rc=$rc $(cat "$T/out")"

echo tester >"$T/role"; touch "$T/lie"; probe; rc=$?
[[ $rc -eq 1 ]] && grep -q '"ok": false' "$T/out" && pass "CONTROL: a hub whose gate disagrees with /v1/view/me fails the probe" || fail "CONTROL lie: rc=$rc $(cat "$T/out")"
rm -f "$T/lie"
EXPECT=developer probe; rc=$?
[[ $rc -eq 1 ]] && grep -q '"expected_role": "developer"' "$T/out" && pass "CONTROL: an unexpected role fails the probe" || fail "CONTROL role: rc=$rc $(cat "$T/out")"
PW="$T/pw-bad" probe; rc=$?
[[ $rc -eq 2 ]] && grep -q '"step": "login"' "$T/out" && pass "a failed sign-in exits 2" || fail "bad login: rc=$rc $(cat "$T/out")"

# The action, sourced like the other orc tests (no ./run: no log file writes).
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_rbac_probe' >"$T/out" 2>&1 </dev/null
}
act TENANT_ID=T_1; rc=$?
[[ $rc -ne 0 ]] && grep -q "TENANT_ID must be a tenant slug" "$T/out" && pass "action refuses a bad TENANT_ID" || fail "action bad tenant: rc=$rc $(cat "$T/out")"
act TENANT_ID=t1 'PROBE_EXPECT_ROLE=Bad!'; rc=$?
[[ $rc -ne 0 ]] && grep -q "PROBE_EXPECT_ROLE is not a role id" "$T/out" && pass "action refuses a malformed PROBE_EXPECT_ROLE" || fail "action bad role: rc=$rc $(cat "$T/out")"
act TENANT_ID=t1 PROBE_PW_FILE="$T/nope"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no readable password file" "$T/out" && pass "action refuses without a password file" || fail "action no pw: rc=$rc $(cat "$T/out")"
echo developer >"$T/role"
act TENANT_ID=t1 PROBE_PW_FILE="$T/pw" PROBE_EXPECT_ROLE=developer PROBE_API="http://127.0.0.1:$(cat "$T/port")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK rbac probe on dev/t1: .*"role": "developer"' "$T/out" && pass "action: OK verdict through the script" || fail "action ok: rc=$rc $(cat "$T/out")"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
