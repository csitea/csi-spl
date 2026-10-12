#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spawn requests wait in a DB queue with a position and a placer
#          takes the head when there is room (owner HUM-10, t1 c9beaa77 msg
#          ca668844; rdb 0180). The hub is a stub with the contract of
#          `spool ask` plus ask_op queue (positions by enqueued_at per role).
#   1. enqueue: the sender is told "queued, position N of M" on its task (an
#      owner topic uuid becomes dispatch-<topic8>); a second request is 2 of 2
#   2. the asks tick past ASKS_OWNER_MIN and the re-raise time: a queued ask
#      is never re-raised, escalated or dead-lettered (CONTROL: the same ask
#      left open IS raised and told to the owner)
#   3. ceiling full (40 windows) -> stays queued; the load target says hold
#      -> stays queued; a machine that does not hold the orch role places
#      nothing
#   4. the ceiling frees -> the head is launched (placement + brief), closed
#      "placed: <ID>@<box>", its sender told; the next one moves to 1 of 1
#   5. the gap: a second placement waits SPAWN_PLACE_GAP_MIN
#   6. no placement -> ONE blocker to the holder, the ask is placing; the
#      next tick places nothing else (one at a time); past
#      SPAWN_PLACE_LOCK_MIN it goes back to position 1; do_spl_spawn_placed
#      closes it and tells the sender
#   7. the launcher's HOLD (exit 10) puts it back at position 1
#   8. do_spl_spawn_queue lists POS, sender and summary
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hub" "$T/briefs"
export SPOOL_TEST=1

# The hub stub: rdb 0097 + 0099 + 0180 rows in one JSON file, epoch times.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]
assert a[0] == "ask"; op = a[1]; kv = {}; i = 2
while i < len(a):
    if a[i] == "--all": kv["all"] = True; i += 1
    else: kv[a[i][2:]] = a[i + 1]; i += 2
path = os.path.join(os.environ["HUB_DIR"], kv["fleet"] + ".json")
rows = json.load(open(path)) if os.path.exists(path) else []
now = time.time() + float(os.environ.get("HUB_SKEW", "0"))
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else ""
OPEN = ("open", "acked", "queued")
def positions():
    for role in set(r["role"] for r in rows):
        q = sorted([r for r in rows if r["role"] == role and r["state"] == "queued"], key=lambda r: (r["q"], r["ask_id"]))
        for n, r in enumerate(q): r["position"], r["queue_len"] = n + 1, len(q)
    for r in rows:
        if r["state"] != "queued": r["position"], r["queue_len"] = 0, 0
def out(r):
    o = dict(r); o["age_s"] = int(now - r["c"]); o["quiet_s"] = int(now - max(r["u"], r.get("r") or 0))
    o["created_at"], o["updated_at"], o["raised_at"], o["escalated_at"], o["enqueued_at"] = iso(r["c"]), iso(r["u"]), iso(r.get("r")), iso(r.get("e")), iso(r.get("q"))
    for k in ("c", "u", "r", "e", "q"): o.pop(k, None)
    for k in ("acked_by", "closed_by", "reason", "raised_at", "escalated_at", "enqueued_at", "placement", "position", "queue_len"):
        if o.get(k) in ("", 0): o.pop(k, None)
    return o
def save(): json.dump(rows, open(path, "w"))
def answer(sel, created=False):
    positions(); print(json.dumps({"fleet": kv["fleet"], "created": created, "asks": [out(r) for r in sel]})); sys.exit(0)
if op == "list":
    sel = [r for r in rows if (kv.get("all") or r["state"] in OPEN) and kv.get("role", "") in ("", r["role"])]
    sel.sort(key=lambda r: (r["state"] not in OPEN, r["c"]))
    answer(sel)
if op == "put":
    for r in rows:
        if r["ask_id"] == kv["id"]: answer([r])
    r = {"ask_id": kv["id"], "role": kv.get("role") or "orch", "kind": kv["kind"], "from": kv["from"], "topic": kv.get("topic", ""),
         "summary": kv.get("summary", ""), "state": "open", "acked_by": "", "closed_by": "", "reason": "", "raised_n": 0,
         "placement": "", "writer_box": os.environ.get("SPOOL_DESK_BOX", "box-desk"), "c": now, "u": now}
    rows.append(r); save(); answer([r], True)
for r in rows:
    if r["ask_id"] != kv["id"]: continue
    if r["state"] not in OPEN:
        print("hub refused: ask_closed (409): already %s by %s: %s" % (r["state"], r["closed_by"], r["reason"]), file=sys.stderr); sys.exit(1)
    if op == "ack": r["state"], r["acked_by"], r["u"] = "acked", kv["by"], now
    elif op in ("done", "decline", "dead"):
        r["state"], r["closed_by"], r["reason"], r["u"] = {"done": "done", "decline": "declined", "dead": "dead"}[op], kv["by"], kv.get("reason", ""), now
    elif op == "raise": r["raised_n"] += 1; r["r"] = now
    elif op == "escalate": r["e"] = now
    elif op == "release":
        if r["state"] == "acked": r["state"] = "open"
    elif op == "queue":
        r["state"], r["u"] = "queued", now
        r.setdefault("q", now)
        if kv.get("placement"): r["placement"] = kv["placement"]
    else:
        print("hub refused: bad_frame (400): ask_op", file=sys.stderr); sys.exit(1)
    save(); answer([r])
print("hub refused: unknown_ask (404): no such ask in this fleet", file=sys.stderr); sys.exit(1)
STUB
chmod +x "$T/bin/hub"

# spool-send.sh stub: one line per message "<from> <to> <kind> <task> <body>".
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2;; --to) to="$2"; shift 2;; --kind) kind="$2"; shift 2;;
  --task) task="$2"; shift 2;; --body) body="$2"; shift 2;; --no-ask) shift;; *) shift 2;; esac; done
printf '%s %s %s %s %s\n' "$from" "$to" "$kind" "$task" "$(tr '\n' ' ' <<<"$body")" >>"$SEND_LOG"
STUB
chmod +x "$T/bin/send"
cat >"$T/bin/owner" <<'STUB'
#!/usr/bin/env bash
cat >>"$OWNER_LOG"
STUB
chmod +x "$T/bin/owner"
# the launcher stub: prints "<ID> <PANE>" (LAUNCH_ID), or exits LAUNCH_RC
cat >"$T/bin/launch" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$LAUNCH_LOG"
echo "spawn-window: c-001 asked for $2" >&2
[ "${LAUNCH_RC:-0}" = 0 ] || exit "$LAUNCH_RC"
echo "${LAUNCH_ID:-c-281} %42"
STUB
chmod +x "$T/bin/launch"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\necho "${WINDOWS:-12}"\n' >"$T/bin/windows"; chmod +x "$T/bin/windows"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\necho "pick=${PICK:-box-desk reason=below its low mark}"\n' >"$T/bin/pick"; chmod +x "$T/bin/pick"
echo "brief text" >"$T/briefs/hub-pg-split.md"

for m in pc sat; do
  mkdir -p "$T/$m/spool/c-001/inbox" "$T/$m/spool/dispatch"
  printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$T/$m/spool/dispatch/lease.conf"
done

menv() {
  local m="$1" box=box-desk; [[ "$m" == sat ]] && box=sat
  printf '%s\n' "SPOOL_ROOT=$T/$m/spool" "SPOOL_BOX_ENV=$T/$m/spool/box.env" "SPOOL_DESK_BOX=$box" \
    "ASKS_HUB_CMD=$T/bin/hub" "HUB_DIR=$T/hub" "SPOOL_ORCHESTRATOR_ID=c-001" "SPOOL_FLEET_RELAY=0" \
    "ASKS_HOLDER=c-001@box-desk" "SPAWN_QUEUE_SEND=$T/bin/send" "ASKS_SEND=$T/bin/send" "SEND_LOG=$T/send.log" \
    "ASKS_OWNER_CMD=$T/bin/owner" "OWNER_LOG=$T/owner.log" "ASKS_MAX_RAISES=4" \
    "SPAWN_PLACE_WINDOWS_CMD=$T/bin/windows" "SPAWN_PLACE_PICK_CMD=$T/bin/pick" "SPAWN_PLACE_LAUNCH_CMD=$T/bin/launch" \
    "LAUNCH_LOG=$T/launch.log" "SPAWN_PLACE_BRIEF_DIR=$T/briefs" "SPAWN_PLACE_WORKDIR=$T" "SPAWN_PLACE_GAP_MIN=0" "SPOOL_AGENT_ID="
}
on() {  # <machine> <action> [env...]
  local m="$1" a="$2"; shift 2
  local -a e; mapfile -t e < <(menv "$m")
  # shellcheck disable=SC2016 # the action runs in the child shell
  env "${e[@]}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-ask-ack spl-asks-tick spl-spawn-queue spl-spawn-enqueue spl-spawn-placed spl-spawn-place; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    '"$a"
}
hubrow() { jq -c --arg i "$1" '.[] | select(.ask_id == $i)' "$T/hub/main.json" 2>/dev/null; }
listrow() { HUB_DIR="$T/hub" "$T/bin/hub" ask list --fleet main --role orch | jq -c --arg i "$1" '.asks[] | select(.ask_id == $i)'; }
put() {  # ID FROM TOPIC SUMMARY
  HUB_DIR="$T/hub" "$T/bin/hub" ask put --fleet main --id "$1" --kind task --role orch --from "$2" --topic "$3" --summary "$4" >/dev/null
}
sends() { cat "$T/send.log" 2>/dev/null; }
A1=a1a1a1a1-0000-4000-8000-000000000001
A2=a2a2a2a2-0000-4000-8000-000000000002
A3=a3a3a3a3-0000-4000-8000-000000000003
A4=a4a4a4a4-0000-4000-8000-000000000004
OWNER_TOPIC=c9beaa77-1111-4222-8333-444455556666

# 1. enqueue --------------------------------------------------------------------
put "$A1" c-002@box-desk "$OWNER_TOPIC" "SPAWN REQUEST hub-pg-split"
put "$A2" c-002@sat dispatch-c9beaa77-x "SPAWN REQUEST gmail checkboxes"
out="$(on pc do_spl_spawn_enqueue ASK_ID="${A1:0:8}" SPAWN_PLACE=claude:hub-pg-split 2>&1)"
r="$(hubrow "$A1")"
if [[ "$(jq -r .state <<<"$r")" == queued && "$(jq -r .placement <<<"$r")" == claude:hub-pg-split ]] &&
   grep -q "^c-001 c-002 note dispatch-c9beaa77 queued, position 1 of 1, placed when the box has room" "$T/send.log"; then
  pass "enqueue: queued with its placement; the sender is told 'position 1 of 1' on dispatch-<topic8>, never the owner topic"
else fail "enqueue: $out | $r | $(sends)"; fi
on pc do_spl_spawn_enqueue ASK_ID="$A2" >/dev/null 2>&1
if grep -q "^c-001 c-002@sat note dispatch-c9beaa77-x queued, position 2 of 2," "$T/send.log"; then
  pass "enqueue: the second request is position 2 of 2, told on its own task, another box's sender as <ID>@<box>"
else fail "second enqueue: $(sends)"; fi
[[ "$(jq -r .state "$T/pc/spool/asks/$A1.json" 2>/dev/null)" == queued ]] &&
  pass "enqueue: the journal mirrors the queued row" || fail "journal: $(cat "$T/pc/spool/asks/$A1.json" 2>&1)"
if ! on pc do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_PLACE='claude:x;rm' >/dev/null 2>&1; then
  pass "enqueue: a placement that is not <vendor>:<slug> is refused"
else fail "a bad placement was taken"; fi

# 2. the asks tick never raises a queued ask (CONTROL: an open one) ---------------
put "$A3" c-002@box-desk dispatch-c9beaa77-y "an ordinary blocker"
: >"$T/send.log"
on pc do_spl_asks_tick HUB_SKEW=$((5 * 3600)) ASKS_RERAISE_MIN=15 ASKS_OWNER_MIN=60 >/dev/null 2>&1
on pc do_spl_asks_tick HUB_SKEW=$((6 * 3600)) ASKS_RERAISE_MIN=15 ASKS_OWNER_MIN=60 >/dev/null 2>&1
r1="$(hubrow "$A1")"; r3="$(hubrow "$A3")"
if [[ "$(jq -r .state <<<"$r1")" == queued && "$(jq -r .raised_n <<<"$r1")" == 0 && "$(jq -r '.e // ""' <<<"$r1")" == "" ]] &&
   ! grep -q "$A1\|${A1:0:8}" "$T/send.log" "$T/owner.log" 2>/dev/null; then
  pass "a queued ask 6 h old (past ASKS_OWNER_MIN and the re-raise time): 0 raises, 0 owner reminders, still queued"
else fail "the tick touched a queued ask: $r1 | $(sends) | $(cat "$T/owner.log" 2>/dev/null)"; fi
if (( $(jq -r .raised_n <<<"$r3") > 0 )) || [[ "$(jq -r '.e // ""' <<<"$r3")" != "" ]]; then
  pass "control: the same tick raised or escalated the open ask (raised_n $(jq -r .raised_n <<<"$r3"))"
else fail "control: the open ask was not raised either - the tick did not run: $r3"; fi
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$A3" --by c-001@box-desk --reason test >/dev/null

# 3. no room ---------------------------------------------------------------------
: >"$T/send.log"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place WINDOWS=40 2>&1)"
if [[ "$(jq -r .state <<<"$(hubrow "$A1")")" == queued && ! -s "$T/launch.log" ]] && grep -q "hold: agent windows 40 >= the ceiling 40" <<<"$out"; then
  pass "ceiling full (40 windows): the head stays queued, nothing launched, the hold says why"
else fail "ceiling: $out | $(hubrow "$A1")"; fi
out="$(on pc do_spl_spawn_place PICK='hold reason=every box past its overflow mark' 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$A1")")" == queued && ! -s "$T/launch.log" ]] && grep -q "load target says hold" <<<"$out" &&
  pass "the fleet load target says hold: the head stays queued" || fail "load hold: $out"
out="$(on sat do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$A1")")" == queued && ! -s "$T/launch.log" ]] &&
  pass "a machine that does not hold the orch role places nothing" || fail "non-holder: $out"

# 4. the ceiling frees: the head is placed ----------------------------------------
out="$(on pc do_spl_spawn_place WINDOWS=39 2>&1)"
r1="$(hubrow "$A1")"
if [[ "$(jq -r .state <<<"$r1")" == "done" && "$(jq -r .reason <<<"$r1")" == "placed: c-281@box-desk" ]] &&
   grep -q "^claude auto $T $T/briefs/hub-pg-split.md hub-pg-split$" "$T/launch.log" &&
   grep -q "^c-001 c-002 note dispatch-c9beaa77 placed: c-281@box-desk" "$T/send.log"; then
  pass "room (39/40): the head is launched with its brief, closed 'placed: c-281@box-desk', its sender told"
else fail "place: $out | $r1 | $(cat "$T/launch.log") | $(sends)"; fi
r2="$(listrow "$A2")"
[[ "$(jq -r .position <<<"$r2")" == 1 && "$(jq -r .queue_len <<<"$r2")" == 1 ]] &&
  pass "the next request moves up: position 1 of 1" || fail "shift: $r2"

# 5. the gap ---------------------------------------------------------------------
out="$(on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$A2")")" == queued ]] && grep -q "last placement started under 10 min ago" <<<"$out" &&
  pass "SPAWN_PLACE_GAP_MIN: the next placement waits" || fail "gap: $out"

# 6. no placement: handed to the holder, one at a time, the lock, placed by hand ------
: >"$T/send.log"
put "$A4" c-002@box-desk dispatch-c9beaa77-z "SPAWN REQUEST perf5"
on pc do_spl_spawn_enqueue ASK_ID="$A4" >/dev/null 2>&1
: >"$T/send.log"
out="$(on pc do_spl_spawn_place 2>&1)"
if [[ "$(jq -r .state <<<"$(hubrow "$A2")")" == acked ]] &&
   grep -q "^c-001 c-001 blocker spawn-queue \*\*SPAWN QUEUE: place ask ${A2:0:8} now\*\*.*no placement was recorded.*PLACED_AS=<ID>@<box> ./run -a do_spl_spawn_placed" "$T/send.log"; then
  pass "no placement: ONE blocker to the holder with the close command; the ask is placing"
else fail "hand: $out | $(sends)"; fi
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$A4")")" == queued && "$(grep -c . "$T/send.log")" == 1 ]] && grep -q "one at a time" <<<"$out" &&
  pass "one at a time: while one is placing the next stays queued" || fail "one at a time: $out | $(sends)"
out="$(on pc do_spl_spawn_place HUB_SKEW=$((31 * 60)) 2>&1)"
r2="$(hubrow "$A2")"
if grep -q "not placed within 30 min: back in line" <<<"$out" && [[ "$(jq -r .state <<<"$r2")" == acked ]] &&
   [[ "$(grep -c "place ask ${A2:0:8} now" "$T/send.log")" == 2 ]]; then
  pass "SPAWN_PLACE_LOCK_MIN: a stalled placement goes back at position 1 and is handed again before the one behind it"
else fail "lock: $out | $r2 | $(sends)"; fi
: >"$T/send.log"
out="$(on pc do_spl_spawn_placed ASK_ID="${A2:0:8}" PLACED_AS=c-282@sat 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$A2")")" == "placed: c-282@sat" ]] && grep -q "^c-001 c-002@sat note dispatch-c9beaa77-x placed: c-282@sat" "$T/send.log" &&
  pass "do_spl_spawn_placed: done 'placed: c-282@sat', the sender told" || fail "placed: $out | $(sends)"
on pc do_spl_spawn_placed ASK_ID="${A2:0:8}" PLACED_AS=x >/dev/null 2>&1 && fail "a bad PLACED_AS was taken" ||
  pass "do_spl_spawn_placed refuses a PLACED_AS that is not <ID>@<box>"

# 7. the launcher's HOLD --------------------------------------------------------------
HUB_DIR="$T/hub" "$T/bin/hub" ask queue --fleet main --id "$A4" --by c-001@box-desk --placement claude:hub-pg-split >/dev/null
out="$(on pc do_spl_spawn_place LAUNCH_RC=10 2>&1)"
r4="$(listrow "$A4")"
[[ "$(jq -r .state <<<"$r4")" == queued && "$(jq -r .position <<<"$r4")" == 1 ]] && grep -q "launcher says HOLD" <<<"$out" &&
  pass "spawn-window HOLD (exit 10): back in line at position 1" || fail "launcher hold: $out | $r4"

# 8. the queue view --------------------------------------------------------------------
out="$(on pc do_spl_spawn_queue 2>&1)"
grep -qE "^1/1 +${A4:0:8} +c-002@box-desk .*claude:hub-pg-split .*SPAWN REQUEST perf5" <<<"$out" &&
  pass "do_spl_spawn_queue: POS, ask, sender, placement and summary" || fail "queue view: $out"
[[ "$(on pc do_spl_spawn_queue SPAWN_QUEUE_FORMAT=json 2>/dev/null | jq -r '.queue[0].position')" == 1 ]] &&
  pass "do_spl_spawn_queue json" || fail "queue json"

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
