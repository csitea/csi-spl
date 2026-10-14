#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_invite_e2e + invite-e2e.py, offline (t1 afa8a4fb R7): a fake
# hub on loopback and a STUBBED mailbox (INVITE_E2E_MAILDIR, .eml files).
#   1. the happy path: steps 1-5 PASS, 6 SKIPPED with no root key, exit 0
#   2. CONTROLS, each must FAIL the run: the link names another tenant, the
#      link's login_hint is not the invitee, a sent copy with no Delivered-To,
#      the hub did not mail the invite, the login is refused
#   3. no password, token or cookie reaches stdout or results.json
#   4. the wrapper: prd outside a test workspace (t1, a customer) and any
#      other env refused before any call; prd in e2e / a listed test
#      workspace runs with the prd cnf mailbox; the invitee is a fresh
#      plus-address of the cnf relay mailbox; the invite body; the engine runs;
#      teardown revokes a pending invite (not bound) and removes a bound member
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PY="$PROJ_ROOT/src/bash/scripts/invite-e2e.py"
INV=sys+inv-r1@example.com

# --- the fake hub -------------------------------------------------------------------
cat >"$T/hub.py" <<'PY'
import http.server, json, os, sys
LOGIN = int(os.environ.get("FAKE_LOGIN", "200"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, body=None, ctype="application/json", hdrs=()):
        raw = (json.dumps(body) if ctype == "application/json" else body or "").encode() if body is not None else b""
        self.send_response(code); self.send_header("Content-Type", ctype)
        for k, v in hdrs: self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def cookie(self): return "spool_session=fake-cookie-s3cret" in (self.headers.get("Cookie") or "")
    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/version": return self.out(200, {"version": "0.0.0-fake"})
        if p == "/login": return self.out(200, "<html>sign in</html>", "text/html; charset=utf-8")
        if p == "/api/v1/auth/session":
            return self.out(200, {"hum": "HUM-77", "t": "t1", "p": "native"}) if self.cookie() else self.out(401, {})
        if p == "/v1/view/topics": return self.out(200, {"topics": []}) if self.cookie() else self.out(401, {})
        self.out(404, {"error": "not_found"})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path == "/api/v1/auth/register": return self.out(202, {"debug_token": "d" * 64})
        if self.path == "/api/v1/auth/email/verify": return self.out(204)
        if self.path == "/api/v1/auth/login":
            if LOGIN != 200: return self.out(LOGIN, {"error": "not_allowed"})
            return self.out(200, {"hum": "HUM-77"}, hdrs=[("Set-Cookie", "spool_session=fake-cookie-s3cret; Path=/")])
        self.out(404, {})
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
start_hub() {
  [[ -n "${HUB_PID:-}" ]] && { kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; }
  coproc HUBP { FAKE_LOGIN="${1:-200}" exec python3 -u "$T/hub.py" 2>/dev/null; }
  HUB_PID=$HUBP_PID
  read -r PORT <&"${HUBP[0]}"
}
trap '[[ -n "${HUB_PID:-}" ]] && kill "$HUB_PID" 2>/dev/null; rm -rf "$T"' EXIT

# mail <file> <tenant> <login_hint> [delivered-to|none] [message-id]
# The hint is query-escaped as the hub's url.QueryEscape does (+ -> %2B).
mail() {
  local dt="" hint
  hint=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$3")
  [[ "${4:-$INV}" != none ]] && dt="Delivered-To: ${4:-$INV}"$'\r\n'
  printf '%sFrom: SPOOL <sys+noreply@example.com>\r\nTo: %s\r\nSubject: You are invited\r\nMessage-ID: %s\r\nContent-Type: text/plain\r\n\r\nSign in: http://127.0.0.1:%s/login?tenant=%s&redirect=%%2Flobby&login_hint=%s\r\n' \
    "$dt" "$INV" "${5:-<m1.tenant_invite@example.com>}" "$PORT" "$2" "$hint" >"$1"
}
# invite_json <dir> [outcome] [message-id]
invite_json() {
  printf '{"status":201,"body":{"tenant_id":"t1","role":"developer","mail":{"outcome":"%s","message_id":"%s"}}}\n' \
    "${2:-sent}" "${3:-<m1.tenant_invite@example.com>}" >"$1/invite.json"
}
# engine <case>: run invite-e2e.py on $T/<case> (state + maildir); sets rc, out
engine() {
  local d="$T/$1"
  out=$(M3_HUB_URL="http://127.0.0.1:$PORT" M3_AUTH_URL="http://127.0.0.1:$PORT" M3_TENANT=t1 M3_STATE="$d" \
    M3_HUMAN_EMAIL="$INV" M3_ROOT_KEY="" M3_SPOOL="" M3_IMAP_USER="" INVITE_E2E_MAILDIR="$d/mail" \
    INVITE_E2E_TIMEOUT=2 python3 -B "$PY" run 2>&1); rc=$?
}
setup() { mkdir -p "$T/$1/mail"; invite_json "$T/$1" "${2:-sent}"; }
start_hub

# --- 1. the happy path -------------------------------------------------------------
setup ok; mail "$T/ok/mail/1.eml" t1 "$INV"
engine ok
for s in 1-invite-mailed 2-invite-mail 2-plus-delivered 3-link-page 4-sign-in 5-bound; do
  grep -q "^PASS $s " <<<"$out" && pass "1. $s PASS" || fail "1. $s: $out"
done
grep -q '^SKIPPED 6-agent-answers ' <<<"$out" && [[ $rc == 0 ]] && pass "1. no root key: 6 SKIPPED, exit 0" || fail "1. rc=$rc: $out"
jq -e '[.results[] | select(.result == "FAIL")] | length == 0' "$T/ok/results.json" >/dev/null \
  && pass "1. results.json carries no FAIL" || fail "1. results.json: $(cat "$T/ok/results.json")"

# --- 2. controls ---------------------------------------------------------------------
ctl() {  # <case> <step that must FAIL> <label>
  if [[ $rc != 0 ]] && grep -q "^FAIL $2 " <<<"$out"; then pass "2. CONTROL $3: $2 FAIL, exit $rc"; else fail "2. CONTROL $3: rc=$rc $out"; fi
}
setup t2; mail "$T/t2/mail/1.eml" t2 "$INV"; engine t2; ctl t2 2-invite-mail "link names another tenant"
setup hint; mail "$T/hint/mail/1.eml" t1 someone-else@example.com; engine hint; ctl hint 2-invite-mail "login_hint is not the invitee"
setup sent; mail "$T/sent/mail/1.eml" t1 "$INV" none; printf '\\Sent\n' >"$T/sent/mail/1.labels"
engine sent; ctl sent 2-plus-delivered "a copy that was only sent (\\Sent, no Delivered-To)"
# dev's relay IS the mailbox: Gmail keeps one self-sent copy, \Inbox + \Sent, no Delivered-To
setup self; mail "$T/self/mail/1.eml" t1 "$INV" none; printf '\\Inbox \\Sent\n' >"$T/self/mail/1.labels"
engine self
grep -q '^PASS 2-plus-delivered ' <<<"$out" && [[ $rc == 0 ]] && pass "2. a self-sent copy filed under \\Inbox counts as delivered" || fail "2. self-sent: rc=$rc $out"

# the X-GM-LABELS parse, on the response shape Gmail's IMAP returns
out=$(python3 -B - "$PY" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("inv", sys.argv[1]); inv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inv)
RAW = b"To: x@example.com\r\n\r\nbody\r\n"
class Fake:
    def uid(self, cmd, *a):
        if cmd == "SEARCH": return "OK", [b"3390"]
        return "OK", [(b'2422 (X-GM-LABELS ("\\\\Inbox" "\\\\Sent") UID 3390 RFC822 {30}', RAW), b")"]
    def logout(self): pass
inv.m3.imap_open = lambda: Fake()
print(inv.mailbox_raws("x@example.com", set()))
PY
)
grep -qF "[(b'3390', b'To: x@example.com\r\n\r\nbody\r\n', ['\\\\Inbox', '\\\\Sent'])]" <<<"$out" \
  && pass "2. IMAP X-GM-LABELS parsed to \\Inbox, \\Sent" || fail "2. label parse: $out"
setup mid; mail "$T/mid/mail/1.eml" t1 "$INV" "$INV" '<other@example.com>'; engine mid; ctl mid 2-invite-mail "another mail's Message-ID"
setup nomail not_sent; mail "$T/nomail/mail/1.eml" t1 "$INV"; engine nomail; ctl nomail 1-invite-mailed "the hub did not mail it"
start_hub 403
setup refused; mail "$T/refused/mail/1.eml" t1 "$INV"; engine refused; ctl refused 4-sign-in "the login is refused"
start_hub

# --- 3. no secret in the output -------------------------------------------------------
grep -qE 's3cret|d{64}' <<<"$(cat "$T/ok/results.json")$out" && fail "3. a cookie or token reached the output" \
  || pass "3. no cookie or token in stdout or results.json"
setup leak; mail "$T/leak/mail/1.eml" t1 "$INV"; engine leak
grep -qE 's3cret|d{64}' <<<"$out$(cat "$T/leak/results.json")" && fail "3. leak run: $out" || pass "3. second run: still clean"

# --- 4. the wrapper ---------------------------------------------------------------------
orc_stub 1 curl spool
run_wrap() {
  : >"$T/calls.log"
  SNIPPET='
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; echo "pin" >>"$STUB_LOG"; }
    do_gcp_require_live_account() { :; }
    gcloud() { echo "gcloud $*" >>"$STUB_LOG"; [[ "$*" == "auth print-access-token "* ]] && echo ya29.fake-access; }
    spl_m3_imap_pass() { ( umask 077; echo relay-pw-s3cret >"$1" ); }
    spl_hub_operator_call() { echo "hub $1 $2 ${3:-}" >>"$STUB_LOG"; SPL_HUB_OP_STATUS="${STUB_CODE:-201}"; SPL_HUB_OP_BODY="{\"tenant_id\":\"t1\"}"; }
    do_spl_tenant_member_remove() { echo "member-remove $TENANT_ID $EMAIL $DRY_RUN" >>"$STUB_LOG"; }
    python3() { [[ "$1" == *invite-e2e.py ]] || command python3 "$@"; echo "engine $M3_HUMAN_EMAIL $M3_TENANT pass=$(stat -c %a "$M3_IMAP_PASS_FILE")" >>"$STUB_LOG";
      [[ "${BIND:-0}" == 1 ]] && echo "{}" >"$M3_STATE/bound.json"; return "${PY_RC:-0}"; }
    do_spl_invite_e2e' in_orc SPL_TENANTS_DIR="$T/no-tenants" SPOOL_ROOT="$T/spool" "$@" >"$T/wrap.out" 2>&1
}
mkdir -p "$T/spool/dispatch"; printf '# test workspaces\nw12live1  # a listed one\n' >"$T/spool/dispatch/test-workspaces"
for t in t1 ws-a e2ex ''; do
  run_wrap ENV=prd TENANT_ID="$t"; rc=$?
  [[ $rc != 0 && ! -s "$T/calls.log" ]] && grep -q "only in a test workspace" "$T/wrap.out" \
    && pass "4. prd TENANT_ID='$t' refused before any call" || fail "4. prd $t: rc=$rc $(cat "$T/wrap.out" "$T/calls.log")"
done
run_wrap ENV=prd TENANT_ID=t1 SWEEP_SKIP_TENANTS=t1; rc=$?
[[ $rc != 0 && ! -s "$T/calls.log" ]] && pass "4. prd t1 refused even when SWEEP_SKIP_TENANTS lists it" || fail "4. prd t1 listed: rc=$rc"
run_wrap ENV=stg TENANT_ID=e2e; rc=$?
[[ $rc != 0 && ! -s "$T/calls.log" ]] && pass "4. an env other than dev/prd refused before any call" || fail "4. stg: rc=$rc $(cat "$T/calls.log")"
puser=$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER' "$APP_ROOT/csi-spl-cnf/csi-spl/prd.env.yaml")
for t in e2e e2e-2 w12live1; do
  run_wrap ENV=prd TENANT_ID="$t" INVITE_E2E_RUN_ID=p1 SPL_STATE_DIR="$T/state/prd"; rc=$?
  pwant="${puser%@*}+inv-p1@${puser#*@}"
  [[ $rc == 0 ]] && jq -e --arg e "$pwant" --arg t "$t" '.tenant == $t and .email == $e' \
      <<<"$(grep '^hub POST' "$T/calls.log" | cut -d' ' -f4-)" >/dev/null && grep -qx "engine $pwant $t pass=600" "$T/calls.log" \
    && grep -q "^hub DELETE /v1/operator/invites?tenant=$t&email=" "$T/calls.log" \
    && pass "4. prd test workspace $t: invites $pwant there, tears it down" || fail "4. prd $t: rc=$rc $(cat "$T/wrap.out" "$T/calls.log")"
done
run_wrap TENANT_ID=t1 INVITE_E2E_RUN_ID='Bad_Id'; rc=$?
[[ $rc != 0 && ! -s "$T/calls.log" ]] && pass "4. a bad run id is refused before any call" || fail "4. run id: rc=$rc $(cat "$T/calls.log")"

run_wrap TENANT_ID=t1 INVITE_E2E_RUN_ID=r1; rc=$?
user=$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml")
want="${user%@*}+inv-r1@${user#*@}"
grep -q "^pin$" "$T/calls.log" && grep -q "^hub POST /v1/operator/invites " "$T/calls.log" && \
  jq -e --arg e "$want" '.tenant == "t1" and .email == $e and .role == "developer" and .ttl_hours == 1' \
    <<<"$(grep '^hub POST' "$T/calls.log" | cut -d' ' -f4-)" >/dev/null \
  && pass "4. invites the plus-address $want of the cnf mailbox, 1 h" || fail "4. invite: $(cat "$T/calls.log")"
grep -qx "engine $want t1 pass=600" "$T/calls.log" && pass "4. the engine runs with a 0600 password file" || fail "4. engine: $(cat "$T/calls.log")"
[[ $rc == 0 ]] && grep -q '^hub DELETE /v1/operator/invites?tenant=t1&email=' "$T/calls.log" && ! grep -q member-remove "$T/calls.log" \
  && pass "4. not bound: teardown revokes the invite" || fail "4. teardown: rc=$rc $(cat "$T/calls.log")"
st="$T/state/dev/invite-e2e/r1"
[[ ! -e "$st/imap-pass" ]] && pass "4. the password file is gone after the run" || fail "4. imap-pass left"
grep -q s3cret "$T/wrap.out" && fail "4. the password reached the log" || pass "4. the password is in no output"
run_wrap TENANT_ID=t1 INVITE_E2E_RUN_ID=r2 BIND=1 PY_RC=1; rc=$?
[[ $rc != 0 ]] && grep -q "^member-remove t1 ${user%@*}+inv-r2@${user#*@} 0$" "$T/calls.log" && ! grep -q '^hub DELETE' "$T/calls.log" \
  && pass "4. bound + a failed step: exit != 0, the member is removed" || fail "4. bound: rc=$rc $(cat "$T/calls.log")"
grep -q "step 6 (the agent answers) will be SKIPPED" "$T/wrap.out" && pass "4. no root key: says step 6 is skipped" || fail "4. skip note: $(cat "$T/wrap.out")"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
