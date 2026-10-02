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
        if r["state"] in ("done", "declined"):
            print("hub refused: ask_closed (409): already %s by %s: %s" % (r["state"], r["closed_by"], r["reason"]), file=sys.stderr); sys.exit(1)
        if op == "ack": r["state"], r["acked_by"], r["u"] = "acked", kv["by"], now
        elif op in ("done", "decline"):
            if op == "decline" and not kv.get("reason"):
                print("hub refused: bad_frame (400): a decline needs a reason", file=sys.stderr); sys.exit(1)
            r["state"], r["closed_by"], r["reason"], r["u"] = ("done" if op == "done" else "declined"), kv["by"], kv.get("reason", ""), now
        elif op == "raise": r["raised_n"] += 1; r["r"] = now
        elif op == "escalate": r["e"] = now
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
printf '#!/usr/bin/env bash\necho "$ASK_JSON" >>"$OWNER_LOG"\n' >"$T/bin/owner"; chmod +x "$T/bin/owner"

for m in pc sat; do
  mkdir -p "$T/$m/spool/CLE-001/inbox" "$T/$m/spool/CLE-002/inbox" "$T/$m/spool/CLE-77929/inbox" "$T/$m/spool/dispatch"
  printf 'LEASE_ORCH=CLE-001\nLEASE_FLEET=main\n' >"$T/$m/spool/dispatch/lease.conf"
done

# env for a machine: its root, its box, the hub stub
menv() {
  local m="$1" box=box-desk; [[ "$m" == sat ]] && box=sat
  printf '%s\n' "SPOOL_ROOT=$T/$m/spool" "SPOOL_BOX_ENV=$T/$m/spool/box.env" "SPOOL_DESK_BOX=$box" \
    "ASKS_HUB_CMD=$T/bin/hub" "HUB_DIR=$T/hub" "SPOOL_BIN=$T/bin/spool" "SPOOL_ORCHESTRATOR_ID=CLE-001" \
    "SPOOL_TMUX_SOCKET=$T/tmux.sock" "SPOOL_FLEET_RELAY=0" "ASKS_SEND=$T/bin/send" "SEND_LOG=$T/$m/send.log"
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
msgid() { sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p' <<<"$1" | head -1; }
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
on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=15 >/dev/null
[[ ! -s "$T/sat/send.log" ]] && pass "no re-raise inside ASKS_RERAISE_MIN" || fail "early re-raise: $(cat "$T/sat/send.log")"
on sat 'ASK_ID='"${A1:0:8}"' do_spl_ask_ack' ASKS_FLEET=main >/dev/null
[[ "$(hubrow "$A1" | jq -r '.state + " " + .acked_by')" == "acked CLE-001@sat" ]] && pass "ack: in progress, by CLE-001@sat (the default actor is this machine's orchestrator)" || fail "ack: $(hubrow "$A1")"
on sat do_spl_asks_tick ASKS_FLEET=main ASKS_RERAISE_MIN=0 >/dev/null
if grep -q "ASKS STILL OPEN: 1 ask(s)" "$T/sat/send.log" && grep -q "${A2:0:8}" "$T/sat/send.log" && ! grep -q "${A1:0:8}" "$T/sat/send.log"; then
  pass "re-raise: the unacked ask goes again in one message; the acked one (no deadline) does not"
else fail "re-raise: $(cat "$T/sat/send.log")"; fi

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

# 9. no fleet: the journal is the whole book ---------------------------------
printf 'LEASE_ORCH=CLE-001\n' >"$T/pc/spool/dispatch/lease.conf"
out="$(on pc do_spl_asks_open HUB_DOWN=1)"
[[ "$out" == *"${A3:0:8}"* && "$out" == *"hub: off"* ]] && pass "without a fleet the journal alone answers (one-machine behaviour)" || fail "no fleet: $out"

echo
if (( fails > 0 )); then echo "asks.tst.sh: $fails FAILED"; exit 1; fi
echo "asks.tst.sh: all passed"
