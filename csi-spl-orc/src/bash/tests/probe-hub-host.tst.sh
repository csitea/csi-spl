#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_probe_hub_host judges a hub host from what it SERVES, driven
#          with stubbed getent/dig/openssl/curl (no network): all checks pass
#          -> 0; a WS upgrade the mapping does not carry (400 instead of 101),
#          a cert whose SAN does not cover the host (the edge default), or a
#          /version without "commit" -> 1. A wildcard SAN covers a tenant host.
#          Control: WS_OK=404 accepts the api host's unknown_tenant answer.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-probe-hub-host.func.sh"
fails=0
check() { if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got rc=$1, want $2)"; fails=$((fails + 1)); fi; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/getent" <<'S'
#!/usr/bin/env bash
echo "203.0.113.9 $2"
S
cat >"$tmp/bin/dig" <<'S'
#!/usr/bin/env bash
echo "ghs.googlehosted.com."
S
cat >"$tmp/bin/openssl" <<'S'
#!/usr/bin/env bash
case "$1" in
  s_client) cat >/dev/null; echo "PEM" ;;
  x509) cat >/dev/null
        if [[ "$*" == *subjectAltName* ]]; then echo "X509v3 Subject Alternative Name:"; echo "    DNS:$STUB_SAN"
        else echo "subject=CN=$STUB_SAN"; fi ;;
esac
S
cat >"$tmp/bin/curl" <<'S'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */version) echo "$STUB_VERSION" ;;
  */v1/health) printf 200 ;;
  */v1/wui/ws) printf '%s' "$STUB_WUI" ;;
  */v1/ws) printf '%s' "$STUB_WS" ;;
esac
S
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
do_log() { :; }
do_require_bin() { :; }
# shellcheck disable=SC1090
source "$FUNC"

run() { ( export STUB_SAN="$1" STUB_WS="$2" STUB_WUI="$3" STUB_VERSION="$4"; shift 4; env "$@" bash -c "$(declare -f do_log do_require_bin do_spl_probe_hub_host); do_spl_probe_hub_host" >/dev/null 2>&1 ); }
V='{"commit":"abc123","version":"0.1.8"}'
run t1.dev.example.test 101 401 "$V" HOST=t1.dev.example.test; check $? 0 "tenant host: exact SAN, ws 101, wui 401 -> 0"
run '*.dev.example.test' 101 401 "$V" HOST=t1.dev.example.test; check $? 0 "tenant host: wildcard SAN covers it -> 0"
run t1.dev.example.test 400 401 "$V" HOST=t1.dev.example.test; check $? 1 "ws upgrade not carried (400) -> 1"
run edge.example.net 101 401 "$V" HOST=t1.dev.example.test; check $? 1 "cert SAN does not cover the host -> 1"
run t1.dev.example.test 101 401 'not found' HOST=t1.dev.example.test; check $? 1 "/version without commit -> 1"
run t1.dev.example.test 101 401 "$V" HOST=t1.dev.example.test EXPECT_COMMIT=fff; check $? 1 "EXPECT_COMMIT mismatch -> 1"
run dev.api.example.test 404 404 "$V" HOST=dev.api.example.test WS_OK=404 WUI_WS_OK=404; check $? 0 "control: api host with WS_OK=404 -> 0"
run dev.api.example.test 404 404 "$V" HOST=dev.api.example.test; check $? 1 "api host without WS_OK -> 1"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
