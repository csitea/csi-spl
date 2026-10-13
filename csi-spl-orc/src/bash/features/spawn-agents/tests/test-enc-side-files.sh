#!/usr/bin/env bash
# spec 136 FR7, lane L5a: a sealed message's body stays out of the poke line,
# the notices log, the ask summary, the hook context, the mirror post and the
# notify stdin. A plain message still carries its body. The marker is planted
# in the clear body (and in ct) of a v:3 object; none of those surfaces may
# show it. Throwaway SPOOL_ROOT, private tmux.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox

MARK='SPL136L5A-MARKER-7f3c9a'
TO=c-102
FROM=c-101
TASK=t-1
MSG=m-1
HOOK="$T_SCRIPTS/spool-agent-hook.sh"

. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
. "$T_FEAT/lib/spool-poke-queue.inc.sh"
. "$T_FEAT/lib/spool-asks.inc.sh"
spool_env_resolve

# The line spec 136 section 3.3 names for a sealed message.
ENC_LINE=": 'SPOOL ${TO}: note from ${FROM} task ${TASK} msg ${MSG} :: encrypted :: run: spool recv --encrypted --as ${TO}'"

echo "# 1. poke line"
unset SPOOL_NOTIFY_ENC
spool_notify_render PLAIN "$TO" note "$FROM" "$TASK" "$MSG" "$MARK"
has "CONTROL plain poke still carries the body" "$MARK" "$PLAIN"
SPOOL_NOTIFY_ENC=1 spool_notify_render ENC "$TO" note "$FROM" "$TASK" "$MSG" "$MARK"
eq "enc poke is the header-only line" "$ENC_LINE" "$ENC"
hasnt "enc poke line carries no marker body" "$MARK" "$ENC"

echo "# 2. notices log"
t_tmux
P="$(t_window "$TO" 'sleep 600')"
printf '%s\tclaude\t%s\t/x\t20260101T000000Z\n' "$TO" "$P" >>"$SPOOL_ROOT/registry.tsv"
SPOOL_NOTIFY_ENC=1 spool_notice_record "$TO" "head" "$MARK"
LOG="$SPOOL_ROOT/$TO/.pokes/notices.log"
hasnt "enc notices log carries no marker body" "$MARK" "$(cat "$LOG" 2>/dev/null)"
has "enc notices log names the sealed message" ":: encrypted ::" "$(cat "$LOG" 2>/dev/null)"
SPOOL_NOTIFY_ENC=1 SPOOL_SHOW_PANE=0 spool_poke_show "$TO" note "$FROM" "$TASK" "$MSG" "$MARK" >/dev/null
PANE="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P")"
hasnt "enc pane tty carries no marker body" "$MARK" "$PANE"
# The show path appends a second record; both must be clean.
hasnt "enc show notices log carries no marker body" "$MARK" "$(cat "$LOG")"

echo "# 3. ask summary"
unset SPOOL_NOTIFY_ENC
eq "CONTROL plain ask summary is the body" "$MARK" "$(spool_ask_summary "$MARK")"
SUM="$(SPOOL_NOTIFY_ENC=1 spool_ask_summary "$MARK")"
hasnt "enc ask summary carries no marker body" "$MARK" "$SUM"
AID=11111111-2222-4333-8444-555555555555
SPOOL_NOTIFY_ENC=1 spool_ask_journal_open "$AID" blocker "$FROM" c-001 "$TASK" "$SUM"
ASKF="$SPOOL_ROOT/asks/${AID}.json"
hasnt "enc ask journal carries no marker body" "$MARK" "$(cat "$ASKF" 2>/dev/null)"

echo "# 4. hook context"
D="$SPOOL_ROOT/$TO"
mkdir -p "$D/inbox"
python3 - "$D/inbox/sealed.json" "$D/inbox/plain.json" "$MARK" <<'EOF'
import json, sys
sealed, plain, mark = sys.argv[1:4]
json.dump({"v": 3, "enc": "age", "from": "c-101", "to": "c-102", "kind": "note",
           "task_id": "t-1", "msg_id": "m-seal", "body": mark, "ct": mark,
           "files": [{"name": mark, "kind": "file"}]}, open(sealed, "w"))
json.dump({"v": 1, "msg_id": "m-plain", "task_id": "t-1", "from": "c-101",
           "to": "c-102", "kind": "note", "body": "plain hello"}, open(plain, "w"))
EOF
ctx() { python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "")'; }
OUT="$(env SPOOL_AGENT_ID="$TO" SPOOL_HARNESS=claude HOOK_NOW=1790000000 bash "$HOOK" SessionStart <<<'{}' | ctx)"
has "CONTROL plain hook context still carries its body" "plain hello" "$OUT"
hasnt "enc hook context carries no marker body" "$MARK" "$OUT"
has "enc hook context says the message is sealed" ":: encrypted ::" "$OUT"

echo "# 5. mirror post"
python3 - "$T_SCRIPTS/spool-mirror.py" "$MARK" "$T_TMP/seat" <<'EOF'
import importlib.util, io, json, os, sys
from contextlib import redirect_stdout
script, mark, seat = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("spool_mirror_l5a", script)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
agent = "c-102"
adir = os.path.join(seat, "spool", agent, ".mirror")
os.makedirs(adir, exist_ok=True)
def arm():
    open(os.path.join(adir, "turn"), "w").write(json.dumps({
        "kind": "dm", "to": "HUM-1",
        "task": "11111111-2222-4333-8444-555555555555"}))
m.seat_env = lambda _s: {
    "SPOOL_HUB_URL": "http://127.0.0.1:9", "SPOOL_TENANT": "t",
    "SPOOL_BOX_ID": "box-t", "SPOOL_ROOT": os.path.join(seat, "spool"),
    "SPOOL_KEYS_DIR": os.path.join(seat, "keys")}
os.environ["SPOOL_MIRROR_DRY"] = "1"
text = json.dumps({"v": 3, "enc": "age", "from": "c-101", "to": "c-102",
                   "kind": "note", "task_id": "t-1", "msg_id": "m-1",
                   "body": mark, "ct": mark, "files": [{"name": mark}]})
arm()
buf = io.StringIO()
with redirect_stdout(buf):
    m.post_one(seat, agent, "answer", text, "")
open(os.path.join(seat, "sealed.out"), "w").write(buf.getvalue())
arm()
buf = io.StringIO()
with redirect_stdout(buf):
    m.post_one(seat, agent, "answer", "plain hello mirror", "")
open(os.path.join(seat, "plain.out"), "w").write(buf.getvalue())
EOF
hasnt "enc mirror post carries no marker body" "$MARK" "$(cat "$T_TMP/seat/sealed.out" 2>/dev/null)"
has "CONTROL plain mirror post still carries its text" "plain hello mirror" "$(cat "$T_TMP/seat/plain.out" 2>/dev/null)"
# The rendered line is what typed/ and trigger/ store. It must not be the body.
rm -rf "$SPOOL_ROOT/$TO/.mirror"
spool_notify_mark_typed "$TO" "$ENC"
spool_notify_mark_trigger "$TO" HUM-1 "$TASK" "$MSG" "$ENC"
MIR="$(find "$SPOOL_ROOT/$TO/.mirror" -type f -print0 2>/dev/null | xargs -0 cat 2>/dev/null)"
check "enc mirror side files were written" test -n "$MIR"
hasnt "enc mirror side files carry no marker body" "$MARK" "$MIR"

echo "# 6. notify stdin (Go)"
API="$T_REPO/csi-spl-api/src/go/spool-hub-api"
# setup-go puts a new enough go on PATH in CI. The box PATH is often the
# older /usr/local/go, with the go.mod version beside it. Take the first
# binary that satisfies go.mod so GOTOOLCHAIN=local does not refuse it.
NEED=$(awk '/^go /{print $2; exit}' "$API/go.mod")
go_meets() {
  local bin=$1 have
  [[ -n "$bin" && -x "$bin" ]] || return 1
  have=$("$bin" version 2>/dev/null | awk '{print $3}')
  have=${have#go}
  [[ -n "$have" && -n "$NEED" ]] || return 1
  printf '%s\n%s\n' "$NEED" "$have" | sort -V -C
}
GO=""
PATH_GO=$(command -v go 2>/dev/null || true)
if go_meets "$PATH_GO"; then
  GO=$PATH_GO
else
  for gobin in $(printf '%s\n' /usr/local/go*/bin/go 2>/dev/null | sort -Vr); do
    if go_meets "$gobin"; then GO=$gobin; break; fi
  done
fi
if [[ -z "$GO" ]]; then
  echo "SKIP: no go >= ${NEED:-unknown} on PATH or under /usr/local (enc notify stdin)"
else
  if ( cd "$API" && GOTOOLCHAIN=local "$GO" test -count=1 -timeout 120s ./internal/notify/ -run 'TestRunSealedOmitsBody|TestRunPassesTheMessage' ); then
    ok "enc notify stdin carries no marker body"
  else
    nok "enc notify stdin carries no marker body"
  fi
fi

t_done
