#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_delivery_probe (bug B, 4ecb4b0d) - the action that times a
#          person's message to the OTHER session's socket - only ever writes to
#          a test tenant, stays offline in a dry run, and reports a summary
#          that counts the sends whose live frame never came. No cloud call.
#   1. a real tenant (t1, csitea) is refused; e2e / e2e-<x> pass
#   2. the dry run makes no gcloud, curl, docker or spool call. CONTROL: the
#      stub log records one when a call IS made
#   3. summary(): a MISS (no live frame) is counted, and its catch-up time is
#      reported apart from the live hop, never folded into it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker cloud-sql-proxy spool; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. test tenants only ----------------------------------------------------------
for t in t1 csitea e2e_x E2E; do
  SNIPPET="spl_delivery_probe_tenant_ok '$t'" in_orc >/dev/null 2>&1 &&
    fail "the probe would post into tenant '$t'" || pass "the probe refuses tenant '$t'"
done
for t in e2e e2e-lat; do
  SNIPPET="spl_delivery_probe_tenant_ok '$t'" in_orc >/dev/null 2>&1 &&
    pass "test tenant '$t' is accepted" || fail "test tenant '$t' was refused"
done

# --- 2. the dry run is offline -----------------------------------------------------
: >"$T/calls.log"
SNIPPET='do_spl_delivery_probe' in_orc >"$T/o" 2>&1
grep -q 'DRY_RUN' "$T/o" && pass "the dry run says what it would do" ||
  fail "the dry run said nothing: $(cat "$T/o")"
[ -s "$T/calls.log" ] && fail "the dry run made a real call: $(cat "$T/calls.log")" ||
  pass "the dry run made no gcloud/curl/docker/spool call"
: >"$T/calls.log"
STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" curl -s https://example.invalid >/dev/null 2>&1
[ -s "$T/calls.log" ] && pass "CONTROL: a real call would have been recorded" ||
  fail "CONTROL: the stub log never records, so the offline check proves nothing"

# --- 3. the summary counts misses --------------------------------------------------
py="$PROJ_ROOT/src/bash/scripts/delivery-probe.py"
got="$(python3 - "$py" <<'EOP'
import sys
src = open(sys.argv[1]).read()
ns = {}
# only the pure helpers: importing the module would load m3-e2e.py
exec(compile(src[src.index("def pct("):src.index("def dial(")], "helpers", "exec"), ns)
rows = [{"t_send": 0, "t_ack": 0.05, "t_live": 0.06, "t_seen": 0.06},
        {"t_send": 0, "t_ack": 0.05, "t_seen": 31.0, "t_caught": 31.0}]
s = ns["summary"](rows)
print(s["missed_live"], s["send->other socket"]["n"], s["send->other socket"]["max"],
      s["send->other sees it (live or catch-up)"]["max"])
EOP
)"
[ "$got" = "1 1 0.06 31.0" ] && pass "a miss is counted and kept out of the live hop" ||
  fail "summary() got '$got', want '1 1 0.06 31.0'"

[ "$fails" -eq 0 ] && { echo "OK delivery-probe"; exit 0; }
echo "FAILED delivery-probe: $fails"; exit 1
