#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_reply_probe (live proof that a channel-less ALL-0
#          reply reaches the topic's agent) stays offline in its dry run and
#          refuses bad input before any cloud or spool call.
#   1. dry run: no spool / gcloud / curl call; names the box and the agent
#   2. refusals: box-desk / box-wui, a human agent id, bad tenant, bad
#      DRY_RUN, bad wait
#   3. DRY_RUN=0 without a root key stops before any spool call
#   4. CONTROL: a spool call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool psql

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_topic_reply_probe in_orc TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "pin box-trp-[0-9]\{14\} under t1 .* announcing q-998, open a channel-less topic as q-998" <<<"$out" &&
  pass "dry run names the box and the agent" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "PROBE_BOX=box-wui" "PROBE_BOX=box-desk" "PROBE_AGENT=HUM-4" "PROBE_AGENT=q-12" \
  "TENANT_ID=T1" "DRY_RUN=2" "PROBE_WAIT_SECS=soon" "PROBE_WAIT_SECS=0"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_topic_reply_probe in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    [[ ! -s "$T/calls.log" ]] && pass "refuses $bad before any call" || fail "refuses $bad but called: $(cat "$T/calls.log")"
  fi
done

# --- 3. no root key: stops before any call -----------------------------------------------
: >"$T/calls.log"
if SNIPPET=do_spl_topic_reply_probe in_orc TENANT_ID=t1 DRY_RUN=0 ROOT_KEY="$T/none" >"$T/o" 2>&1; then
  fail "DRY_RUN=0 without a root key succeeded: $(cat "$T/o")"
else
  grep -q "FATAL ROOT_KEY" "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "no root key: FATAL before any call" \
    || fail "no root key: $(cat "$T/o") calls=$(cat "$T/calls.log")"
fi

# --- 4. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all topic-reply-probe.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
