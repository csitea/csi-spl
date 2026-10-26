#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: wui-e2e-mock-serve.sh (the browser-e2e harness workflows 10 and 11
#          share, CLE-77928) serves a bundle on a free port beside the
#          signed-out API stub, runs the command with BASE_URL set, and stops
#          both servers after. serve-generated.mjs is faked by a small node
#          server that records the --api it was given. Also: workflow 10 calls
#          the script and carries no inline copy, and workflow 11 runs it by
#          calling workflow 10 (spec 072 A35), holding no e2e of its own.
#          CONTROL: a bundle server that never answers fails the script.
#          SPL-2920: with no RUNNER_TEMP, log files someone else left in the
#          shared TMPDIR neither stop the run nor show up as its logs.
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
[[ -f "$T/wui-e2e-serve.log" && -f "$T/wui-e2e-api.log" ]] && pass "under RUNNER_TEMP the logs stay in RUNNER_TEMP (CI unchanged)" || fail "the logs are not in RUNNER_TEMP"

# SPL-2920: another user's leftovers at the old fixed names in a shared TMPDIR.
# The api log is a directory, so even root cannot write it; the serve log is a
# read-only file holding an old run's line.
shared="$T/shared"; mkdir -p "$shared/wui-e2e-api.log"
echo "STALE serving on :37515" >"$shared/wui-e2e-serve.log"; chmod 0444 "$shared/wui-e2e-serve.log"
out=$(cd "$wui" && env -u RUNNER_TEMP CHROME_PATH=/bin/true TMPDIR="$shared" API_FILE="$T/api" bash "$S" \
  sh -c 'curl -fsS "$BASE_URL/login"' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx ok <<<"$out" && pass "foreign logs in a shared TMPDIR do not stop the run" || fail "shared TMPDIR: rc=$rc $out"
grep -q STALE <<<"$out" && fail "an old run's log was printed as this run's" || pass "no log from another run is printed"
left=$(find "$shared" -mindepth 1 -maxdepth 1 -name 'wui-e2e-mock-serve.*' | wc -l)
[[ $left -eq 0 ]] && pass "the private log dir is removed on exit" || fail "$left private log dir(s) left in TMPDIR"

out=$(cd "$wui" && CHROME_PATH=/bin/true RUNNER_TEMP="$T" API_FILE="$T/api" NEVER_ANSWER=1 bash "$S" true 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'generated bundle not serving' <<<"$out" && pass "CONTROL: a silent bundle server fails the script" || fail "CONTROL: rc=$rc $out"
out=$(cd "$wui" && env -u CHROME_PATH bash "$S" true 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "CHROME_PATH unset is refused" || fail "CHROME_PATH unset accepted"

# SPL-3469: one pinned font, the same file on the gate and on a box.
pin="$PROJ_ROOT/src/bash/scripts/wui-e2e-fonts.conf"
out=$(cd "$wui" && env -u FONTCONFIG_FILE CHROME_PATH=/bin/true RUNNER_TEMP="$T" API_FILE="$T/api" bash "$S" \
  sh -c 'echo "$FONTCONFIG_FILE"; fc-match sans-serif family' 2>/dev/null); rc=$?
[[ $rc -eq 0 && $out == "$pin"$'\n'"DejaVu Sans" ]] && pass "the command runs under the pinned fonts.conf (DejaVu Sans)" || fail "pin: rc=$rc $out"
printf '<?xml version="1.0"?>\n<fontconfig><dir>%s</dir></fontconfig>\n' "$T/no-fonts" >"$T/other.conf"; mkdir -p "$T/no-fonts"
out=$(cd "$wui" && CHROME_PATH=/bin/true RUNNER_TEMP="$T" API_FILE="$T/api" FONTCONFIG_FILE="$T/other.conf" bash "$S" true 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'not DejaVu Sans' <<<"$out" && pass "CONTROL: a fonts.conf without DejaVu Sans is refused" || fail "CONTROL pin: rc=$rc $out"
hs=$(FONTCONFIG_FILE="$pin" fc-match sans-serif -f '%{hintstyle} %{antialias}')
[[ $hs == "1 True" ]] && pass "the pin renders hintslight + antialias, as /etc/fonts does" || fail "pin render settings: hintstyle antialias = '$hs', want '1 True'"
# The hosted runner's dejavu dir holds files a box lacks (DejaVu Math TeX
# Gyre won sans-serif there): a copy of the dir with one such file added must
# still give the same 8 files.
mkdir -p "$T/dejavu" && cp /usr/share/fonts/truetype/dejavu/*.ttf "$T/dejavu/" \
  && cp /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf "$T/dejavu/DejaVuMathTeXGyre.ttf"
sed "s#/usr/share/fonts/truetype/dejavu#$T/dejavu#g" "$pin" >"$T/hosted.conf"
files=$(FONTCONFIG_FILE="$T/hosted.conf" fc-list -f '%{file}\n' | grep "^$T/dejavu/" | sort -u)
[[ $(wc -l <<<"$files") -eq 8 ]] && ! grep -q MathTeXGyre <<<"$files" \
  && pass "CONTROL: a dejavu file outside fonts-dejavu-core is not read (8 files)" || fail "pin font set: $(wc -l <<<"$files") files: $files"
grep -qF 'FONTCONFIG_FILE: ${{ github.workspace }}/csi-spl-orc/src/bash/scripts/wui-e2e-fonts.conf' "$WF10" \
  && pass "10_ci-quality.yml pins the same fonts.conf" || fail "10_ci-quality.yml does not set FONTCONFIG_FILE to the script's file"

n=$(basename "$WF10")
grep -q 'bash ../csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh .*pnpm run test:e2e' "$WF10" && pass "$n runs the e2e through the script" || fail "$n does not call the script"
for wf in "$WF10" "$WF11"; do
  n=$(basename "$wf")
  grep -q 'BaseHTTPRequestHandler' "$wf" && fail "$n still carries an inline API stub" || pass "$n carries no inline copy"
done
grep -qE '^[[:space:]]*uses: \./\.github/workflows/10_ci-quality\.yml$' "$WF11" && pass "11_ci-public.yml runs the e2e by calling workflow 10" || fail "11_ci-public.yml does not call workflow 10"

echo "---"; (( fails == 0 )) && echo "wui-e2e-mock-serve: all passed" || { echo "wui-e2e-mock-serve: $fails failed"; exit 1; }
