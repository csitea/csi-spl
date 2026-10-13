#!/usr/bin/env bash
# do_spl_join_check (spec 073 AC8, SPL-907): the join check workflow 23 runs
# per env, hermetic. A fake hub (python, 127.0.0.1) answers the five routes
# the check calls; a fake installer (JOIN_CHECK_INSTALL) redeems the token
# at it as install.sh --join would. No real hub, no real installer.
#
# The controls are the point:
#   - no secret / no cnf member -> ::notice::, rc 0, nothing called
#   - the happy path: sign in, mint, the box joins, used, removed, 404, sign out
#   - the password only in the login body: never in the output, argv or the
#     installer's env; the token only in the installer's env (never its
#     argv) and masked in its output; the temp dir is gone afterwards
#   - every failure (sign-in, mint, join, AC8 time) -> rc 1, ::error::, and
#     the cleanup removes the seat, revokes an unused token, signs out
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-join-check.func.sh"
PW='s3cr3t-not-real-$(x) "q"'
TOK='spj1.t1.TOKENSECRETnotreal_0123'
mkdir -p "$T/app/csi-spl-orc" "$T/app/csi-spl-cnf/csi-spl" "$T/tmp"
cnf() { # <email> <tenant>
  printf '{"env":{"dns":{"api_fqdn":"api.example.com"},"box":{"join_check_email":"%s","join_check_tenant":"%s"}}}\n' \
    "$1" "$2" >"$T/app/csi-spl-cnf/csi-spl/dev.env.json"
}

# the fake hub: FAKE_PW signs in, FAKE_MINT_CODE overrides the mint answer
cat >"$T/hub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
st = {"used": False, "seated": set(), "revoked": False}
log = open(sys.argv[2], "a")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ans(self, code, obj, hdr=None):
        b = json.dumps(obj).encode()
        self.send_response(code)
        for k, v in (hdr or {}).items(): self.send_header(k, v)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def sess(self): return "sess=ok" in (self.headers.get("Cookie") or "")
    def route(self, m):
        p = self.path; log.write(f"{m} {p}\n"); log.flush()
        if m == "POST" and p == "/api/v1/auth/login":
            b = self.body()
            if self.headers.get("Content-Type") != "application/json": return self.ans(415, {"error": "ct"})
            if b.get("password") != os.environ["FAKE_PW"] or b.get("tenant") != "t1":
                return self.ans(401, {"error": "invalid_credentials", "message": "wrong email or password"})
            return self.ans(200, {"email": b["email"]}, {"Set-Cookie": "sess=ok; Path=/; HttpOnly"})
        if m == "POST" and p == "/v1/pins/join":
            b = self.body()
            if b.get("token") != os.environ["FAKE_TOK"] or st["used"] or st["revoked"]:
                return self.ans(410, {"error": "join_token_used"})
            st["used"] = True; st["seated"].add(b["box_id"]); return self.ans(200, {"box_id": b["box_id"]})
        if not self.sess(): return self.ans(401, {"error": "view_door", "message": "no session"})
        if m == "POST" and p == "/v1/tenant/agents/join-tokens":
            code = int(os.environ.get("FAKE_MINT_CODE") or 201)
            if code != 201: return self.ans(code, {"error": "box_join_disabled", "message": "joining is off"})
            b = self.body(); st["box"] = b.get("box_id")
            return self.ans(201, {"id": "0123abcd", "token": os.environ["FAKE_TOK"], "box_id": b.get("box_id")})
        if m == "GET" and p == "/v1/tenant/agents/join-tokens":
            s = "used" if st["used"] else ("revoked" if st["revoked"] else "open")
            return self.ans(200, {"tokens": [{"id": "0123abcd", "state": s, "consumed_box": st.get("box") if st["used"] else ""}]})
        if m == "DELETE" and p.startswith("/v1/tenant/agents/pins/"):
            box = p.rsplit("/", 1)[1]
            if box in st["seated"]: st["seated"].discard(box); return self.ans(200, {"box_id": box})
            return self.ans(404, {"error": "not_found"})
        if m == "DELETE" and p == "/v1/tenant/agents/join-tokens/0123abcd":
            if st["used"]: return self.ans(409, {"error": "join_token_used"})
            st["revoked"] = True; return self.ans(200, {"id": "0123abcd"})
        if m == "POST" and p == "/api/v1/auth/logout": return self.ans(200, {})
        return self.ans(404, {"error": "no_route"})
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_DELETE(self): self.route("DELETE")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

# the fake installer: records what it got, redeems the token like spool join
cat >"$T/fake-install.sh" <<'SH'
#!/usr/bin/env bash
{
  echo "argv=$*"
  echo "claim=$(cat "$SPL_WS_BASE/claim") home=$HOME hub=$SPOOL_HUB_URL"
  env | grep -q '^SPL_PROBE_ADMIN_PW' && echo "env-has-password" || echo "env-clean"
  [[ -n "${SPOOL_JOIN_TOKEN:-}" ]] && echo "join-token-in-env"
} >>"$FAKE_LOG"
# a Go module cache, read-only as Go writes it: the cleanup must still remove it
mkdir -p "$HOME/go/pkg/mod/m@v1" && touch "$HOME/go/pkg/mod/m@v1/f.go" && chmod -R a-w "$HOME/go"
if [[ -n "${SPOOL_JOIN_TOKEN:-}" ]]; then
  box=""; while [[ $# -gt 0 ]]; do [[ "$1" == --box ]] && box="$2"; shift; done
  printf '{"token":"%s","box_id":"%s"}' "$SPOOL_JOIN_TOKEN" "$box" |
    curl -sf -o /dev/null -H 'Content-Type: application/json' --data-binary @- "$SPOOL_HUB_URL/v1/pins/join" || exit 5
  echo "spool-install: seated $box with $SPOOL_JOIN_TOKEN"
  sleep "${FAKE_SLEEP:-0}"
fi
exit "${FAKE_INSTALL_RC:-0}"
SH
chmod +x "$T/fake-install.sh"

HUB_PID=""
start_hub() {
  [[ -n "$HUB_PID" ]] && kill "$HUB_PID" 2>/dev/null && wait "$HUB_PID" 2>/dev/null
  rm -f "$T/port" "$T/req.log"
  FAKE_PW="$PW" FAKE_TOK="$TOK" FAKE_MINT_CODE="${1:-}" python3 "$T/hub.py" "$T/port" "$T/req.log" &
  HUB_PID=$!
  for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
}
trap '[[ -n "$HUB_PID" ]] && kill "$HUB_PID" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

act() { # <env assignments...>
  rm -f "$T/fake.log"; : >"$T/req.log"
  env -u SPL_PROBE_ADMIN_PW -u SPL_PROBE_ADMIN_PW_DEV -u JOIN_CHECK_SEAT_MAX_S -u GITHUB_ACTIONS \
    TMPDIR="$T/tmp" PROJ_PATH="$T/app/csi-spl-orc" FUNC="$FUNC" ENV=dev GITHUB_RUN_ID=42 \
    JOIN_CHECK_HUB="http://127.0.0.1:$(cat "$T/port")" JOIN_CHECK_INSTALL="$T/fake-install.sh" \
    FAKE_LOG="$T/fake.log" "$@" bash -c '
    set -euo pipefail
    do_log() { echo "$*"; }
    source "$FUNC"
    do_spl_join_check' >"$T/stdout" 2>&1 </dev/null
}
reqs() { tr '\n' ';' <"$T/req.log"; }
clean_tmp() { [[ -z "$(ls -A "$T/tmp")" ]]; }

start_hub

# 1. no secret / no cnf member -> skip, nothing called
cnf admin@example.com t1
act; rc=$?
[[ $rc -eq 0 ]] && grep -q '^::notice::dev join check skipped: the GitHub secret SPL_PROBE_ADMIN_PW_DEV is not set' "$T/stdout" \
  && [[ ! -s "$T/req.log" && ! -e "$T/fake.log" ]] && pass "no secret: ::notice:: names SPL_PROBE_ADMIN_PW_DEV, rc 0, nothing called" \
  || fail "no secret: rc=$rc $(cat "$T/stdout")"
cnf "" t1
act SPL_PROBE_ADMIN_PW="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^::notice::dev join check skipped: cnf env.box.join_check_email / join_check_tenant is not set' "$T/stdout" \
  && [[ ! -s "$T/req.log" ]] && pass "no cnf member: ::notice:: names the cnf keys, rc 0, nothing called" || fail "no cnf member: rc=$rc $(cat "$T/stdout")"
act ENV=prd SPL_PROBE_ADMIN_PW="$PW"
grep -q 'FATAL no readable cnf' "$T/stdout" && pass "prd with no prd cnf: refused, not skipped silently" || fail "prd: $(cat "$T/stdout")"

# 2. the happy path
cnf admin@example.com t1
act SPL_PROBE_ADMIN_PW="$PW" SPL_PROBE_ADMIN_PW_DEV="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'join check: minted, joined, verified and removed ci-join-42-dev in t1' "$T/stdout" \
  && pass "happy path: rc 0, every step" || fail "happy path: rc=$rc $(cat "$T/stdout")"
want='POST /api/v1/auth/login;POST /v1/tenant/agents/join-tokens;POST /v1/pins/join;GET /v1/tenant/agents/join-tokens;DELETE /v1/tenant/agents/pins/ci-join-42-dev;DELETE /v1/tenant/agents/pins/ci-join-42-dev;POST /api/v1/auth/logout;'
[[ "$(reqs)" == "$want" ]] && pass "sign in, mint, join, list, remove, 404, sign out - in that order" || fail "calls: $(reqs)"
grep -q 'INFO 4/6 ci-join-42-dev joined in [0-9]*s (AC8: < 60s)' "$T/stdout" && pass "the seat's wall clock is logged against AC8" || fail "no AC8 line"
grep -q '^claim=t1 home=.*/home hub=http://127.0.0.1' "$T/fake.log" && pass "the box is throwaway: its own HOME, a dedicated claim of t1, the hub" \
  || fail "box env: $(cat "$T/fake.log")"
grep -q -- '^argv=--cli none --no-hooks --no-skills --env dev --tenant t1 --box ci-join-42-dev --no-seat$' "$T/fake.log" \
  && grep -q -- '^argv=--cli none --no-hooks --no-skills --env dev --tenant t1 --box ci-join-42-dev$' "$T/fake.log" \
  && pass "install.sh runs --no-seat first, then joins" || fail "installer argv: $(grep argv "$T/fake.log")"
[[ "$(grep -c '^env-clean$' "$T/fake.log")" == 2 ]] && pass "the installer's env never carries SPL_PROBE_ADMIN_PW*" || fail "the password reached the installer's env"
grep -q '^join-token-in-env$' "$T/fake.log" && ! grep -q "^argv=.*spj1" "$T/fake.log" \
  && pass "the token reaches the installer in its env, never its argv" || fail "token handoff: $(cat "$T/fake.log")"
grep -q 's3cr3t' "$T/stdout" && fail "the password is in the output" || pass "the password is not in the output"
grep -q 'TOKENSECRET' "$T/stdout" && fail "the token is in the output" || pass "the token is not in the output"
grep -q 'seated ci-join-42-dev with spj1.<redacted>' "$T/stdout" && pass "the installer's output is printed with the token masked" || fail "no masked installer line"
clean_tmp && pass "no temp file left (token, cookie, body, a read-only module cache)" || fail "TMPDIR not empty: $(ls -A "$T/tmp")"
act SPL_PROBE_ADMIN_PW="$PW" GITHUB_ACTIONS=true
grep -q '^::add-mask::spj1\.t1\.' "$T/stdout" && pass "in Actions the token is registered as a mask" || fail "no ::add-mask:: in Actions"

# 3. wrong password -> FAIL 2/6, no mint
start_hub
act SPL_PROBE_ADMIN_PW="wrong"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL 2/6 sign-in as admin@example.com in t1 -> HTTP 401 invalid_credentials' "$T/stdout" \
  && grep -q '^::error::dev join check failed' "$T/stdout" && [[ "$(reqs)" == 'POST /api/v1/auth/login;' ]] \
  && pass "wrong password: rc 1, ::error::, nothing minted" || fail "wrong password: rc=$rc $(reqs) $(cat "$T/stdout")"

# 4. the workspace switch is off -> FAIL 3/6 names the hub's code, signs out
start_hub 403
act SPL_PROBE_ADMIN_PW="$PW"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL 3/6 mint a join token -> HTTP 403 box_join_disabled' "$T/stdout" \
  && [[ "$(reqs)" == 'POST /api/v1/auth/login;POST /v1/tenant/agents/join-tokens;POST /api/v1/auth/logout;' ]] \
  && pass "mint refused: rc 1, the hub's code named, signed out" || fail "mint refused: rc=$rc $(reqs) $(cat "$T/stdout")"
clean_tmp && pass "a failed run leaves no temp file" || fail "TMPDIR not empty after a failure"

# 5. the join fails before the redeem -> the unused token is revoked
printf '#!/usr/bin/env bash\n[[ -z "${SPOOL_JOIN_TOKEN:-}" ]] || exit 5\n' >"$T/fail-install.sh"; chmod +x "$T/fail-install.sh"
start_hub
act SPL_PROBE_ADMIN_PW="$PW" JOIN_CHECK_INSTALL="$T/fail-install.sh"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL 4/6 install.sh with the join token (rc 5)' "$T/stdout" \
  && grep -q 'DELETE /v1/tenant/agents/join-tokens/0123abcd' "$T/req.log" && grep -q 'POST /api/v1/auth/logout' "$T/req.log" \
  && pass "a failed join: rc 1, the unused token revoked, signed out" || fail "failed join: rc=$rc $(reqs) $(cat "$T/stdout")"

# 6. AC8: a seat slower than the limit fails, and the seat is still removed
start_hub
act SPL_PROBE_ADMIN_PW="$PW" JOIN_CHECK_SEAT_MAX_S=1 FAKE_SLEEP=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL 4/6 the seat took [0-9]*s, AC8 wants < 1s' "$T/stdout" \
  && grep -q 'INFO cleanup: removed seat ci-join-42-dev' "$T/stdout" \
  && [[ "$(grep -c 'DELETE /v1/tenant/agents/pins/ci-join-42-dev' "$T/req.log")" == 1 ]] \
  && pass "AC8 over time: rc 1, the seat removed by the cleanup" || fail "AC8: rc=$rc $(reqs) $(cat "$T/stdout")"

# 7. the workflow wires it: per-env secret through env, the named action
WF="$PROJ_ROOT/../.github/workflows/23_join-check.yml"
grep -q "format('SPL_PROBE_ADMIN_PW_{0}'" "$WF" && grep -q 'run: ./csi-spl-orc/run -a do_spl_join_check' "$WF" \
  && pass "workflow 23 maps SPL_PROBE_ADMIN_PW_<ENV> and runs do_spl_join_check" || fail "workflow 23 is not wired"
grep -E 'echo .*SPL_PROBE_ADMIN|run:.*secrets' "$WF" | grep -v '^\s*#' >/dev/null \
  && fail "workflow 23 echoes the secret or puts it on a run line" || pass "workflow 23 passes the secret only through env"
[[ "$(grep -oE 'secrets(\.[A-Za-z0-9_]+|\[[^]]*\])' "$WF" | sort -u)" == "secrets[format('SPL_PROBE_ADMIN_PW_{0}', matrix.environment == 'dev' && 'DEV' || 'PRD')]" ]] \
  && pass "workflow 23 reads no other secret" || fail "workflow 23 reads: $(grep -oE 'secrets(\.[A-Za-z0-9_]+|\[[^]]*\])' "$WF" | sort -u)"

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
