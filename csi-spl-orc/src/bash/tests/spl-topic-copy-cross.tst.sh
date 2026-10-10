#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_copy_cross copies a topic of one workspace into a
#          channel of another through two desks, offline. The desk spool is a
#          stateful stub: hub-tail serves $T/src.ndjson (source tenant) or
#          $T/dst.ndjson (target tenant), a send appends to the file of the
#          tenant it went to, hub-get-file drops the blob in the desk's files/.
#   1. a missing required var fails fast, before any spool call
#   2. DRY_RUN=1 lists every post and sends nothing
#   3. DRY_RUN=0: order kept (unsorted input, a duplicate from a second box),
#      headers carry the display name and UTC time and never an e-mail, the
#      root carries the marker, every post is in the same target topic, an
#      attachment is fetched and put again by name, the link-back names the
#      permalink, the source is archived
#   4. a re-run posts nothing and repeats no link-back
#   5. a failure part-way: the re-run posts only the rest, no duplicate
#   6. MSG_IDS + TITLE: a title root, only the selected messages, another
#      target topic; ARCHIVE=0 leaves the source alone
#      6b. a topic with no human sender links back to its addressee
#      6c. the permalink host is the tenant's only when the cnf maps it
#   7. a MSG_IDS entry that matches nothing is refused, nothing is sent
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
AGENT=c-001
TOPIC=22222222-2222-4222-8222-222222222222
FID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for b in box-desk box-two; do mkdir -p "$T/state/dev/desk/src/$b/spool/$AGENT"; done
mkdir -p "$T/state/dev/desk/dst/box-desk/spool/$AGENT"
printf '{"HUM-10": "FirstName LastName", "HUM-11": "someone@example.com"}\n' >"$T/names.json"

# seed: the source topic, out of order, msg 3 carrying one blob attachment
seed() {
  : >"$T/dst.ndjson"
  python3 - "$T/src.ndjson" "$TOPIC" "$FID" <<'EOF_PY'
import json, sys
path, topic, fid = sys.argv[1:]
rows = [
  ("33333333-0000-4000-8000-000000000003", "2026-10-10T12:03:00Z", "c-002", "third, with a file", [{"mode": "blob", "kind": "file", "file_id": fid, "name": "report.txt"}]),
  ("11111111-0000-4000-8000-000000000001", "2026-10-10T12:01:00Z", "HUM-10", "first, the question", []),
  ("44444444-0000-4000-8000-000000000004", "2026-10-10T12:04:00Z", "HUM-11", "fourth", []),
  ("22222222-0000-4000-8000-000000000002", "2026-10-10T12:02:00Z", "c-002", "second", []),
]
with open(path, "w") as f:
    for mid, ts, frm, body, files in rows:
        f.write(json.dumps({"v": 1, "msg_id": mid, "task_id": topic, "ts": ts, "from": frm, "to": "ALL-0",
                            "kind": "note", "body": body, "files": files}) + "\n")
EOF_PY
}

# run [VAR=value]... - the action against the stub; calls in $T/calls (args
# joined by "|", prefixed by the tenant), output in $T/o, rc in $rc.
run() {
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; SPL_WUI_URL=https://wui.invalid; SPL_FQDN=wui.invalid; SPL_CNF="${SPL_CNF_T:-}"; }
spl_host_spool() { :; }
do_spl_hub_member_list() { return 1; }
spl_desk_spool() {
  local d="$1" tenant="$3"; shift 4; [[ "${1:-}" == -- ]] && shift
  { local IFS="|" line; line="$tenant|$*"; echo "${line//$'"'"'\n'"'"'/ }" >>"$CALLS"; }
  local f="$T_DIR/$tenant.ndjson"; [[ "$tenant" == src ]] && f="$T_DIR/src.ndjson"
  case "$1" in
    hub-tail) cat "$f" 2>/dev/null; return 0 ;;
    hub-get-file) mkdir -p "$d/spool/files"; echo blob >"$d/spool/files/$3"; echo "{\"fetched\":true}" ;;
    put-file) echo "{\"file_id\":\"bbbb\"}" ;;
    archive) echo "{\"archived\":true}" ;;
    send)
      local n; n=$(grep -c "^$tenant|send|" "$CALLS")
      [[ "$tenant" == dst && -n "${FAIL_AT:-}" && "$n" -ge "$FAIL_AT" ]] && { echo "spool: hub unreachable"; return 1; }
      python3 - "$f" "$@" <<"EOF_PY"
import json, sys, uuid
path, args = sys.argv[1], sys.argv[3:]
a = {args[i]: args[i + 1] for i in range(0, len(args) - 1, 2) if args[i].startswith("--")}
mid = str(uuid.uuid4())
n = sum(1 for _ in open(path)) if __import__("os").path.exists(path) else 0
open(path, "a").write(json.dumps({"msg_id": mid, "task_id": a.get("--task", ""), "ts": "2026-10-10T14:%02d:00Z" % n,
                                  "from": a.get("--from", ""), "to": "ALL-0", "body": a.get("--body", ""), "files": []}) + "\n")
print(json.dumps({"delivery": "sent", "msg_id": mid, "task_id": a.get("--task", "")}))
EOF_PY
      ;;
  esac
}
do_spl_topic_copy_cross'
  in_orc SNIPPET="$SNIPPET" SRC_TENANT=src DST_TENANT=dst SRC_TOPIC_ID="$TOPIC" DST_CHANNEL='#github' DESK_AGENT="$AGENT" \
    SRC_DESK_BOXES='box-desk box-two' SRC_NAMES_FILE="$T/names.json" CALLS="$T/calls" T_DIR="$T" "$@" >"$T/o" 2>&1
  rc=$?
}
dst_sends() { grep -c '^dst|send|' "$T/calls"; }
bodies() { python3 -c 'import json,sys; [print(json.dumps(json.loads(l)["body"], ensure_ascii=False)) for l in open(sys.argv[1])]' "$T/dst.ndjson"; }

# --- 1. a missing var fails fast -------------------------------------------------------
: >"$T/calls"; seed
SNIPPET='do_spl_topic_copy_cross' in_orc DST_TENANT=dst SRC_TOPIC_ID="$TOPIC" DST_CHANNEL=github DESK_AGENT="$AGENT" CALLS="$T/calls" >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'SRC_TENANT must be set' "$T/o" &&
  pass "a missing SRC_TENANT fails fast, no spool call" || fail "missing var (rc=$rc): $(cat "$T/o")"

# --- 2. DRY_RUN=1 sends nothing ---------------------------------------------------------
: >"$T/calls"; seed
run
if [[ $rc -eq 0 && "$(grep -c '|send|' "$T/calls")" == 0 && "$(grep -c 'would post' "$T/o")" == 4 ]] &&
  grep -q '"messages": 4' "$T/o" && grep -q '"attachments": 1' "$T/o"; then
  pass "DRY_RUN=1 lists 4 posts (1 attachment) and sends nothing"
else
  fail "dry run (rc=$rc): calls=$(cat "$T/calls") out=$(cat "$T/o")"
fi

# --- 3. the copy --------------------------------------------------------------------------
: >"$T/calls"; seed
python3 -c 'import sys; l=open(sys.argv[1]).readline(); open(sys.argv[1],"a").write(l)' "$T/src.ndjson" # a duplicate row
run DRY_RUN=0
b="$(bodies)"
task="$(python3 -c 'import json,sys; print({json.loads(l)["task_id"] for l in open(sys.argv[1])}.pop())' "$T/dst.ndjson")"
if [[ $rc -eq 0 && "$(dst_sends)" == 4 ]] &&
  [[ "$(grep -o '^"\*\*[^*]*\*\* · [0-9: -]* UTC' <<<"$b" | tr -d '"')" == $'**FirstName LastName** · 2026-10-10 12:01 UTC\n**c-002** · 2026-10-10 12:02 UTC\n**c-002** · 2026-10-10 12:03 UTC\n**HUM-11** · 2026-10-10 12:04 UTC' ]]; then
  pass "4 posts in source order, headers name + UTC time, an e-mail name falls back to the id"
else
  fail "order/headers (rc=$rc): $b / $(cat "$T/o")"
fi
[[ "$(sed -n 1p <<<"$b")" == *"Copied from workspace src, topic $TOPIC: 4 of its 4"* && "$(grep -c 'Copied from' <<<"$b")" == 1 ]] &&
  ! grep -q '@example.com' "$T/dst.ndjson" &&
  pass "the root alone carries the copy marker, no e-mail address is copied" || fail "marker: $b"
[[ "$(grep '^dst|send|' "$T/calls" | grep -c -- "|--channel|github|--task|$task|")" == 4 ]] &&
  pass "every post goes to #github in one target topic" || fail "target topic: $(grep '^dst|send|' "$T/calls")"
grep -q "^src|hub-get-file|--file-id|$FID" "$T/calls" && grep '^dst|send|' "$T/calls" | sed -n 3p | grep -- '--put-file|.*/report.txt' >/dev/null &&
  pass "the attachment is fetched from the source and put again in the target by name" || fail "attachment: $(cat "$T/calls")"
grep '^src|send|' "$T/calls" | grep -- "--task|$TOPIC|.*--body|Moved to https://dst.wui.invalid/t/$task" >/dev/null &&
  grep -q "^src|archive|--task|$TOPIC" "$T/calls" &&
  pass "the link-back names the target permalink and the source is archived" || fail "link-back/archive: $(grep '^src|' "$T/calls")"

# --- 4. a re-run is a no-op ---------------------------------------------------------------
: >"$T/calls"
run DRY_RUN=0
[[ $rc -eq 0 && "$(dst_sends)" == 0 && "$(grep -c '^src|send|' "$T/calls")" == 0 ]] && grep -q '"already": 4' "$T/o" &&
  pass "a re-run posts nothing and repeats no link-back" || fail "re-run (rc=$rc): $(cat "$T/calls") $(cat "$T/o")"

# --- 5. a failure part-way, then the re-run --------------------------------------------------
: >"$T/calls"; seed
run DRY_RUN=0 FAIL_AT=3 ARCHIVE=0 LINK_BACK=0
rc1=$rc; n1=$(wc -l <"$T/dst.ndjson")
: >"$T/calls"
run DRY_RUN=0 ARCHIVE=0 LINK_BACK=0
[[ $rc1 -ne 0 && "$n1" == 2 && $rc -eq 0 && "$(dst_sends)" == 2 && "$(wc -l <"$T/dst.ndjson")" == 4 ]] && grep -q '"already": 2' "$T/o" &&
  [[ "$(grep -c '12:0[1-4] UTC' "$T/dst.ndjson")" == 4 ]] &&
  pass "a failed run leaves 2, the re-run posts only the other 2" || fail "resume (rc1=$rc1 n1=$n1 rc=$rc): $(cat "$T/o")"
! grep '^src|' "$T/calls" | grep -E '\|(send|archive)\|' >/dev/null &&
  pass "LINK_BACK=0 ARCHIVE=0 leave the source alone" || fail "source touched: $(grep '^src|' "$T/calls")"

# --- 6. MSG_IDS + TITLE ------------------------------------------------------------------------
: >"$T/calls"; seed
run DRY_RUN=0 MSG_IDS='33333333,11111111-0000-4000-8000-000000000001' TITLE='Part one' ARCHIVE=0
b="$(bodies)"
[[ $rc -eq 0 && "$(dst_sends)" == 3 && "$(sed -n 1p <<<"$b")" == '"**Part one**\n\n_Copied from workspace src, topic '"$TOPIC"': 2 of its 4 message(s)._"' ]] &&
  [[ "$(sed -n 2p <<<"$b")" == *"12:01 UTC"* && "$(sed -n 3p <<<"$b")" == *"12:03 UTC"* ]] &&
  ! grep -q "^src|archive" "$T/calls" && grep '^src|send|' "$T/calls" | grep 'Part one' >/dev/null &&
  [[ "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["task_id"])' "$T/dst.ndjson")" != "$task" ]] &&
  pass "a title root, the 2 selected messages in order, another topic, no archive" || fail "selection (rc=$rc): $b / $(cat "$T/o")"

# --- 6b. no human sender: the link-back answers the human the topic was sent to ---------------
: >"$T/calls"; seed
python3 - "$T/src.ndjson" <<'EOF_PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
for m in rows:
    m["from"], m["to"] = "c-002", "HUM-12"
open(sys.argv[1], "w").write("".join(json.dumps(m) + "\n" for m in rows))
EOF_PY
run DRY_RUN=0 ARCHIVE=0
[[ $rc -eq 0 ]] && grep '^src|send|' "$T/calls" | grep -- '--to|HUM-12|' >/dev/null &&
  pass "a topic with no human sender links back to the human it was addressed to" || fail "link-back addressee (rc=$rc): $(cat "$T/o")"

# --- 6c. the permalink host follows env.dns.mapped_tenants -----------------------------------
: >"$T/calls"; seed
printf 'env:\n  dns:\n    mapped_tenants: [other]\n' >"$T/cnf.yaml"
run SPL_CNF_T="$T/cnf.yaml"
grep -q '"permalink": "https://wui.invalid/t/' "$T/o" && grep -q 'WARN dst has no tenant host' "$T/o" &&
  pass "an unmapped target tenant gets the apex permalink and a WARN" || fail "unmapped host: $(cat "$T/o")"
printf 'env:\n  dns:\n    mapped_tenants: [other, dst]\n' >"$T/cnf.yaml"
run SPL_CNF_T="$T/cnf.yaml"
grep -q '"permalink": "https://dst.wui.invalid/t/' "$T/o" && ! grep -q 'WARN dst' "$T/o" &&
  pass "a mapped target tenant gets its own host" || fail "mapped host: $(cat "$T/o")"

# --- 7. an unknown MSG_IDS entry --------------------------------------------------------------
: >"$T/calls"; seed
run DRY_RUN=0 MSG_IDS='99999999'
[[ $rc -ne 0 && "$(grep -c '|send|' "$T/calls")" == 0 ]] && grep -q 'MSG_IDS entry 99999999 matches 0' "$T/o" &&
  pass "a MSG_IDS entry that matches nothing is refused, nothing sent" || fail "unknown msg id (rc=$rc): $(cat "$T/o")"

echo "fails=$fails"
exit $(( fails > 0 ))
