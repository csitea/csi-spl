#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dev_password_reset over a scratch dir and a fake reset
#          script. No hub.
#   1. prd is refused; bad input is refused
#   2. dry run: says what it would do, the file unchanged
#   3. a file the first probe seat still owns (probe-invited beside it) is
#      refused, the file unchanged; the probe seat's own probe/ dir is not
#   4. DRY_RUN=0: the reset script gets the email, tenant, hub and file; OK
#   5. a failed reset is FAIL (exit 1) and leaves the file as it was
#   6. the operator route (default since SPL-2157): the SA is pinned, the
#      script runs inside spl_via_proxy with RESET_SPOOL; RESET_VIA=debug_token
#      skips both; another RESET_VIA is refused
#   7. dev-password-reset.py against a fake hub + a fake spool: the operator
#      route gets the password on STDIN only, signs in, writes the file 0600;
#      CONTROL: a hub with no debug_token and no operator route fails with a
#      clear message (no traceback), the file unchanged
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
D="$T/m3-e2e/t1"; mkdir -p "$D"; F="$D/pw-human"
echo replaced >"$F"

cat >"$T/reset.sh" <<'EOF'
#!/usr/bin/env bash
echo "$RESET_EMAIL $RESET_TENANT $RESET_API $RESET_PW_FILE" >>"$RESET_LOG"
echo "spool=${RESET_SPOOL:-} dsn=${SPL_PROXY_DSN:-}" >>"$RESET_LOG.env"
[ -e "$RESET_FAIL" ] && { echo '{"step": "reset", "status": 401}'; exit 1; }
echo new-secret >"$RESET_PW_FILE"
echo '{"step": "login", "status": 200}'
EOF
chmod +x "$T/reset.sh"

reset() {
  env PROJ_PATH="$PROJ_ROOT" RESET_CMD="$T/reset.sh" RESET_LOG="$T/log" RESET_FAIL="$T/fail" \
    ENV=dev TENANT_ID=t1 RESET_EMAIL=m3-e2e-human@example.com RESET_PW_FILE="$F" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_spl_cloud_cnf() { SPL_CNF=/fake/dev.env.yaml; }
    spl_cnf_api_fqdn() { printf -v "$1" %s hub.example.com; }
    do_gcp_pin_account() { echo "pin $1" >>"$RESET_LOG.ops"; }
    spl_host_spool() { SPL_SPOOL=/fake/spool; }
    spl_via_proxy() { echo proxy >>"$RESET_LOG.ops"; SPL_PROXY_DSN=fake-dsn "$@"; }
    source "$PROJ_PATH/src/bash/run/spl-dev-password-reset.func.sh"
    do_spl_dev_password_reset'
}

reset ENV=prd DRY_RUN=0 >/dev/null 2>&1 && fail "1. prd accepted" || pass "1. prd is refused"
reset RESET_EMAIL='x;y' >/dev/null 2>&1 && fail "1. a bad email accepted" || pass "1. RESET_EMAIL must be an email"
reset RESET_PW_FILE=pw-human >/dev/null 2>&1 && fail "1. a relative file accepted" || pass "1. RESET_PW_FILE must be absolute"

reset >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$F")" == replaced && ! -e "$T/log" ]] && grep -q "would: reset the password of m3-e2e-human@example.com" "$T/o" &&
  pass "2. dry run: the plan, the file unchanged" || fail "2. dry: rc=$rc $(cat "$T/o")"

touch "$D/probe-invited"
reset DRY_RUN=0 >"$T/o" 2>&1 && fail "3. an unmigrated probe dir accepted" ||
  { [[ "$(cat "$F")" == replaced && ! -e "$T/log" ]] && grep -q 'do_spl_probe_member_seat first' "$T/o" &&
    pass "3. a dir the first probe seat still owns is refused" || fail "3. marker: $(cat "$T/o")"; }
rm -f "$D/probe-invited"
P="$D/probe"; mkdir -p "$P"; touch "$P/probe-invited"; echo old >"$P/pw-human"
reset DRY_RUN=0 RESET_PW_FILE="$P/pw-human" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$P/pw-human")" == new-secret ]] &&
  pass "3. the probe seat's own dir (probe/, marker inside) is reset" || fail "3. probe dir: rc=$rc $(cat "$T/o")"
rm -rf "$P" "$T/log"*

reset DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$F")" == new-secret ]] && grep -qxF "m3-e2e-human@example.com t1 https://hub.example.com $F" "$T/log" &&
  grep -q '^OK m3-e2e-human@example.com has a new password' "$T/o" &&
  pass "4. reset, signed in, kept in the file" || fail "4. reset: rc=$rc $(cat "$T/o")"

echo kept >"$F"; touch "$T/fail"
reset DRY_RUN=0 >"$T/o" 2>&1 && fail "5. a failed reset passed" ||
  { [[ "$(cat "$F")" == kept ]] && grep -q '^FAIL m3-e2e-human@example.com was not reset' "$T/o" &&
    pass "5. a failed reset is FAIL, the file as it was" || fail "5. fail: $(cat "$T/o")"; }

rm -f "$T/fail" "$T/log"*
reset DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx proxy "$T/log.ops" && grep -q '^pin ' "$T/log.ops" && grep -qx 'spool=/fake/spool dsn=fake-dsn' "$T/log.env" &&
  pass "6. operator route: SA pinned, the script runs in the proxy with RESET_SPOOL" || fail "6. operator: rc=$rc $(cat "$T/o" "$T/log"* 2>&1)"
rm -f "$T/log"*
reset DRY_RUN=0 RESET_VIA=debug_token >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/log.ops" ]] && grep -qx 'spool= dsn=' "$T/log.env" &&
  pass "6. RESET_VIA=debug_token: no proxy, no SA" || fail "6. debug_token: rc=$rc $(cat "$T/o" "$T/log"* 2>&1)"
reset DRY_RUN=0 RESET_VIA=mail >"$T/o" 2>&1 && fail "6. RESET_VIA=mail accepted" ||
  { grep -q 'RESET_VIA must be' "$T/o" && pass "6. another RESET_VIA is refused" || fail "6. via: $(cat "$T/o")"; }

# --- 7. the script itself, against a fake hub ---------------------------------
cat >"$T/hub.py" <<'PYH'
import http.server, json, os, sys
T = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, body=None, hdrs=()):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        for k, v in hdrs: self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with open(os.path.join(T, "calls"), "a") as f: f.write(self.path + "\n")
        if self.path == "/api/v1/auth/password/forgot": return self.out(204)
        if self.path == "/api/v1/auth/login":
            ok = open(os.path.join(T, "spool-pw")).read().strip() == b["password"] if os.path.exists(os.path.join(T, "spool-pw")) else False
            return self.out(200, {}, [("Set-Cookie", "spool_session=c; Path=/")]) if ok and b.get("tenant") == "t1" else self.out(401, {"error": "bad"})
        self.out(404, {})
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PYH
cat >"$T/spool" <<EOF
#!/usr/bin/env bash
echo "\$* dsn=\$SPOOL_HUB_DB_DSN" >"$T/spool-args"
cat >"$T/spool-pw"
echo '{"status":"reset"}'
EOF
chmod +x "$T/spool"
python3 "$T/hub.py" "$T" & HUB=$!
trap 'kill $HUB 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
PY_RESET() { env RESET_API="http://127.0.0.1:$(cat "$T/port")" RESET_EMAIL=probe@example.com RESET_TENANT=t1 RESET_PW_FILE="$F" "$@" \
  python3 "$PROJ_ROOT/src/bash/scripts/dev-password-reset.py"; }
echo kept >"$F"; : >"$T/calls"
PY_RESET RESET_SPOOL="$T/spool" SPL_PROXY_DSN=postgres://u:s3cret@127.0.0.1/db >"$T/o" 2>&1; rc=$?
pw="$(cat "$T/spool-pw" 2>/dev/null)"
[[ $rc -eq 0 && -n "$pw" && "$(cat "$F")" == "$pw" && "$(stat -c %a "$F")" == 600 ]] && grep -q '"via": "operator"' "$T/o" &&
  pass "7. operator route: reset, signed in, file 0600" || fail "7. operator: rc=$rc $(cat "$T/o")"
grep -qx 'hub-reset-password --tenant t1 --email probe@example.com --password-stdin dsn=postgres://u:s3cret@127.0.0.1/db' "$T/spool-args" &&
  pass "7. the DSN reaches spool in its env, the password not in argv" || fail "7. spool args: $(cat "$T/spool-args")"
grep -q 'forgot' "$T/calls" && fail "7. the operator route also asked password/forgot (a mail)" || pass "7. the operator route sends no reset mail"
grep -qF -e "$pw" -e s3cret "$T/o" && fail "7. a password or the DSN printed" || pass "7. no password or DSN in the output"
echo kept >"$F"
PY_RESET >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 && "$(cat "$F")" == kept ]] && grep -q 'no debug_token (lde only since SPL-2157)' "$T/o" && ! grep -q Traceback "$T/o" &&
  pass "7. CONTROL: no debug_token, no operator route -> a clear failure, the file unchanged" || fail "7. control: rc=$rc $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
