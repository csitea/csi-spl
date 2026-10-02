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
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool

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

# --- 4. the catch-up read finds a view-v1 row (env.msg.msg_id) ---------------------
# The first after-fix run reported a message the view DID hold as never seen,
# because the match looked at row.msg / row only.
got="$(python3 - "$py" <<'EOP'
import sys
src = open(sys.argv[1]).read()
ns = {}
exec(compile(src[src.index("def row_msg_id("):src.index("def live_revision(")], "rowid", "exec"), ns)
f = ns["row_msg_id"]
print(f({"cursor": "c", "env": {"from_box": "box-wui", "msg": {"msg_id": "m1"}}}), f({"msg": {"msg_id": "m2"}}), f({"msg_id": "m3"}))
EOP
)"
[ "$got" = "m1 m2 m3" ] && pass "the catch-up read matches env.msg, msg and flat rows" ||
  fail "row_msg_id got '$got', want 'm1 m2 m3'"

[ "$fails" -eq 0 ] && { echo "OK delivery-probe"; exit 0; }
echo "FAILED delivery-probe: $fails"; exit 1
