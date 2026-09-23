#!/usr/bin/env bash
# rdb 0028 do_spl_channel_privacy_probe / channel-privacy-probe.py, hermetic: a
# stub hub on 127.0.0.1 answers the login and GET /v1/view/topics/{id} with
# the topic in $T/topic.json.
#
# The probe's whole job is to tell a CLOSED door from an OPEN one, so the test
# has to show it doing both. CONTROL 1 is a leaking hub (the pre-0028 shape,
# the real dev topic: five untagged HUM-17 messages plus one channel-tagged
# reply) and must FAIL. CONTROL 2 is a hub that returns nothing at all, which
# would satisfy "no leaked message" vacuously, and must also fail - that is
# what ALLOW_MIN is for.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/channel-privacy-probe.py"
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
            return self.reply(200, {}, cookie=b.get("password") == "pw-ok")
        self.reply(404, {"error": "not_found"})
    def do_GET(self):
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        if self.path == "/v1/view/me": return self.reply(200, {"human_id": "HUM-4"})
        if self.path.startswith("/v1/view/topics/"):
            rows = json.load(open(os.path.join(T, "topic.json")))
            if rows is None: return self.reply(404, {"error": "not_found"})
            return self.reply(200, {"messages": rows})
        self.reply(404, {"error": "not_found"})
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY

# one stored message, in the shape the view API returns
msg() { printf '{"env":{"channel":"%s","msg":{"from":"%s","body":"x"}}}' "$2" "$1"; }

port=$(( 20000 + RANDOM % 20000 ))
printf 'pw-ok' >"$T/pw"
python3 "$T/stub.py" "$T" "$port" & SRV=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/v1/view/me" && break; sleep 0.1; done

run() { # run <allow_min> <deny_from>
  PROBE_API="http://127.0.0.1:$port" PROBE_TENANT=t1 PROBE_EMAIL=e@example.com PROBE_PW_FILE="$T/pw" \
    PROBE_TASK=57e6f191-582e-45b1-a08e-389c0b034803 PROBE_ALLOW_MIN="$1" PROBE_DENY_FROM="$2" \
    python3 "$PY" 2>&1
}

# ---- the door holds: only the channel-tagged reply comes back ---------------
printf '[%s]' "$(msg HUM-9 live-proof)" >"$T/topic.json"
out=$(run 1 HUM-17); rc=$?
if [[ $rc -eq 0 ]]; then
  pass "a hub that returns only the readable message passes (exit 0)"
else
  fail "the closed-door case did not pass (exit $rc): $out"
fi

# ---- CONTROL 1: the pre-0028 leak, the real dev topic's shape --------------
leak="$(msg HUM-17 '')"
printf '[%s,%s,%s,%s,%s,%s]' "$leak" "$leak" "$leak" "$leak" "$leak" "$(msg HUM-9 live-proof)" >"$T/topic.json"
out=$(run 1 HUM-17); rc=$?
if [[ $rc -ne 0 ]] && grep -q '"leaked"' <<<"$out" && grep -q 'HUM-17/DM' <<<"$out"; then
  pass "CONTROL: a leaking hub FAILS and names the messages (exit $rc)"
else
  fail "CONTROL: a leaking hub was accepted (exit $rc): $out"
fi

# ---- CONTROL 2: returning nothing must not pass vacuously -------------------
printf 'null' >"$T/topic.json"
out=$(run 1 HUM-17); rc=$?
if [[ $rc -ne 0 ]]; then
  pass "CONTROL: a 404 with ALLOW_MIN=1 FAILS, it does not pass by returning nothing (exit $rc)"
else
  fail "CONTROL: an empty topic satisfied the probe vacuously: $out"
fi
# ...and the same 404 is a PASS when nothing was expected, or the check above
# would be red for the wrong reason.
out=$(run 0 HUM-17); rc=$?
if [[ $rc -eq 0 ]]; then
  pass "CONTROL: the same 404 with ALLOW_MIN=0 passes (the refusal itself is the proof)"
else
  fail "CONTROL: ALLOW_MIN=0 did not accept a 404 (exit $rc): $out"
fi

# ---- a bad password is exit 2, not a silent pass ----------------------------
printf 'pw-bad' >"$T/pw"
printf '[%s]' "$(msg HUM-9 live-proof)" >"$T/topic.json"
out=$(run 1 HUM-17); rc=$?
if [[ $rc -eq 2 ]]; then
  pass "CONTROL: a refused sign-in is exit 2, distinct from a door verdict"
else
  fail "CONTROL: a refused sign-in gave exit $rc: $out"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all channel-privacy-probe.tst.sh assertions"
exit "$fails"
