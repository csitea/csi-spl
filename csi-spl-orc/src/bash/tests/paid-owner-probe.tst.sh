#!/usr/bin/env bash
# 047 W1 do_spl_paid_owner_probe / paid-owner-probe.py, hermetic: a stub hub on
# 127.0.0.1 answers register (with a debug token), verify, login and
# GET /v1/view/me. It admits the buyer as $T/role and refuses the other address
# unless $T/open exists. CONTROLS: a buyer seated as developer, and a hub that
# lets the other address in, must both fail the probe. Since SPL-2157 the dev
# hub answers no debug token: with $T/nodebug the stub answers none, and the
# probe reads the verify mail over IMAP (m3's reader, faked in-process here);
# CONTROL: no token and no mailbox fails with a clear reason (exit 2).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../scripts/paid-owner-probe.py"
FN="$HERE/../run/spl-paid-owner-probe.func.sh"
T="$(mktemp -d)"; trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T = sys.argv[1]
BUYER = "buyer@example.com"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, st, body, cookie=""):
        raw = json.dumps(body).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        if cookie: self.send_header("Set-Cookie", "spool_session_dev=" + cookie + "; Path=/; HttpOnly")
        self.end_headers(); self.wfile.write(raw)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def do_POST(self):
        b = self.body()
        with open(os.path.join(T, "calls"), "a") as f: f.write(self.path + " " + json.dumps(b) + "\n")
        if self.path == "/api/v1/auth/register":
            if os.path.exists(os.path.join(T, "nodebug")): return self.reply(202, {"status": "verification_required"})
            return self.reply(201, {"status": "pending", "debug_token": "tok-" + b["email"]})
        if self.path == "/api/v1/auth/email/verify":
            return self.reply(200, {}) if b.get("token", "").startswith("tok-") and b.get("password") else self.reply(401, {"error": "verify_invalid"})
        if self.path == "/api/v1/auth/login":
            if b.get("tenant") != "w1t": return self.reply(403, {"error": "not_allowed"})
            if b["email"] == BUYER or os.path.exists(os.path.join(T, "open")): return self.reply(200, {}, cookie="c-" + b["email"])
            return self.reply(403, {"error": "not_allowed"})
    def do_GET(self):
        if self.headers.get("Cookie", "") != "spool_session_dev=c-" + BUYER: return self.reply(401, {"error": "view_door"})
        role = open(os.path.join(T, "role")).read().strip()
        self.reply(200, {"human_id": "HUM-9", "tenant_id": "w1t", "role": role})
s = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
echo biz_owner >"$T/role"
python3 "$T/stub.py" "$T" & SRV=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
probe() { : >"$T/calls"; PROBE_API="http://127.0.0.1:$(cat "$T/port")" PROBE_TENANT=w1t PROBE_BUYER_EMAIL=buyer@example.com \
  PROBE_OTHER_EMAIL="${OTHER:-other@example.com}" python3 "$PY" >"$T/out" 2>&1; }

probe; rc=$?
[[ $rc -eq 0 ]] && grep -q '"ok": true' "$T/out" && grep -q '"role": "biz_owner"' "$T/out" && grep -q '"error": "not_allowed"' "$T/out" \
  && pass "buyer signs in as biz_owner, the other address is refused (not_allowed), 0 operator actions" || fail "happy path: rc=$rc $(cat "$T/out")"
[[ "$(grep -c '"tenant": "w1t"' "$T/calls")" -eq 2 ]] && pass "both logins name the tenant" || fail "login bodies: $(cat "$T/calls")"
grep -q 'example.com\|spool_session\|c-buyer' "$T/out" && fail "an address or the cookie is printed" || pass "no address, password or cookie in the verdict"
pw="$(grep -o '"password": "[^"]*"' "$T/calls" | sed -n 1p | cut -d'"' -f4)"
[[ ${#pw} -ge 20 ]] && ! grep -qF "$pw" "$T/out" && pass "a random password (${#pw} chars), not printed" || fail "password: '${pw:0:3}...'"

echo developer >"$T/role"; probe; rc=$?
[[ $rc -eq 1 ]] && grep -q '"ok": false' "$T/out" && pass "CONTROL: a buyer seated as developer fails the probe" || fail "CONTROL role: rc=$rc $(cat "$T/out")"
echo biz_owner >"$T/role"; touch "$T/open"; probe; rc=$?
[[ $rc -eq 1 ]] && grep -q '"ok": false' "$T/out" && pass "CONTROL: a hub that admits the other address fails the probe" || fail "CONTROL open: rc=$rc $(cat "$T/out")"
rm -f "$T/open"
OTHER=Buyer@Example.com probe; rc=$?
[[ $rc -eq 2 ]] && pass "the same address twice is refused before any call" || fail "same address: rc=$rc"

# no debug token (dev and prd since SPL-2157)
touch "$T/nodebug"; probe; rc=$?
[[ $rc -eq 2 ]] && grep -q 'no debug_token (lde only since SPL-2157)' "$T/out" && ! grep -q Traceback "$T/out" && ! grep -q 'example.com' "$T/out" \
  && pass "CONTROL: no debug token and no mailbox -> exit 2, a clear reason, no address" || fail "no-token control: rc=$rc $(cat "$T/out")"
out="$(PROBE_API="http://127.0.0.1:$(cat "$T/port")" PROBE_TENANT=w1t PROBE_BUYER_EMAIL=buyer@example.com PROBE_OTHER_EMAIL=other@example.com \
  python3 -B - "$PY" <<'PYI' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pop", sys.argv[1]); pop = importlib.util.module_from_spec(spec); spec.loader.exec_module(pop)
pop.m3.IMAP_USER = "relay@example.com"
asked = []
pop.m3.imap_uids = lambda rcpt: {b"1"}
def mail(rcpt, seen):
    asked.append((rcpt, sorted(seen)))
    return ("tok-" + rcpt, {"mail_from": "x"}) if rcpt.startswith("buyer") else ("", {"mail": "no verify mail to %s within 1s" % rcpt})
pop.m3.imap_verify_token = mail
print("BUYER", pop.account("buyer@example.com"))
print("OTHER", pop.account("other@example.com"))
print("ASKED", asked)
PYI
)"
grep -q "^BUYER ('.*', None)" <<<"$out" && pass "no debug token: the verify mail over IMAP verifies the account" || fail "imap path: $out"
grep -q "^OTHER (None, {.*'via': 'imap', 'error': 'no verify mail within" <<<"$out" && ! grep -q '^OTHER.*other@' <<<"$out" \
  && pass "no mail in time: a clear failure that names no address" || fail "imap miss: $out"
grep -qF "ASKED [('buyer@example.com', [b'1'])" <<<"$out" && pass "only a mail newer than the register counts (seen UIDs passed)" || fail "seen: $out"
rm -f "$T/nodebug"

# the action: dev only, fields checked before any cnf or network
out="$(ENV=prd TENANT_ID=w1t BUYER_EMAIL=a@example.com OTHER_EMAIL=b@example.com bash -c "do_log() { echo \"\$*\"; }; do_require_bin() { :; }; source '$FN'; do_spl_paid_owner_probe" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "ENV must be dev" <<<"$out" && pass "ENV=prd refused (prd checkouts are real)" || fail "prd: rc=$rc $out"
out="$(ENV=dev TENANT_ID=w1t BUYER_EMAIL=a@example.com OTHER_EMAIL=A@example.com bash -c "do_log() { echo \"\$*\"; }; do_require_bin() { :; }; source '$FN'; do_spl_paid_owner_probe" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "must differ" <<<"$out" && pass "one address for both refused" || fail "same: rc=$rc $out"

# the action: both addresses must be plus-addresses of the cnf relay mailbox
printf 'env:\n  mail:\n    env:\n      SPOOL_HUB_MAIL_SMTP_USER: Relay@example.net\n      SPOOL_HUB_MAIL_SMTP_HOST: smtp.example.net\n' >"$T/cnf.yaml"
act() { env TENANT_ID=w1t "$@" bash -c "do_log() { echo \"\$*\"; }; do_require_bin() { :; }; do_spl_cloud_cnf() { SPL_CNF='$T/cnf.yaml'; }
  spl_cnf_api_fqdn() { printf -v \"\$1\" %s api.example.net; }; spl_m3_imap_pass() { echo IMAP-PASS-READ; }; source '$FN'; do_spl_paid_owner_probe" 2>&1; }
out="$(act ENV=dev BUYER_EMAIL=a@example.com OTHER_EMAIL=relay+o@example.net)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "a@example.com is no plus-address of the relay mailbox" <<<"$out" && ! grep -q IMAP-PASS-READ <<<"$out" \
  && pass "a buyer outside the relay mailbox is refused before any secret read" || fail "relay check: rc=$rc $out"
out="$(act ENV=dev BUYER_EMAIL=relay+b@example.net OTHER_EMAIL=Relay+O@example.net)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN would register, verify (the mail over IMAP)" <<<"$out" && ! grep -q IMAP-PASS-READ <<<"$out" \
  && pass "relay plus-addresses: the dry run plans the IMAP verify, reads no secret" || fail "dry: rc=$rc $out"

(( fails == 0 )) && echo "paid-owner-probe: all passed" || { echo "paid-owner-probe: $fails failed"; exit 1; }
