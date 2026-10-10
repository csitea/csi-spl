#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_msg_delete deletes the desk agent's OWN messages of one
#          topic through `spool delete`, offline. The desk spool is a stateful
#          stub: hub-tail serves $T/topic.ndjson, a delete removes that row.
#   1. a bad TOPIC is refused before any spool call
#   2. DRY_RUN=1 lists the agent's messages newest first, deletes nothing,
#      and never lists another author's message
#   3. DRY_RUN=0 deletes every message of the agent, newest first (the root
#      last), leaves the others, and reports left 0
#   4. MSG_IDS narrows it to the named messages (prefixes accepted)
#   5. a MSG_IDS entry that is not the agent's is refused, nothing deleted
#   6. a delete that does not take (the row still shows) is a FATAL
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
AGENT=c-002
TOPIC=22222222-2222-4222-8222-222222222222
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/$AGENT"

seed() {
  python3 - "$T/topic.ndjson" "$TOPIC" <<'EOF_PY'
import json, sys
path, topic = sys.argv[1:]
rows = [("aaaaaaaa-0000-4000-8000-000000000001", "2026-10-10T14:00:01Z", "c-002"),
        ("bbbbbbbb-0000-4000-8000-000000000002", "2026-10-10T14:00:02Z", "HUM-10"),
        ("cccccccc-0000-4000-8000-000000000003", "2026-10-10T14:00:03Z", "c-002"),
        ("dddddddd-0000-4000-8000-000000000004", "2026-10-10T14:00:04Z", "c-002")]
with open(path, "w") as f:
    for mid, ts, frm in rows:
        f.write(json.dumps({"v": 1, "msg_id": mid, "task_id": topic, "ts": ts, "from": frm, "to": "ALL-0", "body": "x", "files": []}) + "\n")
EOF_PY
}

# run [VAR=value]... - the action against the stub; calls in $T/calls, output
# in $T/o, rc in $rc. KEEP=1 makes the stub's delete a no-op (case 6).
run() {
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  shift 4; [[ "${1:-}" == -- ]] && shift
  { local IFS="|"; echo "$*" >>"$CALLS"; }
  case "$1" in
    hub-tail) cat "$TOPIC_F" ;;
    delete)
      [[ "${KEEP:-0}" == 1 ]] || { grep -v "\"$3\"" "$TOPIC_F" >"$TOPIC_F.n"; mv "$TOPIC_F.n" "$TOPIC_F"; }
      echo "{\"msg_id\":\"$3\",\"deleted\":\"true\"}" ;;
  esac
}
do_spl_desk_msg_delete'
  in_orc SNIPPET="$SNIPPET" TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT="$AGENT" TOPIC="$TOPIC" \
    CALLS="$T/calls" TOPIC_F="$T/topic.ndjson" "$@" >"$T/o" 2>&1
  rc=$?
}
deletes() { grep '^delete|' "$T/calls" | cut -d'|' -f3 | cut -c1-8 | tr '\n' ' '; }

# --- 1. a bad TOPIC ------------------------------------------------------------------------
seed; run TOPIC=nope DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'TOPIC must be' "$T/o" &&
  pass "a bad TOPIC is refused before any spool call" || fail "bad topic (rc=$rc): $(cat "$T/o")"

# --- 2. DRY_RUN=1 --------------------------------------------------------------------------
seed; run
[[ $rc -eq 0 && -z "$(deletes)" && "$(grep -c 'would delete' "$T/o")" == 3 ]] && ! grep -q 'would delete bbbbbbbb' "$T/o" &&
  [[ "$(grep -o 'would delete [a-f]*' "$T/o" | cut -c14-21 | tr '\n' ' ')" == "dddddddd cccccccc aaaaaaaa " ]] &&
  pass "DRY_RUN=1 lists the agent's 3 messages newest first, deletes nothing" || fail "dry run (rc=$rc): $(cat "$T/o")"

# --- 3. DRY_RUN=0, all of the agent's ----------------------------------------------------------
seed; run DRY_RUN=0
[[ $rc -eq 0 && "$(deletes)" == "dddddddd cccccccc aaaaaaaa " && "$(wc -l <"$T/topic.ndjson")" == 1 ]] &&
  grep -q 'bbbbbbbb' "$T/topic.ndjson" && grep -q '"left": 0' "$T/o" && grep -q -- '|--as|c-002' "$T/calls" &&
  pass "deletes the agent's 3 messages newest first (root last), keeps the human's, left 0" || fail "delete all (rc=$rc): $(deletes) / $(cat "$T/o")"

# --- 4. MSG_IDS ---------------------------------------------------------------------------------
seed; run DRY_RUN=0 MSG_IDS='aaaaaaaa,dddddddd-0000-4000-8000-000000000004'
[[ $rc -eq 0 && "$(deletes)" == "dddddddd aaaaaaaa " ]] && grep -q 'cccccccc' "$T/topic.ndjson" &&
  pass "MSG_IDS narrows the delete to the named messages" || fail "msg ids (rc=$rc): $(deletes) / $(cat "$T/o")"

# --- 5. another author's id ------------------------------------------------------------------------
seed; run DRY_RUN=0 MSG_IDS='bbbbbbbb'
[[ $rc -ne 0 && -z "$(deletes)" ]] && grep -q 'MSG_IDS entry bbbbbbbb matches 0' "$T/o" &&
  pass "a MSG_IDS entry that is not the agent's is refused, nothing deleted" || fail "foreign id (rc=$rc): $(cat "$T/o")"

# --- 6. a delete that does not take ------------------------------------------------------------------
seed; run DRY_RUN=0 KEEP=1
[[ $rc -ne 0 ]] && grep -q 'FATAL 3 of the deleted messages still show' "$T/o" &&
  pass "a row still there after the delete is a FATAL" || fail "kept row (rc=$rc): $(cat "$T/o")"

echo "fails=$fails"
exit $(( fails > 0 ))
