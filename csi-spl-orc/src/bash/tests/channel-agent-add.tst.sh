#!/usr/bin/env bash
# specs/038 do_spl_channel_agent_add / channel-agent-add.py, hermetic: a stub
# hub on 127.0.0.1 answers the login, POST /v1/channels and POST
# /v1/channels/{ch}/agents, and records every request it gets.
#
# 1. the script signs in, creates the channel when asked (409 is fine), and
#    posts one {id, box} per agent; exit 0
# 2. CONTROL: an agent the hub refuses (404 not_a_member) fails the run and is
#    named; a bad password never reaches the channel calls (exit 2)
# 3. the action refuses bad ids before anything is read, and its dry run
#    makes no call
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
PY="$HERE/../scripts/channel-agent-add.py"
T="$(mktemp -d)"; SRV=""; trap '[[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat >"$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
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
        n = int(self.headers.get("Content-Length") or 0)
        b = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/v1/auth/login":
            return self.reply(200, {}, cookie=b.get("password") == "pw-ok")
        with open(os.path.join(T, "reqs.log"), "a") as f:
            f.write(self.path + " " + json.dumps(b, sort_keys=True) + "\n")
        if self.headers.get("Cookie") != "spool_session=tok": return self.reply(401, {"error": "view_door"})
        if self.path == "/v1/channels": return self.reply(409, {"error": "channel_exists"})
        if self.path.endswith("/agents"):
            if b.get("id") == "CLE-404": return self.reply(404, {"error": "not_a_member"})
            return self.reply(201, {"id": b.get("id"), "box": b.get("box")})
        self.reply(404, {"error": "not_found"})
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
port=$(( 20000 + RANDOM % 20000 ))
printf 'pw-ok' >"$T/pw"; printf 'pw-bad' >"$T/pwbad"
python3 "$T/stub.py" "$T" "$port" & SRV=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done

run() { # run <pw file> <create> <agents>
  SEAT_API="http://127.0.0.1:$port" SEAT_TENANT=t1 SEAT_EMAIL=e@example.com SEAT_PW_FILE="$1" \
    SEAT_CHANNEL=agent-post-proof SEAT_BOX=box-desk SEAT_CREATE="$2" SEAT_AGENTS="$3" python3 "$PY" 2>&1
}

# --- 1. seated ------------------------------------------------------------------
: >"$T/reqs.log"
out=$(run "$T/pw" 1 "CLE-555 CLE-666"); rc=$?
[[ $rc -eq 0 ]] && pass "two agents seated, an existing channel is fine (exit 0)" || fail "seat (exit $rc): $out"
want=$'/v1/channels {"channel": "agent-post-proof"}\n/v1/channels/agent-post-proof/agents {"box": "box-desk", "id": "CLE-555"}\n/v1/channels/agent-post-proof/agents {"box": "box-desk", "id": "CLE-666"}'
[[ "$(cat "$T/reqs.log")" == "$want" ]] && pass "…create once, then one {id, box} per agent" ||
  fail "requests: $(cat "$T/reqs.log")"

# --- 2. CONTROLS ----------------------------------------------------------------
out=$(run "$T/pw" 0 "CLE-555 CLE-404"); rc=$?
[[ $rc -eq 1 && "$out" == *'"CLE-404": {"error": "not_a_member", "status": 404}'* ]] &&
  pass "CONTROL a refused agent fails the run and is named (exit 1)" || fail "refused agent (exit $rc): $out"
: >"$T/reqs.log"
out=$(run "$T/pwbad" 1 "CLE-555"); rc=$?
[[ $rc -eq 2 && ! -s "$T/reqs.log" ]] && pass "CONTROL a failed sign-in makes no channel call (exit 2)" ||
  fail "bad password (exit $rc, reqs: $(cat "$T/reqs.log")): $out"

# --- 3. the action's own argument rules and dry run ----------------------------
mkdir -p "$T/stub"
for b in gcloud curl docker python3-never; do printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"; done
chmod +x "$T/stub/"*
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_channel_agent_add'
}
for bad in "TENANT_ID=T1" "CHANNEL=Bad Name" "AGENTS=" "AGENTS=HUM-4" "AGENTS=cle-5" "AGENT_BOX=box-wui" "CHANNEL_CREATE=yes"; do
  if in_orc TENANT_ID=t1 CHANNEL=agent-post-proof AGENTS=CLE-555 DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "refuses $bad" || fail "refuses $bad without saying why: $(cat "$T/o")"
  fi
done
: >"$T/calls.log"
in_orc TENANT_ID=t1 CHANNEL=agent-post-proof AGENTS=CLE-555 CHANNEL_CREATE=1 >"$T/o" 2>&1
grep -q 'DRY_RUN would:.*create #agent-post-proof' "$T/o" && [[ ! -s "$T/calls.log" ]] &&
  pass "the dry run says what it would do and calls out nowhere" || fail "dry run: $(cat "$T/o") calls: $(cat "$T/calls.log")"

echo "=== $([[ $fails -eq 0 ]] && echo 'all channel-agent-add.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
