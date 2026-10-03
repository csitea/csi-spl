#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_responder_run posts at most ONE "Seen" per topic across
#          MACHINES (c-082). Measured on prd t1 topic 139c58c8, 2026-10-03:
#          box-rsp posted a Seen at 03:35, the lease moved, and sat-rsp posted
#          a second one at 05:17 - its ledger is per machine. Two simulated
#          machines (own state dir, own box id) share one stub hub: a TSV of
#          (task, from_id, from_box) rows that `spool hub-rsp` counts and the
#          stub reply appends to.
#   1. machine A (box-rsp) answers topic T once
#   2. machine B (sat-rsp, empty ledger, holds the lease) gets a NEW human
#      post in T -> posts NOTHING, and records T in its own ledger
#   3. CONTROL: B gets topic U with no RSP row on the hub -> exactly one Seen
#   4. hub down: B's Seen in topic V is DEFERRED (none posted, the file still
#      goes), survives the inbox ack, and is posted once when the hub answers
#   5. hub down past RESP_HUB_WAIT: the Seen in topic W is given up, no post
#   6. rollout gap (a hub that does not answer rsp_count, or a box spool
#      without hub-rsp): answered on the local ledger as before, never silenced
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/A/desk/t1/box-rsp/spool" "$T/B/desk/t1/sat-rsp/spool" "$T/spool"
: >"$T/hub.tsv"; : >"$T/send.log"; echo '{}' >"$T/env.yaml"
cat >"$T/send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SEND_LOG"
SH

# on_box <state dir> <box>: one machine. recv reads $INBOX; hub-rsp counts the
# shared hub's RSP-* rows of the topic (HUB_DOWN=1: it fails, as unreachable);
# the reply is a hub row from <box>.
on_box() {
  local sd="$1" bx="$2"; shift 2
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/$sd" \
    SPOOL_TEST=1 SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_TMUX_SOCKET="$T/no-tmux.sock" \
    SPOOL_FLEET_RELAY=0 RESP_SEND="$T/send.sh" SEND_LOG="$T/send.log" HUB="$T/hub.tsv" \
    INBOX="$T/inbox.json" HUB_DOWN="${HUB_DOWN:-0}" ENV=dev TENANT_ID=t1 DESK_BOX="$bx" DRY_RUN=0 RESP_SEEN_REPLY=1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF="'"$T"'/env.yaml"; SPL_ORG_APP="csi-spl"; export SPL_CNF SPL_ORG_APP; return 0; }
    yq() { echo "api.example.net"; }
    spl_host_spool() { return 0; }
    spl_desk_spool() {
      case "$*" in
        *"-- recv"*) cat "$INBOX" ;;
        *"-- hub-rsp --task "*)
          [[ "$HUB_DOWN" == 1 ]] && { echo "hub unreachable" >&2; return 1; }
          [[ "$HUB_DOWN" == old ]] && { echo "spool: the hub does not answer rsp_count" >&2; return 1; }
          [[ "$HUB_DOWN" == bin ]] && { echo "unknown command \"hub-rsp\"" >&2; return 1; }
          local t="${@: -1}"
          printf "{\"task_id\": \"%s\", \"rsp\": %s}\n" "$t" "$(awk -F "\t" -v t="$t" "\$1 == t && \$2 ~ /^RSP-/" "$HUB" | wc -l)" ;;
        *) echo "{}" ;;
      esac
    }
    do_spl_desk_reply() { printf "%s\t%s\t%s\n" "$DESK_TASK" "$DESK_AGENT" "$DESK_BOX" >>"$HUB"; }
    do_spl_responder_run'
}
post() { printf '[{"v":1,"msg_id":"%s","from":"HUM-10","task_id":"%s","ts":"%s","to":"ALL-0","kind":"note","body":"hello?"}]\n' "$1" "$2" "$3" >"$T/inbox.json"; printf '%s\tHUM-10\tbox-wui\n' "$2" >>"$T/hub.tsv"; }
seen_count() { awk -F '\t' -v t="$1" '$1 == t && $2 ~ /^RSP-/' "$T/hub.tsv" | wc -l; }

# --- 1. machine A answers topic T ---------------------------------------------------
post m1 t-139 2026-10-03T03:35:00Z
on_box A box-rsp >"$T/o" 2>&1
[ "$(seen_count t-139)" = 1 ] && pass "machine A posts one Seen in a new topic" || fail "A: $(cat "$T/o")"

# --- 2. the lease moves; machine B gets a new human post in the same topic ----------
post m2 t-139 2026-10-03T05:14:39Z
on_box B sat-rsp >"$T/o" 2>&1
if [ "$(seen_count t-139)" = 1 ]; then
  pass "machine B posts NOTHING in a topic machine A already answered (hub has the RSP row)"
else
  fail "machine B posted a second Seen: $(cat "$T/hub.tsv") / $(cat "$T/o")"
fi
grep -qx t-139 "$T/B/desk/t1/sat-rsp/seen-topics" 2>/dev/null &&
  pass "machine B records the topic in its own ledger (the fast path next time)" ||
  fail "machine B's ledger lacks t-139"
grep -q "t-139" "$T/send.log" && pass "the escalation is still filed to the orchestrator" ||
  fail "the later post was not filed: $(cat "$T/send.log")"

# --- 3. CONTROL: a topic with no RSP row --------------------------------------------
post m3 t-uuu 2026-10-03T05:20:00Z
on_box B sat-rsp >"$T/o" 2>&1
[ "$(seen_count t-uuu)" = 1 ] && pass "CONTROL: machine B posts one Seen in a topic with no RSP row" ||
  fail "CONTROL: B's Seen count in t-uuu is $(seen_count t-uuu): $(cat "$T/o")"

# --- 4. hub down: deferred, not doubled, not lost -----------------------------------
post m4 t-vvv 2026-10-03T05:30:00Z
HUB_DOWN=1 on_box B sat-rsp >"$T/o" 2>&1
if [ "$(seen_count t-vvv)" = 0 ] && grep -q "deferred the Seen in topic t-vvv" "$T/o"; then
  pass "hub down: the Seen is deferred (fails closed), not posted blind"
else
  fail "hub down: $(seen_count t-vvv) Seen(s) / $(cat "$T/o")"
fi
grep -q "t-vvv" "$T/send.log" && pass "hub down: the escalation file still goes" || fail "hub down: nothing filed"
echo '[]' >"$T/inbox.json"
HUB_DOWN=1 on_box B sat-rsp >"$T/o" 2>&1
[ "$(seen_count t-vvv)" = 0 ] && pass "hub still down, inbox already acked: still no Seen" || fail "posted while the hub was down"
on_box B sat-rsp >"$T/o" 2>&1
on_box B sat-rsp >>"$T/o" 2>&1
[ "$(seen_count t-vvv)" = 1 ] && pass "hub back: the deferred Seen is posted exactly once" ||
  fail "hub back: $(seen_count t-vvv) Seen(s) in t-vvv / $(cat "$T/o")"
[ "$(grep -c -- "--task t-vvv" "$T/send.log")" = 1 ] && pass "the deferred topic is filed once, not per retry" ||
  fail "t-vvv filed $(grep -c -- "--task t-vvv" "$T/send.log") times"

# --- 5. hub down past RESP_HUB_WAIT: given up, never posted blind ------------------
post m5 t-www 2026-10-03T05:40:00Z
HUB_DOWN=1 RESP_HUB_WAIT=0 on_box B sat-rsp >"$T/o" 2>&1
echo '[]' >"$T/inbox.json"
on_box B sat-rsp >>"$T/o" 2>&1
if [ "$(seen_count t-www)" = 0 ] && grep -q "gave up the Seen in topic t-www" "$T/o"; then
  pass "hub down past RESP_HUB_WAIT: the Seen is given up, nothing posted later"
else
  fail "t-www: $(seen_count t-www) Seen(s) / $(cat "$T/o")"
fi

# --- 6. rollout gap: not an outage, the old ledger-only behaviour ------------------
post m6 t-xxx 2026-10-03T05:50:00Z
HUB_DOWN=old on_box B sat-rsp >"$T/o" 2>&1
post m7 t-yyy 2026-10-03T05:51:00Z
HUB_DOWN=bin on_box B sat-rsp >>"$T/o" 2>&1
if [ "$(seen_count t-xxx)" = 1 ] && [ "$(seen_count t-yyy)" = 1 ] && grep -q "not deployed" "$T/o"; then
  pass "rollout gap (old hub / old spool binary): one Seen on the local ledger, with a WARN"
else
  fail "rollout gap: t-xxx $(seen_count t-xxx), t-yyy $(seen_count t-yyy) / $(cat "$T/o")"
fi

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
