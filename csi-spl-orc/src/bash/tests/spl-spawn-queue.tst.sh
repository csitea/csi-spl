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
#  10. SPL-1817 (rdb 0195, owner t1 3209f8b8 msg 8cb6cc7d): an enqueue with
#      no class, a bad one, an urgent feature or a bypass of a bug is refused;
#      the queue orders by class; the placer takes the class furthest under
#      its band of the live lanes (CONTROL: the queue's own head is another
#      row), a ci head or a bypass as it is; unknown lanes are left out; the
#      supply blocker goes to the dispatch holder once per gap (CONTROL: none
#      while a row of that class is queued); do_spl_spawn_share lists the
#      shares, verdicts and the bypass
#  11. SPL-2042: a queue of [handed ask, launchable ask] places the
#      launchable one in the next tick; a stalled hand-off back at position
#      1 waits behind a launchable ask; a launch in flight keeps one at a time
#  12. SPL-2088: a hand-pinned slug (hand-<box>-<slug>, <box>hand-<slug>)
#      finds the brief of <slug> and launches with SPAWN_BOX=<box>; the
#      pinned box past its overflow mark HOLDs it (CONTROL: under it, it
#      launches); a hand-off touches no .place.last (CONTROL: a launch does)
#  13. SPL-2263: a mistral placement whose brief names csi-spl-wui/ launches
#      claude (CONTROL: a docs brief stays mistral)
#   9. do_spl_spawn_place_install_cron writes ONE line whose PATH has
#      /usr/local/bin (yq lives there; cron's own PATH is /usr/bin:/bin) and
#      runs under flock -n; idempotent; remove takes only its line
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
RANK = {"ci": 0, "refactor": 2, "bug": 3, "feature": 4}
def rank(r): return 1 if r.get("flag") and r.get("class") != "ci" else RANK.get(r.get("class", ""), 5)
def positions():
    for role in set(r["role"] for r in rows):
        q = sorted([r for r in rows if r["role"] == role and r["state"] == "queued"], key=lambda r: (rank(r), r["q"], r["ask_id"]))
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
        if not (kv.get("class") or r.get("class")):
            print("hub refused: bad_frame (400): a queued ask needs class ci, refactor, bug or feature", file=sys.stderr); sys.exit(1)
        if kv.get("class"): r["class"] = kv["class"]
        if kv.get("flag"): r["flag"], r["flag_msg"], r["flag_by"], r["flag_at"] = kv["flag"], kv.get("flag-msg", ""), kv["by"], iso(now)
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
# the lane map stub: {lanes: $LANES} (an array of {agent_id, agent_box, state})
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\necho "{\\"lanes\\": ${LANES:-[]}}"\n' >"$T/bin/lanes"; chmod +x "$T/bin/lanes"
# the launcher stub: prints "<ID> <PANE>" (LAUNCH_ID), or exits LAUNCH_RC
cat >"$T/bin/launch" <<'STUB'
#!/usr/bin/env bash
echo "$*${SPAWN_BOX:+ SPAWN_BOX=$SPAWN_BOX}" >>"$LAUNCH_LOG"
echo "spawn-window: c-001 asked for $2" >&2
[ -z "${LAUNCH_ERR:-}" ] || echo "$LAUNCH_ERR" >&2
[ "${LAUNCH_RC:-0}" = 0 ] || exit "$LAUNCH_RC"
echo "${LAUNCH_ID:-c-281} %42"
STUB
chmod +x "$T/bin/launch"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\necho "${WINDOWS:-12}"\n' >"$T/bin/windows"; chmod +x "$T/bin/windows"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\n[ -z "${PICK_BOXES:-}" ] || echo "$PICK_BOXES"\necho "pick=${PICK:-box-desk reason=below its low mark}"\n' >"$T/bin/pick"; chmod +x "$T/bin/pick"
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
    "LAUNCH_LOG=$T/launch.log" "SPAWN_PLACE_BRIEF_DIR=$T/briefs" "SPAWN_PLACE_WORKDIR=$T" "SPAWN_PLACE_GAP_MIN=0" "SPOOL_AGENT_ID=" \
    "SPAWN_SHARE_LANES_CMD=$T/bin/lanes" "SPAWN_SHARE_DISPATCH=c-002@box-desk"
}
on() {  # <machine> <action> [env...]
  local m="$1" a="$2"; shift 2
  local -a e; mapfile -t e < <(menv "$m")
  # shellcheck disable=SC2016 # the action runs in the child shell
  env "${e[@]}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-ask-ack spl-asks-tick spl-spawn-queue spl-spawn-share spl-spawn-enqueue spl-spawn-placed spl-spawn-place; do
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
out="$(on pc do_spl_spawn_enqueue ASK_ID="${A1:0:8}" SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split 2>&1)"
r="$(hubrow "$A1")"
if [[ "$(jq -r .state <<<"$r")" == queued && "$(jq -r .placement <<<"$r")" == claude:hub-pg-split ]] &&
   grep -q "^c-001 c-002 note dispatch-c9beaa77 queued, position 1 of 1, placed when the box has room" "$T/send.log"; then
  pass "enqueue: queued with its placement; the sender is told 'position 1 of 1' on dispatch-<topic8>, never the owner topic"
else fail "enqueue: $out | $r | $(sends)"; fi
on pc do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_CLASS=bug >/dev/null 2>&1
if grep -q "^c-001 c-002@sat note dispatch-c9beaa77-x queued, position 2 of 2," "$T/send.log"; then
  pass "enqueue: the second request is position 2 of 2, told on its own task, another box's sender as <ID>@<box>"
else fail "second enqueue: $(sends)"; fi
[[ "$(jq -r .state "$T/pc/spool/asks/$A1.json" 2>/dev/null)" == queued ]] &&
  pass "enqueue: the journal mirrors the queued row" || fail "journal: $(cat "$T/pc/spool/asks/$A1.json" 2>&1)"
if ! on pc do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_CLASS=bug SPAWN_PLACE='claude:x;rm' >/dev/null 2>&1; then
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
on pc do_spl_spawn_enqueue ASK_ID="$A4" SPAWN_CLASS=bug >/dev/null 2>&1
: >"$T/send.log"
out="$(on pc do_spl_spawn_place 2>&1)"
if [[ "$(jq -r .state <<<"$(hubrow "$A2")")" == acked ]] &&
   grep -q "^c-001 c-001 blocker spawn-queue \*\*SPAWN QUEUE: place ask ${A2:0:8} now\*\*.*no placement was recorded.*PLACED_AS=<ID>@<box> ./run -a do_spl_spawn_placed" "$T/send.log"; then
  pass "no placement: ONE blocker to the holder with the close command; the ask is placing"
else fail "hand: $out | $(sends)"; fi
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$A4")")" == queued && "$(grep -c . "$T/send.log")" == 1 ]] && grep -q "ask ${A2:0:8} is with the holder" <<<"$out" &&
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
out="$(on pc do_spl_spawn_place LAUNCH_RC=10 "LAUNCH_ERR=spawn-window: HOLD auto: waiting: claude weekly >= 90% on box-a, box-b: queue the lane, spawn nothing. Queue it; nothing was spawned." 2>&1)"
r4="$(listrow "$A4")"
[[ "$(jq -r .state <<<"$r4")" == queued && "$(jq -r .position <<<"$r4")" == 1 ]] &&
  grep -q "launcher says HOLD (waiting: claude weekly >= 90% on box-a, box-b): back in line" <<<"$out" &&
  pass "spawn-window HOLD (exit 10): back in line at position 1, its reason logged" || fail "launcher hold: $out | $r4"

# 8. the queue view --------------------------------------------------------------------
out="$(on pc do_spl_spawn_queue 2>&1)"
grep -qE "^1/1 +bug +${A4:0:8} +c-002@box-desk .*claude:hub-pg-split .*SPAWN REQUEST perf5" <<<"$out" &&
  pass "do_spl_spawn_queue: POS, CLASS, ask, sender, placement and summary" || fail "queue view: $out"
grep -qE "^WAIT ${A4:0:8} waiting: claude weekly >= 90% on box-a, box-b \(held 0m ago\)$" <<<"$out" &&
  pass "do_spl_spawn_queue: the held ask shows why it waits (SPL-2035)" || fail "queue wait: $out"
[[ "$(on pc do_spl_spawn_queue SPAWN_QUEUE_FORMAT=json 2>/dev/null | jq -r '.queue[0].position')" == 1 ]] &&
  pass "do_spl_spawn_queue json" || fail "queue json"

# 10. SPL-1817: classes, bands, supply, the share report ---------------------------
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$A4" --by c-001@box-desk --reason "placed: c-283@box-desk" >/dev/null
BYPASS_MSG=8cb6cc7d-7628-4ac3-be00-86e427bb3487
n=0
# placed ID CLASS AGENT: a lane placed from the queue with that class
placed() {
  HUB_DIR="$T/hub" "$T/bin/hub" ask put --fleet main --id "$1" --kind task --role orch --from c-002@box-desk --topic t --summary "lane $3" >/dev/null
  HUB_DIR="$T/hub" "$T/bin/hub" ask queue --fleet main --id "$1" --by c-001@box-desk --class "$2" >/dev/null
  HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$1" --by c-001@box-desk --reason "placed: $3@box-desk" >/dev/null
}
lane_ids=()
for c in refactor refactor refactor bug feature feature feature feature feature feature; do
  n=$((n + 1)); id="$(printf 'b%07d-0000-4000-8000-%012d' "$n" "$n")"; placed "$id" "$c" "c-3$(printf %02d "$n")"
  lane_ids+=("c-3$(printf %02d "$n")")
done
# 10 classed lanes (refactor 30%, bug 10%, feature 60%) + 2 placed before the class existed
LANES="$(printf '%s\n' "${lane_ids[@]}" c-398 c-399 | jq -R -s -c '[split("\n")[] | select(length > 0) | {agent_id: ., agent_box: "box-desk", state: "live"}]')"
export LANES
F1=f1f1f1f1-0000-4000-8000-000000000001; R1=f2f2f2f2-0000-4000-8000-000000000002; B1=f3f3f3f3-0000-4000-8000-000000000003
put "$F1" c-002@box-desk dispatch-3209f8b8-f "SPAWN REQUEST a feature"
put "$R1" c-002@box-desk dispatch-3209f8b8-r "SPAWN REQUEST a refactor"
put "$B1" c-002@box-desk dispatch-3209f8b8-b "SPAWN REQUEST a bug"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$F1" 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$F1")")" == open ]] && grep -q "FATAL SPAWN_CLASS must be ci, refactor, bug or feature" <<<"$out" &&
  pass "enqueue with no SPAWN_CLASS: refused with the four values, the ask stays open" || fail "no class: $out | $(hubrow "$F1")"
on pc do_spl_spawn_enqueue ASK_ID="$F1" SPAWN_CLASS=chore >/dev/null 2>&1 && fail "class chore taken" || pass "enqueue: SPAWN_CLASS=chore refused"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_BYPASS=$BYPASS_MSG >/dev/null 2>&1 && fail "a bypass on a bug was taken" ||
  pass "enqueue: SPAWN_BYPASS on a bug refused"
on pc do_spl_spawn_enqueue ASK_ID="$F1" SPAWN_CLASS=feature SPAWN_BYPASS=8cb6cc7d >/dev/null 2>&1 && fail "a short bypass id was taken" ||
  pass "enqueue: SPAWN_BYPASS must be a full owner msg id"
on pc do_spl_spawn_enqueue ASK_ID="$F1" SPAWN_CLASS=feature SPAWN_URGENT=1 >/dev/null 2>&1 && fail "an urgent feature was taken" ||
  pass "enqueue: SPAWN_URGENT on a feature refused"
on pc do_spl_spawn_enqueue ASK_ID="$F1" SPAWN_CLASS=feature >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$R1" SPAWN_CLASS=refactor >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug >/dev/null 2>&1
[[ "$(jq -r .position <<<"$(listrow "$R1")") $(jq -r .position <<<"$(listrow "$B1")") $(jq -r .position <<<"$(listrow "$F1")")" == "1 2 3" ]] &&
  pass "the queue orders by class: refactor 1, bug 2, the older feature 3" || fail "class order: $(listrow "$R1") $(listrow "$B1") $(listrow "$F1")"
: >"$T/send.log"
out="$(on pc do_spl_spawn_place SPAWN_SHARE_SUPPLY_MIN=60 2>&1)"
if [[ "$(jq -r .state <<<"$(hubrow "$B1")")" == acked && "$(jq -r .state <<<"$(hubrow "$R1")")" == queued ]] &&
   grep -q "band pick: ask ${B1:0:8} (bug at 10%, queue position 2)" <<<"$out" && grep -q "SPAWN QUEUE: place ask ${B1:0:8} now" "$T/send.log"; then
  pass "bands: bug at 10% (< 20%) is taken before the queue's head, refactor at 30% (control: position 1 is the refactor)"
else fail "band pick: $out | $(sends)"; fi
grep -q "of 10 known live lanes (2 unknown, left out)" <<<"$out" && pass "lanes placed before the class existed are unknown, left out of the denominator" ||
  fail "unknown lanes: $out"
grep -q "SPAWN SHARE" "$T/send.log" && fail "a supply blocker while bug is queued and refactor is in band: $(sends)" ||
  pass "supply control: no blocker while the class under its band has a queued row"
on pc do_spl_spawn_placed ASK_ID="$B1" PLACED_AS=c-311@box-desk >/dev/null 2>&1
# bug now 2 of 11: refactor 27%, bug 18%, feature 54%: still bug-short, nothing of it queued
LANES="$(jq -c '. + [{agent_id: "c-311", agent_box: "box-desk", state: "live"}]' <<<"$LANES")"
: >"$T/send.log"
out="$(on pc do_spl_spawn_place WINDOWS=40 SPAWN_SHARE_SUPPLY_MIN=60 2>&1)"
if grep -q "^c-001 c-002 blocker spawn-share \*\*SPAWN SHARE: bug share 18% < 20% (2 of 11 live lanes with a class) and no bug row is queued" "$T/send.log" &&
   [[ "$(grep -c "SPAWN SHARE" "$T/send.log")" == 1 ]]; then
  pass "supply: bug under its band with none queued -> ONE blocker to the dispatch holder (refactor in band: none)"
else fail "supply: $out | $(sends)"; fi
on pc do_spl_spawn_place WINDOWS=40 SPAWN_SHARE_SUPPLY_MIN=60 >/dev/null 2>&1
[[ "$(grep -c "SPAWN SHARE" "$T/send.log")" == 1 ]] && pass "supply: no second blocker within SPAWN_SHARE_SUPPLY_MIN" || fail "supply repeat: $(sends)"
# a CI-red fix and an owner bypass are taken as they are, ci first
C1=f4f4f4f4-0000-4000-8000-000000000004; X1=f5f5f5f5-0000-4000-8000-000000000005
put "$C1" c-002@box-desk dispatch-3209f8b8-c "SPAWN REQUEST trunk is red"
put "$X1" c-002@box-desk dispatch-3209f8b8-x "SPAWN REQUEST the owner's fast feature"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$X1" SPAWN_CLASS=feature SPAWN_BYPASS=$BYPASS_MSG 2>&1)"
grep -q "BYPASS on owner msg 8cb6cc7d: recorded" <<<"$out" && [[ "$(jq -r .flag_msg <<<"$(hubrow "$X1")")" == "$BYPASS_MSG" ]] &&
  grep -q "$X1"$'\t'"$BYPASS_MSG"$'\t'"c-001@box-desk" "$T/pc/spool/asks/bypass.tsv" &&
  pass "bypass: on the hub row and in the local bypass log (ask, owner msg, who)" || fail "bypass record: $out | $(hubrow "$X1")"
on pc do_spl_spawn_enqueue ASK_ID="$C1" SPAWN_CLASS=ci >/dev/null 2>&1
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$C1")")" == acked && "$(jq -r .state <<<"$(hubrow "$R1")")" == queued ]] && ! grep -q "band pick" <<<"$out" &&
  pass "a ci head is taken as it is, before the bands" || fail "ci: $out"
on pc do_spl_spawn_placed ASK_ID="$C1" PLACED_AS=c-312@box-desk >/dev/null 2>&1
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$X1")")" == acked && "$(jq -r .state <<<"$(hubrow "$R1")")" == queued ]] &&
  pass "an owner bypass feature is taken outside the bands (feature over its share, refactor queued)" || fail "bypass place: $out"
on pc do_spl_spawn_placed ASK_ID="$X1" PLACED_AS=c-313@box-desk >/dev/null 2>&1
out="$(on pc do_spl_spawn_share 2>&1)"
if grep -qE "^\| refactor \| 3 \| 27% \| 20-30% \| ok \|" <<<"$out" && grep -qE "^\| bug \| 2 \| 18% \| 20-30% \| UNDER \|" <<<"$out" &&
   grep -qE "^\| 8cb6cc7d \| ${X1:0:8} \| c-313@box-desk \| c-001@box-desk \|" <<<"$out" && grep -q "2 placed before the class existed" <<<"$out"; then
  pass "do_spl_spawn_share: live lanes by class with %, the band verdict, the unknown count and the bypass (owner msg, ask, lane, who)"
else fail "share report: $out"; fi
[[ "$(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>/dev/null | jq -r '.by.feature.n, .known' | tr '\n' ' ')" == "6 11 " ]] &&
  pass "do_spl_spawn_share json" || fail "share json: $(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>&1)"
mkdir -p "$T/pc/spool/c-398/lifetime"; printf '# a brief\nClass: refactor\n' >"$T/pc/spool/c-398/lifetime/brief.md"
[[ "$(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>/dev/null | jq -r '.by.refactor.n, .unknown' | tr '\n' ' ')" == "4 1 " ]] &&
  pass "a lane's brief 'Class:' line classes it (a standing seat)" || fail "brief class: $(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>&1)"
# SPL-1854: the hub's asks list over ARG_MAX (779 KB on sat) went to jq as one
# argument: "Argument list too long". Same rows plus closed ones of 1 KB each,
# ARG_MAX of them (2 MB here, 4 MB on the CI runners: it follows the stack limit).
want="$(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>/dev/null)"
HUB_DIR="$T/hub" "$T/bin/hub" ask list --fleet main --role orch --all |
  jq -c --arg pad "$(printf '%01000d' 0)" --argjson n "$(( $(getconf ARG_MAX) / 1000 + 1 ))" \
    '.asks += [range($n) | {ask_id: "dead-\(.)", state: "dead", summary: $pad}]' >"$T/big-asks.json"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/big-asks.json" >"$T/bin/bighub"; chmod +x "$T/bin/bighub"
mkdir -p "$T/sharetmp"
got="$(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json ASKS_HUB_CMD="$T/bin/bighub" TMPDIR="$T/sharetmp" 2>&1)"
[[ "$(stat -c %s "$T/big-asks.json")" -gt "$(getconf ARG_MAX)" && -n "$want" && "$got" == "$want" ]] &&
  pass "an asks list over ARG_MAX: the same share, read from a file (SPL-1854)" ||
  fail "big asks ($(stat -c %s "$T/big-asks.json") bytes, ARG_MAX $(getconf ARG_MAX)): $(head -c 300 <<<"$got")"
[[ -z "$(ls -A "$T/sharetmp")" ]] && pass "the share leaves no temp dir" || fail "temp left: $(ls -A "$T/sharetmp")"
on pc do_spl_spawn_share ASKS_HUB_CMD=false TMPDIR="$T/sharetmp" >/dev/null 2>&1 && fail "a dead hub gave a share" ||
  { [[ -z "$(ls -A "$T/sharetmp")" ]] && pass "a dead hub: no share and no temp dir left" || fail "temp left on a hub error: $(ls -A "$T/sharetmp")"; }

# 11. SPL-2042: a hand-off blocks only the asks that need the holder --------------
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$R1" --by c-001@box-desk --reason "placed: c-314@box-desk" >/dev/null
H1=e1e1e1e1-0000-4000-8000-000000000001; L1=e2e2e2e2-0000-4000-8000-000000000002
L2=e3e3e3e3-0000-4000-8000-000000000003; K1=e4e4e4e4-0000-4000-8000-000000000004; L3=e5e5e5e5-0000-4000-8000-000000000005
put "$H1" c-002@box-desk dispatch-88982c94-h "SPAWN REQUEST needs judgement"
put "$L1" c-002@box-desk dispatch-88982c94-l "SPAWN REQUEST has a brief"
on pc do_spl_spawn_enqueue ASK_ID="$H1" SPAWN_CLASS=bug >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$L1" SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split >/dev/null 2>&1
: >"$T/send.log"; : >"$T/launch.log"
on pc do_spl_spawn_place >/dev/null 2>&1
[[ "$(jq -r .state <<<"$(hubrow "$H1")")" == acked && "$(jq -r .state <<<"$(hubrow "$L1")")" == queued ]] &&
  grep -q "place ask ${H1:0:8} now" "$T/send.log" &&
  pass "queue [no placement, launchable]: the head is handed to the holder" || fail "hand H1: $(hubrow "$H1") | $(sends)"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-401 2>&1)"
if [[ "$(jq -r .reason <<<"$(hubrow "$L1")")" == "placed: c-401@box-desk" && "$(jq -r .state <<<"$(hubrow "$H1")")" == acked ]] &&
   grep -q "ask ${H1:0:8} is with the holder" <<<"$out" && ! grep -q "one at a time" <<<"$out"; then
  pass "a hand-off blocks nothing the placer launches itself: the launchable ask is placed in the next tick (SPL-2042)"
else fail "handed blocks the line: $out | $(hubrow "$L1")"; fi
put "$L2" c-002@box-desk dispatch-88982c94-m "SPAWN REQUEST has a brief too"
on pc do_spl_spawn_enqueue ASK_ID="$L2" SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split >/dev/null 2>&1
out="$(on pc do_spl_spawn_place HUB_SKEW=$((31 * 60)) LAUNCH_ID=c-402 2>&1)"
r1="$(listrow "$H1")"
if grep -q "${H1:0:8} was not placed within 30 min: back in line" <<<"$out" && [[ "$(jq -r .position <<<"$r1")" == 1 ]] &&
   [[ "$(jq -r .reason <<<"$(hubrow "$L2")")" == "placed: c-402@box-desk" && "$(grep -c "place ask ${H1:0:8} now" "$T/send.log")" == 1 ]]; then
  pass "a stalled hand-off back at position 1 waits behind the ask the placer launches (control: it is the queue's head)"
else fail "handed back in front: $out | $r1 | $(hubrow "$L2") | $(sends)"; fi
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$H1")")" == acked && "$(grep -c "place ask ${H1:0:8} now" "$T/send.log")" == 2 ]] &&
  pass "with no launchable ask left, the stalled hand-off is handed again" || fail "re-hand: $out | $(sends)"
put "$K1" c-002@box-desk dispatch-88982c94-k "SPAWN REQUEST a launch in flight"
put "$L3" c-002@box-desk dispatch-88982c94-n "SPAWN REQUEST next with a brief"
on pc do_spl_spawn_enqueue ASK_ID="$K1" SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$L3" SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split >/dev/null 2>&1
HUB_DIR="$T/hub" "$T/bin/hub" ask ack --fleet main --id "$K1" --by c-001@box-desk >/dev/null
: >"$T/launch.log"
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$L3")")" == queued && ! -s "$T/launch.log" ]] && grep -q "one at a time" <<<"$out" &&
  pass "an ask the placer launches itself still placing: one at a time holds" || fail "launch in flight: $out | $(hubrow "$L3")"
for i in "$H1" "$K1" "$L3"; do HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done
on pc do_spl_spawn_place >/dev/null 2>&1
grep -q "^${F1}$" "$T/pc/spool/asks/.place.handed" && ! grep -q "^${H1}$" "$T/pc/spool/asks/.place.handed" &&
  pass "the hand-off record is pruned once its ask left the line (control: a handed ask still queued stays)" ||
  fail "stale hand-off record: $(cat "$T/pc/spool/asks/.place.handed")"

# 12. SPL-2088: a hand-pinned slug, the pinned box's load, the gap slot -----------
qids() { HUB_DIR="$T/hub" "$T/bin/hub" ask list --fleet main --role orch | jq -r '.asks[] | select(.state == "queued" or .state == "acked") | .ask_id'; }
for i in $(qids); do HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done
P1=d1d1d1d1-0000-4000-8000-000000000001; P2=d2d2d2d2-0000-4000-8000-000000000002; P3=d3d3d3d3-0000-4000-8000-000000000003
echo "brief text" >"$T/briefs/qto-gap.md"
put "$P1" c-002@box-desk dispatch-88982c94-p "SPAWN REQUEST hand-pinned to sat"
on pc do_spl_spawn_enqueue ASK_ID="$P1" SPAWN_CLASS=bug SPAWN_PLACE=claude:hand-sat-qto-gap >/dev/null 2>&1
SAT_FULL="BOX sat  load5 28.8  cpus 16  180%  full  band 50..85 (box)"
SAT_BUSY="BOX sat  load5 17.99  cpus 16  112%  full  band 50..85 (box)"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place "PICK_BOXES=$SAT_FULL" 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$P1")")" == queued && ! -s "$T/launch.log" && ! -e "$T/pc/spool/asks/.place.last" ]] &&
  grep -q "pinned to sat: box sat at 180% is past its overflow mark (170%" <<<"$out" &&
  pass "hand-sat- slug, sat past its overflow mark: HOLD, nothing launched, no gap slot burned" || fail "pin hold: $out | $(hubrow "$P1")"
out="$(on pc do_spl_spawn_place "PICK_BOXES=$SAT_BUSY" LAUNCH_ID=c-501 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$P1")")" == "placed: c-501@box-desk" && -e "$T/pc/spool/asks/.place.last" ]] &&
  grep -q "^claude auto $T $T/briefs/qto-gap.md qto-gap SPAWN_BOX=sat$" "$T/launch.log" &&
  pass "hand-sat-qto-gap: the brief of qto-gap is found and launched with SPAWN_BOX=sat (control: sat under its overflow mark)" ||
  fail "pin launch: $out | $(hubrow "$P1") | $(cat "$T/launch.log")"
put "$P2" c-002@box-desk dispatch-88982c94-q "SPAWN REQUEST sathand"
on pc do_spl_spawn_enqueue ASK_ID="$P2" SPAWN_CLASS=bug SPAWN_PLACE=claude:sathand-qto-gap >/dev/null 2>&1
: >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-502 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$P2")")" == "placed: c-502@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/qto-gap.md qto-gap SPAWN_BOX=sat$" "$T/launch.log" &&
  pass "sathand-qto-gap: same brief, SPAWN_BOX=sat" || fail "sathand: $out | $(cat "$T/launch.log")"
put "$P3" c-002@box-desk dispatch-88982c94-r "SPAWN REQUEST needs judgement"
on pc do_spl_spawn_enqueue ASK_ID="$P3" SPAWN_CLASS=bug >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$P3")")" == acked && ! -e "$T/pc/spool/asks/.place.last" ]] && grep -q "place ask ${P3:0:8} now" "$T/send.log" &&
  pass "a hand-off to the holder burns no SPAWN_PLACE_GAP_MIN slot (control: the launch above touched .place.last)" ||
  fail "hand-off slot: $out | $(ls -la "$T/pc/spool/asks/")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$P3" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null

# 13. SPL-2263 (owner HUM-10, t1 b61851fb): a mistral placement whose brief
# names csi-spl-wui/ launches claude while mistral_ui_allowed is not true
# (APP_PATH=$T has no cnf: the default false). CONTROL: a docs brief keeps mistral.
U1=b7b7b7b7-0000-4000-8000-000000000001; U2=b8b8b8b8-0000-4000-8000-000000000002
echo "Fix the hover in csi-spl-wui/src/components/x.vue" >"$T/briefs/ui-hover.md"
echo "Rewrite csi-spl-doc/doc/md/x.md" >"$T/briefs/docs-x.md"
put "$U1" c-002@box-desk dispatch-b61851fb-u "SPAWN REQUEST ui hover"
on pc do_spl_spawn_enqueue ASK_ID="$U1" SPAWN_CLASS=bug SPAWN_PLACE=mistral:ui-hover >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-503 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$U1")")" == "placed: c-503@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/ui-hover.md ui-hover$" "$T/launch.log" &&
  grep -q "placed as mistral, launched as claude: mistral takes no UI work until do_spl_vendor_ui_retest passes" <<<"$out" &&
  pass "a mistral placement with a WUI brief launches claude" || fail "ui placement: $out | $(cat "$T/launch.log")"
put "$U2" c-002@box-desk dispatch-b61851fb-v "SPAWN REQUEST docs"
on pc do_spl_spawn_enqueue ASK_ID="$U2" SPAWN_CLASS=bug SPAWN_PLACE=mistral:docs-x >/dev/null 2>&1
: >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=m-504 2>&1)"
grep -q "^mistral auto $T $T/briefs/docs-x.md docs-x$" "$T/launch.log" &&
  pass "control: a mistral placement with a docs brief stays mistral" || fail "docs placement: $out | $(cat "$T/launch.log")"

# 9. the cron line ----------------------------------------------------------------------
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc"; printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
printf '5 * * * * x # csi-spl:orch-rotate\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the action runs in the child shell
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" SPAWN_PLACE_CRON_LOG_DIR="$T/cronlog" \
    PROJ_PATH="$PROJ_ROOT" SPL_ORG_APP=csi-spl "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-spawn-place-install-cron.func.sh"
    do_spl_spawn_place_install_cron'
}
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
line="$(grep '# csi-spl:spawn-place$' "$T/crontab")"
# shellcheck disable=SC2016 # $HOME stays literal in the cron line
want='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin'
[[ $rc -eq 0 && "$line" == "* * * * * cd $SRC/csi-spl-orc && $want flock -n $T/cronlog/spawn-place.lock ./run -a do_spl_spawn_place >> $T/cronlog/cron.out 2>&1 # csi-spl:spawn-place" ]] &&
  grep -q 'orch-rotate' "$T/crontab" &&
  pass "cron: one line, PATH has /usr/local/bin (yq), flock -n, other lines kept" || fail "cron install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:spawn-place$' "$T/crontab")" == 1 ]] && pass "cron: a second install is a no-op" || fail "cron lines: $(cat "$T/crontab")"
cron SPAWN_PLACE_CRON_ACTION=check >"$T/o" 2>&1 && grep -q 'OK the spawn placer is installed' "$T/o" && ! grep -q 'other settings' "$T/o" &&
  pass "cron: check says installed" || fail "cron check: $(cat "$T/o")"
cron DRY_RUN=0 SPAWN_PLACE_CRON_ACTION=remove >/dev/null 2>&1
! grep -q 'spawn-place' "$T/crontab" && grep -q 'orch-rotate' "$T/crontab" && pass "cron: remove takes only its line" || fail "cron remove: $(cat "$T/crontab")"

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
