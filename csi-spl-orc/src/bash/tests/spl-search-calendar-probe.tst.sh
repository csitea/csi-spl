#!/usr/bin/env bash
# SPL-6251 do_spl_search_calendar_probe / search-calendar-probe.py, hermetic: a
# stub hub on 127.0.0.1 answers the login, the calendar entry create / delete
# and GET /v1/view/search. In "calendar" mode type:calendar and type:cal find
# the entry by its title word and type:event answers the event log only
# (green); in "nocalendar" mode, the hub before SPL-6251, type:calendar and
# type:cal are 400 bad_query (red).
#
# CONTROLS: nocalendar FAILS the probe (exit 1) and names each missed search; a
# hub that answers a calendar section to type:event FAILS it; a refused sign-in
# is exit 2; the entry is deleted on every path that made one; the action
# refuses bad knobs, and is a dry run without DRY_RUN=0.
# ONE COPY: the action defines no knobs check of its own; it calls the doc
# probe's spl_search_doc_probe_check, loaded when the file is sourced alone.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/search-calendar-probe.py"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs
T = sys.argv[1]
EV = "33333333-3333-4333-8333-333333333333"
state = {"title": ""}
def mode(): return open(os.path.join(T, "mode")).read().strip()
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
    def log(self, line): open(os.path.join(T, "calls.log"), "a").write(line + "\n")
    def authed(self): return self.headers.get("Cookie") == "spool_session=tok"
    def do_POST(self):
        b = self.body(); self.log("POST " + self.path)
        if self.path == "/api/v1/auth/login":
            return self.reply(200, {}, cookie=b.get("password") == "pw-ok")
        if not self.authed(): return self.reply(401, {"error": "auth"})
        if self.path == "/v1/calendar/events":
            state["title"] = b.get("title", "")
            return self.reply(201, {"event": {"id": EV, "title": state["title"]}})
        self.reply(404, {"error": "not_found"})
    def do_DELETE(self):
        self.log("DELETE " + self.path); self.reply(200, {"deleted": True})
    def do_GET(self):
        if self.path == "/ping": return self.reply(200, {})
        if not self.authed(): return self.reply(401, {"error": "view_door"})
        u = urlsplit(self.path); q = parse_qs(u.query)["q"][0]
        self.log("GET search " + q)
        ty = q.split()[0].split(":", 1)[1]
        words = [w for w in q.split() if not w.startswith("type:")]
        hit = all(w in state["title"].split() for w in words)
        rows = [{"id": EV}] if hit else []
        m = mode()
        if ty in ("calendar", "cal"):
            if m == "nocalendar": return self.reply(400, {"error": "bad_query"})
            return self.reply(200, {"types": ["calendar"], "groups": {"calendars": {"results": rows, "next": None}}})
        if m == "leaky":
            return self.reply(200, {"types": ["event", "calendar"], "groups": {"events": {"results": [], "next": None}, "calendars": {"results": rows, "next": None}}})
        self.reply(200, {"types": ["event"], "groups": {"events": {"results": [], "next": None}}})
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf 'pw-ok' >"$T/pw"; printf 'pw-bad' >"$T/pw-bad"; echo calendar >"$T/mode"
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

run() { # run <mode> [pw file]
  echo "$1" >"$T/mode"; rm -f "$T/calls.log"
  PROBE_API="http://127.0.0.1:$port" PROBE_TENANT=t1 PROBE_EMAIL=e@example.com PROBE_PW_FILE="${2:-$T/pw}" \
    PROBE_NONCE=fixed python3 "$PY" 2>&1
}
deleted() { grep -c '^DELETE /v1/calendar/events/' "$T/calls.log" 2>/dev/null || true; }

# ---- green: type:calendar and type:cal find it, type:event does not ---------
out=$(run calendar); rc=$?
if [[ $rc -eq 0 && "$(deleted)" -eq 1 ]] && grep -q '"ok": true' <<<"$out" && [[ "$(grep -c '^OK ' <<<"$out")" -eq 3 ]] &&
  grep -q '^GET search type:cal zqcal' "$T/calls.log"; then
  pass "a hub with the calendar section: 3 searches OK, the entry deleted (exit 0)"
else
  fail "the green run did not pass (exit $rc): $out"
fi

# ---- CONTROL: the hub before SPL-6251 is red, each miss named ---------------
out=$(run nocalendar); rc=$?
if [[ $rc -eq 1 && "$(deleted)" -eq 1 ]] && grep -qE '^MISS +type:calendar .*status=400' <<<"$out" &&
  [[ "$(grep -c '^MISS ' <<<"$out")" -eq 2 ]] && grep -q '"ok": false' <<<"$out"; then
  pass "CONTROL a hub without the calendar section: exit 1, 2 searches MISS (400), the entry still deleted"
else
  fail "CONTROL the no-calendar hub did not fail as it should (exit $rc): $out"
fi

# ---- CONTROL: type:event answering a calendar section is red ----------------
out=$(run leaky); rc=$?
if [[ $rc -eq 1 ]] && grep -qE '^MISS +type:event .*want=absent' <<<"$out"; then
  pass "CONTROL a hub whose type:event answers calendar entries: exit 1, that search MISS"
else
  fail "CONTROL the leaky type:event passed (exit $rc): $out"
fi

# ---- a refused sign-in is exit 2, nothing made ------------------------------
out=$(run calendar "$T/pw-bad"); rc=$?
if [[ $rc -eq 2 ]] && ! grep -q 'calendar/events' "$T/calls.log" && grep -q '"step": "login"' <<<"$out" && ! grep -q 'pw-' <<<"$out"; then
  pass "a refused sign-in: exit 2, no entry made, no password printed"
else
  fail "the refused sign-in was not exit 2 with nothing made (exit $rc): $out"
fi

# ---- the action: knobs refused, dry run by default --------------------------
ACT="$HERE/../run/spl-search-calendar-probe.func.sh"
chk() { # chk <ENV> <TENANT_ID> [DRY_RUN]
  bash -c 'do_log() { echo "$*"; }; spl_dry_run() { [[ "${DRY_RUN:-1}" != 0 ]]; }
    do_require_bin() { :; }; do_spl_cloud_cnf() { :; }; spl_cnf_api_fqdn() { printf -v "$1" %s api.example.com; }
    source "$1"; do_spl_search_calendar_probe' _ "$ACT" 2>&1 <<<"" | cat
}
o1=$(ENV=qa TENANT_ID=t1 chk); o2=$(ENV=dev TENANT_ID='T 1' chk); o3=$(ENV=dev TENANT_ID=t1 chk)
if grep -q 'FATAL ENV must be dev or prd' <<<"$o1" && grep -q 'FATAL TENANT_ID must be a tenant slug' <<<"$o2" &&
  grep -q 'OK DRY_RUN nothing was touched' <<<"$o3"; then
  pass "the action refuses a bad ENV and TENANT_ID, and is a dry run without DRY_RUN=0"
else
  fail "the action's knobs: [$o1] [$o2] [$o3]"
fi

# ---- one copy: the knobs check is the doc probe's ---------------------------
own=$(grep -nE '^spl_search_calendar_probe_check\(\)|FATAL TENANT_ID' "$ACT")
if [[ -z "$own" ]] && grep -q 'spl_search_doc_probe_check "\$tenant"' "$ACT"; then
  pass "one knobs check: the action calls spl_search_doc_probe_check and defines no copy"
else
  fail "own knobs check left, or no call of spl_search_doc_probe_check: $own"
fi

if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "PASS: all"
