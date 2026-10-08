#!/usr/bin/env bash
# spec 099 T009 do_spl_topic_head_shape_probe / topic-head-shape-probe.py,
# hermetic: a stub hub on 127.0.0.1 answers the login and the topic lists, and
# classifies every list read into a shape exactly as hub view.go topicShape
# does (children > dm > channel > agent > all_flat > all). The probe passes
# only if each of the six shapes was really requested N times.
#
# CONTROLS: a hub that fails one shape (500) must FAIL the probe; a member
# whose lists show no channel must FAIL the channel shape (no silent skip);
# a refused sign-in is exit 2; the probe sends nothing but the login POST.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/topic-head-shape-probe.py"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs
T = sys.argv[1]
PARENT = "11111111-2222-4333-8444-555555555555"
def shape(path, q):
    if path.endswith("/children"): return "children"
    if q.get("dm") == ["true"]: return "dm"
    if q.get("channel", [""])[0]: return "channel"
    if q.get("agent", [""])[0]: return "agent"
    if q.get("roots") == ["false"]: return "all_flat"
    return "all"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, st, body, cookie=False):
        raw = json.dumps(body).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        if cookie: self.send_header("Set-Cookie", "spool_session=tok; Path=/; HttpOnly")
        self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        open(os.path.join(T, "posts.log"), "a").write(self.path + "\n")
        n = int(self.headers.get("Content-Length") or 0)
        b = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/v1/auth/login":
            return self.reply(200, {}, cookie=b.get("password") == "pw-ok")
        self.reply(404, {"error": "not_found"})
    def do_GET(self):
        if self.path == "/ping": return self.reply(200, {})
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        u = urlsplit(self.path); q = parse_qs(u.query)
        if not u.path.startswith("/v1/view/topics"): return self.reply(404, {"error": "not_found"})
        s = shape(u.path, q)
        if s == "agent": open(os.path.join(T, "agent.log"), "a").write(q["agent"][0] + "\n")
        open(os.path.join(T, "shapes.log"), "a").write(s + "\n")
        if os.path.exists(os.path.join(T, "fail-" + s)): return self.reply(500, {"error": "internal"})
        ch = None if os.path.exists(os.path.join(T, "no-channel")) else "general"
        rows = [{"task_id": PARENT, "parent_task_id": None, "channel": ch, "participants": ["HUM-4", "ALL-0@box-wui", "c-123@box-a"]},
                {"task_id": "66666666-7777-4888-8999-000000000000", "parent_task_id": PARENT, "channel": ch,
                 "participants": ["HUM-4"]}]
        self.reply(200, {"topics": rows, "next": None})
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf 'pw-ok' >"$T/pw"
python3 "$T/stub.py" "$T" "$port" >"$T/stub.log" 2>&1 & SRV=$!
up=0
for _ in $(seq 1 200); do
  kill -0 "$SRV" 2>/dev/null || break
  curl -s -o /dev/null "http://127.0.0.1:$port/ping" && { up=1; break; }
  sleep 0.1
done
if [[ $up -ne 1 ]]; then
  echo "FAIL: the stub hub is not answering on 127.0.0.1:$port"; sed 's/^/  /' "$T/stub.log"; exit 1
fi

run() { # run <n>
  rm -f "$T/shapes.log" "$T/posts.log" "$T/agent.log"
  PROBE_API="http://127.0.0.1:$port" PROBE_TENANT=t1 PROBE_EMAIL=e@example.com PROBE_PW_FILE="$T/pw" \
    PROBE_N="$1" python3 "$PY" 2>&1
}
count() { grep -cx "$1" "$T/shapes.log" 2>/dev/null || true; }

# ---- every shape is driven N times (plus the two target-discovery reads) ----
out=$(run 3); rc=$?
want_ok=1
for s in all all_flat channel dm agent children; do
  extra=0; [[ "$s" == all || "$s" == all_flat ]] && extra=1
  got=$(count "$s")
  [[ "$got" -eq $((3 + extra)) ]] || { want_ok=0; echo "  $s: hub saw $got reads, want $((3 + extra))"; }
done
if [[ $rc -eq 0 && $want_ok -eq 1 ]] && grep -q '"ok": true' <<<"$out"; then
  pass "all six shapes reach the hub 3 times each, as the hub classifies them (exit 0)"
else
  fail "the six shapes were not each driven (exit $rc): $out"
fi
if grep -q 'pw-ok' <<<"$out"; then fail "the password was printed"; else pass "the password is never printed"; fi

if [[ "$(sort -u "$T/agent.log")" == "c-123" ]]; then
  pass "the agent shape reads a real agent id (not HUM-/ALL-, no @box)"
else
  fail "the agent shape read: $(sort -u "$T/agent.log" | tr '\n' ' ')"
fi

# ---- read-only: the login is the one POST -----------------------------------
if [[ "$(cat "$T/posts.log")" == "/api/v1/auth/login" ]]; then
  pass "the probe sends no POST but the sign-in"
else
  fail "the probe wrote something: $(tr '\n' ' ' <"$T/posts.log")"
fi

# ---- CONTROL: a failing shape fails the probe -------------------------------
touch "$T/fail-children"
out=$(run 2); rc=$?
rm -f "$T/fail-children"
if [[ $rc -eq 1 ]] && grep -qE '^children +2 +500=2' <<<"$out"; then
  pass "CONTROL: a hub answering 500 on children FAILS and names it (exit 1)"
else
  fail "CONTROL: a 500 on children was accepted (exit $rc): $out"
fi

# ---- CONTROL: no channel target is a FAIL, not a silent skip ----------------
touch "$T/no-channel"
out=$(run 1); rc=$?
rm -f "$T/no-channel"
if [[ $rc -eq 1 ]] && grep -q 'no target: set PROBE_CHANNEL' <<<"$out" && [[ "$(count channel)" -eq 0 ]]; then
  pass "CONTROL: no readable channel FAILS the channel shape and names PROBE_CHANNEL"
else
  fail "CONTROL: a missing channel target passed (exit $rc): $out"
fi

# ---- a refused sign-in is exit 2 --------------------------------------------
printf 'pw-bad' >"$T/pw"
out=$(run 1); rc=$?
if [[ $rc -eq 2 ]] && [[ ! -s "$T/shapes.log" ]]; then
  pass "CONTROL: a refused sign-in is exit 2 and reads nothing"
else
  fail "CONTROL: a refused sign-in gave exit $rc: $out"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all topic-head-shape-probe.tst.sh assertions"
exit "$fails"
