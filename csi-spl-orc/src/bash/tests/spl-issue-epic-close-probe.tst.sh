#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_epic_close_probe (SPL-1643 live proof) stays offline in
#          its dry run, refuses bad input before any call, and its script
#          judges a hub right.
#   1. dry run: no call; names the steps
#   2. refusals: bad tenant, bad DRY_RUN - each before any call
#   3. the script against a local fake hub that does the cascade: rc 0
#   4. CONTROL: the same fake hub without the cascade (close leaves the
#      issues live): rc 1, step f FAIL
#   5. the script refuses a missing env (rc 2)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool psql
SCRIPT="$TEST_DIR/../scripts/issue-epic-close-probe.py"

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_issue_epic_close_probe in_orc TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "test epic with 2 open issues in t1 on dev" <<<"$out" && pass "dry run names the tenant and env" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "TENANT_ID=T1" "TENANT_ID=" "DRY_RUN=2"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_issue_epic_close_probe in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    grep -q FATAL "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "refuses $bad before any call" || fail "refuses $bad: $(cat "$T/o")"
  fi
done

# --- 3/4. the script against a fake hub ----------------------------------------------------
cat >"$T/fakehub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
CASCADE = os.environ.get("FAKE_CASCADE") == "1"
issues, archived, seq = {}, set(), [0]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, st, body, cookie=False):
        b = json.dumps(body).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json")
        if cookie: self.send_header("Set-Cookie", "spool_session=x; Path=/")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def kids(self, k): return [x for x, i in issues.items() if i.get("epic") == k]
    def do_POST(self):
        p, q = self.body(), self.path
        if q == "/api/v1/auth/login": return self.send(200, {}, cookie=True)
        if q == "/v1/issues":
            seq[0] += 1; k = "SPL-%d" % seq[0]; issues[k] = dict(p, key=k); return self.send(201, {"issue": issues[k]})
        m = re.match(r"/v1/issues/(SPL-\d+)/(archive|unarchive)", q)
        if m:
            k, op = m.groups(); ks = self.kids(k)
            for x in [k] + ks: (archived.add if op == "archive" else archived.discard)(x)
            return self.send(200, {"issue": issues[k], "descendants": ks})
        self.send(404, {"error": "not_found"})
    def do_PATCH(self):
        k = self.path.rsplit("/", 1)[1]; p = self.body(); ks = self.kids(k)
        open_ = [x for x in ks if issues[x]["status"] != "done"]
        if open_ and not p.get("cascade"):
            return self.send(409, {"error": "epic_close_confirm", "detail": "%s has %d open issues: ..." % (k, len(open_))})
        issues[k]["status"] = p["status"]
        if CASCADE:
            for x in ks: issues[x]["status"] = p["status"]
            archived.update([k] + ks)
        self.send(200, {"issue": issues[k], "archived": CASCADE, "closed": ks if CASCADE else [], "descendants": ks if CASCADE else []})
    def do_GET(self):
        k = self.path.rsplit("/", 1)[1]
        if k in archived or k not in issues: return self.send(404, {"error": "not_found"})
        self.send(200, {"issue": issues[k]})
s = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
printf 'pw\n' >"$T/pw"; chmod 600 "$T/pw"
run_fake() { # <cascade 0|1> -> rc of the script; its output in $T/probe.out
  local port pid _ rc
  rm -f "$T/port"
  FAKE_CASCADE="$1" python3 "$T/fakehub.py" "$T/port" & pid=$!
  for _ in $(seq 1 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
  port="$(cat "$T/port")"
  PROBE_API="http://127.0.0.1:$port" PROBE_TENANT=t1 PROBE_EMAIL=e2e@example.com PROBE_PW_FILE="$T/pw" \
    M3_STATE_DIR="$T" python3 "$SCRIPT" >"$T/probe.out" 2>&1; rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return $rc
}
run_fake 1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^FAIL' "$T/probe.out" && grep -q '^PASS h-all-3-restored-done' "$T/probe.out" \
  && pass "a hub that cascades: every step PASS" || fail "cascading hub: rc=$rc $(cat "$T/probe.out")"
run_fake 0; rc=$?
[[ $rc -eq 1 ]] && grep -q '^FAIL f-all-3-archived' "$T/probe.out" \
  && pass "CONTROL a hub without the cascade: rc 1, step f FAIL" || fail "CONTROL no-cascade hub: rc=$rc $(cat "$T/probe.out")"

# --- 5. missing env ---------------------------------------------------------------------
env -u PROBE_API python3 "$SCRIPT" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 2 ]] && grep -q "FATAL PROBE_API must be set" "$T/o" && pass "script refuses a missing PROBE_API" || fail "missing env: rc=$rc $(cat "$T/o")"

echo "=== $([[ $fails -eq 0 ]] && echo 'all spl-issue-epic-close-probe.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
