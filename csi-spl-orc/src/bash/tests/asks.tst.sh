#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: asks to the orchestrator survive the orchestrator (CLE-77929,
#          owner bug t1 #spool-hub-bugs 2f7996aa; SPEC-spool-fleet-roles.md
#          4.3), across TWO simulated machines (pc, sat), each with its own
#          spool root; the hub is a stub with the real contract of `spool ask`
#          (rdb 0097: idempotent put, ack/done/decline/raise/escalate, 409
#          ask_closed naming the closer, list oldest first).
#   1. CONTROL: a note to the orchestrator and a blocker to a peer are NOT
#      asks; a blocker the orchestrator sends itself is not either
#   2. fire and forget: spool-send.sh blocker --to orchestrator journals the
#      ask before it returns (open, unsynced) and starts the hub leg;
#      do_spl_asks_sync puts it; a replay changes nothing
#   3. hub down: the send still journals it; do_spl_asks_open shows it
#      (src journal, WARN); the next tick pushes it once the hub answers
#   4. KILL-MID-ASK: the pc orchestrator holds the role, gets the HANDOVER
#      list (it HAS received both asks) and dies before acking. The lease
#      moves to sat: pc's tick stands down, sat's first tick hands BOTH open
#      asks to CLE-001@sat - from the hub, sat's own journal was empty
#   5. re-raise: an unacked ask quiet past ASKS_RERAISE_MIN goes again (one
#      message, raised_n counts); an acked one does not, unless overdue
#   6. owner leg: unacked past ASKS_OWNER_MIN -> ASKS_OWNER_CMD once; with
#      no owner leg configured: one WARN per ask, nothing sent
#   7. close: done on sat; the dead holder's late close is exit 3 naming the
#      closer; a decline needs a reason; a closed ask's inbox file moves to
#      archive/
#   8. the orchestrator's view: open asks first, untracked blocker/task, FYI
#      collapsed per sender; ORCH_INBOX_ARCHIVE=1 moves the handled messages
#      and never an open ask's
#  10. the share-group deltas (CLE-77942, rdb 0099): KILL-MID-ASK across the
#      two machines - pc's holder acks and dies, sat's tick releases the
#      expired lock and re-raises it "lock expired" (CONTROL: lock off = the
#      old filter leaves it acked forever); a re-ack renews the lock; at the
#      delivery limit an ask is no longer raised, goes to the owner once and
#      is dead-lettered with the reason (CONTROL: no limit = raised again);
#      the next tick posts one resolved line in that reminder; without an
#      owner leg it is dead-lettered saying nobody was told
#  11. a hub book past ARG_MAX (3 MB) is listed (CONTROL: the same book as
#      a jq argument fails: Argument list too long)
#  12. the orchestrator view on 5000 inbox files and that book: section 2
#      and the archive count are right (CONTROL: the old --argjson asks fails)
#  13. spec 068 L4 peers: with 4 seats a blocker to the orchestrator is ONE
#      hub message to peers, still an ask; exactly 1 seat is responsible;
#      ack/done are its message's lock (3 seats refused, book untouched);
#      CONTROL: SPOOL_TO_PEERS=0 = the book's lock
#  14. the owner's reminder names the topic, who is waiting and what to do.
#      A channel topic the owner can read gets the reply in that topic; the
#      next tick after an ack posts one resolved line there. A title with no
#      readable topic is a new topic that still names the title and the uuid.
#      A lookup that fails keeps the old id line and a new topic
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
SCRIPTS="$PROJ_ROOT/src/bash/features/spawn-agents/scripts"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hub"
export SPOOL_TEST=1

# The hub stub: one JSON file per fleet, the rows of rdb 0097 with epoch
# times; the writing box is the caller's SPOOL_DESK_BOX.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time
if os.environ.get("HUB_DOWN") == "1":
    print("dial: connection refused", file=sys.stderr); sys.exit(1)
a = sys.argv[1:]
assert a[0] == "ask"; op = a[1]; kv = {}; i = 2
while i < len(a):
    if a[i] == "--all": kv["all"] = True; i += 1
    else: kv[a[i][2:]] = a[i + 1]; i += 2
path = os.path.join(os.environ["HUB_DIR"], kv["fleet"] + ".json")
rows = json.load(open(path)) if os.path.exists(path) else []
now = time.time() + float(os.environ.get("HUB_SKEW", "0"))
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else ""
def out(r):
    o = dict(r); o["age_s"] = int(now - r["c"]); o["quiet_s"] = int(now - max(r["u"], r.get("r") or 0))
    o["created_at"], o["updated_at"], o["raised_at"], o["escalated_at"] = iso(r["c"]), iso(r["u"]), iso(r.get("r")), iso(r.get("e"))
    for k in ("c", "u", "r", "e"): o.pop(k, None)
    for k in ("deadline_at", "acked_by", "closed_by", "reason", "raised_at", "escalated_at"):  # the hub's omitempty
        if o.get(k) == "": o.pop(k)
    return o
def save(): json.dump(rows, open(path, "w"))
box = os.environ.get("SPOOL_DESK_BOX", "box-desk")
if op == "list":
    sel = [r for r in rows if (kv.get("all") or r["state"] in ("open", "acked")) and kv.get("role", "") in ("", r["role"])]
    sel.sort(key=lambda r: (r["state"] not in ("open", "acked"), r["c"]))
    print(json.dumps({"fleet": kv["fleet"], "created": False, "asks": [out(r) for r in sel]})); sys.exit(0)
if op == "put":
    for r in rows:
        if r["ask_id"] == kv["id"]:
            print(json.dumps({"fleet": kv["fleet"], "created": False, "asks": [out(r)]})); sys.exit(0)
    r = {"ask_id": kv["id"], "role": kv.get("role") or "orch", "kind": kv["kind"], "from": kv["from"], "topic": kv.get("topic", ""), "summary": kv.get("summary", ""),
         "deadline_at": kv.get("deadline", ""), "state": "open", "acked_by": "", "closed_by": "", "reason": "",
         "raised_n": 0, "writer_box": box, "c": now, "u": now}
    rows.append(r); save()
    print(json.dumps({"fleet": kv["fleet"], "created": True, "asks": [out(r)]})); sys.exit(0)
for r in rows:
    if r["ask_id"] == kv["id"]:
        if r["state"] in ("done", "declined", "dead"):
            print("hub refused: ask_closed (409): already %s by %s: %s" % (r["state"], r["closed_by"], r["reason"]), file=sys.stderr); sys.exit(1)
        if op == "ack": r["state"], r["acked_by"], r["u"] = "acked", kv["by"], now
        elif op in ("done", "decline"):
            if op == "decline" and not kv.get("reason"):
                print("hub refused: bad_frame (400): a decline needs a reason", file=sys.stderr); sys.exit(1)
            r["state"], r["closed_by"], r["reason"], r["u"] = ("done" if op == "done" else "declined"), kv["by"], kv.get("reason", ""), now
        elif op == "raise": r["raised_n"] += 1; r["r"] = now
        elif op == "escalate": r["e"] = now
        elif op == "release":
            if r["state"] == "acked": r["state"] = "open"
        elif op == "dead":
            if not kv.get("reason"):
                print("hub refused: bad_frame (400): a dead-letter needs a reason", file=sys.stderr); sys.exit(1)
            r["state"], r["closed_by"], r["reason"], r["u"] = "dead", kv["by"], kv["reason"], now
        r["writer_box"] = box; save()
        print(json.dumps({"fleet": kv["fleet"], "created": False, "asks": [out(r)]})); sys.exit(0)
print("hub refused: unknown_ask (404): no such ask in this fleet", file=sys.stderr); sys.exit(1)
STUB
chmod +x "$T/bin/hub"

# The spool binary stub: `send` writes the v:1 object into <to>/inbox and
# prints spool's result, as the real one does for a local delivery.
cat >"$T/bin/spool" <<'STUB'
#!/usr/bin/env bash
[ "$1" = send ] || { echo "stub spool: only send" >&2; exit 1; }
shift; from="" to="" kind="" body="" task=""
while [ $# -gt 0 ]; do case "$1" in
  --from) from="$2";; --to) to="$2";; --kind) kind="$2";; --body) body="$2";; --task) task="$2";; esac; shift 2; done
id="$(python3 -c 'import uuid; print(uuid.uuid4())')"; task="${task:-$(python3 -c 'import uuid; print(uuid.uuid4())')}"
ts="${STUB_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
mkdir -p "$SPOOL_ROOT/$to/inbox" "$SPOOL_ROOT/$from/outbox"
jq -n -c --arg id "$id" --arg t "$task" --arg ts "$ts" --arg f "$from" --arg to "$to" --arg k "$kind" --arg b "$body" \
  '{v:1, msg_id:$id, task_id:$t, ts:$ts, from:$f, to:$to, kind:$k, body:$b, files:[]}' \
  >"$SPOOL_ROOT/$to/inbox/$(date -u +%Y%m%dT%H%M%SZ)--$from--${id:0:8}.json"
printf '{"delivery":"local","msg_id":"%s","task_id":"%s","ts":"%s"}\n' "$id" "$task" "$ts"
STUB
chmod +x "$T/bin/spool"

# The tick's send stub: one line per message, the body flattened.
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
from="" to="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2;; --to) to="$2"; shift 2;; --body) body="$2"; shift 2;; --no-ask) shift;; *) shift 2;; esac; done
printf '%s %s %s\n' "$from" "$to" "$(tr '\n' ' ' <<<"$body")" >>"$SEND_LOG"
STUB
chmod +x "$T/bin/send"
cat >"$T/bin/owner" <<'STUB'
#!/usr/bin/env bash
jq -c --arg text "$(cat)" --arg task "${ASK_TASK:-}" '. + {owner_text: $text, owner_task: $task}' <<<"$ASK_JSON" >>"$OWNER_LOG"
STUB
chmod +x "$T/bin/owner"

for m in pc sat; do
  mkdir -p "$T/$m/spool/CLE-001/inbox" "$T/$m/spool/CLE-002/inbox" "$T/$m/spool/CLE-77929/inbox" "$T/$m/spool/dispatch"
  printf 'LEASE_ORCH=CLE-001\nLEASE_FLEET=main\n' >"$T/$m/spool/dispatch/lease.conf"
done

# env for a machine: its root, its box, the hub stub; no delivery limit
# (section 10 sets it), since sections 4-6 count every hand-over as a raise;
# an agent's own SPOOL_AGENT_ID would otherwise become the default acker
menv() {
  local m="$1" box=box-desk; [[ "$m" == sat ]] && box=sat
  printf '%s\n' "SPOOL_ROOT=$T/$m/spool" "SPOOL_BOX_ENV=$T/$m/spool/box.env" "SPOOL_DESK_BOX=$box" \
    "ASKS_HUB_CMD=$T/bin/hub" "HUB_DIR=$T/hub" "SPOOL_BIN=$T/bin/spool" "SPOOL_ORCHESTRATOR_ID=CLE-001" \
    "SPOOL_TMUX_SOCKET=$T/tmux.sock" "SPOOL_FLEET_RELAY=0" "ASKS_SEND=$T/bin/send" "SEND_LOG=$T/$m/send.log" \
    "ASKS_MAX_RAISES=0" "SPOOL_AGENT_ID="
}
# on <machine> <action> [env...]: run one action as that machine
on() {
  local m="$1" a="$2"; shift 2
  local -a e; mapfile -t e < <(menv "$m")
  env "${e[@]}" PROJ_PATH="$PROJ_ROOT" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-ask-put spl-asks-sync spl-ask-ack spl-ask-close spl-asks-tick spl-orch-inbox; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    '"$a"
}
# send <machine> <spool-send args...>: the real spool-send.sh on that machine
send() {
  local m="$1"; shift
  local -a e; mapfile -t e < <(menv "$m")
  env "${e[@]}" SPOOL_ASKS_SYNC_CMD="${SYNC_CMD:-true}" bash "$SCRIPTS/spool-send.sh" --no-poke "$@"
}
jrn() { cat "$T/$1/spool/asks/$2.json" 2>/dev/null; }
msgid() { sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p' <<<"$1" | sed -n 1p; }
hubrow() { jq -c --arg i "$1" '.[] | select(.ask_id == $i)' "$T/hub/main.json" 2>/dev/null; }

# 1. CONTROL ----------------------------------------------------------------
send pc --from CLE-77929 --to orchestrator --kind note --body 'fyi: tests green' >/dev/null 2>&1
send pc --from CLE-77929 --to CLE-002 --kind blocker --body 'peer blocker' >/dev/null 2>&1
send pc --from CLE-001 --to CLE-001 --kind task --body 'note to self' >/dev/null 2>&1
n="$(find "$T/pc/spool/asks" -name '*.json' 2>/dev/null | wc -l)"
[[ "$n" -eq 0 ]] && pass "control: a note to the orchestrator, a blocker to a peer and the orchestrator's note to itself are not asks" || fail "control: $n ask(s) journaled"

# 2. fire and forget -----------------------------------------------------------
printf '#!/usr/bin/env bash\necho "$1" >>"%s/synclog"\n' "$T" >"$T/bin/synclog"; chmod +x "$T/bin/synclog"
# the sender's first copy, re-sent below as the old habit was: two asks, one declined as a duplicate in this step
SYNC_CMD="$T/bin/synclog" send pc --from CLE-002 --to orchestrator --kind blocker --task 692aefe8 --body 'BLOCKER: 692aefe8, first copy' >/dev/null 2>&1
out="$(SYNC_CMD="$T/bin/synclog" send pc --from CLE-002 --to orchestrator --kind blocker --task 692aefe8 \
  --body $'**BLOCKER: t1 692aefe8 has had NO lane for ~6 h**\nDecide now.' 2>&1)"
A1="$(msgid "$out")"
[[ -n "$A1" ]] || fail "the first ask was not sent: $out"
j="$(jrn pc "$A1")"
if [[ -n "$A1" && "$(jq -r .state <<<"$j")" == open && "$(jq -r .synced <<<"$j")" == false && "$(jq -r .from <<<"$j")" == CLE-002@box-desk \
      && "$(jq -r .summary <<<"$j")" == "BLOCKER: t1 692aefe8 has had NO lane for ~6 h" && "$out" == *"ask: open ${A1:0:8}"* ]]; then
  pass "a blocker to the orchestrator is journaled before spool-send returns: open, unsynced, from CLE-002@box-desk, summary = first line"
else fail "journal: $out / $j"; fi
grep -qx "$A1" "$T/synclog" 2>/dev/null && pass "the hub leg was started with the ask id (fire and forget)" || fail "sync not started"
A0=""
for f in "$T/pc/spool/asks/"*.json; do f="$(basename "$f" .json)"; [[ "$f" != "$A1" ]] && A0="$f"; done
grep -q "open $A1 CLE-002@box-desk open" "$T/pc/spool/asks/journal.log" && pass "journal.log records the open event" || fail "journal.log: $(cat "$T/pc/spool/asks/journal.log")"
out="$(on pc do_spl_asks_sync ASKS_FLEET=main)"
[[ "$(hubrow "$A1" | jq -r .state)" == open && "$(jq -r .synced <<<"$(jrn pc "$A1")")" == true ]] && pass "do_spl_asks_sync puts it on the hub and marks the journal synced" || fail "sync: $out"
on pc do_spl_asks_sync ASKS_FLEET=main >/dev/null
[[ "$(jq length "$T/hub/main.json")" -eq 2 ]] && pass "a replay changes nothing (2 asks on the hub, both sends)" || fail "replay: $(jq -c . "$T/hub/main.json")"
out="$(on pc 'ASK_ID='"${A0:0:8}"' ASK_STATE=declined ASK_REASON="duplicate send" do_spl_ask_close' ASKS_FLEET=main)"
[[ "$(hubrow "$A0" | jq -r .state)" == declined ]] && pass "an ask closes by its 8-hex prefix (the duplicate, declined with a reason)" || fail "decline: $out"

# 3. hub down ------------------------------------------------------------------
out="$(HUB_DOWN=1 send pc --from CLE-77929 --to CLE-001 --kind task --task 2f7996aa-0dc8-45b2-a16e-bc001b104595 --ask-deadline 2026-10-01T03:00:00Z --body 'Give 2f7996aa an owner' 2>&1)"
A2="$(msgid "$out")"
[[ -n "$A2" ]] || fail "the hub-down ask was not sent: $out"
out="$(on pc do_spl_asks_open ASKS_FLEET=main HUB_DOWN=1 2>&1)"
if [[ "$(jq -r .synced <<<"$(jrn pc "$A2")")" == false && "$out" == *"did not answer"* && "$out" == *"${A2:0:8}"* && "$out" == *journal* && "$out" == *"${A1:0:8}"* && "$out" == *"hub: unreachable"* ]]; then
  pass "hub down: the ask is journaled anyway; the book shows it (src journal) next to the mirrored ones, with a WARN"
else fail "hub down: $out"; fi
grep -E "^${A2:0:8} .* open! " <<<"$out" >/dev/null && pass "an open ask past its deadline is flagged (open!)" || fail "overdue flag: $out"

# 4. KILL-MID-ASK --------------------------------------------------------------
echo "CLE-001@box-desk 1790906467" >"$T/pc/spool/dispatch/lease.orch"
echo "CLE-001@box-desk 1790906467" >"$T/sat/spool/dispatch/lease.orch"
out="$(on pc do_spl_asks_tick ASKS_FLEET=main)"
[[ -n "$(hubrow "$A2")" ]] && pass "the holder's tick pushed the ask written while the hub was down" || fail "tick push: $out"
if grep -q "^CLE-001 CLE-001 \*\*ASKS HANDOVER: 2 open ask(s) for CLE-001@box-desk" "$T/pc/send.log" && grep -q "${A1:0:8}" "$T/pc/send.log" && grep -q "${A2:0:8}" "$T/pc/send.log"; then
  pass "the pc orchestrator's first tick hands it both open asks in ONE blocker (it has now received them)"
else fail "pc handover: $(cat "$T/pc/send.log" 2>/dev/null) / $out"; fi
# ... and dies before acking: no ack, no close. The lease moves to sat.
echo "CLE-001@sat 1790906600" >"$T/pc/spool/dispatch/lease.orch"
echo "CLE-001@sat 1790906600" >"$T/sat/spool/dispatch/lease.orch"
: >"$T/pc/send.log"
out="$(on pc do_spl_asks_tick ASKS_FLEET=main)"
[[ ! -s "$T/pc/send.log" && "$out" == *"held on sat"* ]] && pass "pc's tick stands down: the role is held on sat" || fail "pc stand-down: $out"
[[ -z "$(ls "$T/sat/spool/asks/"*.json 2>/dev/null)" ]] && pass "sat's own journal holds none of the asks (they were sent on pc)" || fail "sat journal not empty"
out="$(on sat do_spl_asks_tick ASKS_FLEET=main)"
if grep -q "^CLE-001 CLE-001 \*\*ASKS HANDOVER: 2 open ask(s) for CLE-001@sat\*\* (the orch role was not seen on this machine)" "$T/sat/send.log" \
   && grep -q "${A1:0:8}" "$T/sat/send.log" && grep -q "${A2:0:8}" "$T/sat/send.log"; then
  pass "KILL-MID-ASK: the successor on sat gets BOTH asks the dead holder received and never acked"
else fail "sat handover: $(cat "$T/sat/send.log" 2>/dev/null) / $out"; fi
[[ "$(jq -r .state <<<"$(jrn sat "$A1")")" == open && "$(jq -r .synced <<<"$(jrn sat "$A1")")" == true ]] && pass "sat's journal now mirrors the hub (the file-system half on the new holder's machine)" || fail "sat mirror: $(jrn sat "$A1")"
[[ "$(hubrow "$A1" | jq -r .raised_n)" -ge 2 ]] && pass "raised_n counts the hand-overs on the hub" || fail "raised_n: $(hubrow "$A1")"

# 5. re-raise ------------------------------------------------------------------
: >"$T/sat/send.log"
# the lease loop's tick holds the lock: a manual tick waits for it instead of skipping
( flock 9; sleep 3 ) 9>>"$T/sat/spool/asks/.tick.lock" &
sleep 0.5
out="$(on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=15 ASKS_TICK_WAIT=20)"
wait
[[ ! -s "$T/sat/send.log" ]] && pass "no re-raise inside ASKS_RERAISE_MIN" || fail "early re-raise: $(cat "$T/sat/send.log")"
[[ "$out" == *"asks tick: holder CLE-001@sat, hub ok: 2 open (2 unacked, 0 acked); re-raise due 0 (quiet >= 15 min); owner due 0 (open >= 60 min)"* ]] &&
  pass "a tick with nothing due says so in one summary line - and it ran after waiting out the held lock" || fail "summary / lock wait: $out"
n1="$(grep -c ' mirror ' "$T/sat/spool/asks/journal.log")"
on sat do_spl_asks_open ASKS_FLEET=main >/dev/null; on sat do_spl_asks_open ASKS_FLEET=main >/dev/null
[[ "$(grep -c ' mirror ' "$T/sat/spool/asks/journal.log")" == "$n1" ]] && pass "an unchanged hub row is not re-mirrored on every read" || fail "mirror churn: $(tail -3 "$T/sat/spool/asks/journal.log")"
on sat 'ASK_ID='"${A1:0:8}"' do_spl_ask_ack' ASKS_FLEET=main >/dev/null
[[ "$(hubrow "$A1" | jq -r '.state + " " + .acked_by')" == "acked CLE-001@sat" ]] && pass "ack: in progress, by CLE-001@sat (the default actor is this machine's orchestrator)" || fail "ack: $(hubrow "$A1")"
on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=0 >/dev/null
if grep -q "ASKS STILL OPEN: 1 ask(s)" "$T/sat/send.log" && grep -q "${A2:0:8}" "$T/sat/send.log" && ! grep -q "${A1:0:8}" "$T/sat/send.log"; then
  pass "re-raise: the unacked ask goes again in one message; the acked one (no deadline) does not"
else fail "re-raise: $(cat "$T/sat/send.log")"; fi

# 5b. the REAL send leg: the tick's blocker lands in the holder's inbox through
# spool-send.sh with the host spool (SPL_SPOOL), never a stale tree build that
# refuses kind blocker; a failed send says why
printf '#!/usr/bin/env bash\necho "spool: kind \\"blocker\\" is not one of task|result|note|reject" >&2; exit 1\n' >"$T/bin/oldspool"; chmod +x "$T/bin/oldspool"
before="$(ls "$T/sat/spool/CLE-001/inbox" | wc -l)"
out="$(on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=0 ASKS_SEND= SPOOL_BIN="$T/bin/oldspool" SPL_SPOOL="$T/bin/spool")"
if [[ "$(ls "$T/sat/spool/CLE-001/inbox" | wc -l)" -eq $((before + 1)) ]] && grep -l '"task_id":"asks-open"' "$T/sat/spool/CLE-001/inbox/"*.json >/dev/null && [[ "$out" == *"re-raised 1 ask(s)"* ]]; then
  pass "the real send leg: the re-raise blocker lands in CLE-001's inbox (task asks-open) via the host spool, past a stale tree build"
else fail "real send: $out / $(ls "$T/sat/spool/CLE-001/inbox")"; fi
out="$(on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=0 ASKS_SEND= SPOOL_BIN="$T/bin/oldspool" SPL_SPOOL="$T/bin/oldspool")"
[[ "$out" == *"did NOT reach CLE-001@sat (spool-send exit 11)"* && "$out" == *'kind "blocker" is not one of'* && "$out" != *"re-raised"* ]] &&
  pass "a failed send is a WARN naming the exit code and the spool error, never a silent tick" || fail "failed send: $out"

# 6. owner leg -----------------------------------------------------------------
out="$(on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=99 ASKS_OWNER_MIN=0)"
out2="$(on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=99 ASKS_OWNER_MIN=0)"
[[ "$out" == *"no owner leg is configured"* && "$out2" != *"no owner leg"* ]] && pass "no owner leg configured: one WARN per ask, nothing sent" || fail "owner off: $out / $out2"
on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=99 ASKS_OWNER_MIN=0 ASKS_OWNER_CMD="$T/bin/owner" OWNER_LOG="$T/owner.log" >/dev/null
on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=99 ASKS_OWNER_MIN=0 ASKS_OWNER_CMD="$T/bin/owner" OWNER_LOG="$T/owner.log" >/dev/null
if [[ "$(wc -l <"$T/owner.log")" -eq 1 && "$(jq -r .ask_id "$T/owner.log")" == "$A2" && -n "$(hubrow "$A2" | jq -r .escalated_at)" ]]; then
  pass "owner leg: the unacked ask goes to the owner ONCE (escalated_at set); the acked one never"
else fail "owner leg: $(cat "$T/owner.log" 2>/dev/null)"; fi

# 7. close ---------------------------------------------------------------------
out="$(on sat 'ASK_ID='"${A1:0:8}"' ASK_REASON="given to CLE-77915, 50-commit target" do_spl_ask_close' ASKS_FLEET=main)"
[[ "$(hubrow "$A1" | jq -r '.state + "|" + .closed_by + "|" + .reason')" == "done|CLE-001@sat|given to CLE-77915, 50-commit target" ]] && pass "close: done by CLE-001@sat with the reason" || fail "close: $out"
out="$(on pc 'ASK_ID='"$A1"' ASK_BY=CLE-001@box-desk do_spl_ask_close' ASKS_FLEET=main)"; rc=$?
[[ $rc -eq 3 && "$out" == *"CLE-001@sat"* && "$out" == *"given to CLE-77915"* ]] && pass "the dead holder's late close: exit 3, names the closer and the reason" || fail "late close (rc=$rc): $out"
out="$(on pc 'ASK_ID='"${A2:0:8}"' ASK_STATE=declined do_spl_ask_close' ASKS_FLEET=main)"; rc=$?
[[ $rc -eq 1 && "$out" == *"needs ASK_REASON"* ]] && pass "a decline without a reason is refused" || fail "decline no reason (rc=$rc): $out"
f="$(grep -l "$A2" "$T/pc/spool/CLE-001/inbox/"*.json 2>/dev/null)"
out="$(on pc 'ASK_ID='"${A2:0:8}"' ASK_REASON="CLE-77929 owns it" do_spl_ask_close' ASKS_FLEET=main)"
[[ -n "$f" && ! -e "$f" && -e "$T/pc/spool/CLE-001/archive/$(basename "$f")" ]] && pass "a closed ask's inbox file moves to archive/" || fail "archive on close: $out"

# 8. the orchestrator's view ----------------------------------------------------
# the lease is back on pc (its orchestrator was restarted)
echo "CLE-001@box-desk 1790907000" >"$T/pc/spool/dispatch/lease.orch"
send pc --from CLE-002 --to CLE-001 --kind task --no-ask --body 'untracked old-style ask' >/dev/null 2>&1
for i in 1 2 3; do STUB_TS=2026-10-01T10:0$i:00Z send pc --from CLE-77911 --to CLE-001 --kind note --body "lease note $i" >/dev/null 2>&1; done
out="$(send pc --from CLE-77924 --to orchestrator --kind blocker --body 'naming window needs a go' 2>&1)"; A3="$(msgid "$out")"
[[ -n "$A3" ]] || fail "the third ask was not sent: $out"
out="$(on pc do_spl_orch_inbox ASKS_FLEET=main ORCH_INBOX_KEEP_MIN=0)"
o1="$(grep -n '== 1. OPEN ASKS' <<<"$out" | cut -d: -f1)"; o2="$(grep -n '== 2. UNTRACKED' <<<"$out" | cut -d: -f1)"; o3="$(grep -n '== 3. FYI' <<<"$out" | cut -d: -f1)"
sec1="$(sed -n "${o1},${o2}p" <<<"$out")"; sec2="$(sed -n "${o2},${o3}p" <<<"$out")"; sec3="$(sed -n "${o3},\$p" <<<"$out")"
[[ "$sec1" == *"${A3:0:8}"* && "$sec1" != *"${A1:0:8}"* ]] && pass "view 1: the open ask leads; closed ones are gone" || fail "view 1: $sec1"
[[ "$sec2" == *"untracked old-style ask"* && "$sec2" != *"naming window"* ]] && pass "view 2: a blocker/task outside the book is listed as untracked" || fail "view 2: $sec2"
grep -E '^CLE-77911 +3x ' <<<"$sec3" >/dev/null && pass "view 3: three FYI notes from one sender collapse to one row (3x)" || fail "view 3: $sec3"
[[ "$out" == *"can move to archive/"* ]] && pass "without ORCH_INBOX_ARCHIVE it only counts what it would move" || fail "dry archive: $out"
before="$(ls "$T/pc/spool/CLE-001/inbox" | wc -l)"
out="$(on pc do_spl_orch_inbox ASKS_FLEET=main ORCH_INBOX_KEEP_MIN=0 ORCH_INBOX_ARCHIVE=1)"
left="$(cat "$T/pc/spool/CLE-001/inbox/"*.json | jq -r .kind | sort | tr '\n' ' ')"
if grep -q "$A3" "$T/pc/spool/CLE-001/inbox/"*.json && [[ "$left" != *note* && "$(ls "$T/pc/spool/CLE-001/inbox" | wc -l)" -lt "$before" ]]; then
  pass "ORCH_INBOX_ARCHIVE=1 moves the FYI and the closed asks' messages; the open ask's message stays (left: $left)"
else fail "archive: $left / $out"; fi

# 10. share-group deltas: lock timeout + delivery limit (fleet kq, holder CLE-001@sat)
hub() { env HUB_DIR="$T/hub" SPOOL_DESK_BOX="${HBOX:-sat}" HUB_SKEW="${HUB_SKEW:-0}" "$T/bin/hub" ask "$@" >/dev/null; }
kqrow() { jq -c --arg i "$1" '.[] | select(.ask_id == $i)' "$T/hub/kq.json" 2>/dev/null; }
B1=aaaaaaaa-1111-4111-8111-111111111111 B2=bbbbbbbb-2222-4222-8222-222222222222 B3=cccccccc-3333-4333-8333-333333333333
for b in "$B1" "$B2"; do hub put --fleet kq --id "$b" --kind blocker --from CLE-002@sat --summary "share-group ${b:0:4}"; done
HBOX=box-desk hub ack --fleet kq --id "$B1" --by CLE-001@box-desk
tick() { on sat do_spl_asks_tick ASKS_FLEET=kq ASKS_RERAISE_MIN=99 ASKS_OWNER_MIN=999 "$@"; }
: >"$T/sat/send.log"
out="$(tick HUB_SKEW=3700 ASKS_LOCK_MIN=0)"
[[ "$(kqrow "$B1" | jq -r .state)" == acked && ! -s "$T/sat/send.log" ]] &&
  pass "CONTROL: with the lock off (the old filter) the dead holder's acked ask stays acked and is never re-raised" || fail "lock-off control: $(kqrow "$B1") / $(cat "$T/sat/send.log")"
out="$(tick HUB_SKEW=1800 ASKS_LOCK_MIN=60)"
[[ "$(kqrow "$B1" | jq -r .state)" == acked && ! -s "$T/sat/send.log" && "$out" == *"lock expired 0 (acked quiet >= 60 min)"* ]] &&
  pass "inside ASKS_LOCK_MIN the holder keeps its lock" || fail "inside the lock: $out"
out="$(tick HUB_SKEW=3700 ASKS_LOCK_MIN=60)"
if [[ "$(kqrow "$B1" | jq -r '.state + " " + .acked_by + " " + (.raised_n | tostring)')" == "open CLE-001@box-desk 1" && "$out" == *"lock expired 1 (acked quiet >= 60 min)"* ]] &&
   grep -q "${B1:0:8}.*LOCK EXPIRED, acked by CLE-001@box-desk" "$T/sat/send.log" && ! grep -q "${B2:0:8}" "$T/sat/send.log"; then
  pass "KILL-MID-ASK: pc's holder acked and died; sat's tick releases the expired lock (open, last holder kept), re-raises it labelled LOCK EXPIRED and counts it"
else fail "lock expiry: $(kqrow "$B1") / $(cat "$T/sat/send.log") / $out"; fi
[[ "$(jq -r .state <<<"$(jrn sat "$B1")")" == open ]] && pass "sat's journal records the release" || fail "journal release: $(jrn sat "$B1")"
HBOX=sat HUB_SKEW=3700 hub ack --fleet kq --id "$B1" --by CLE-001@sat
: >"$T/sat/send.log"
out="$(tick HUB_SKEW=3800 ASKS_LOCK_MIN=60)"
[[ "$(kqrow "$B1" | jq -r .state)" == acked && ! -s "$T/sat/send.log" ]] && pass "the successor's ack takes the lock again (a re-ack renews it)" || fail "renew: $(kqrow "$B1") / $out"

for i in 1 2 3; do hub raise --fleet kq --id "$B2" --by CLE-001@sat; done
out="$(tick HUB_SKEW=3800 ASKS_RERAISE_MIN=0 ASKS_MAX_RAISES=4)"
[[ "$(kqrow "$B2" | jq -r '.state + " " + (.raised_n | tostring)')" == "open 4" ]] && pass "below the delivery limit the ask is re-raised (3 -> 4)" || fail "below the limit: $(kqrow "$B2") / $out"
: >"$T/sat/send.log"
out="$(tick HUB_SKEW=3800 ASKS_RERAISE_MIN=0 ASKS_MAX_RAISES=0)"
[[ "$(kqrow "$B2" | jq -r '.state + " " + (.raised_n | tostring)')" == "open 5" ]] && grep -q "${B2:0:8}" "$T/sat/send.log" &&
  pass "CONTROL: with no delivery limit (the old filter) it is raised again, forever" || fail "no-limit control: $(kqrow "$B2") / $out"
: >"$T/sat/send.log"
out="$(tick HUB_SKEW=3800 ASKS_RERAISE_MIN=0 ASKS_MAX_RAISES=4 ASKS_OWNER_CMD="$T/bin/owner" OWNER_LOG="$T/dlq.log")"
out2="$(tick HUB_SKEW=3800 ASKS_RERAISE_MIN=0 ASKS_MAX_RAISES=4 ASKS_OWNER_CMD="$T/bin/owner" OWNER_LOG="$T/dlq.log")"
dl1="$(sed -n '1p' "$T/dlq.log")"; dl2="$(sed -n '2p' "$T/dlq.log")"
if [[ "$(kqrow "$B2" | jq -r '.state + "|" + .closed_by + "|" + .reason')" == "dead|CLE-001@sat|max delivery count 4 reached (raised 5x); the owner was told" ]] &&
   [[ "$(wc -l <"$T/dlq.log")" -eq 2 && "$(jq -r .ask_id <<<"$dl1")" == "$B2" && "$(jq -r .owner_text <<<"$dl1")" == "**Dead-lettered"* && "$(jq -r .owner_text <<<"$dl1")" == *"Ask id $B2"* ]] &&
   [[ "$(jq -r .owner_text <<<"$dl2")" == "resolved: it was closed because nobody answered" && "$(jq -r .ask_id <<<"$dl2")" == "$B2" && "$(jq -r .owner_task <<<"$dl1")" == "$(jq -r .owner_task <<<"$dl2")" ]] &&
   [[ "$out" != *"reminder resolved"* && "$out2" == *"reminder resolved: it was closed because nobody answered"* ]] &&
   ! grep -q "${B2:0:8}" "$T/sat/send.log" && [[ "$out" == *"dead-letter due 1 (raised >= 4)"* ]]; then
  pass "at the delivery limit: not re-raised, told to the owner ONCE, dead-lettered with the reason; the next tick posts resolved"
else fail "dead-letter: $(kqrow "$B2") / $(cat "$T/dlq.log" 2>/dev/null) / $(cat "$T/sat/send.log") / $out / $out2"; fi
out3="$(tick HUB_SKEW=3800 ASKS_RERAISE_MIN=0 ASKS_MAX_RAISES=4 ASKS_OWNER_CMD="$T/bin/owner" OWNER_LOG="$T/dlq.log")"
[[ "$(wc -l <"$T/dlq.log")" -eq 2 && "$out3" != *"reminder resolved"* ]] && pass "a third tick adds no second resolved reply" || fail "third tick: $(wc -l <"$T/dlq.log") / $out3"
[[ "$(jq -r '.state + " " + .reason' <<<"$(jrn sat "$B2")")" == "dead max delivery count 4 reached (raised 5x); the owner was told" ]] && pass "the journal holds the dead-letter and its reason" || fail "journal dead: $(jrn sat "$B2")"
out="$(on sat 'ASK_ID='"${B2:0:8}"' do_spl_ask_ack' ASKS_FLEET=kq)"; rc=$?
[[ $rc -eq 3 && "$out" == *"already dead by CLE-001@sat"* ]] && pass "a late ack of a dead-lettered ask: exit 3, names who and why" || fail "late ack dead (rc=$rc): $out"
hub put --fleet kq --id "$B3" --kind task --from CLE-002@sat --summary "share-group ${B3:0:4}"
for i in 1 2 3 4; do hub raise --fleet kq --id "$B3" --by CLE-001@sat; done
out="$(tick HUB_SKEW=3800 ASKS_MAX_RAISES=4)"
[[ "$(kqrow "$B3" | jq -r '.state + "|" + .reason')" == "dead|max delivery count 4 reached (raised 4x); no owner leg configured, nobody was told" && "$out" == *"no owner leg is configured"* ]] &&
  pass "no owner leg: at the limit it is still dead-lettered, the reason says nobody was told" || fail "dead no owner: $(kqrow "$B3") / $out"
out="$(on sat do_spl_asks_open ASKS_FLEET=kq)"
[[ "$out" == *"${B1:0:8}"* && "$out" != *"${B2:0:8}"* ]] && pass "the open book drops the dead-lettered asks" || fail "open book: $out"

# 9. no fleet: the journal is the whole book ---------------------------------
printf 'LEASE_ORCH=CLE-001\n' >"$T/pc/spool/dispatch/lease.conf"
out="$(on pc do_spl_asks_open HUB_DOWN=1)"
[[ "$out" == *"${A3:0:8}"* && "$out" == *"hub: off"* ]] && pass "without a fleet the journal alone answers (one-machine behaviour)" || fail "no fleet: $out"

# 11. a book past ARG_MAX (sat 2026-10-03: line 153 "jq: Argument list too long")
python3 - "$T/hub/big.json" <<'PY'
import json, sys, time
t = time.time() - 600
rows = [{"ask_id": "dddddddd-%04d-4444-8444-444444444444" % i, "role": "orch", "kind": "blocker", "from": "CLE-002@sat", "topic": "",
         "summary": "big %04d " % i + "x" * 100000, "deadline_at": "", "state": "open" if i == 0 else "done", "acked_by": "",
         "closed_by": "CLE-001@sat" if i else "", "reason": "", "raised_n": 0, "writer_box": "sat", "c": t + i, "u": t + i} for i in range(30)]
json.dump(rows, open(sys.argv[1], "w"))
PY
book="$(env HUB_DIR="$T/hub" "$T/bin/hub" ask list --fleet big --role orch --all | jq -c .asks)"
err="$(jq -c -n --argjson hub "$book" 'length' 2>&1 >/dev/null)"; rc=$?
(( ${#book} > 3000000 )) && [[ $rc -ne 0 && "$err" == *"Argument list too long"* ]] &&
  pass "CONTROL: the ${#book}-byte book as --argjson (the old line 153) fails: Argument list too long" || fail "big control (rc=$rc, ${#book} bytes): $err"
out="$(on sat do_spl_asks_open ASKS_FLEET=big ASKS_ALL=1 ASKS_FORMAT=json 2>&1)"; rc=$?
n="$(jq -r 'select(.hub == "ok") | .asks | length' <<<"$out" 2>/dev/null | tail -1)"
[[ $rc -eq 0 && "$n" == 30 && "$out" != *"too long"* ]] && pass "do_spl_asks_open lists the ARG_MAX-sized book from the hub (30 rows, hub ok)" || fail "big book (rc=$rc, n=$n): ${out:0:300}"
out="$(on sat do_spl_asks_open ASKS_FLEET=big 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"dddddddd"* && "$out" == *"1 open"* ]] && pass "the table view of the big book shows its one open ask" || fail "big table (rc=$rc): ${out:0:300}"

# 12. the orchestrator's view on a big inbox and the big book (2026-10-03:
# spl-orch-inbox.func.sh lines 42 and 84 "jq: Argument list too long", so
# section 2 and the archive count were silently empty)
ib="$T/sat/spool/CLE-77929/inbox"
python3 - "$ib" <<'PY'
import json, os, sys
d = sys.argv[1]
def put(i, kind, mid, body, ts):
    json.dump({"v": 1, "msg_id": mid, "task_id": "eeeeeeee-%04d" % i, "ts": ts, "from": "CLE-0%03d" % (i % 7 + 2), "to": "CLE-77929",
               "kind": kind, "body": body, "files": []}, open(os.path.join(d, "20261003T080000Z--x--%05d.json" % i), "w"))
put(0, "blocker", "ffffffff-0000-4fff-8fff-ffffffffffff", "untracked big-inbox ask", "2026-10-03T08:00:00Z")
put(1, "blocker", "dddddddd-0000-4444-8444-444444444444", "tracked open ask", "2026-10-03T07:00:00Z")
put(2, "blocker", "dddddddd-0001-4444-8444-444444444444", "tracked closed ask", "2026-10-03T07:00:00Z")
for i in range(3, 5000):
    put(i, "note", "cccccccc-%04d-4ccc-8ccc-cccccccccccc" % i, "big inbox note %d" % i, "2026-10-01T10:00:00Z")
PY
rows="$(on sat 'spl_asks_init && spl_asks_load && printf "%s" "$ASKS_ROWS"' ASKS_FLEET=big 2>/dev/null)"
msgs="$(on sat 'spl_orch_inbox_msgs "'"$ib"'"')"
err="$(jq -r --argjson asks "$rows" '.[0].file' <<<"$msgs" 2>&1 >/dev/null)"; rc=$?
(( ${#rows} > 3000000 )) && [[ "$(jq length <<<"$msgs")" == 5000 && $rc -ne 0 && "$err" == *"Argument list too long"* ]] &&
  pass "CONTROL: 5000 inbox files with the ${#rows}-byte book as --argjson asks (the old lines 42/84) fail: Argument list too long" ||
  fail "big inbox control (rc=$rc, ${#rows} bytes, $(jq length <<<"$msgs") msgs): $err"
out="$(on sat do_spl_orch_inbox ORCH_ID=CLE-77929 ASKS_FLEET=big ORCH_INBOX_KEEP_MIN=0 2>&1)"; rc=$?
o2="$(grep -n '== 2. UNTRACKED' <<<"$out" | cut -d: -f1)"; o3="$(grep -n '== 3. FYI' <<<"$out" | cut -d: -f1)"
sec2="$(sed -n "${o2:-1},${o3:-1}p" <<<"$out")"
[[ $rc -eq 0 && "$out" != *"too long"* && "$sec2" == *"untracked big-inbox ask"* && "$sec2" != *"tracked open ask"* && "$sec2" != *"tracked closed ask"* ]] &&
  pass "view 2 on 5000 inbox files and the big book lists the untracked blocker, not the tracked ones" || fail "big view 2 (rc=$rc): ${out:0:600}"
[[ "$out" == *"INFO 4998 handled message(s) can move to archive/"* ]] &&
  pass "the archive count on the big inbox: 4997 old notes + 1 closed ask = 4998" || fail "big archive count: $(grep -i archive <<<"$out")"

# 13. spec 068 L4: peers - the ask's lock moves to its message --------------
# sat gets 4 seats (peer/seats). A blocker --to orchestrator goes to the hub as
# ONE message to peers (the relay stub below stores it, needs_peer); it is
# journaled as an ask (the book keeps its fields). 4 seats poll; exactly one
# is responsible. asks.sh ack is that message's fence and done its close: the
# responsible seat closes, the other 3 are refused and the book is untouched.
PH="$T/peers"; mkdir -p "$PH"
cat >"$T/bin/peers.py" <<'PY'
import fcntl, json, os, sys, uuid
st = os.environ["PEERS_HUB"]; a = sys.argv[1:]
lk = open(os.path.join(st, "lock"), "w"); fcntl.flock(lk, fcntl.LOCK_EX)
p = os.path.join(st, "db.json"); db = json.load(open(p)) if os.path.exists(p) else []
def save(): json.dump(db, open(p, "w"))
if a[0] != "claim":
    o = dict(zip(a[0::2], a[1::2]))
    if o.get("--to") != "peers": sys.exit(3)
    m = {"msg_id": str(uuid.uuid4()), "task_id": o.get("--task", str(uuid.uuid4())), "ts": "2026-10-03T12:00:00Z", "from": o["--from"], "to": "peers",
         "kind": o["--kind"], "body": o["--body"], "files": [], "needs_peer": True, "responsible": None, "responsible_gen": 0, "handled": ""}
    db.append(m); save(); print(json.dumps({"delivery": "sent", "msg_id": m["msg_id"], "task_id": m["task_id"], "ts": m["ts"]}, separators=(",", ":"))); sys.exit(0)
op = a[1].lstrip("-"); o = dict(zip(a[2::2], a[3::2]))
if op == "done": o = dict(zip(a[3::2], a[4::2])); o["--msg"] = a[2]
seat = o.get("--seat", ""); m = next((r for r in db if r["msg_id"] == o.get("--msg")), None)
if op == "poll":
    out = []
    for r in db:
        if len(out) < int(o["--max"]) and not r["handled"] and r["responsible"] is None:
            r["responsible"] = seat; r["responsible_gen"] += 1; out.append({k: r[k] for k in ("msg_id", "responsible_gen", "task_id", "ts", "from", "to", "kind", "body", "files")})
    save(); print(json.dumps(out)); sys.exit(0)
if op == "check": sys.exit(0 if m and m["responsible"] == seat and m["responsible_gen"] == int(o["--gen"]) else 1)
if op == "done":
    if not m or m["responsible"] != seat:
        print("hub refused: not_responsible (409): %s holds it" % (m and m["responsible"]), file=sys.stderr); sys.exit(1)
    m["handled"] = o.get("--how", "answered"); save(); print("{}"); sys.exit(0)
sys.exit(2)
PY
printf '#!/usr/bin/env bash\nexec python3 "%s/bin/peers.py" "$@"\n' "$T" >"$T/bin/peers"; chmod +x "$T/bin/peers"
# the orc ./run stub asks.sh hands the book close to: one line per call
mkdir -p "$T/orc"; printf '#!/usr/bin/env bash\necho "$2 ASK_ID=$ASK_ID ASK_STATE=${ASK_STATE:-} ASK_BY=${ASK_BY:-}" >>"%s/orc.log"\n' "$T" >"$T/orc/run"; chmod +x "$T/orc/run"
asks() {  # <seat> <asks.sh args...>
  local s="$1"; shift
  local -a e; mapfile -t e < <(menv sat)
  env "${e[@]}" SPOOL_AGENT_ID="$s" ASKS_ORC="$T/orc" ASKS_CLAIM_CMD="$T/bin/peers" PEERS_HUB="$PH" bash "$SCRIPTS/asks.sh" "$@"
}
SEATS="c-001 c-002 g-003 g-004"
mkdir -p "$T/sat/spool/peer"; printf 'c-001 claude\nc-002 claude\ng-003 grok\ng-004 grok\n' >"$T/sat/spool/peer/seats"
mapfile -t e < <(menv sat)
out="$(env "${e[@]}" SPOOL_ASKS_SYNC_CMD=true PEERS_HUB="$PH" SPOOL_FLEET_RELAY=1 SPOOL_FLEET_RELAY_CMD="$T/bin/peers" \
  bash "$SCRIPTS/spool-send.sh" --from CLE-002 --to orchestrator --kind blocker --body 'BLOCKER: peers own this' 2>&1)"
P1="$(msgid "$out")"
[[ -n "$P1" && "$out" == *"orchestrator = peers"* && "$(jq length "$PH/db.json")" == 1 && "$(jq -r '.[0].to' "$PH/db.json")" == peers ]] &&
  pass "peers: one blocker --to orchestrator is ONE hub message to peers" || fail "peers send: $out"
j="$(jrn sat "$P1")"
[[ "$(jq -r '.state + " " + .kind + " " + .to' <<<"$j")" == "open blocker peers" ]] && pass "peers: it is journaled as an ask under the hub msg id (the book keeps its fields)" || fail "peers journal: $j"
for s in $SEATS; do ( PEERS_HUB="$PH" "$T/bin/peers" claim --poll --seat "$s@sat" --max 3 --ttl 120 >"$T/poll.$s" ) & done; wait
R=""; n=0
for s in $SEATS; do
  k="$(jq length "$T/poll.$s")"; n=$((n + k))
  # the poll loop's delivery: the claimed row, with its gen, in the seat's inbox
  (( k > 0 )) && { R="$s"; mkdir -p "$T/sat/spool/$s/inbox"; jq -c '.[0] + {v: 1, to: "'"$s"'"}' "$T/poll.$s" >"$T/sat/spool/$s/inbox/m.json"; }
done
[[ "$n" == 1 && -n "$R" ]] && pass "peers: 4 seats poll one report: exactly 1 responsible ($R)" || fail "peers poll: n=$n"
ok=0; refused=0
for s in $SEATS; do
  if asks "$s" ack "${P1:0:8}" >/dev/null 2>&1; then ok=$((ok + 1)); else [[ $? == 1 ]] && refused=$((refused + 1)); fi
done
[[ "$ok $refused" == "1 3" && "$(asks "$R" ack "${P1:0:8}" 2>&1)" == *"mine"* ]] && pass "peers: ack is the message's fence: 1 seat mine, 3 refused (exit 1)" || fail "peers ack: ok=$ok refused=$refused"
: >"$T/orc.log"
for s in $SEATS; do [[ "$s" == "$R" ]] && continue; asks "$s" "done" "$P1" >/dev/null 2>&1; [[ $? == 1 ]] || fail "peers: $s's done was not refused"; done
[[ "$(jq -r '.[0].handled' "$PH/db.json")" == "" && ! -s "$T/orc.log" ]] && pass "peers: done by the 3 other seats is refused; message open, book untouched" || fail "peers done others: $(cat "$T/orc.log")"
out="$(asks "$R" "done" "${P1:0:8}" 2>&1)"; rc=$?
[[ $rc == 0 && "$(jq -r '.[0].handled' "$PH/db.json")" == answered && "$(cat "$T/orc.log")" == "do_spl_ask_close ASK_ID=$P1 ASK_STATE=done ASK_BY=$R@sat" ]] &&
  pass "peers: the responsible seat's done closes the message (answered), then the ask in the book, by that seat" || fail "peers done (rc=$rc): $out / $(cat "$T/orc.log")"
: >"$T/orc.log"
out="$(SPOOL_TO_PEERS=0 asks "$R" ack "${P1:0:8}" 2>&1)"
[[ "$(cat "$T/orc.log")" == "do_spl_ask_ack ASK_ID=${P1:0:8} ASK_STATE= ASK_BY=" ]] && pass "CONTROL: switch off (SPOOL_TO_PEERS=0): ack is the book's lock again (do_spl_ask_ack)" || fail "control off: $out / $(cat "$T/orc.log")"


# 14. the owner's reminder: plain words, one tap, then resolved -------------
# topic_read: the opening line, 100 characters, and a mention of the whole
# owner id (HUM-10 is not a prefix of HUM-100). A channel post is to ALL-0.
python3 - "$T" <<'PY'
import json, os, sys
t = sys.argv[1]
def w(name, rows):
    with open(os.path.join(t, name), "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
w("title-long.json", [{"ts": "2026-10-04T10:00:00Z", "msg_id": "1", "body": "A" * 101 + "\nrest", "to": "ALL-0", "from": "c-176"}])
w("title-exact.json", [{"ts": "2026-10-04T10:00:00Z", "msg_id": "1", "body": "B" * 100, "to": "ALL-0", "from": "c-176"}])
w("title-miss.json", [
    {"ts": "2026-10-04T10:00:00Z", "msg_id": "1", "body": "Needs a go\nmore", "to": "ALL-0", "from": "c-176"},
    {"ts": "2026-10-04T10:01:00Z", "msg_id": "2", "body": "see @HUM-100", "to": "ALL-0", "from": "c-176"}])
w("title-hit.json", [
    {"ts": "2026-10-04T10:00:00Z", "msg_id": "1", "body": "  Needs   a go  ", "to": "ALL-0", "from": "c-001"},
    {"ts": "2026-10-04T10:02:00Z", "msg_id": "2", "body": "cc @HUM-10 please", "to": "ALL-0", "from": "c-176"}])
w("title-direct.json", [{"ts": "2026-10-04T10:00:00Z", "msg_id": "1", "body": "cc @HUM-10 please", "to": "HUM-10", "from": "c-176"}])
w("title-from.json", [{"ts": "2026-10-04T10:00:00Z", "msg_id": "1", "body": "hello", "to": "ALL-0", "from": "HUM-10"}])
PY
tread() { on sat spl_asks_topic_read ASKS_OWNER=HUM-10 <"$1"; }
got="$(tread "$T/title-long.json")"
[[ "$(jq -r .title <<<"$got")" == "$(python3 -c 'print("A"*100 + "...")')" && "$(jq -r .readable <<<"$got")" == false ]] &&
  pass "topic title: 101 characters collapse to 100 plus an ellipsis, and an unnamed channel is not readable" || fail "long title: $got"
got="$(tread "$T/title-exact.json")"
[[ "$(jq -r .title <<<"$got")" == "$(python3 -c 'print("B"*100)')" && "$(jq -r .readable <<<"$got")" == false ]] &&
  pass "topic title: 100 characters stay whole" || fail "exact title: $got"
got="$(tread "$T/title-miss.json")"
[[ "$(jq -r .title <<<"$got")" == "Needs a go" && "$(jq -r .readable <<<"$got")" == false ]] &&
  pass "a mention of HUM-100 does not name HUM-10; the oldest line is the title" || fail "mention boundary: $got"
got="$(tread "$T/title-hit.json")"
[[ "$(jq -r .title <<<"$got")" == "Needs a go" && "$(jq -r .readable <<<"$got")" == true ]] &&
  pass "whitespace collapses, and @HUM-10 on a channel post is readable" || fail "mention hit: $got"
got="$(tread "$T/title-direct.json")"
[[ "$(jq -r .title <<<"$got")" == "cc @HUM-10 please" && "$(jq -r .readable <<<"$got")" == false ]] &&
  pass "a direct message that names the owner is not a channel topic" || fail "dm: $got"
got="$(tread "$T/title-from.json")"
[[ "$(jq -r .readable <<<"$got")" == true && "$(jq -r .title <<<"$got")" == hello ]] &&
  pass "a channel post from the owner is readable" || fail "from owner: $got"

# the set-aside wording, when the title is known (the dead-letter above has none)
printf '%s\n' '{"ask_id":"abababab-1111-4111-8111-111111111111","from":"CLE-176@sat","topic":"11111111-aaaa-4aaa-8aaa-aaaaaaaaaaa1","summary":"sum","age_s":120,"raised_n":5,"kind":"blocker"}' >"$T/wrow.json"
printf '%s\n' '{"title":"Needs one owner go","readable":true,"channel":"tasks","ask":"Approve it."}' >"$T/wctx.json"
words="$(on sat "spl_asks_owner_words \"\$(cat $T/wrow.json)\" CLE-001@sat true \"\$(cat $T/wctx.json)\" 4" ASKS_OWNER=HUM-10)"
if [[ "$words" == "Topic: Needs one owner go (#tasks)"* && "$words" == *"@HUM-10"* && "$words" == *"Set aside after 5 raises (the limit is 4): nobody answered (2 min)."* &&
      "$words" == *"Waiting: CLE-176."* && "$words" == *"Summary: sum"* && "$words" == *"What to do: Approve it."* && "$words" == *"11111111-aaaa-4aaa-8aaa-aaaaaaaaaaa1"* &&
      "$words" != *"Ask id"* ]]; then
  pass "a dead-letter whose title is known says set aside, who is waiting, and what to do"
else fail "set aside words: $words"; fi

C_TOPIC=11111111-aaaa-4aaa-8aaa-aaaaaaaaaaa1
C_PRIV=22222222-bbbb-4bbb-8bbb-bbbbbbbbbbb2
C_MISS=33333333-cccc-4ccc-8ccc-ccccccccccc3
C_READ=dddddddd-1414-4141-8141-aaaaaaaaaaa1
C_NOR=eeeeeeee-2424-4242-8242-bbbbbbbbbbb2
C_OLD=ffffffff-3434-4343-8343-ccccccccccc3
cat >"$T/bin/topic" <<EOF
#!/usr/bin/env bash
case "\$1" in
  $C_TOPIC) printf '%s\n' '{"title":"Needs one owner go","readable":true,"channel":"tasks","ask":"Approve the repo-settings change."}' ;;
  $C_PRIV) printf '%s\n' '{"title":"Private thread","readable":false}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/topic"
hub put --fleet ctx --id "$C_READ" --kind blocker --from CLE-176@sat --topic "$C_TOPIC" --summary "needs one owner go, a repo-settings change"
hub put --fleet ctx --id "$C_NOR" --kind blocker --from CLE-176@sat --topic "$C_PRIV" --summary "the private summary"
hub put --fleet ctx --id "$C_OLD" --kind task --from CLE-002@sat --topic "$C_MISS" --summary "lookup misses"
: >"$T/ctx.log"
ctx_tick() { on sat do_spl_asks_tick ASKS_FLEET=ctx ASKS_RERAISE_MIN=99 ASKS_OWNER_MIN=0 ASKS_MAX_RAISES=0 ASKS_OWNER=HUM-10 ASKS_OWNER_CMD="$T/bin/owner" ASKS_TOPIC_CMD="$T/bin/topic" OWNER_LOG="$T/ctx.log" HUB_SKEW=0; }
ctx_row() { jq -c --arg id "$1" 'select(.ask_id == $id and (.owner_text | startswith("resolved:") | not))' "$T/ctx.log"; }
out="$(ctx_tick)"
rread="$(ctx_row "$C_READ")"; rnor="$(ctx_row "$C_NOR")"; rold="$(ctx_row "$C_OLD")"
uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [[ "$(jq -r .owner_task <<<"$rread")" == "$C_TOPIC" && "$(jq -r .owner_text <<<"$rread")" == "Topic: Needs one owner go (#tasks)"* &&
      "$(jq -r .owner_text <<<"$rread")" == *"@HUM-10"* && "$(jq -r .owner_text <<<"$rread")" == *"Waiting: CLE-176."* &&
      "$(jq -r .owner_text <<<"$rread")" == *"Summary: needs one owner go, a repo-settings change"* &&
      "$(jq -r .owner_text <<<"$rread")" == *"What to do: Approve the repo-settings change."* &&
      "$(jq -r .owner_text <<<"$rread")" == *"$C_TOPIC"* && "$(jq -r .owner_text <<<"$rread")" != *"Ask id"* &&
      "$(jq -r .owner_text <<<"$rread")" != *"$C_READ"* ]]; then
  pass "a readable channel topic: the reminder is a reply in it, in plain words, with the topic uuid"
else fail "readable reminder: $rread"; fi
if [[ "$(jq -r .owner_task <<<"$rnor")" != "$C_PRIV" && "$(jq -r .owner_task <<<"$rnor")" =~ $uuid_re &&
      "$(jq -r .owner_text <<<"$rnor")" == "Topic: Private thread"* && "$(jq -r .owner_text <<<"$rnor")" == *"$C_PRIV"* &&
      "$(jq -r .owner_text <<<"$rnor")" != *"@HUM-10"* && "$(jq -r .owner_text <<<"$rnor")" != *"Ask id"* &&
      "$(jq -r .owner_text <<<"$rnor")" == *"Waiting: CLE-176."* && "$(jq -r .owner_text <<<"$rnor")" == *"Summary: the private summary"* ]]; then
  pass "a title the owner cannot read: a new topic that names the title and the source uuid"
else fail "unreadable reminder: $rnor"; fi
if [[ "$(jq -r .owner_task <<<"$rold")" != "$C_MISS" && "$(jq -r .owner_task <<<"$rold")" =~ $uuid_re &&
      "$(jq -r .owner_text <<<"$rold")" == "**Unanswered ask to the orchestrator ("* &&
      "$(jq -r .owner_text <<<"$rold")" == *"re-raised 0x"* && "$(jq -r .owner_text <<<"$rold")" == *"Ask id $C_OLD"* &&
      "$(jq -r .owner_text <<<"$rold")" == *"topic $C_MISS"* ]]; then
  pass "a topic lookup that fails keeps the old id line and a new topic"
else fail "lookup miss: $rold"; fi
[[ "$(sed -n '1p' "$T/sat/spool/asks/.owner-told.$C_READ")" == "$C_TOPIC" ]] && pass "the reminder topic is recorded beside the ask" || fail "sidecar: $(cat "$T/sat/spool/asks/.owner-told.$C_READ" 2>/dev/null)"
on sat "ASK_ID=${C_READ:0:8} do_spl_ask_ack" ASKS_FLEET=ctx >/dev/null
out="$(ctx_tick)"
res="$(jq -c --arg id "$C_READ" 'select(.ask_id == $id and (.owner_text | startswith("resolved:")))' "$T/ctx.log")"
[[ "$(jq -r .owner_text <<<"$res")" == "resolved: the orchestrator acknowledged it" && "$(jq -r .owner_task <<<"$res")" == "$C_TOPIC" && "$out" == *"reminder resolved: the orchestrator acknowledged it"* ]] &&
  pass "an acked ask posts one resolved reply in the reminder's topic" || fail "resolved: $res / $out"
out="$(ctx_tick)"
[[ "$(jq -c --arg id "$C_READ" 'select(.ask_id == $id and (.owner_text | startswith("resolved:")))' "$T/ctx.log" | wc -l)" -eq 1 && "$out" != *"reminder resolved"* ]] &&
  pass "the resolved reply is posted once" || fail "resolved twice: $(cat "$T/ctx.log") / $out"

echo
if (( fails > 0 )); then echo "asks.tst.sh: $fails FAILED"; exit 1; fi
echo "asks.tst.sh: all passed"
