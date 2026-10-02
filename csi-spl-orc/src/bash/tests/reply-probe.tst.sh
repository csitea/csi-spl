#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_reply_probe (SPL-1004 live replay: an opening to a person,
#          then an untagged ALL-0 reply, both reach the member agent) stays
#          offline in its dry run and refuses bad input before any call.
#   1. dry run: no spool / gcloud / curl call; names the box, the member, the
#      channel and the opening's addressee
#   2. refusals: t1, box-desk / box-wui, a human as the member, an agent as
#      the addressee, bad tenant, bad DRY_RUN, bad wait
#   5. the post helper builds the reply frame the WUI reply pane sends:
#      is_parent 0, no channel tag, the given task and to
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
out=$(SNIPPET=do_spl_reply_probe in_orc TENANT_ID=e2e 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "pin box-rpp-[0-9]\{14\} under e2e .* announcing PRB-9975, create #rp-probe-[0-9]* with PRB-9975 seated" <<<"$out" &&
  grep -q "open a topic in #rp-probe-[0-9]* to HUM-27, reply in it to ALL-0 (untagged)" <<<"$out" &&
  pass "dry run names the box, the member, the channel and the addressee" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "TENANT_ID=t1" "PROBE_BOX=box-wui" "PROBE_BOX=box-desk" "PROBE_MEMBER=HUM-4" "PROBE_MEMBER=prb-1" \
  "PROBE_OPEN_TO=CLE-7" "PROBE_OPEN_TO=" "TENANT_ID=E2E" "DRY_RUN=2" "PROBE_WAIT_SECS=soon" "PROBE_WAIT_SECS=0"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_reply_probe in_orc TENANT_ID=e2e "$bad" >"$T/o" 2>&1; then
    [[ "$bad" == "PROBE_OPEN_TO=" ]] && { pass "an empty PROBE_OPEN_TO takes the default"; continue; }
    fail "accepts $bad"
  else
    [[ ! -s "$T/calls.log" ]] && pass "refuses $bad before any call" || fail "refuses $bad but called: $(cat "$T/calls.log")"
  fi
done

# --- 3. no root key: stops before any call -----------------------------------------------
: >"$T/calls.log"
if SNIPPET=do_spl_reply_probe in_orc TENANT_ID=e2e DRY_RUN=0 ROOT_KEY="$T/none" >"$T/o" 2>&1; then
  fail "DRY_RUN=0 without a root key succeeded: $(cat "$T/o")"
else
  grep -q "FATAL ROOT_KEY" "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "no root key: FATAL before any call" \
    || fail "no root key: $(cat "$T/o") calls=$(cat "$T/calls.log")"
fi

# --- 4. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

# --- 5. the reply frame -------------------------------------------------------------------
# Drive the helper's frame builder against a fake m3 module: no network.
mkdir -p "$T/py"
cp "$PROJ_ROOT/src/bash/scripts/fallback-probe-post.py" "$T/py/"
cat >"$T/py/m3-e2e.py" <<'PY'
import json, os
SENT = []
def http(*a, **k): return 200, {}, {}
def session_cookie(h): return "c"
def ws_url(p): return p
class WS:
    def __init__(self, *a): pass
    def send(self, f):
        SENT.append(f)
        if f.get("type") == "send":
            open(os.environ["FRAME_OUT"], "w").write(json.dumps(f))
    def wait(self, pred):
        return {"type": "welcome"} if SENT[-1]["type"] == "hello" else {"type": "ack", "msg_id": "m"}
    def close(self): pass
PY
echo pw >"$T/pw"
frame() { env PROBE_API=https://x PROBE_TENANT=e2e PROBE_EMAIL=a@b PROBE_PW_FILE="$T/pw" PROBE_CHANNEL=rp \
  PROBE_BODY=b FRAME_OUT="$T/frame.json" "$@" python3 "$T/py/fallback-probe-post.py" >/dev/null && cat "$T/frame.json"; }
f=$(frame PROBE_TASK=11111111-2222-4333-8444-555555555555 PROBE_PARENT=0)
python3 -c 'import json,sys; f=json.loads(sys.argv[1]); assert f["is_parent"]==0 and "channel" not in f and "to" not in f and f["task_id"].startswith("1111")' "$f" &&
  pass "PROBE_PARENT=0 sends the reply-pane frame: is_parent 0, no channel tag, the given task" || fail "reply frame: $f"
f=$(frame PROBE_TO=HUM-27)
python3 -c 'import json,sys; f=json.loads(sys.argv[1]); assert f["is_parent"]==1 and f["channel"]=="rp" and f["to"]=="HUM-27"' "$f" &&
  pass "PROBE_TO makes the opening addressed to a person, tagged with the channel" || fail "opening frame: $f"
f=$(frame)
python3 -c 'import json,sys; f=json.loads(sys.argv[1]); assert f["is_parent"]==1 and f["channel"]=="rp" and "to" not in f' "$f" &&
  pass "CONTROL with none of them set the frame is the SPL-997 new topic, unchanged" || fail "default frame: $f"

echo "=== $([[ $fails -eq 0 ]] && echo 'all reply-probe.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
