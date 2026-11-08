#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spl_hub_operator_call's client cap (SPL-5067, spec 169): SPL_HUB_OP_MAX_TIME.
#   1. unset: curl gets the default -m 30
#   2. set: curl gets that value
#   3. a value that is not whole seconds: FATAL before any call
#   4. real curl, a hub slower than the cap: no HTTP response, non-zero
#   5. real curl, the same hub under a cap longer than it answers: 200 and the body
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v python3 >/dev/null || { echo "FAIL: no python3"; exit 1; }

mkdir -p "$T/stub" "$T/state"
printf '#!/usr/bin/env bash\necho a-token\n' >"$T/stub/gcloud"
chmod +x "$T/stub/gcloud"
# The curl stub records its argv and answers 200, so case 1 waits for nothing.
mkdir -p "$T/fake"
printf '#!/usr/bin/env bash\necho "$*" >>"$STUB_ARGS"\necho 200\n' >"$T/fake/curl"
chmod +x "$T/fake/curl"

cat >"$T/slow.py" <<'PY'
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        time.sleep(2)
        try:
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
        except OSError:
            pass
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$T/slow.py" "$T/port" & SRV=$!
trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$T/port")"

call() { # <PATH prefix dir> [VAR=value...]
  local dir="$1"; shift
  : >"$T/args"
  env PATH="$dir:$T/stub:$PATH" PROJ_PATH="$PROJ_ROOT" STUB_ARGS="$T/args" SPL_HUB_URL="$URL" \
    GCP_ACCOUNT=pinned@example.com SPL_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-hub-operator.func.sh"
    spl_hub_operator_call POST /v1/operator/x "{}" || exit $?
    echo "status=$SPL_HUB_OP_STATUS body=$SPL_HUB_OP_BODY"' >"$T/out" 2>&1 </dev/null
}

call "$T/fake"; rc=$?
[[ $rc -eq 0 ]] && grep -q -- '-m 30 ' "$T/args" && pass "1. unset: -m 30" || fail "1. default: rc=$rc $(cat "$T/args" "$T/out")"
call "$T/fake" SPL_HUB_OP_MAX_TIME=600; rc=$?
[[ $rc -eq 0 ]] && grep -q -- '-m 600 ' "$T/args" && pass "2. set: -m 600" || fail "2. set: rc=$rc $(cat "$T/args" "$T/out")"
call "$T/fake" SPL_HUB_OP_MAX_TIME=soon; rc=$?
[[ $rc -ne 0 && ! -s "$T/args" ]] && grep -q 'FATAL SPL_HUB_OP_MAX_TIME' "$T/out" && pass "3. not whole seconds: FATAL, no call" || fail "3. bad value: rc=$rc $(cat "$T/args" "$T/out")"
call "" SPL_HUB_OP_MAX_TIME=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no HTTP response' "$T/out" && pass "4. a hub slower than the cap: no HTTP response" || fail "4. slow hub: rc=$rc $(cat "$T/out")"
call "" SPL_HUB_OP_MAX_TIME=10; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'status=200 body={"ok":true}' "$T/out" && pass "5. a cap longer than the hub: 200 and the body" || fail "5. longer cap: rc=$rc $(cat "$T/out")"

echo "spl-hub-operator-max-time: $fails failure(s)"
[[ $fails -eq 0 ]]
