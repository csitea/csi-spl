#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_reply_count_probe (SPL-1008 live seed: an OLD channel topic
#          of agent replies - note, blocker, result - behind newer topics)
#          stays offline in its dry run and refuses bad input before any call.
#   1. dry run: no spool / gcloud / curl call; names the box, the member, the
#      channel, the reply shapes and the newer-topic count
#   2. refusals: t1, box-desk / box-wui, a human as the member, an agent as
#      PROBE_HUMAN, bad tenant, bad DRY_RUN, bad PROBE_NEWER
#   3. DRY_RUN=0 without a root key stops before any spool call
#   4. CONTROL: a spool call made through the stub IS recorded
#   5. the batch poster's frames: "new" opens a channel-tagged topic
#      (is_parent 1), "$<n>" replies in the n-th post's topic with is_parent 0
#      and no channel tag, as the WUI reply pane sends it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool psql

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_reply_count_probe in_orc TENANT_ID=e2e 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "pin box-rcp-[0-9]\{14\} under e2e .* announcing PRB-9976, create #rc-probe-[0-9]* with PRB-9976 seated" <<<"$out" &&
  grep -q "PRB-9976 replies to HUM-1 (note, blocker, result)" <<<"$out" &&
  grep -q "open 8 newer topics of 4 lines each" <<<"$out" &&
  pass "dry run names the box, the member, the channel, the shapes and the newer topics" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "TENANT_ID=t1" "PROBE_BOX=box-wui" "PROBE_BOX=box-desk" "PROBE_MEMBER=HUM-4" "PROBE_MEMBER=prb-1" \
  "PROBE_HUMAN=CLE-7" "TENANT_ID=E2E" "DRY_RUN=2" "PROBE_NEWER=many" "PROBE_NEWER=0" "PROBE_NEWER=21"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_reply_count_probe in_orc TENANT_ID=e2e "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    [[ ! -s "$T/calls.log" ]] && pass "refuses $bad before any call" || fail "refuses $bad but called: $(cat "$T/calls.log")"
  fi
done

# --- 3. no root key: stops before any call -----------------------------------------------
: >"$T/calls.log"
if SNIPPET=do_spl_reply_count_probe in_orc TENANT_ID=e2e DRY_RUN=0 ROOT_KEY="$T/none" >"$T/o" 2>&1; then
  fail "DRY_RUN=0 without a root key succeeded: $(cat "$T/o")"
else
  grep -q "FATAL ROOT_KEY" "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "no root key: FATAL before any call" \
    || fail "no root key: $(cat "$T/o") calls=$(cat "$T/calls.log")"
fi

# --- 4. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

# --- 5. the batch poster's frames (a fake m3 module: no network) --------------------------
mkdir -p "$T/py"
cp "$PROJ_ROOT/src/bash/scripts/reply-count-probe-post.py" "$T/py/"
: >"$T/py/m3-e2e.py"
out=$(cd "$T/py" && python3 -c '
import importlib.util, json
spec = importlib.util.spec_from_file_location("p", "reply-count-probe-post.py"); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
done = []
for f in p.frames([{"task": "new", "body": "a"}, {"task": "$0", "body": "b"}], "rc-x", done):
    done.append({"msg_id": f["msg_id"], "task_id": f["task_id"]}); print(json.dumps(f, sort_keys=True))
' 2>&1)
first=$(sed -n 1p <<<"$out"); second=$(sed -n 2p <<<"$out")
task=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["task_id"])' "$first" 2>/dev/null)
python3 -c 'import json,sys; f=json.loads(sys.argv[1]); assert f["is_parent"]==1 and f["channel"]=="rc-x" and f["type"]=="send"' "$first" 2>/dev/null &&
  python3 -c 'import json,sys; f=json.loads(sys.argv[1]); assert f["is_parent"]==0 and "channel" not in f and f["task_id"]==sys.argv[2]' "$second" "$task" 2>/dev/null &&
  pass "frames: a new topic is channel-tagged, \$0 replies in its task untagged" || fail "frames: $out"

echo "reply-count-probe: $fails failure(s)"
(( fails == 0 ))
