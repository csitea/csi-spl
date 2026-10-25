#!/usr/bin/env bash
# SPL-3337 do_spl_search_doc_probe / search-doc-probe.py, hermetic: a stub hub
# on 127.0.0.1 answers the login, the doctree create / add / edit / delete and
# GET /v1/view/search. In "index" mode it finds a doc by the words it holds
# now (green); in "noindex" mode, the hub before SPL-3337, search finds no doc
# and type:doc is 400 bad_query (red).
#
# CONTROLS: noindex FAILS the probe (exit 1) and names each missed search; a
# stub that keeps finding the OLD word after the edit FAILS it; a refused
# sign-in is exit 2; the doc is deleted on every path that made one; the
# action refuses bad knobs, and is a dry run without DRY_RUN=0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/search-doc-probe.py"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs
T = sys.argv[1]
DOC, ITEM = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
state = {"text": "", "old": ""}
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
        if self.path == "/v1/workspace/doctree": return self.reply(200, {"id": DOC, "root": "r", "rev": 1})
        if self.path == "/v1/workspace/doctree/%s/items" % DOC:
            state["text"] = b.get("title", "") + " " + b.get("body", "")
            return self.reply(200, {"rev": 2, "item": ITEM})
        self.reply(404, {"error": "not_found"})
    def do_PATCH(self):
        b = self.body(); self.log("PATCH " + self.path)
        state["old"], state["text"] = state["text"], state["text"].split(" ")[0] + " " + state["text"].split(" ")[1] + " " + b.get("value", "")
        self.reply(200, {"item_rev": 2})
    def do_DELETE(self):
        self.log("DELETE " + self.path); self.reply(200, {"deleted": True})
    def do_GET(self):
        if self.path == "/ping": return self.reply(200, {})
        if not self.authed(): return self.reply(401, {"error": "view_door"})
        u = urlsplit(self.path); q = parse_qs(u.query)["q"][0]
        self.log("GET search " + q)
        words = [w for w in q.split() if not w.startswith("type:")]
        m = mode()
        if m == "noindex":
            if q.startswith("type:doc"): return self.reply(400, {"error": "bad_query"})
            return self.reply(200, {"groups": {"messages": {"results": [], "next": None}}})
        text = state["text"] + (" " + state["old"] if m == "stale" else "")
        hit = all(w in text.split() for w in words)
        rows = [{"doc_id": DOC, "item_id": ITEM}] if hit else []
        self.reply(200, {"groups": {"messages": {"results": [], "next": None}, "docs": {"results": rows, "next": None}}})
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf 'pw-ok' >"$T/pw"; printf 'pw-bad' >"$T/pw-bad"; echo index >"$T/mode"
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
deleted() { grep -c '^DELETE /v1/workspace/doctree/' "$T/calls.log" 2>/dev/null || true; }

# ---- green: found by its word, by type:doc, after the edit; old word gone ---
out=$(run index); rc=$?
if [[ $rc -eq 0 && "$(deleted)" -eq 1 ]] && grep -q '"ok": true' <<<"$out" && [[ "$(grep -c '^OK ' <<<"$out")" -eq 5 ]] &&
  grep -q '^GET search type:doc zqa' "$T/calls.log"; then
  pass "a hub that indexes docs: 4 searches + the edit OK, the doc deleted (exit 0)"
else
  fail "the green run did not pass (exit $rc): $out"
fi

# ---- CONTROL: the hub before SPL-3337 is red, each miss named ---------------
out=$(run noindex); rc=$?
if [[ $rc -eq 1 && "$(deleted)" -eq 1 ]] && grep -qE '^MISS +type:doc .*status=400' <<<"$out" &&
  [[ "$(grep -c '^MISS ' <<<"$out")" -eq 3 ]] && grep -q '"ok": false' <<<"$out"; then
  pass "CONTROL a hub without the doc section: exit 1, 3 searches MISS (type:doc 400), the doc still deleted"
else
  fail "CONTROL the no-index hub did not fail as it should (exit $rc): $out"
fi

# ---- CONTROL: a stale index (old word still found) is red ------------------
out=$(run stale); rc=$?
if [[ $rc -eq 1 ]] && grep -qE '^MISS +zqb.*want=absent' <<<"$out"; then
  pass "CONTROL an index that keeps the edited-away word: exit 1, that search MISS"
else
  fail "CONTROL the stale index passed (exit $rc): $out"
fi

# ---- a refused sign-in is exit 2, nothing made ------------------------------
out=$(run index "$T/pw-bad"); rc=$?
if [[ $rc -eq 2 ]] && ! grep -q 'doctree' "$T/calls.log" && grep -q '"step": "login"' <<<"$out" && ! grep -q 'pw-' <<<"$out"; then
  pass "a refused sign-in: exit 2, no doc made, no password printed"
else
  fail "the refused sign-in was not exit 2 with nothing made (exit $rc): $out"
fi

# ---- the action: knobs refused, dry run by default --------------------------
ACT="$HERE/../run/spl-search-doc-probe.func.sh"
chk() { # chk <ENV> <TENANT_ID> [DRY_RUN]
  bash -c 'do_log() { echo "$*"; }; spl_dry_run() { [[ "${DRY_RUN:-1}" != 0 ]]; }
    do_require_bin() { :; }; do_spl_cloud_cnf() { :; }; spl_cnf_api_fqdn() { printf -v "$1" %s api.example.com; }
    source "$1"; do_spl_search_doc_probe' _ "$ACT" 2>&1 <<<"" | cat
}
o1=$(ENV=qa TENANT_ID=t1 chk); o2=$(ENV=dev TENANT_ID='T 1' chk); o3=$(ENV=dev TENANT_ID=t1 chk)
if grep -q 'FATAL ENV must be dev or prd' <<<"$o1" && grep -q 'FATAL TENANT_ID must be a tenant slug' <<<"$o2" &&
  grep -q 'OK DRY_RUN nothing was touched' <<<"$o3"; then
  pass "the action refuses a bad ENV and TENANT_ID, and is a dry run without DRY_RUN=0"
else
  fail "the action's knobs: [$o1] [$o2] [$o3]"
fi

if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "PASS: all"
