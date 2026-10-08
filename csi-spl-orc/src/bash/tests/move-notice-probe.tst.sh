#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_move_notice_probe (bug topic 226a8209 live proof) stays
#          offline in its dry run and refuses bad input before any call.
#   1. dry run: no spool / gcloud / curl call; names the channel and the box
#   2. refusals: bad tenant, the lobby / general / issues channels, box-wui,
#      bad DRY_RUN, bad wait - each before any call
#   3. the hub-tail reader: m1 on N passes; m1 on the old topic does not
#   4. the notice reader: a note on N naming m1 passes; m1 itself does not
#   5. CONTROL: a spool call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool psql
M1=645f9e3e-5dc1-4e21-aab2-12235aad2c9b A=5901e226-01b9-4d6f-a13e-f714897c3ffd N=65f75266-e077-45b6-bee8-8f78dd1cc30f

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_move_notice_probe in_orc TENANT_ID=t1 DESK_BOX=box-desk 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "into #live-proof of t1 .* as box-desk" <<<"$out" && pass "dry run names the default channel and the box" \
  || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "TENANT_ID=T1" "PROBE_CHANNEL=lobby" "PROBE_CHANNEL=general" "PROBE_CHANNEL=issues" "PROBE_CHANNEL=#x" \
  "DESK_BOX=box-wui" "DESK_BOX=Box" "DRY_RUN=2" "PROBE_WAIT_SECS=soon" "PROBE_WAIT_SECS=0"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_move_notice_probe in_orc TENANT_ID=t1 DESK_BOX=box-desk "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    grep -q FATAL "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "refuses $bad before any call" || fail "refuses $bad: $(cat "$T/o") calls=$(cat "$T/calls.log")"
  fi
done

# --- 3. the hub-tail reader --------------------------------------------------------------
tail_n="{\"msg_id\":\"$M1\",\"task_id\":\"$N\",\"v\":1}"
SNIPPET="_spl_move_probe_has '$tail_n' $M1 $N" in_orc && pass "m1 on N is read as moved" || fail "m1 on N not read"
SNIPPET="_spl_move_probe_has '{\"msg_id\":\"$M1\",\"task_id\":\"$A\"}' $M1 $N" in_orc &&
  fail "m1 on the OLD topic read as moved" || pass "CONTROL m1 on the old topic is not"

# --- 4. the notice reader ----------------------------------------------------------------
mkdir -p "$T/sp/c-001/inbox"
printf '{"msg_id":"%s","task_id":"%s","body":"x"}\n' "$M1" "$A" >"$T/sp/c-001/inbox/a.json"
SNIPPET="_spl_move_probe_notice '$T/sp' $M1 $N" in_orc && fail "m1 itself counted as the notice" || pass "CONTROL m1 itself is no notice"
printf '{"msg_id":"0f8fad5b-d9cb-469f-a165-70867728950e","task_id":"%s","body":"Moved: message %s now lives in %s"}\n' "$N" "$M1" "$N" \
  >"$T/sp/c-001/inbox/b.json"
SNIPPET="_spl_move_probe_notice '$T/sp' $M1 $N" in_orc && pass "a note on N naming m1 is the notice" || fail "notice not found"

# --- 5. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all move-notice-probe.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
