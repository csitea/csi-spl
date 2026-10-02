#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: wui-e2e-mock-serve.sh (the browser-e2e harness workflows 10 and 11
#          share, CLE-77928) serves a bundle on a free port beside the
#          signed-out API stub, runs the command with BASE_URL set, and stops
#          both servers after. serve-generated.mjs is faked by a small node
#          server that records the --api it was given. Also: both workflows
#          call the script and neither carries the inline copy any more.
#          CONTROL: a bundle server that never answers fails the script.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/bash/scripts/wui-e2e-mock-serve.sh"
WF10="$APP_ROOT/.github/workflows/10_ci-quality.yml"
WF11="$APP_ROOT/.github/workflows/11_ci-public.yml"
command -v node >/dev/null && command -v curl >/dev/null || { echo "SKIP: node + curl needed"; exit 0; }

wui="$T/wui"; mkdir -p "$wui/src/node/test"
cat >"$wui/src/node/test/serve-generated.mjs" <<'JS'
import http from 'node:http'; import fs from 'node:fs'
const a = process.argv, port = +a[a.indexOf('--port') + 1], api = a[a.indexOf('--api') + 1]
fs.writeFileSync(process.env.API_FILE, api)
if (!process.env.NEVER_ANSWER) http.createServer((q, r) => r.end('ok')).listen(port, '127.0.0.1')
else setInterval(() => {}, 1000)
JS

out=$(cd "$wui" && CHROME_PATH=/bin/true RUNNER_TEMP="$T" API_FILE="$T/api" bash "$S" \
  sh -c 'curl -fsS "$BASE_URL/login"; echo; curl -s -o /dev/null -w "%{http_code} " "$(cat "$API_FILE")/api/v1/auth/session"; curl -s "$(cat "$API_FILE")/api/v1/auth/providers"' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "the command ran and exited 0" || fail "rc=$rc: $out"
grep -qx ok <<<"$out" && pass "BASE_URL points at the bundle server" || fail "bundle not reached: $out"
grep -q '^401 {"native":false,"providers":\[\]}' <<<"$out" && pass "the API stub answers session 401 + an empty provider list" || fail "API stub: $out"
api_port=$(sed 's/.*://' "$T/api")
curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$api_port/" && fail "the API stub outlived the script" || pass "both servers stop with the script"

out=$(cd "$wui" && CHROME_PATH=/bin/true RUNNER_TEMP="$T" API_FILE="$T/api" NEVER_ANSWER=1 bash "$S" true 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'generated bundle not serving' <<<"$out" && pass "CONTROL: a silent bundle server fails the script" || fail "CONTROL: rc=$rc $out"
out=$(cd "$wui" && env -u CHROME_PATH bash "$S" true 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "CHROME_PATH unset is refused" || fail "CHROME_PATH unset accepted"

for wf in "$WF10" "$WF11"; do
  n=$(basename "$wf")
  grep -q 'bash ../csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh .*pnpm run test:e2e' "$wf" && pass "$n runs the e2e through the script" || fail "$n does not call the script"
  grep -q 'BaseHTTPRequestHandler' "$wf" && fail "$n still carries an inline API stub" || pass "$n carries no inline copy"
done

echo "---"; (( fails == 0 )) && echo "wui-e2e-mock-serve: all passed" || { echo "wui-e2e-mock-serve: $fails failed"; exit 1; }
