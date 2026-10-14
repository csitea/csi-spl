#!/usr/bin/env bash
# SPL-1832 do_spl_search_speed_probe / search-speed-probe.py, hermetic: a stub
# hub on 127.0.0.1 answers the login and GET /v1/view/search (a first page with
# a message cursor, then a "Load more" page). The probe must time n first pages
# and n cursor pages per term, and print their rows.
#
# CONTROLS: a hub answering 503 (search_budget) on a term FAILS the probe and
# names it; a refused sign-in is exit 2; the probe sends nothing but the login
# POST; the action refuses bad knobs before any network call.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/search-speed-probe.py"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs
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
        if u.path != "/v1/view/search": return self.reply(404, {"error": "not_found"})
        term, cur = q["q"][0], q.get("cursor", [""])[0]
        open(os.path.join(T, "gets.log"), "a").write(term + " " + (cur or "-") + "\n")
        if os.path.exists(os.path.join(T, "slow-" + term)):
            return self.reply(503, {"error": "search_budget"})
        rows = [{"msg_id": str(i)} for i in range(30 if cur else 5)]
        self.reply(200, {"groups": {"messages": {"results": rows, "next": None if cur else "c1"}}})
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

run() { # run <n> <terms>
  rm -f "$T/gets.log" "$T/posts.log"
  PROBE_API="http://127.0.0.1:$port" PROBE_TENANT=t1 PROBE_EMAIL=e@example.com PROBE_PW_FILE="$T/pw" \
    PROBE_N="$1" PROBE_TERMS="$2" python3 "$PY" 2>&1
}
gets() { grep -cx "$1" "$T/gets.log" 2>/dev/null || true; }

# ---- n first pages and n cursor pages per term ------------------------------
out=$(run 3 "archive,two words"); rc=$?
if [[ $rc -eq 0 && "$(gets 'archive -')" -eq 3 && "$(gets 'archive c1')" -eq 3 && "$(gets 'two words c1')" -eq 3 ]] &&
  grep -qE '^archive +first +3 +200=3 .* 5$' <<<"$out" && grep -qE '^archive +more +3 +200=3 .* 30$' <<<"$out" &&
  grep -q '"ok": true' <<<"$out"; then
  pass "each term: 3 first pages and 3 Load more pages by its cursor, with their rows (exit 0)"
else
  fail "the first / Load more pages were not each timed (exit $rc): $out"
fi
if grep -q 'pw-ok' <<<"$out"; then fail "the password was printed"; else pass "the password is never printed"; fi
if [[ "$(cat "$T/posts.log")" == "/api/v1/auth/login" ]]; then
  pass "the probe sends no POST but the sign-in"
else
  fail "the probe wrote something: $(tr '\n' ' ' <"$T/posts.log")"
fi

# ---- CONTROL: a 503 on one term fails the probe and names it ----------------
touch "$T/slow-archive"
out=$(run 2 "archive,spool"); rc=$?
rm -f "$T/slow-archive"
if [[ $rc -eq 1 ]] && grep -qE '^archive +first +2 +503=2' <<<"$out" && grep -qE '^spool +more +2 +200=2' <<<"$out"; then
  pass "CONTROL: a hub answering 503 on archive FAILS and names it; the other term still runs (exit 1)"
else
  fail "CONTROL: a 503 was accepted (exit $rc): $out"
fi

# ---- CONTROL: a refused sign-in is exit 2 -----------------------------------
printf 'pw-bad' >"$T/pw"
out=$(run 1 archive); rc=$?
printf 'pw-ok' >"$T/pw"
if [[ $rc -eq 2 && ! -s "$T/gets.log" ]]; then
  pass "CONTROL: a refused sign-in is exit 2 and searches nothing"
else
  fail "CONTROL: a refused sign-in gave exit $rc: $out"
fi

# ---- the action refuses bad knobs before any network call -------------------
chk() { bash -c 'do_log() { echo "$*"; }; source "$1/../run/spl-search-speed-probe.func.sh"; shift; ENV="$1" spl_search_speed_probe_check "$2" "$3" "$4"' _ "$HERE" "$@"; }
chk prd t1 5 archive >/dev/null && pass "a well-formed call passes the check" || fail "a well-formed call was refused"
for bad in "stg t1 5 archive" "prd T1 5 archive" "prd t1 0 archive" "prd t1 51 archive" "prd t1 5 a,,b"; do
  # shellcheck disable=SC2086
  if chk $bad >/dev/null; then fail "bad knobs accepted: $bad"; else pass "bad knobs refused: $bad"; fi
done
if chk prd t1 5 "" >/dev/null; then fail "empty PROBE_TERMS accepted"; else pass "empty PROBE_TERMS refused"; fi

echo "search-speed-probe: $fails failure(s)"
[[ $fails -eq 0 ]]
