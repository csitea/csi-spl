#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2553 - a desk's answer to a person in a #lobby WELCOME topic
#          goes to a DM with that person (--ref the welcome topic), never into
#          the topic every #lobby member reads (owner HUM-10, t1 cd9b0f47
#          msg 118f32d7). The desk spool is stubbed: every call is logged,
#          `topics` answers a #lobby page whose subject is SUBJECT, or fails
#          with TOPICS_FAIL=1.
#   1. a member's reply in their welcome topic -> answered in the DM topic
#      uuid5(tenant, topic, person), --ref the topic, route welcome-dm;
#      CONTROL: the same reply in a #lobby topic that is not a welcome is
#      answered in that topic
#   2. the DESK_TO + full DESK_TASK form (do_spl_take, the dispatcher) -> the
#      same DM; a second agent answering the same person lands in the SAME
#      DM topic
#   3. the topic list cannot be read -> the answer stays in the topic
#   4. desk-welcome-text.py --match: every locale x variant with a name
#      matches; a probe subject and a bare template prefix do not
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
WT=33333333-3333-4333-8333-333333333333
WELCOME="🎈🐙 Hooray, FirstName LastName is here! Eight arms of welcome from all of us bots. So glad you joined, the fun starts now! 🌈"
DMT="$(python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool:welcome-dm:t1:'"$WT"':HUM-24"))')"
for a in c-002 c-003; do mkdir -p "$T/state/dev/desk/t1/box-desk/spool/$a"; done

# a member's question, a reply (to ALL-0) in the welcome topic
python3 - "$T/inbox.json" "$WT" <<'EOF_PY'
import json, sys
json.dump([{"v": 1, "msg_id": "m-1", "task_id": sys.argv[2], "ts": "2026-10-06T08:52:00Z",
            "from": "HUM-24", "to": "ALL-0", "kind": "note",
            "body": "the topic menu does not show", "files": []}], open(sys.argv[1], "w"))
EOF_PY

# reply <agent> [VAR=value]... - DRY_RUN=0 against the stubbed spool; the
# calls land in $T/calls (args joined by "|"), the output in $T/o.
reply() {
  local agent="$1"; shift
  : >"$T/calls"
  rm -f "$T/state/dev/desk/t1/box-desk/answered"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local IFS="|"; echo "$*" >>"$CALLS"
  case "$1" in
    recv) cat "$INBOX" ;;
    topics) [[ "${TOPICS_FAIL:-0}" == 1 ]] && { echo "spool: hub unreachable"; return 1; }
      python3 -c "import json,sys; print(json.dumps({\"channel\":\"lobby\",\"topics\":[{\"task_id\":\"aaaaaaaa-0000-4000-8000-000000000000\",\"subject\":\"other\",\"last_ts\":\"x\"},{\"task_id\":sys.argv[1],\"subject\":sys.argv[2],\"last_ts\":\"x\"}],\"next\":None}))" "$WT" "$SUBJECT" ;;
    send) echo "{\"msg_id\":\"s-1\",\"delivery\":\"sent\"}" ;;
  esac
}
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT="$agent" DESK_BODY="Here is how the menu works." DRY_RUN=0 \
    CALLS="$T/calls" INBOX="$T/inbox.json" WT="$WT" SUBJECT="$WELCOME" "$@" >"$T/o" 2>&1
}
sends() { grep '^send|' "$T/calls"; }
sent_in() { sends | grep -c -- "--task|$1|"; }

# --- 1. a member's reply in the welcome topic -> the DM ------------------------------
reply c-002
if [[ "$(sends | wc -l)" == 1 && "$(sent_in "$DMT")" == 1 && "$(sent_in "$WT")" == 0 ]] &&
  grep -q -- "--to|HUM-24|" <<<"$(sends)" && grep -q -- "--ref|$WT" <<<"$(sends)" && grep -q '"route": "welcome-dm"' "$T/o"; then
  pass "an answer to a member in their #lobby welcome topic goes to the DM $DMT with --ref the topic"
else
  fail "welcome-topic answer not in the DM: calls=$(cat "$T/calls") out=$(cat "$T/o")"
fi
reply c-002 SUBJECT="[spool-probe] L1 lobby mv6bams6"
[[ "$(sent_in "$WT")" == 1 && "$(sent_in "$DMT")" == 0 ]] && ! grep -q -- "--ref|" <<<"$(sends)" &&
  pass "CONTROL: a #lobby topic that is not a welcome is answered in the topic" ||
  fail "non-welcome topic moved: calls=$(cat "$T/calls")"

# --- 2. the full DESK_TO + DESK_TASK form; one DM topic for every desk ---------------
reply c-002 DESK_TO=HUM-24 DESK_TASK="$WT"
[[ "$(sent_in "$DMT")" == 1 && "$(sent_in "$WT")" == 0 ]] &&
  pass "DESK_TO + DESK_TASK into a welcome topic (do_spl_take) goes to the DM" ||
  fail "named welcome topic not moved: calls=$(cat "$T/calls")"
reply c-003 DESK_TO=HUM-24 DESK_TASK="$WT"
[[ "$(sent_in "$DMT")" == 1 ]] && grep -q -- "--from|c-003|" <<<"$(sends)" &&
  pass "a second desk answering the same person lands in the same DM topic" ||
  fail "second desk used another DM: calls=$(cat "$T/calls")"

# --- 3. the topic list cannot be read -> the topic -----------------------------------
reply c-002 TOPICS_FAIL=1
[[ "$(sent_in "$WT")" == 1 && "$(sent_in "$DMT")" == 0 ]] &&
  pass "an unreadable topic list keeps the answer in the topic (today's behaviour)" ||
  fail "unreadable topic list: calls=$(cat "$T/calls")"

# --- 4. the matcher ------------------------------------------------------------------
W="$PROJ_ROOT/src/bash/scripts/desk-welcome-text.py"
bad="$(python3 - "$W" <<'EOF_PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("w", sys.argv[1]); w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
miss = [f"{l}[{i}]" for l, ts in w.TEXTS.items() for i, t in enumerate(ts) if not w.is_welcome(t.format(name="Ann Lee"))]
print(" ".join(miss))
EOF_PY
)"
[[ -z "$bad" ]] && pass "--match knows every locale x variant with a name in it" || fail "--match misses: $bad"
if ! python3 "$W" --match <<<"[spool-probe] L1 lobby mv6bams6" && ! python3 "$W" --match <<<"🎉🥳 Welcome aboard, " &&
  python3 "$W" --match <<<"$WELCOME"; then
  pass "--match: the prd welcome subject matches; a probe and a bare prefix do not"
else
  fail "--match judged a subject wrongly"
fi

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASSED"
