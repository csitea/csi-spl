#!/usr/bin/env bash
# do_spl_box_presence_watch / box-presence-watch.py, hermetic: the summary of
# a recorded JSONL (two rolls, one box offline across each, one blip with no
# roll), and a live watch against a stub hub on 127.0.0.1 that flips revision.
# CONTROL: a box never seen online (box-wui) is not counted as a machine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/box-presence-watch.py"
T="$(mktemp -d)"; SRV=""; trap '[[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
j() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$T/out"; }

python3 - "$T/rec.jsonl" <<'PY'
import json, sys
rows = []
def r(ts, rev, desk, lab=True):
    rows.append({"ts": ts, "rev": rev, "status": 200, "ms": 20.0, "boxes": {"box-desk": desk, "box-lab": lab, "box-wui": False}})
for i in range(10): r(1000 + 5 * i, "rev-1", True)
for i in range(10, 16): r(1000 + 5 * i, "rev-2", False)          # roll 1: box-desk offline 30 s
for i in range(16, 30): r(1000 + 5 * i, "rev-2", True)
r(1150, "rev-3", False, False); r(1155, "rev-3", False, False)   # roll 2: both offline 10 s
for i in range(32, 60): r(1000 + 5 * i, "rev-3", True)
r(1300, "rev-3", True, False)                                    # no roll: box-lab blips 5 s
for i in range(61, 64): r(1000 + 5 * i, "rev-3", True)
open(sys.argv[1], "w").write("".join(json.dumps(x) + "\n" for x in rows))
PY
WATCH_SUMMARY="$T/rec.jsonl" python3 "$PY" >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 && "$(j 'len(d["rolls"])')" == 2 ]] && pass "two revision changes are two rolls" || fail "rolls: rc=$rc $(cat "$T/out")"
[[ "$(j 'd["live_boxes"]')" == "['box-desk', 'box-lab']" ]] && pass "CONTROL: box-wui, never online, is not a machine" || fail "live $(j 'd["live_boxes"]')"
[[ "$(j '[d["rolls"][0][k] for k in ("n","max")]')" == "[1, 30.0]" ]] && pass "roll 1: box-desk offline 30 s, n=1" || fail "roll 1 $(j 'd["rolls"][0]')"
[[ "$(j '[d["rolls"][1][k] for k in ("n","min","max")]')" == "[2, 10.0, 10.0]" ]] && pass "roll 2: both machines offline 10 s, n=2" || fail "roll 2 $(j 'd["rolls"][1]')"
[[ "$(j '[(x["box"], x["secs"]) for x in d["no_roll_runs"]]')" == "[('box-lab', 5.0)]" ]] && pass "an offline blip with no roll near it is reported apart" || fail "stray $(j 'd["no_roll_runs"]')"

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T = sys.argv[1]; n = {"roster": 0}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, st, body, cookie=False):
        raw = json.dumps(body).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json")
        if cookie: self.send_header("Set-Cookie", "spool_session=tok; Path=/; HttpOnly")
        self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        self.reply(200, {}, cookie=b.get("password") == "pw-ok")
    def do_GET(self):
        if self.path == "/v1/wui/revision":
            return self.reply(200, {"revision": "rev-a" if n["roster"] < 2 else "rev-b"})
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        n["roster"] += 1
        self.reply(200, {"boxes": [{"box_id": "box-desk", "online": n["roster"] != 3, "revoked": False}], "humans": []})
s = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$T/stub.py" "$T" & SRV=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
umask 077; echo pw-ok >"$T/pw"; echo wrong >"$T/pw-bad"
watch() { PROBE_API="http://127.0.0.1:$(cat "$T/port")" PROBE_TENANT=t1 PROBE_EMAIL=m@example.com PROBE_PW_FILE="${PW:-$T/pw}" \
  WATCH_SECS=4 WATCH_EVERY=1 WATCH_OUT="$T/live.jsonl" python3 "$PY" >"$T/out" 2>&1; }
watch; rc=$?
[[ $rc -eq 0 && "$(j '[d["rolls"][0]["n"], d["reads"] >= 4]')" == "[1, True]" ]] && pass "live watch records reads and finds the roll" || fail "live: rc=$rc $(cat "$T/out")"
grep -q 'pw-ok\|spool_session' "$T/out" "$T/live.jsonl" && fail "password or cookie written" || pass "neither the password nor the cookie is written"
PW="$T/pw-bad" watch; rc=$?
[[ $rc -eq 2 ]] && pass "a failed sign-in exits 2" || fail "bad login: rc=$rc $(cat "$T/out")"

PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
act() {
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_box_presence_watch' >"$T/out" 2>&1 </dev/null
}
act WATCH_SUMMARY="$T/rec.jsonl"; rc=$?
[[ $rc -eq 0 ]] && grep -q '"rolls"' "$T/out" && pass "action summarises a recorded file" || fail "action summary: rc=$rc $(cat "$T/out")"
act TENANT_ID=T_1; rc=$?
[[ $rc -ne 0 ]] && grep -q "TENANT_ID must be a tenant slug" "$T/out" && pass "action refuses a bad TENANT_ID" || fail "action bad tenant: rc=$rc $(cat "$T/out")"
act TENANT_ID=t1 PROBE_PW_FILE="$T/nope"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no readable password file" "$T/out" && pass "action refuses without a password file" || fail "action no pw: rc=$rc $(cat "$T/out")"

(( fails == 0 )) && echo "ALL box-presence-watch CHECKS PASSED" || { echo "$fails FAILED"; exit 1; }
