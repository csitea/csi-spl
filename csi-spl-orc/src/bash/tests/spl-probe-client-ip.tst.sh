#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_probe_client_ip (spec 017 T012) derives the hops from the
#          chain the hub echoes, and only reads.
#   1. one proxy appends the caller   -> hops=1, rc 0; current=yes when the
#      deployed hops already key on the caller, current=no when not
#   2. a proxy that also appends itself -> hops=2
#   3. samples that disagree           -> rc 3 (never a guessed value)
#   4. probe not mounted (404)         -> rc 1
#   5. a proxy that rewrote the header (marker gone) -> rc 3
#   6. spoof-control: any 429 -> held rc 0; no 429 -> rc 3
#   7. no gcloud call at all (CONTROL: the stub records one if made)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# curl stub: the probe path prints $BODY_DIR/<n> for the n-th call (or the last
# one) with $CODE; the control path prints the next code from $CODES.
mkdir -p "$T/stub"
cat >"$T/stub/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
n=$(grep -c '^curl ' "$STUB_LOG")
case "$*" in
  *"/v1/debug/client-ip"*)
    f="$BODY_DIR/$n"; [[ -f "$f" ]] || f="$BODY_DIR/last"
    cat "$f"; printf '\n%s' "${CODE:-200}" ;;
  *"/api/v1/auth/providers"*)
    read -ra c <<<"$CODES"; i=$(( (n - 1) % ${#c[@]} )); printf '%s' "${c[$i]}" ;;
esac
exit 0
EOF
cat >"$T/stub/gcloud" <<'EOF'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"; exit 1
EOF
chmod +x "$T/stub/curl" "$T/stub/gcloud"

export ENV=dev
run_probe() {
  : >"$T/calls.log"
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls.log" \
    BODY_DIR="$T/bodies" HUB_URL="https://hub.test" PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_probe_client_ip'
  local rc=$?
  cat "$T/calls.log" >>"$T/all.log"
  return $rc
}
body() { # <name> <json>
  mkdir -p "$T/bodies"; printf '%s' "$2" >"$T/bodies/$1"
}
reset_bodies() { rm -rf "$T/bodies"; mkdir -p "$T/bodies"; }

# 1. one appending proxy
reset_bodies
body last '{"peer":"169.254.1.1","x_forwarded_for":["192.0.2.1","203.0.113.50"],"trusted_proxy_hops":1,"client_ip":"203.0.113.50"}'
out=$(run_probe 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"dev hops=1 "* && "$out" == *"current=yes"* ]] && pass "one proxy: hops=1, current=yes" || fail "one proxy: rc=$rc out=$out"
body last '{"peer":"169.254.1.1","x_forwarded_for":["192.0.2.1","203.0.113.50"],"trusted_proxy_hops":0,"client_ip":"169.254.1.1"}'
out=$(run_probe 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"hops=1 "* && "$out" == *"deployed_hops=0 current=no"* ]] && pass "deployed hops 0 reported as not current" || fail "current=no: rc=$rc out=$out"

# 2. a proxy that appends itself as well (client, proxy)
body last '{"peer":"35.191.0.9","x_forwarded_for":["192.0.2.1","203.0.113.50","198.51.100.200"],"trusted_proxy_hops":0,"client_ip":"35.191.0.9"}'
out=$(run_probe 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"hops=2 "* ]] && pass "two appended entries: hops=2" || fail "hops=2: rc=$rc out=$out"

# 3. samples disagree
reset_bodies
body 1 '{"peer":"p","x_forwarded_for":["192.0.2.1","203.0.113.50"],"trusted_proxy_hops":0,"client_ip":"p"}'
body last '{"peer":"p","x_forwarded_for":["192.0.2.1","203.0.113.50","198.51.100.200"],"trusted_proxy_hops":0,"client_ip":"p"}'
out=$(run_probe 2>&1); rc=$?
[[ $rc -eq 3 && "$out" == *inconsistent* ]] && pass "disagreeing samples refused (rc 3)" || fail "disagree: rc=$rc out=$out"

# 4. probe off
reset_bodies
body last '{"error":"not_found"}'
out=$(run_probe CODE=404 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"SPOOL_HUB_CLIENT_IP_PROBE off"* ]] && pass "probe not mounted: rc 1" || fail "404: rc=$rc out=$out"

# 5. header rewritten (marker gone)
body last '{"peer":"p","x_forwarded_for":["203.0.113.50"],"trusted_proxy_hops":0,"client_ip":"p"}'
out=$(run_probe 2>&1); rc=$?
[[ $rc -eq 3 && "$out" == *"rewrote"* ]] && pass "rewritten header: rc 3" || fail "rewrite: rc=$rc out=$out"

# 6. spoof-control
out=$(run_probe PROBE_MODE=spoof-control PROBE_N=6 CODES="404 404 404 429 429 429" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"control=held"* && "$out" == *"limited=3"* ]] && pass "spoof-control: 429s -> held" || fail "control held: rc=$rc out=$out"
out=$(run_probe PROBE_MODE=spoof-control PROBE_N=6 CODES="404" 2>&1); rc=$?
[[ $rc -eq 3 && "$out" == *"control=no-429"* ]] && pass "spoof-control: no 429 -> rc 3" || fail "control no-429: rc=$rc out=$out"
grep -q -- "X-Forwarded-For: 192.0.2.2" "$T/calls.log" && grep -q -- "X-Forwarded-For: 192.0.2.3" "$T/calls.log" \
  && pass "spoof-control rotates the spoofed entry" || fail "spoof-control did not rotate the entry"

# 7. read-only: never gcloud
if grep -q '^gcloud ' "$T/all.log"; then fail "a gcloud call was made"; else pass "no gcloud call"; fi

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
