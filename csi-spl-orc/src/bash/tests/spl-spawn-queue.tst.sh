#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spawn requests wait in a DB queue with a position and a placer
#          takes the head when there is room (owner HUM-10, t1 c9beaa77 msg
#          ca668844; rdb 0180). The hub is a stub with the contract of
#          `spool ask` plus ask_op queue (positions per role: priority, then
#          class, then enqueued_at).
#   1. enqueue: the sender is told "queued, position N of M" on its task (an
#      owner topic uuid becomes dispatch-<topic8>); a second request is 2 of 2
#  1b. SPL-5325: a placed brief with no Topic: on a dispatch-<word> ask is
#      refused at the enqueue with the placer's links line (CONTROLS: a hub
#      uuid, a dispatch-<topic8> ask, a Topic: line all queue)
#   2. the asks tick past ASKS_OWNER_MIN and the re-raise time: a queued ask
#      is never re-raised, escalated or dead-lettered (CONTROL: the same ask
#      left open IS raised and told to the owner)
#   3. ceiling full (40 windows) -> stays queued; the load target says hold
#      -> stays queued; a machine that does not hold the orch role places
#      nothing
#   4. the ceiling frees -> the head is launched (placement + brief), closed
#      "placed: <ID>@<box>", its sender told; the next one moves to 1 of 1
#   5. the gap: a second placement waits the 3 min floor; past it, it waits
#      until the placed lane's heartbeat progress_ts moved past the launch,
#      at most SPAWN_PLACE_GAP_MIN (10); no, an old or unreadable heartbeat
#      or a failed launch holds to it; the load target holds regardless.
#      SPL-3574: an agy lane (no heartbeat.json) with a metered token-burn
#      bucket here, or a lane on another box with a metered by_agent row on
#      the hub, past the launch ends it too (CONTROLS: an unmetered sample,
#      burn before the launch, another id or box hold to the ceiling)
#   6. no placement -> ONE blocker to the holder, the ask is placing; the
#      next tick places nothing else (one at a time); past
#      SPAWN_PLACE_LOCK_MIN it goes back to position 1; do_spl_spawn_placed
#      closes it and tells the sender
#   7. the launcher's HOLD (exit 10) puts it back at position 1
#   8. do_spl_spawn_queue lists POS, PRIO, sender and summary
#  SPL-4955: a row of an archived topic is declined, not placed (near the end)
#  21. spec 150 row B10b: ASK_DISCUSSION at enqueue fills the row's discussion
#      while NULL, never overwrites; a bad id is refused
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
#  12b. SPL-4009: a head pinned to a full box blocks nothing: the unpinned
#      row behind it is placed in the same tick (CONTROLS: every row pinned
#      to the full box -> nothing launched, each holds; the box with room ->
#      the pinned head is placed first)
#  13. SPL-2263: a mistral placement whose brief names csi-spl-wui/ launches
#      claude, agy when its "Kind:" is specs_and_docs or i18n (SPL-2942, an R7
#      review of a claude author stays cross-vendor) (CONTROL: a docs brief
#      naming no csi-spl-wui/ stays mistral); SPL-3627: a brief under the
#      data rule ("Data: secret", or the prose "Data rule:") launches
#      claude, never agy or qwen (CONTROL: the SPL-2942 brief, no marker, agy)
#  13b. SPL-3018: the agy swap target out of quota (agy's banner in the
#      watchdog's pane capture, or an S2 kind=limit verdict on an a- lane): a
#      review row holds, queued, and blocks no other row; a non-review docs
#      row launches claude (CONTROL: a banner past its reset launches agy)
#  13b2. SPL-3846: with a fresh agent-run.tsv, the banner and the S2 of a
#      dead a- id hold nothing (CONTROL: a live id's still hold; no fresh
#      report = liveness unknown, they hold); an answered agy probe newer
#      than the S2 drops it (CONTROL: a probe older than it does not)
#  13b3. SPL-3998/SPL-5078: the other box's watchdog blocker (S2 kind=limit
#      on a live a- lane there) puts that box out, and a row waits only with
#      every box out (CONTROLS: the other box alone is not out everywhere; a
#      dead remote lane or a blocker past its reset leaves that box in; no
#      lane map or rows only = unknown, the blocker counts)
#  13b4. SPL-4020: an agy row is judged against the box it launches on: the
#      pick names sat, sat's watchdog blocker (its lane live there, SPL-5078)
#      -> launched on this box (SPAWN_BOX), and HOLDS with the
#      reset when this box is full or the row is pinned to sat (CONTROLS: the
#      pick names this box -> launched here; no blocker -> as before, no
#      SPAWN_BOX). SPL-5208: sat's blocker from a CLOSED lane still steers a
#      row to this box when it is in with room; this box full, or this box
#      out too -> not held, launched on sat (SPL-5078 W1); a row placed as
#      mistral and swapped to agy runs the lane map too (R7 W4)
#  13c. SPL-3024: a row placed directly as agy:<slug> holds while agy is out
#      of quota, review or not (CONTROL: agy in quota launches it as agy)
#      SPL-3138: agy back but the row not launched (ceiling full): its agy
#      WAIT line is gone, a line of an ask no longer queued is pruned
#      (CONTROL: a non-agy reason is kept)
#  13d. SPL-3470: a placed row queued on another box (writer_box sat) whose
#      brief is not here HOLDS: queued, never acked or handed to the holder,
#      .place.wait names sat, and a launchable row behind it is placed in the
#      same tick; the brief copied here -> it launches and its WAIT line is
#      gone (CONTROL: the same missing brief on a row queued from this box is
#      handed to the holder, as before)
#  14. SPL-2429: a human sender (HUM-<n>@box) has no spool inbox: its
#      "queued" and "placed" notes go to the dispatch lease holder, naming
#      the human, the full topic and the lane; nothing is sent to the HUM id;
#      no lease = one WARN (CONTROL: an agent sender is still told itself)
#  15. owner HUM-10 msg 91bf8278 (mistral does docs and reviews only): a
#      mistral placement of a coding kind (SPAWN_KIND, else the brief's
#      "Kind:", none counting as coding) is refused at enqueue, and a row
#      queued anyway launches claude (CONTROL: mistral_coding_allowed true
#      queues it and launches mistral)
#  16. SPL-2508: a brief whose epic is done, diss or archived on the hub (the
#      hub answers not_found for an archived one) is not queued, one FATAL
#      line names the brief, the epic and the fix (CONTROL: an open epic and a
#      hub that does not answer queue it); a row queued while its epic was
#      open whose epic closed since is handed to the holder with the reason,
#      not launched (CONTROL: an open epic launches)
#  18. spec 143 4.4 (SPL-2790): a launched row's brief "Kind:" and
#      "Category:" are recorded on the hub's request before the launch; a
#      brief with neither sends no category op and places as before
#      (CONTROL); a path the hub refuses is one WARN line and the row is
#      still placed
#  19. SPL-3349: the owner's review-seat GO (msg 994f2257) takes a review
#      seat (a placement slug ending in -reviewer) of class bug: queued
#      unflagged on the hub, in the local bypass log, listed by
#      do_spl_spawn_share; the GO on a non-seat or with no placement, and
#      another owner id on a seat, are still refused; bug OVER its band and
#      feature UNDER, the bypassed seat is placed before the feature (CONTROL:
#      a non-seat bug queued without the GO waits, the feature is placed)
#      SPL-3762: a -reviewer placement queued with no SPAWN_BYPASS gets the
#      standing GO at enqueue (logged, one INFO line) and is placed first;
#      SPAWN_URGENT on a seat and a non-reviewer slug are unchanged
#  20. spec 150 C405: do_spl_spawn_queue prints PRIO, the hub's discussion
#      priority 1..5 (3 without one), next to POS; the json view carries it
#      (RED CONTROL: the column dropped)
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
# The specs repo the enqueue's epic+spec check reads (LI_SPEC_REPO): spec 135
# on origin/master. No issue without an epic and a git spec (owner HUM-10, t1
# 7a98c2d1 msg 5863d0d6): a placed brief names both.
git init -q --bare "$T/specs.git" && git init -q -b master "$T/specs"
mkdir -p "$T/specs/csi-spl-doc/specs/135-work-process" && echo '# Spec 135' >"$T/specs/csi-spl-doc/specs/135-work-process/spec.md"
git -C "$T/specs" add -A && git -C "$T/specs" -c user.name='FirstName LastName' -c user.email=dev@example.com commit -q -m s &&
  git -C "$T/specs" remote add origin "$T/specs.git" && git -C "$T/specs" push -q origin master 2>/dev/null
export LI_SPEC_REPO="$T/specs"
# Every placed brief names its discussion too (spec 153 3.20, SPL-4797): case 16c.
ES=$'Spec: csi-spl-doc/specs/135-work-process\nEpic: SPL-1\nTopic: 7c0de153-0000-4000-8000-000000003170'

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
# rdb 0241 + spec 150 B9: the discussion's priority (HUB_PRIOS, {uuid: 1..5}), 3 without one, ranks first
def prio(r): return json.loads(os.environ.get("HUB_PRIOS") or "{}").get(r.get("discussion") or "", 3)
def positions():
    for role in set(r["role"] for r in rows):
        q = sorted([r for r in rows if r["role"] == role and r["state"] == "queued"], key=lambda r: (prio(r), rank(r), r["q"], r["ask_id"]))
        for n, r in enumerate(q): r["position"], r["queue_len"] = n + 1, len(q)
    for r in rows:
        if r["state"] != "queued": r["position"], r["queue_len"] = 0, 0
def out(r):
    o = dict(r); o["priority"] = prio(r); o["age_s"] = int(now - r["c"]); o["quiet_s"] = int(now - max(r["u"], r.get("r") or 0))
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
        if r["ask_id"] == kv["id"]:
            if kv.get("discussion") and not r.get("discussion"): r["discussion"] = kv["discussion"]; save()  # fills NULL, never overwrites (spec 150 B10b)
            answer([r])
    r = {"ask_id": kv["id"], "role": kv.get("role") or "orch", "kind": kv["kind"], "from": kv["from"], "topic": kv.get("topic", ""),
         "summary": kv.get("summary", ""), "discussion": kv.get("discussion", ""), "state": "open", "acked_by": "", "closed_by": "", "reason": "", "raised_n": 0,
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
    elif op == "category":
        if kv.get("category") and kv["category"] not in ("coding", "coding/hard", "review", "review/r7"):
            print("hub refused: unknown_category (400): no category %s" % kv["category"], file=sys.stderr); sys.exit(1)
        r["work_kind"], r["category_path"] = kv.get("work-kind", ""), kv.get("category", "")
    else:
        print("hub refused: bad_frame (400): ask_op", file=sys.stderr); sys.exit(1)
    r["writer_box"] = os.environ.get("SPOOL_DESK_BOX", "box-desk")
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
# the hub's token burn stub (GET /v1/operator/fleet-tokens): $BURN_JSON, or nothing
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\ncat "$BURN_JSON" 2>/dev/null\n' >"$T/bin/burn"; chmod +x "$T/bin/burn"; mkdir -p "$T/burn"
# the launcher stub: prints "<ID> <PANE>" (LAUNCH_ID), or exits LAUNCH_RC;
# the slug LAUNCH_HOLD_SLUG alone gets spawn-window's HOLD (exit 10)
# and the slugs of LAUNCH_DARK_SLUG their pinned box's silence (exit 8, remote exit 5)
cat >"$T/bin/launch" <<'STUB'
#!/usr/bin/env bash
echo "$*${SPAWN_BOX:+ SPAWN_BOX=$SPAWN_BOX}" >>"$LAUNCH_LOG"
echo "$5 SPAWN_LANE_TOPIC=${SPAWN_LANE_TOPIC-<unset>}" >>"$LAUNCH_LOG.env"
echo "$5 BOX_PICK_REVIEW_SEAT=${BOX_PICK_REVIEW_SEAT-<unset>}" >>"$LAUNCH_LOG.seat"
echo "spawn-window: c-001 asked for $2" >&2
[ -z "${LAUNCH_ERR:-}" ] || echo "$LAUNCH_ERR" >&2
if [ -n "${LAUNCH_HOLD_SLUG:-}" ] && [ "$5" = "$LAUNCH_HOLD_SLUG" ]; then
  echo "spawn-window: HOLD auto: waiting: grok weekly >= 90% on box-a: queue the lane, spawn nothing." >&2; exit 10
fi
if [[ " ${LAUNCH_DARK_SLUG:-} " == *" $5 "* ]]; then
  echo "spawn-remote: no reply from $SPAWN_BOX within 300s (task t1); it may still come" >&2
  echo "spawn-window: the spawn on SPAWN_BOX=$SPAWN_BOX did not start (spawn-remote exit 5)" >&2; exit 8
fi
[ "${LAUNCH_RC:-0}" = 0 ] || exit "$LAUNCH_RC"
echo "${LAUNCH_ID:-c-281} %42"
STUB
chmod +x "$T/bin/launch"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\necho "${WINDOWS:-12}"\n' >"$T/bin/windows"; chmod +x "$T/bin/windows"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\n[ -z "${PICK_BOXES:-}" ] || echo "$PICK_BOXES"\necho "pick=${PICK:-box-desk reason=below its low mark}"\n' >"$T/bin/pick"; chmod +x "$T/bin/pick"
printf 'brief text\n%s\n' "$ES" >"$T/briefs/hub-pg-split.md"

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
    "SPAWN_SHARE_LANES_CMD=$T/bin/lanes" "SPAWN_SHARE_DISPATCH=c-002@box-desk" \
    "SPAWN_SHARE_BANDS={\"refactor\": [20, 30], \"bug\": [20, 30], \"feature\": [40, 100]}" "RHYTHM_NOW=2026-01-15T12:00Z" \
    "TOKEN_BURN_STATE_DIR=$T/burn" "SPAWN_PLACE_BURN_CMD=$T/bin/burn" "BURN_JSON=$T/burn.json"
}
on() {  # <machine> <action> [env...]
  local m="$1" a="$2"; shift 2
  local -a e; mapfile -t e < <(menv "$m")
  # shellcheck disable=SC2016 # the action runs in the child shell
  env "${e[@]}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" SPOOL_VENDOR_CLIS_CMD="echo claude,grok,agy,qwen,mistral" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    # DO_LOG_REAL=1: the run'"'"'s own do_log, which sets the GLOBAL msg (SPL-3762)
    [[ "${DO_LOG_REAL:-0}" != 1 ]] || source <(awk '"'"'/^(_do_log[a-z_]*|do_log)\(\) \{/,/^}/'"'"' "'"$PROJ_ROOT"'/run")
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
echo "brief text, no spec, no epic" >"$T/briefs/no-spec.md"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_CLASS=bug SPAWN_PLACE=claude:no-spec 2>&1)"
if [[ "$(jq -r .state <<<"$(hubrow "$A2")")" == open ]] &&
   grep -q "FATAL ask not queued: no issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6): no spec folder named" <<<"$out"; then
  pass "enqueue: a placed brief with no spec and no epic is not queued, one FATAL line says what to add (control: hub-pg-split's brief names both and queued above)"
else fail "no-spec enqueue: $out | $(hubrow "$A2")"; fi
on pc do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_CLASS=bug >/dev/null 2>&1
if grep -q "^c-001 c-002@sat note dispatch-c9beaa77-x queued, position 2 of 2," "$T/send.log"; then
  pass "enqueue: the second request is position 2 of 2, told on its own task, another box's sender as <ID>@<box>"
else fail "second enqueue: $(sends)"; fi
[[ "$(jq -r .state "$T/pc/spool/asks/$A1.json" 2>/dev/null)" == queued ]] &&
  pass "enqueue: the journal mirrors the queued row" || fail "journal: $(cat "$T/pc/spool/asks/$A1.json" 2>&1)"
if ! on pc do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_CLASS=bug SPAWN_PLACE='claude:x;rm' >/dev/null 2>&1; then
  pass "enqueue: a placement that is not <vendor>:<slug> is refused"
else fail "a bad placement was taken"; fi

# SPL-5325: the placer's links check runs at the enqueue. A placed brief with
# no Topic: line, on an ask whose topic is a dispatch-<word> task, is refused
# at once with the placer's line; before, it queued and was refused only at the
# head (88af5bd4, 0135f355, 7cf29924 on 2026-11-11). CONTROLS: the same brief on
# a hub uuid or a dispatch-<topic8> ask, and a brief with a Topic: line on the
# dispatch-<word> ask, all queue. Each is closed again: the later cases count
# the queue.
printf '%s\n' 'Spec: csi-spl-doc/specs/135-work-process' 'Epic: SPL-1' >"$T/briefs/no-topic.md"
printf '%s\n' "$ES" >"$T/briefs/with-topic.md"
N1=b1b1b1b1-0000-4000-8000-000000005325; N2=b2b2b2b2-0000-4000-8000-000000005325
N3=b3b3b3b3-0000-4000-8000-000000005325; N4=b4b4b4b4-0000-4000-8000-000000005325
put "$N1" c-002@box-desk dispatch-prepush "SPAWN REQUEST prepush sig"
put "$N2" c-002@box-desk "$OWNER_TOPIC" "SPAWN REQUEST no-topic on a hub topic"
put "$N3" c-002@box-desk dispatch-c9beaa77 "SPAWN REQUEST no-topic on dispatch-<topic8>"
put "$N4" c-002@box-desk dispatch-prepush "SPAWN REQUEST with-topic on dispatch-<word>"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$N1" SPAWN_CLASS=bug SPAWN_PLACE=claude:no-topic 2>&1)"; rc=$?
if (( rc != 0 )) && [[ "$(jq -r .state <<<"$(hubrow "$N1")")" == open ]] &&
   grep -q "FATAL ask not queued: lane refused, no discussion: the ask's topic 'dispatch-prepush' names no hub topic and brief $T/briefs/no-topic.md names none (add a 'Topic: <uuid>' line" <<<"$out"; then
  pass "SPL-5325: a brief with no Topic: on a dispatch-<word> ask is refused at the enqueue (rc $rc, no queue row), the placer's line"
else fail "SPL-5325 refuse: rc $rc | $out | $(hubrow "$N1")"; fi
for c in "$N2 no-topic hub-uuid" "$N3 no-topic dispatch-<topic8>" "$N4 with-topic Topic:-line"; do
  read -r n b what <<<"$c"
  out="$(on pc do_spl_spawn_enqueue ASK_ID="$n" SPAWN_CLASS=bug SPAWN_PLACE="claude:$b" 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ "$(jq -r .state <<<"$(hubrow "$n")")" == queued ]]; then
    pass "SPL-5325 control: $what ask is queued"
  else fail "SPL-5325 control $what: rc $rc | $out | $(hubrow "$n")"; fi
  HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$n" --by c-001@box-desk --reason test >/dev/null
done
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$N1" --by c-001@box-desk --reason test >/dev/null
: >"$T/send.log"

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
# spec 153 C6c: an ask whose topic is a full uuid launches with
# SPAWN_LANE_TOPIC=<uuid> (the twin, a dispatch-<topic8> alias, is the
# hand-sat-qto-gap launch below); master set none. Spec 153 3.12: a
# dispatch-<topic8> ask sets its 8 hex, which the hub resolves (the sathand-
# launch below); RED on 06c1fa804: it set none
grep -qx "hub-pg-split SPAWN_LANE_TOPIC=$OWNER_TOPIC" "$T/launch.log.env" &&
  pass "C6c: the ask's full-uuid topic is SPAWN_LANE_TOPIC in the launch env" || fail "C6c: $(cat "$T/launch.log.env" 2>&1)"
r2="$(listrow "$A2")"
[[ "$(jq -r .position <<<"$r2")" == 1 && "$(jq -r .queue_len <<<"$r2")" == 1 ]] &&
  pass "the next request moves up: position 1 of 1" || fail "shift: $r2"

# 5. the gap ---------------------------------------------------------------------
out="$(on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$A2")")" == queued ]] && grep -q "last placement started under 3 min ago (the floor)" <<<"$out" &&
  [[ "$(cat "$T/pc/spool/asks/.place.agent")" == c-281@box-desk ]] &&
  pass "the gap: under the 3 min floor the next placement waits; the launch named its lane in .place.agent" || fail "gap: $out"
# SDLC row 06: the gap ends at the floor once the placed lane's heartbeat
# progress_ts moved past the launch; else it holds to SPAWN_PLACE_GAP_MIN
GQ="$T/pc/spool/asks"; HB="$T/pc/spool/c-281"; mkdir -p "$HB"
gap() {  # MIN_AGO_LAUNCH [env...]: the room verdict, launch MIN_AGO_LAUNCH ago
  local ago="$1"; shift
  touch -d "@$(( $(date +%s) - ago * 60 ))" "$GQ/.place.last"
  # shellcheck disable=SC2016 # expanded in the child shell
  on pc 'spl_asks_init >/dev/null 2>&1; if why="$(spl_spawn_place_no_room)"; then echo "hold: $why"; else echo room; fi' SPAWN_PLACE_GAP_MIN=10 "$@" 2>&1
}
iso() { date -u -d "@$(( $(date +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }
rm -f "$HB/heartbeat.json"
out="$(gap 4)"
[[ "$out" == "hold: the last placement started under 10 min ago and c-281@box-desk has no heartbeat or token-burn progress since" ]] &&
  pass "4 min after the launch, no heartbeat.json: holds to the ceiling" || fail "no heartbeat: $out"
printf '{"progress_ts": "%s"}\n' "$(iso 1)" >"$HB/heartbeat.json"
out="$(gap 4)"
[[ "$out" == room ]] && pass "4 min after the launch, progress_ts 1 min ago: the gap ends past the 3 min floor" || fail "heartbeat moved: $out"
out="$(gap 2)"
[[ "$out" == "hold: the last placement started under 3 min ago (the floor)" ]] &&
  pass "2 min after the launch, progress_ts moved: the floor still holds" || fail "floor: $out"
out="$(gap 4 PICK='hold reason=every box past its overflow mark')"
[[ "$out" == "hold: the fleet load target says hold reason=every box past its overflow mark" ]] &&
  pass "progress_ts moved but the load target says hold: it holds" || fail "load guard: $out"
printf '{"progress_ts": "%s"}\n' "$(iso 6)" >"$HB/heartbeat.json"
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] && pass "progress_ts older than the launch: holds to the ceiling" || fail "old heartbeat: $out"
echo 'not json' >"$HB/heartbeat.json"
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] && pass "an unreadable heartbeat.json: holds to the ceiling" || fail "unreadable: $out"
printf '{"progress_ts": "%s"}\n' "$(iso 1)" >"$HB/heartbeat.json"
touch -d "@$(( $(date +%s) - 300 ))" "$GQ/.place.agent"
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] &&
  pass "a .place.agent older than the launch (the launch failed): holds to the ceiling" || fail "stale agent: $out"
rm -f "$HB/heartbeat.json"
# SPL-3574: an agy lane writes no heartbeat.json, and a lane on another box
# has none here; both show progress by token burn. Here: a metered bucket of
# the collector's buckets.tsv (id vendor model minute in out cr cw met dirty);
# another box: the hub's fleet-tokens by_agent row of <box, id>.
burn() { printf '%s\tagy\tgemini\t%s\t%s\t0\t0\t0\t%s\t0\n' "$1" "$(( ($(date +%s) - $2 * 60) / 60 * 60 ))" "$3" "$4" >"$T/burn/buckets.tsv"; }
echo a-295@box-desk >"$GQ/.place.agent"
burn a-295 1 0 0
out="$(gap 4)"
[[ "$out" == "hold: the last placement started under 10 min ago and a-295@box-desk has no heartbeat or token-burn progress since" ]] &&
  pass "SPL-3574 CONTROL: an agy lane here whose pane is only alive (an unmetered sample): holds to the ceiling" || fail "agy unmetered: $out"
burn a-295 1 1200 1
out="$(gap 4)"
[[ "$out" == room ]] && pass "SPL-3574: an agy lane here, no heartbeat.json, metered token burn 1 min ago: the gap ends past the floor" || fail "agy burn: $out"
burn a-295 6 1200 1
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] && pass "SPL-3574 CONTROL: token burn only before the launch: holds" || fail "agy old burn: $out"
burn a-296 1 1200 1
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] && pass "SPL-3574 CONTROL: another lane's token burn: holds" || fail "agy other id: $out"
rm -f "$T/burn/buckets.tsv"
echo a-394@sat >"$GQ/.place.agent"
hubburn() { jq -n --arg a "$1" --arg b "$2" --argjson m "$3" --arg t "$(iso "$4")" '{by_agent: [{agent_id: $a, box: $b, vendor: "agy", is_metered: $m, last_active: $t}]}' >"$T/burn.json"; }
rm -f "$T/burn.json"
out="$(gap 4)"
[[ "$out" == "hold: the last placement started under 10 min ago and a-394@sat has no heartbeat or token-burn progress since" ]] &&
  pass "SPL-3574 CONTROL: a lane on another box, the hub has no token burn of it: holds to the ceiling" || fail "remote none: $out"
hubburn a-394 sat true 1
out="$(gap 4)"
[[ "$out" == room ]] && pass "SPL-3574: a lane on another box with metered token burn on the hub 1 min ago: the gap ends past the floor" || fail "remote burn: $out"
mkdir -p "$T/pc/spool/a-394"; printf '{"progress_ts": "%s"}\n' "$(iso 1)" >"$T/pc/spool/a-394/heartbeat.json"
hubburn a-394 sat false 1
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] &&
  pass "SPL-3574 CONTROL: a remote lane's pane only alive on the hub (unmetered), a same-id heartbeat here ignored: holds" || fail "remote unmetered: $out"
rm -rf "$T/pc/spool/a-394"
hubburn a-394 box-desk true 1
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] && pass "SPL-3574 CONTROL: the same id burning on another box: holds" || fail "remote other box: $out"
hubburn a-394 sat true 6
out="$(gap 4)"
[[ "$out" == hold:*"no heartbeat or token-burn progress since" ]] && pass "SPL-3574 CONTROL: the remote lane's last metered minute is before the launch: holds" || fail "remote old: $out"
rm -f "$T/burn.json"; echo c-281@box-desk >"$GQ/.place.agent"
out="$(gap 11)"
[[ "$out" == room ]] && pass "11 min after the launch, no heartbeat: the ceiling ends the gap" || fail "ceiling: $out"
rm -rf "$HB"

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
grep -qE "^1/1 +3 +bug +${A4:0:8} +c-002@box-desk .*claude:hub-pg-split .*SPAWN REQUEST perf5" <<<"$out" &&
  pass "do_spl_spawn_queue: POS, PRIO, CLASS, ask, sender, placement and summary" || fail "queue view: $out"
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
if grep -q "^c-001 c-002 note spawn-share \*\*SPAWN SHARE: bug share 18% < 20% (2 of 11 live lanes with a class) and no bug row is queued" "$T/send.log" &&
   [[ "$(grep -c "SPAWN SHARE" "$T/send.log")" == 1 ]]; then
  pass "supply: bug under its band with none queued -> ONE blocker to the dispatch holder (refactor in band: none)"
else fail "supply: $out | $(sends)"; fi
on pc do_spl_spawn_place WINDOWS=40 SPAWN_SHARE_SUPPLY_MIN=60 >/dev/null 2>&1
[[ "$(grep -c "SPAWN SHARE" "$T/send.log")" == 1 ]] && pass "supply: no second blocker within SPAWN_SHARE_SUPPLY_MIN" || fail "supply repeat: $(sends)"
# spec 166 B2: the supply blocker keeps the owner's 24 h floor (20%) at any
# phase, never the phase band (by day bug 15%, at night 30%); no band pin here
for ph in "day 2026-01-15T12:00Z" "night 2026-01-15T22:00Z"; do
  rm -f "$T/pc/spool/asks/.share.bug.last" "$T/pc/spool/asks/.share.refactor.last"; : >"$T/send.log"
  out="$(on pc do_spl_spawn_place WINDOWS=40 SPAWN_SHARE_SUPPLY_MIN=60 SPAWN_SHARE_BANDS= RHYTHM_NOW="${ph#* }" 2>&1)"
  if grep -q "^c-001 c-002 note spawn-share \*\*SPAWN SHARE: bug share 18% < 20% (2 of 11 live lanes with a class)" "$T/send.log" &&
     [[ "$(grep -c "SPAWN SHARE" "$T/send.log")" == 1 ]]; then
    pass "supply by ${ph%% *}: bug 18% under the owner's 20% -> ONE blocker naming 20%, not the ${ph%% *} band"
  else fail "supply by ${ph%% *}: $out | $(sends)"; fi
done
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
printf 'brief text\n%s\n' "$ES" >"$T/briefs/qto-gap.md"
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
grep -qx "qto-gap SPAWN_LANE_TOPIC=<unset>" "$T/launch.log.env" &&
  pass "C6c twin: an ask topic dispatch-88982c94-p (an alias) sets no SPAWN_LANE_TOPIC" || fail "C6c twin: $(cat "$T/launch.log.env" 2>&1)"
put "$P2" c-002@box-desk dispatch-88982c94 "SPAWN REQUEST sathand"
on pc do_spl_spawn_enqueue ASK_ID="$P2" SPAWN_CLASS=bug SPAWN_PLACE=claude:sathand-qto-gap >/dev/null 2>&1
: >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-502 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$P2")")" == "placed: c-502@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/qto-gap.md qto-gap SPAWN_BOX=sat$" "$T/launch.log" &&
  pass "sathand-qto-gap: same brief, SPAWN_BOX=sat" || fail "sathand: $out | $(cat "$T/launch.log")"
grep -qx "qto-gap SPAWN_LANE_TOPIC=88982c94" "$T/launch.log.env" &&
  pass "spec 153 3.12: an ask topic dispatch-88982c94 launches with its 8 hex for the hub to resolve" || fail "3.12 ask topic: $(cat "$T/launch.log.env" 2>&1)"
put "$P3" c-002@box-desk dispatch-88982c94-r "SPAWN REQUEST needs judgement"
on pc do_spl_spawn_enqueue ASK_ID="$P3" SPAWN_CLASS=bug >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$P3")")" == acked && ! -e "$T/pc/spool/asks/.place.last" ]] && grep -q "place ask ${P3:0:8} now" "$T/send.log" &&
  pass "a hand-off to the holder burns no SPAWN_PLACE_GAP_MIN slot (control: the launch above touched .place.last)" ||
  fail "hand-off slot: $out | $(ls -la "$T/pc/spool/asks/")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$P3" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null

# 12b. SPL-4009: a row pinned to a full box blocks nothing -----------------------
# The head pinned to sat past its overflow mark leaves this tick's line: the
# unpinned row behind it is placed in the same tick, the pinned one stays
# queued with its WAIT line. CONTROLS: (a) every row pinned to the full box
# -> nothing launched, each gets its hold line; (b) sat with room -> the
# pinned head is placed first, as before.
W1=d4d4d4d4-0000-4000-8000-000000000004; W2=d5d5d5d5-0000-4000-8000-000000000005
W3=d6d6d6d6-0000-4000-8000-000000000006; W4=d7d7d7d7-0000-4000-8000-000000000007
pinwait() { grep "^$1"$'\t' "$T/pc/spool/asks/.place.wait" 2>/dev/null | cut -f3; }
put "$W1" c-002@box-desk dispatch-88982c94-s "SPAWN REQUEST pinned to sat, at the head"
put "$W2" c-002@box-desk dispatch-88982c94-t "SPAWN REQUEST unpinned, behind it"
on pc do_spl_spawn_enqueue ASK_ID="$W1" SPAWN_CLASS=bug SPAWN_PLACE=claude:hand-sat-qto-gap >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$W2" SPAWN_CLASS=bug SPAWN_PLACE=claude:qto-gap >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place "PICK_BOXES=$SAT_FULL" LAUNCH_ID=c-503 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$W1")")" == queued && "$(jq -r .reason <<<"$(hubrow "$W2")")" == "placed: c-503@box-desk" ]] &&
  grep -qx "claude auto $T $T/briefs/qto-gap.md qto-gap" "$T/launch.log" &&
  grep -q "ask ${W1:0:8} is pinned to sat: box sat at 180% is past its overflow mark" <<<"$out" &&
  [[ "$(pinwait "$W1")" == "pinned to sat: box sat at 180% is past its overflow mark"* ]] &&
  pass "12b. the head pinned to a full sat blocks nothing: the unpinned row behind it is placed, the pinned one stays queued with its WAIT line (SPL-4009)" ||
  fail "12b. pinned head blocks: $out | $(hubrow "$W1") | $(hubrow "$W2") | $(cat "$T/launch.log")"
put "$W3" c-002@box-desk dispatch-88982c94-u "SPAWN REQUEST pinned to sat too"
on pc do_spl_spawn_enqueue ASK_ID="$W3" SPAWN_CLASS=bug SPAWN_PLACE=claude:sathand-qto-gap >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last" "$T/pc/spool/asks/.place.wait"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place "PICK_BOXES=$SAT_FULL" 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$W1")")" == queued && "$(jq -r .state <<<"$(hubrow "$W3")")" == queued && ! -s "$T/launch.log" ]] &&
  [[ "$(pinwait "$W1")" == "pinned to sat:"* && "$(pinwait "$W3")" == "pinned to sat:"* ]] &&
  grep -q "the spawn queue is empty" <<<"$out" && [[ ! -e "$T/pc/spool/asks/.place.last" ]] &&
  pass "12b. control (a): every queued row pinned to the full sat: nothing launched, each gets its hold line" ||
  fail "12b. control (a): $out | $(cat "$T/launch.log") | $(cat "$T/pc/spool/asks/.place.wait" 2>&1)"
put "$W4" c-002@box-desk dispatch-88982c94-v "SPAWN REQUEST unpinned, behind two pinned"
on pc do_spl_spawn_enqueue ASK_ID="$W4" SPAWN_CLASS=bug SPAWN_PLACE=claude:qto-gap >/dev/null 2>&1
: >"$T/launch.log"
out="$(on pc do_spl_spawn_place "PICK_BOXES=$SAT_BUSY" LAUNCH_ID=c-504 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$W1")")" == "placed: c-504@box-desk" && "$(jq -r .state <<<"$(hubrow "$W4")")" == queued ]] &&
  grep -qx "claude auto $T $T/briefs/qto-gap.md qto-gap SPAWN_BOX=sat" "$T/launch.log" && [[ -z "$(pinwait "$W1")" ]] &&
  pass "12b. control (b): sat with room: the pinned head is placed first, as before, its WAIT line gone" ||
  fail "12b. control (b): $out | $(hubrow "$W1") | $(cat "$T/launch.log")"
for i in $(qids); do HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done

# 12c. SPL-4265: a launcher HOLD (spawn-window exit 10) of the head burns no
# gap slot and blocks nothing: the next row the placer can launch is placed
# in the same tick, the held head keeps position 1. Before, .place.last was
# touched before the launch, the HOLD left it armed with no .place.agent, and
# the gap held the whole queue SPAWN_PLACE_GAP_MIN behind the same head (15
# HOLD lines and 40 rows unplaced on sat, 2026-10-29). CONTROLS: a hold with
# nothing launchable behind it leaves .place.last as it was (absent, or its
# old time); a real launch still arms the gap.
G1=9a9a9a9a-0000-4000-8000-000000000001; G2=9b9b9b9b-0000-4000-8000-000000000002
printf 'brief text\n%s\n' "$ES" >"$T/briefs/grok-head.md"
put "$G1" c-002@box-desk dispatch-88982c94-w "SPAWN REQUEST a held grok head"
put "$G2" c-002@box-desk dispatch-88982c94-x "SPAWN REQUEST a claude row behind it"
on pc do_spl_spawn_enqueue ASK_ID="$G1" SPAWN_CLASS=bug SPAWN_PLACE=claude:grok-head >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$G2" SPAWN_CLASS=bug SPAWN_PLACE=claude:qto-gap >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last" "$T/pc/spool/asks/.place.agent"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 LAUNCH_HOLD_SLUG=grok-head LAUNCH_ID=c-505 2>&1)"
g1="$(listrow "$G1")"
[[ "$(jq -r .state <<<"$g1")" == queued && "$(jq -r .position <<<"$g1")" == 1 && "$(jq -r .reason <<<"$(hubrow "$G2")")" == "placed: c-505@box-desk" ]] &&
  grep -q "ask ${G1:0:8}: the launcher says HOLD (waiting: grok weekly >= 90% on box-a): back in line at position 1" <<<"$out" &&
  [[ "$(sed -n 2p "$T/launch.log")" == "claude auto $T $T/briefs/qto-gap.md qto-gap" && "$(cat "$T/pc/spool/asks/.place.agent" 2>/dev/null)" == c-505@box-desk ]] &&
  pass "12c. a launcher HOLD of the head blocks nothing: the row behind it is placed in the same tick, the held head keeps position 1 (SPL-4265)" ||
  fail "12c. held head blocks the queue: $out | $g1 | $(hubrow "$G2") | $(cat "$T/launch.log")"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 LAUNCH_HOLD_SLUG=grok-head 2>&1)"
grep -q "hold: the last placement started under 3 min ago (the floor)" <<<"$out" && [[ "$(jq -r .state <<<"$(hubrow "$G1")")" == queued ]] &&
  pass "12c. control: the real launch of the row behind armed the gap" || fail "12c. gap after the launch: $out"
for i in $(qids); do [[ "$i" == "$G1" ]] || HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 LAUNCH_HOLD_SLUG=grok-head 2>&1)"
[[ ! -e "$T/pc/spool/asks/.place.last" && "$(jq -r .state <<<"$(hubrow "$G1")")" == queued && "$(grep -c . "$T/launch.log")" == 1 ]] &&
  pass "12c. a HOLD with nothing launchable behind it burns no gap slot: .place.last stays absent" ||
  fail "12c. the hold burned the gap: $out | $(cat "$T/launch.log")"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 LAUNCH_HOLD_SLUG=grok-head 2>&1)"
! grep -q "hold: the last placement" <<<"$out" && grep -q "ask ${G1:0:8}: the launcher says HOLD" <<<"$out" &&
  pass "12c. the next tick tries the held head again, no gap hold (before: 'no heartbeat' for SPAWN_PLACE_GAP_MIN)" ||
  fail "12c. next tick: $out"
old_t=$(( $(date +%s) - 20 * 60 )); touch -d "@$old_t" "$T/pc/spool/asks/.place.last"
on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 LAUNCH_HOLD_SLUG=grok-head >/dev/null 2>&1
[[ "$(stat -c %Y "$T/pc/spool/asks/.place.last")" == "$old_t" ]] &&
  pass "12c. a HOLD keeps an older .place.last at its time (the last real launch)" ||
  fail "12c. .place.last moved: $(stat -c %Y "$T/pc/spool/asks/.place.last") != $old_t"
for i in $(qids); do HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done

# 12d. SPL-5143: a pinned box that never answers (spawn-window exit 8 on
# spawn-remote exit 5) HOLDS like a full box: no gap slot, the next row in the
# same tick, the pinned row queued, one log line a tick, no blocker. Before,
# each failure re-armed the gap and the row was picked first again: 4 h with
# nothing placed, 2026-11-07. CONTROL: another exit 8 (the box refused) still
# fails as before, gap armed and the holder told.
D1=9c9c9c9c-0000-4000-8000-000000000001; D2=9d9d9d9d-0000-4000-8000-000000000002
D3=9e9e9e9e-0000-4000-8000-000000000003; D4=9f9f9f9f-0000-4000-8000-000000000004
D5=90909090-0000-4000-8000-000000000005; D6=91919191-0000-4000-8000-000000000006
printf 'brief text\n%s\n' "$ES" >"$T/briefs/dark-pin.md"
printf '# Review of a lane\n%s\n' "$ES" >"$T/briefs/dark-seat-reviewer.md"
printf 'brief text\n%s\n' "$ES" >"$T/briefs/dark-behind.md"
dark_row() {  # ID SLUG
  put "$1" c-002@box-desk "dispatch-5143-${1:0:4}" "SPAWN REQUEST $2"
  on pc do_spl_spawn_enqueue ASK_ID="$1" SPAWN_CLASS=bug SPAWN_PLACE="claude:$2" >/dev/null 2>&1
}
dark_tick() {  # [env...]: a tick once the 10 min gap has passed
  [[ ! -e "$T/pc/spool/asks/.place.last" ]] || touch -d "@$(( $(date +%s) - 11 * 60 ))" "$T/pc/spool/asks/.place.last"
  on pc do_spl_spawn_place SPAWN_PLACE_GAP_MIN=10 SPAWN_PLACE_DARK_RETRY_MIN=0 LAUNCH_DARK_SLUG=dark-pin "$@" 2>&1
}
dark_placed() { local i n=0; for i in "$@"; do [[ "$(jq -r .reason <<<"$(hubrow "$i")")" == placed:* ]] && n=$((n + 1)); done; echo "$n"; }
dark_row "$D1" hand-sat-dark-pin; dark_row "$D2" dark-behind; dark_row "$D3" dark-behind; dark_row "$D4" dark-behind
rm -f "$T/pc/spool/asks/.place.last" "$T/pc/spool/asks/.place.agent"; : >"$T/launch.log"; : >"$T/send.log"
lines=0
for n in 1 2 3; do
  out="$(dark_tick LAUNCH_ID=c-50$n)"
  lines=$(( lines + $(grep -c "ask ${D1:0:8}: no reply from sat" <<<"$out") ))
done
[[ "$(grep -c ' dark-pin SPAWN_BOX=sat$' "$T/launch.log")" == 3 && "$(dark_placed "$D2" "$D3" "$D4")" == 3 ]] &&
  pass "12d. three silent launches of a pinned row: the three rows behind it are placed" ||
  fail "12d. placed $(dark_placed "$D2" "$D3" "$D4") of 3 behind it: $(cat "$T/launch.log")"
[[ "$(jq -r .state <<<"$(hubrow "$D1")")" == queued && "$(jq -r .position <<<"$(listrow "$D1")")" == 1 && "$lines" == 3 ]] &&
  grep -q "^$D1"$'\t'".*no reply from sat" "$T/pc/spool/asks/.place.wait" &&
  pass "12d. the pinned row stays queued at position 1, one log line a tick, its reason in .place.wait" ||
  fail "12d. pinned row: $(hubrow "$D1") lines=$lines"
! grep -q "${D1:0:8}" "$T/send.log" && pass "12d. a dark box sends the holder no failure blocker per tick" || fail "12d. blocker: $(sends)"
dark_row "$D5" dark-behind; dark_row "$D6" hand-sat-dark-seat-reviewer
printf '2026-01-15T12:00Z\t%s\t%s\tc-001@box-desk\n' "$D6" "$(sed -n 's/^SPL_SPAWN_REVIEW_SEAT_GO=//p' "$PROJ_ROOT/src/bash/run/spl-spawn-enqueue.func.sh")" >>"$T/pc/spool/asks/bypass.tsv"
out="$(dark_tick "LAUNCH_DARK_SLUG=dark-pin dark-seat-reviewer" LAUNCH_ID=c-504)"
grep -q "review-seat pick: ask ${D6:0:8}" <<<"$out" && [[ "$(jq -r .state <<<"$(hubrow "$D6")")" == queued && "$(dark_placed "$D5")" == 1 ]] &&
  pass "12d. a review seat picked ahead of the bands, its box silent: the next row is placed in the same tick" ||
  fail "12d. seat pick: $out | $(hubrow "$D5")"
sed -i "/$D6/d" "$T/pc/spool/asks/bypass.tsv"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$D6" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/send.log"
out="$(dark_tick LAUNCH_DARK_SLUG= LAUNCH_RC=8 "LAUNCH_ERR=spawn-window: the spawn on SPAWN_BOX=sat did not start (spawn-remote exit 4)")"
[[ -e "$T/pc/spool/asks/.place.last" ]] && grep -q "the launch of claude:dark-pin failed (exit 8)" <<<"$out" && grep -q "ask ${D1:0:8} (claude:dark-pin) failed" "$T/send.log" &&
  pass "12d. CONTROL: a box that refused (remote exit 4) still fails: gap armed, the holder told" ||
  fail "12d. control: $out | $(sends)"
for i in $(qids); do HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done

# 12e. SPL-5143, R7 W1/W2/N1: a box that gave no reply is tried once per
# SPAWN_PLACE_DARK_RETRY_MIN and its rows leave the line meanwhile, so they
# use none of a tick's SPAWN_PLACE_HOLD_TRIES. A row dark for
# SPAWN_PLACE_DARK_ALARM_MIN gets one blocker; its wait line keeps the start.
rm -f "$T/pc/spool/asks/.place.dark"
E0=e0e0e0e0-0000-4000-8000-00000000000; E1=e8e8e8e8-0000-4000-8000-00000000000; E7=e7e7e7e7-0000-4000-8000-00000000000
DF="$T/pc/spool/asks/.place.dark"
for n in 1 2 3 4 5 6; do printf 'brief text\n%s\n' "$ES" >"$T/briefs/dk$n.md"; done
dk_tick() { dark_tick SPAWN_PLACE_DARK_RETRY_MIN=30 "LAUNCH_DARK_SLUG=dk1 dk2 dk3 dk4 dk5" "$@"; }
dk_clean() { for i in $(qids); do HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$i" --by c-001@box-desk --reason "placed: c-499@box-desk" >/dev/null; done; rm -f "$DF" "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"; }
dk_clean
for n in 1 2 3 4 5; do dark_row "${E0}$n" "hand-sat-dk$n"; done; dark_row "${E0}6" dk6
out="$(dk_tick LAUNCH_ID=c-510)"
[[ "$(grep -c ' dk[1-5] SPAWN_BOX=sat$' "$T/launch.log")" == 1 && "$(dark_placed "${E0}6")" == 1 ]] &&
  pass "12e. five rows on one silent box: one launch tried, the row behind them placed in the same tick" ||
  fail "12e. one box: placed $(dark_placed "${E0}6"): $(cat "$T/launch.log")"
[[ "$(jq -r .state <<<"$(hubrow "${E0}1")")" == queued && "$(jq -r .state <<<"$(hubrow "${E0}5")")" == queued ]] &&
  pass "12e. the rows pinned to the silent box stay queued" || fail "12e. rows: $(hubrow "${E0}1")"
: >"$T/launch.log"; dark_row "${E1}1" dk6
out="$(dk_tick LAUNCH_ID=c-511)"
[[ "$(grep -c ' dk[1-5] SPAWN_BOX=' "$T/launch.log")" == 0 && "$(dark_placed "${E1}1")" == 1 && "$(grep -c "ask ${E0:0:8}" <<<"$out")" -ge 1 ]] &&
  grep -q "^${E0}1"$'\t'".*no reply from sat since " "$T/pc/spool/asks/.place.wait" &&
  pass "12e. inside the retry window the silent box costs no launch, the wait line carries its start" ||
  fail "12e. window: $out | $(cat "$T/launch.log")"
awk -F'\t' -v OFS='\t' -v o="$(( $(date +%s) - 3 * 3600 ))" '{ $3 = o; print }' "$DF" >"$DF.t" && mv "$DF.t" "$DF"
: >"$T/send.log"; dark_row "${E1}2" dk6; dk_tick LAUNCH_ID=c-512 >/dev/null
first="$(grep -c "${E0:0:8}" "$T/send.log")"
dark_row "${E1}3" dk6; dk_tick LAUNCH_ID=c-513 >/dev/null
[[ "$first" -ge 1 && "$(grep -c "${E0:0:8}" "$T/send.log")" == "$first" ]] && grep -q 'no reply' "$T/send.log" &&
  pass "12e. a row dark past the alarm mark tells the holder once, not per tick" ||
  fail "12e. alarm: first=$first $(sends)"
awk -F'\t' -v OFS='\t' -v o="$(( $(date +%s) - 31 * 60 ))" '{ $4 = o; print }' "$DF" >"$DF.t" && mv "$DF.t" "$DF"
: >"$T/launch.log"; dark_row "${E1}4" dk6; dk_tick LAUNCH_ID=c-514 >/dev/null
[[ "$(grep -c ' dk[1-5] SPAWN_BOX=sat$' "$T/launch.log")" == 1 && "$(dark_placed "${E1}4")" == 1 ]] &&
  pass "12e. the retry window over: one row of the box is tried again, one only" ||
  fail "12e. retry: $(cat "$T/launch.log")"
awk -F'\t' -v OFS='\t' -v o="$(( $(date +%s) - 31 * 60 ))" '{ $4 = o; print }' "$DF" >"$DF.t" && mv "$DF.t" "$DF"
dark_tick SPAWN_PLACE_DARK_RETRY_MIN=30 LAUNCH_DARK_SLUG= LAUNCH_ID=c-515 >/dev/null
[[ "$(grep -c $'\tsat\t' "$DF")" == 0 ]] && pass "12e. a launch that starts on the box clears its dark state" || fail "12e. clear: $(cat "$DF")"
dk_clean
for n in 1 2 3 4 5; do dark_row "${E7}$n" "hand-bx$n-dk$n"; done; dark_row "${E7}6" dk6
dk_tick LAUNCH_ID=c-516 >/dev/null; dk_tick LAUNCH_ID=c-517 >/dev/null
[[ "$(grep -c ' dk[1-5] SPAWN_BOX=' "$T/launch.log")" == 5 && "$(dark_placed "${E7}6")" == 1 ]] &&
  pass "12e. five silent boxes: five tries once, the next tick places the row behind them" ||
  fail "12e. five boxes: $(cat "$T/launch.log")"
dk_clean
# N1: the placer matches spawn-window's own line, so the real text is pinned
grep -qF 'did not start (spawn-remote exit ${rc})" >&2; exit 8' "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-window.sh" &&
  grep -qF "'did not start (spawn-remote exit 5)\$'" "$PROJ_ROOT/src/bash/run/spl-spawn-place.func.sh" &&
  pass "12e. spawn-window's pinned exit 8 line is the text the placer matches" ||
  fail "12e. the launcher's line and the placer's match differ"

# 13. SPL-2263 (owner HUM-10, t1 b61851fb): a mistral placement whose brief
# names csi-spl-wui/ launches claude while mistral_ui_allowed is not true
# (APP_PATH=$T has no cnf: the default false); SPL-2942: agy for a
# specs_and_docs or i18n kind. CONTROL: a docs brief keeps mistral.
U1=b7b7b7b7-0000-4000-8000-000000000001; U2=b8b8b8b8-0000-4000-8000-000000000002
U3=b9b9b9b9-0000-4000-8000-000000000003; U4=babababa-0000-4000-8000-000000000004
printf 'Kind: i18n. Translate the hover in csi-spl-wui/src/components/x.vue\n%s\n' "$ES" >"$T/briefs/ui-hover.md"
printf 'Class: bug. Kind: specs_and_docs. Rewrite csi-spl-doc/doc/md/x.md\n%s\n' "$ES" >"$T/briefs/docs-x.md"
put "$U1" c-002@box-desk dispatch-b61851fb-u "SPAWN REQUEST ui hover"
on pc do_spl_spawn_enqueue ASK_ID="$U1" SPAWN_CLASS=bug SPAWN_PLACE=mistral:ui-hover >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-503 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$U1")")" == "placed: c-503@box-desk" ]] &&
  grep -q "^agy auto $T $T/briefs/ui-hover.md ui-hover$" "$T/launch.log" &&
  grep -q "placed as mistral, launched as agy: mistral takes no UI work until do_spl_vendor_ui_retest passes" <<<"$out" &&
  pass "a mistral placement with a Kind: i18n WUI brief launches agy" || fail "ui placement: $out | $(cat "$T/launch.log")"
printf 'Kind: specs_and_docs\nR7 review of a claude row; files csi-spl-wui/src/pages/docs.vue\n%s\n' "$ES" >"$T/briefs/ui-review.md"
put "$U3" c-002@box-desk dispatch-b61851fb-w "SPAWN REQUEST ui review"
on pc do_spl_spawn_enqueue ASK_ID="$U3" SPAWN_CLASS=bug SPAWN_PLACE=mistral:ui-review >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=a-507 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$U3")")" == "placed: a-507@box-desk" ]] &&
  grep -q "^agy auto $T $T/briefs/ui-review.md ui-review$" "$T/launch.log" &&
  grep -q "placed as mistral, launched as agy: mistral takes no UI work" <<<"$out" &&
  pass "SPL-2942: a mistral placement with a Kind: specs_and_docs WUI brief launches agy, not claude" || fail "ui review placement: $out | $(cat "$T/launch.log")"
printf 'env:\n  box:\n    agent_split:\n      mistral_coding_allowed: true\n' >"$T/coding-on-13.yaml"
printf 'Kind: complex_coding\nSplit csi-spl-wui/src/pages/docs.vue\n%s\n' "$ES" >"$T/briefs/ui-code.md"
put "$U4" c-002@box-desk dispatch-b61851fb-x "SPAWN REQUEST ui code"
on pc do_spl_spawn_enqueue ASK_ID="$U4" SPAWN_CLASS=bug SPAWN_PLACE=mistral:ui-code SPAWN_PLACE_CNF="$T/coding-on-13.yaml" >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-508 SPAWN_PLACE_CNF="$T/coding-on-13.yaml" 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$U4")")" == "placed: c-508@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/ui-code.md ui-code$" "$T/launch.log" &&
  grep -q "placed as mistral, launched as claude: mistral takes no UI work" <<<"$out" &&
  pass "SPL-2942 control: a Kind: complex_coding WUI brief still launches claude" || fail "ui code placement: $out | $(cat "$T/launch.log")"
put "$U2" c-002@box-desk dispatch-b61851fb-v "SPAWN REQUEST docs"
on pc do_spl_spawn_enqueue ASK_ID="$U2" SPAWN_CLASS=bug SPAWN_PLACE=mistral:docs-x >/dev/null 2>&1
: >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=m-504 2>&1)"
grep -q "^mistral auto $T $T/briefs/docs-x.md docs-x$" "$T/launch.log" &&
  pass "control: a mistral placement with a docs brief stays mistral" || fail "docs placement: $out | $(cat "$T/launch.log")"
# SPL-3627 (ask c581963b): a data-rule brief (a "Data: secret" line, or the
# prose "Data rule:" the c003 reviewer brief carried) swaps to claude, never
# agy or qwen, even as a specs_and_docs WUI review. The SPL-2942 case above
# (no marker) is its control: it still launches agy.
D1=bcbcbcbc-0000-4000-8000-000000000001; D2=bdbdbdbd-0000-4000-8000-000000000002
printf 'Kind: specs_and_docs\nData: secret\nR7 review; files csi-spl-wui/src/utils/search.mjs\n%s\n' "$ES" >"$T/briefs/ui-data.md"
printf 'Kind: specs_and_docs\nYou review. Data rule: claude, grok or mistral review it, never agy or qwen.\n5. `git grep -n "in:" -- csi-spl-wui/src/utils/search.mjs`\n%s\n' "$ES" >"$T/briefs/ui-data-prose.md"
for d in "$D1 ui-data c-509" "$D2 ui-data-prose c-510"; do
  read -r did dslug dlid <<<"$d"
  put "$did" c-002@box-desk "dispatch-placer-vendor-$dslug" "SPAWN REQUEST $dslug"
  on pc do_spl_spawn_enqueue ASK_ID="$did" SPAWN_CLASS=bug SPAWN_PLACE="mistral:$dslug" >/dev/null 2>&1
  rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
  out="$(on pc do_spl_spawn_place LAUNCH_ID="$dlid" 2>&1)"
  grep -q "^claude auto $T $T/briefs/$dslug.md $dslug$" "$T/launch.log" && ! grep -qE '^(agy|qwen) ' "$T/launch.log" &&
    grep -q "placed as mistral, launched as claude: mistral takes no UI work.*; the brief is under the data rule" <<<"$out" &&
    pass "SPL-3627: a mistral data-rule brief ($dslug, specs_and_docs, names csi-spl-wui/) launches claude, never agy or qwen" ||
    fail "data rule $dslug: $out | $(cat "$T/launch.log")"
done
# SPL-3776 (ask 47d75020): a mistral review seat (slug ending -reviewer) on a
# Kind: secret brief writes no code: it stays mistral, never claude for a
# claude author. CONTROL: a mistral coding row on a secret brief still swaps,
# to claude, never agy. A review seat's swap onto its author's vendor is
# refused: handed back to the holder, nothing launched; an Author: line names
# the author, else every lane id the brief names (role seats 001-003 aside).
# SPL-3954 (owner HUM-10, t1 1be0e370, msg 594d77e1: "Mistral may review
# them, read-only"): the UI rule never swaps a review seat either, so a
# mistral -reviewer seat whose brief names csi-spl-wui/ stays mistral; a
# mistral review seat on a mistral author is refused. The ui-code and
# ui-hover rows of 13 are the control: a mistral build row on WUI still swaps.
R1=c3c3c3c3-0000-4000-8000-000000000001; R2=c4c4c4c4-0000-4000-8000-000000000002
R3=c5c5c5c5-0000-4000-8000-000000000003; R4=c6c6c6c6-0000-4000-8000-000000000004
printf 'Kind: secret\nThe cross-vendor R7 reviewer of c-709@box-desk, review only.\n%s\n' "$ES" >"$T/briefs/sec-x-reviewer.md"
printf 'Kind: secret\nRotate the unlock key handling in csi-spl-api.\n%s\n' "$ES" >"$T/briefs/sec-code.md"
R5=c7c7c7c7-0000-4000-8000-000000000005
printf 'Kind: secret\nAuthor: m-709@box-desk\nR7 review of m-709@box-desk; files csi-spl-wui/src/utils/key.mjs; asks go to c-001.\n%s\n' "$ES" >"$T/briefs/sec-ui-reviewer.md"
printf 'Kind: secret\nAuthor: g-709@box-desk\nR7 review of g-709 (prior seat c-711); files csi-spl-wui/src/utils/key.mjs\n%s\n' "$ES" >"$T/briefs/sec-grok-reviewer.md"
printf 'Kind: specs_and_docs\nAuthor: c-715@box-desk\nR7 review of c-715; files csi-spl-wui/src/pages/docs.vue\n%s\n' "$ES" >"$T/briefs/ui-docs-reviewer.md"
for r in "$R1 sec-x-reviewer m-511 mistral" "$R2 sec-code c-512 claude" "$R4 sec-grok-reviewer m-514 mistral" "$R5 ui-docs-reviewer m-515 mistral"; do
  read -r rid rslug rlid rto <<<"$r"
  put "$rid" c-002@box-desk "dispatch-spl3776-$rslug" "SPAWN REQUEST $rslug"
  on pc do_spl_spawn_enqueue ASK_ID="$rid" SPAWN_CLASS=bug SPAWN_KIND=specs_and_docs SPAWN_PLACE="mistral:$rslug" >/dev/null 2>&1
  rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
  out="$(on pc do_spl_spawn_place LAUNCH_ID="$rlid" 2>&1)"
  [[ "$(jq -r .reason <<<"$(hubrow "$rid")")" == "placed: $rlid@box-desk" ]] &&
    grep -q "^$rto auto $T $T/briefs/$rslug.md $rslug$" "$T/launch.log" && ! grep -qE '^(agy|qwen) ' "$T/launch.log" &&
    pass "SPL-3776/SPL-3954: mistral:$rslug launches $rto, never agy or qwen" ||
    fail "SPL-3776 $rslug: want $rto: $out | $(cat "$T/launch.log")"
done
put "$R3" c-002@box-desk dispatch-spl3776-sec-ui-reviewer "SPAWN REQUEST sec-ui-reviewer"
on pc do_spl_spawn_enqueue ASK_ID="$R3" SPAWN_CLASS=bug SPAWN_KIND=specs_and_docs SPAWN_PLACE=mistral:sec-ui-reviewer >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-513 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$R3")")" == acked && ! -s "$T/launch.log" && ! -e "$T/pc/spool/asks/.place.last" ]] &&
  grep -q "place ask ${R3:0:8} now.*review seat on mistral would review its author's vendor (mistral: m-709)" "$T/send.log" &&
  grep -q "WARN ask ${R3:0:8}: placed as mistral, its swap is refused: .*review seat on mistral" <<<"$out" &&
  pass "SPL-3776: a mistral review seat on a mistral author is handed back, nothing launched" ||
  fail "SPL-3776 refusal: $out | launch: $(cat "$T/launch.log") | $(sends) | $(hubrow "$R3")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$R3" --by c-001@box-desk --reason "placed: g-513@box-desk" >/dev/null

# 13b. SPL-3018: the agy swap target out of quota. Its record on this box is
# agy's banner in the watchdog's pane capture (ctx*/a-*/pane, reset = the
# capture's mtime + "Resets in"), or lane-mix's S2 kind=limit verdict on an
# a- lane. A review row (Kind: review, or "review" in the brief's name or
# first heading) HOLDS, queued, one INFO line with the reset, and blocks no
# other row; a non-review docs row launches claude; a stale banner = agy in.
Q1=bbbb0001-0000-4000-8000-000000000001; Q2=bbbb0002-0000-4000-8000-000000000002
WD13="$T/pc/spool/dispatch/wd"
mkdir -p "$WD13/ctx.3/a-860"
printf '> Read and follow your seed\n\n⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\nError ID: x-1\n' >"$WD13/ctx.3/a-860/pane"
printf '# Lane brief: the cross-vendor R7 reviewer of row B8\nKind: specs_and_docs\nfiles csi-spl-wui/src/pages/docs.vue\n%s\n' "$ES" >"$T/briefs/ui-r7.md"
printf 'Kind: specs_and_docs\nRewrite the help text in csi-spl-wui/src/pages/help.vue\n%s\n' "$ES" >"$T/briefs/ui-help.md"
put "$Q1" c-002@box-desk dispatch-placer-agy-quota "SPAWN REQUEST ui r7"
on pc do_spl_spawn_enqueue ASK_ID="$Q1" SPAWN_CLASS=bug SPAWN_PLACE=mistral:ui-r7 >/dev/null 2>&1
put "$Q2" c-002@box-desk dispatch-placer-agy-quota "SPAWN REQUEST ui help"
on pc do_spl_spawn_enqueue ASK_ID="$Q2" SPAWN_CLASS=bug SPAWN_PLACE=mistral:ui-help >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-511 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$Q1")")" == queued ]] && ! grep -q "ui-r7" "$T/launch.log" &&
  grep -q "INFO hold: ask ${Q1:0:8}: a review row stays cross-vendor (SPL-2942), and agy is out of quota until 20[0-9-]*T[0-9:]*Z (a-860 banner" <<<"$out" &&
  grep -q "^${Q1}"$'\t'".*agy is out of quota until" "$T/pc/spool/asks/.place.wait" &&
  pass "SPL-3018: agy out + a review row: held, queued, not launched, the reset named" || fail "agy out review: $out | $(cat "$T/launch.log")"
[[ "$(jq -r .reason <<<"$(hubrow "$Q2")")" == "placed: c-511@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/ui-help.md ui-help$" "$T/launch.log" &&
  grep -q "placed as mistral, launched as claude: .*agy is out of quota until" <<<"$out" &&
  pass "SPL-3018: agy out + a non-review docs row: claude, and the held review row blocks it not" || fail "agy out docs: $out | $(cat "$T/launch.log")"
rm -rf "$WD13/ctx.3"; mkdir -p "$WD13/ctx.1/a-861"
echo 'HIT S2 kind=limit pane: quota' >"$WD13/ctx.1/a-861/out.s2"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=a-512 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$Q1")")" == queued && ! -s "$T/launch.log" ]] &&
  grep -q "INFO hold: ask ${Q1:0:8}: .*agy is out of quota until .*(a-861 S2 kind=limit" <<<"$out" &&
  pass "SPL-3018: lane-mix's S2 kind=limit verdict on an a- lane holds it too" || fail "agy verdict: $out | $(cat "$T/launch.log")"
rm -rf "$WD13/ctx.1"; mkdir -p "$WD13/ctx.3/a-860"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WD13/ctx.3/a-860/pane"
touch -d '14 hours ago' "$WD13/ctx.3/a-860/pane"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=a-513 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$Q1")")" == "placed: a-513@box-desk" ]] &&
  grep -q "^agy auto $T $T/briefs/ui-r7.md ui-r7$" "$T/launch.log" && ! grep -q "^${Q1}"$'\t' "$T/pc/spool/asks/.place.wait" &&
  pass "SPL-3018 control: a banner past its reset = agy in: the review row launches agy" || fail "agy in: $out | $(cat "$T/launch.log")"
rm -rf "$WD13"

# 13b2. SPL-3846: agy_out reads only live lanes. A box on 2026-10-27 held every
# agy row until 10-30T22:5xZ on dead a-338/a-665 captures ("Resets in 91h")
# and a 90-min-old S2, while agy answered on both boxes. Live = an id in a
# fresh agent-run.tsv; an answered probe (dispatch/vendor-probe/agy.ok) drops
# any record not newer than it.
AR="$T/pc/spool/dispatch/agent-run.tsv"
agyout() { on pc 'spl_spawn_place_agy_out' 2>&1; }
runrep() { { echo "# agent-run v1 ${2:-$(date +%s)}"; for i in $1; do printf '%s\trun\n' "$i"; done; } >"$AR"; }
mkdir -p "$WD13/ctx.3/a-338"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 91h.\n' >"$WD13/ctx.3/a-338/pane"
runrep "c-001 a-900"
out="$(agyout)"
[[ -z "$out" ]] && pass "SPL-3846: the banner of a dead a- id (not in a fresh agent-run.tsv) holds nothing" || fail "dead banner: $out"
runrep "c-001 a-338"
out="$(agyout)"
grep -q "agy is out of quota until 20[0-9-]*T[0-9:]*Z (a-338 banner, Resets in 91h" <<<"$out" &&
  pass "SPL-3846 control: the same banner on a live id still holds" || fail "live banner: $out"
runrep "c-001 a-900" "$(( $(date +%s) - 900 ))"
out="$(agyout)"
[[ -n "$out" ]] && pass "SPL-3846 control: a stale agent-run.tsv = liveness unknown, the banner holds as before" || fail "stale report: $out"
# SPL-4965: the watchdog rewrites its capture each pass, so the mtime is no read
# time: "until" rolled forward for as long as a static banner stayed on screen.
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 1h0m0s.\n' >"$WD13/ctx.3/a-338/pane"
touch -d '3 hours ago' "$WD13/ctx.3/a-338/pane"; rm -f "$T/pc/spool/dispatch/vendor-probe/agy-limit-seen.tsv"; runrep "c-001 a-338"
out="$(agyout)"
[[ -z "$out" ]] && pass "SPL-4965: a 1 h banner read 3 h ago holds nothing" || fail "old banner: $out"
touch "$WD13/ctx.3/a-338/pane"
out="$(agyout)"
[[ -z "$out" ]] && pass "SPL-4965 RED CONTROL: the same banner recaptured now does not roll until forward (FAILs before: until = mtime + 1 h)" || fail "rolled: $out"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 2h0m0s.\n' >"$WD13/ctx.3/a-338/pane"
out="$(agyout)"
grep -qE "agy is out of quota until 20[0-9-]*T[0-9:]*Z \(a-338 banner, Resets in 2h0m0s, read 0m ago\)" <<<"$out" &&
  pass "SPL-4965 control: a real limit, a NEW banner, holds, and the line says how old the read is" || fail "new banner: $out"
sed -i "s/^\(Resets in 2h0m0s\t\).*/\1$(( $(date +%s) - 1800 ))/" "$T/pc/spool/dispatch/vendor-probe/agy-limit-seen.tsv"; touch "$WD13/ctx.3/a-338/pane"
out="$(agyout)"
grep -q "read 30m ago)" <<<"$out" && pass "SPL-4965 control: inside its own reset the banner still holds, its age from the first sighting" || fail "aged banner: $out"
rm -rf "$WD13/ctx.3"; agyout >/dev/null
[[ ! -s "$T/pc/spool/dispatch/vendor-probe/agy-limit-seen.tsv" ]] && pass "SPL-4965: a record gone from the watchdog dir is forgotten" || fail "forget: $(cat "$T/pc/spool/dispatch/vendor-probe/agy-limit-seen.tsv")"
mkdir -p "$WD13/ctx.1/a-665"
echo 'HIT S2 kind=limit pane: quota' >"$WD13/ctx.1/a-665/out.s2"
runrep "c-001"
out="$(agyout)"
[[ -z "$out" ]] && pass "SPL-3846: the S2 kind=limit of a dead a- id holds nothing" || fail "dead S2: $out"
runrep "c-001 a-665"
out="$(agyout)"
grep -q "(a-665 S2 kind=limit" <<<"$out" && pass "SPL-3846 control: the S2 of a live id holds" || fail "live S2: $out"
mkdir -p "$T/pc/spool/dispatch/vendor-probe"; touch -d '1 hour ago' "$WD13/ctx.1/a-665/out.s2"
touch "$T/pc/spool/dispatch/vendor-probe/agy.ok"
out="$(agyout)"
[[ -z "$out" ]] && pass "SPL-3846: an agy probe that answered after the S2 drops it" || fail "probe S2: $out"
touch -d '2 hours ago' "$T/pc/spool/dispatch/vendor-probe/agy.ok"
out="$(agyout)"
grep -q "(a-665 S2 kind=limit" <<<"$out" && pass "SPL-3846 control: a probe older than the S2 drops nothing" || fail "old probe: $out"
rm -rf "$WD13" "$AR" "$T/pc/spool/dispatch/vendor-probe"

# 13b3. SPL-3998: a limit on the OTHER box holds too. On 2026-10-28 00:40Z the
# main box's watchdog sent its S2 kind=limit blockers for a-958 and a-960;
# sat's agy_out printed nothing and sat launched a-963 there 5 min later. The
# record here is that blocker, relayed into the orchestrator's inbox and
# archived by its ack; the lane is live when the lane map's load lists it in
# that box's busy_ids (its BOX-0 row, src box).
WDM="$T/pc/spool/c-001/archive"; mkdir -p "$WDM" "$T/pc/spool/dispatch/vendor-probe"
wdmsg() {  # ID BOX RESET-EPOCH TS-EPOCH
  jq -n --arg b "WATCHDOG (093 S2 kind=limit): $1 is on its usage limit until $(date -u -d "@$3" +%FT%TZ): pane: Individual quota reached, Resets in 155h41m53s.. Harness agy, OS user <HARNESS_USER>, box $2, pane %1389. No restart: a restart hits the same limit." \
    --arg ts "$(date -u -d "@$4" +%FT%TZ)" '{v: 1, msg_id: "330da055-6a5e-48a2-b6da-6b6414f73e1a", from: "c-001@\($b | capture("box (?<x>[a-z-]+),").x)", to: "c-001", kind: "blocker", task_id: "wd-x", ts: $ts, body: $b, files: []}' \
    >"$WDM/$(date -u -d "@$4" +%Y%m%dT%H%M%SZ)--c-001@$2--watchdog-093-s2-kind-limit-$1-330da055.json"
}
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${LOAD_JSON:-}"\n' >"$T/bin/load"; chmod +x "$T/bin/load"
load() { printf '{"hub":"ok","load":[{"box":"sat","here":false,"live":true,"busy_ids":%s,"src":"%s"}]}' "$1" "${2:-box}"; }
agyr() { on pc 'spl_asks_init; spl_spawn_place_agy_all_out' SPAWN_PLACE_LOAD_CMD="$T/bin/load" LOAD_JSON="$1" 2>&1; }
NOW=$(date +%s)
wdmsg a-958 sat $(( NOW + 155 * 3600 )) $(( NOW - 60 ))
out="$(agyr "$(load '["a-958","c-394"]')")"
[[ -z "$out" ]] && pass "SPL-5078: the other box's limit blocker alone is not out everywhere: this box is in" || fail "remote only: $out"
WDB="$T/pc/spool/dispatch/wd/ctx.3/a-860"; mkdir -p "$WDB"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WDB/pane"
out="$(agyr "$(load '["a-958"]')")"
grep -q "^agy is out of quota until .*(a-860 banner.*; agy on sat is at its quota limit until $(date -u -d "@$(( NOW + 155 * 3600 ))" +%FT%TZ) (a-958@sat S2 kind=limit" <<<"$out" &&
  pass "SPL-3998/SPL-5078: both boxes out: out everywhere, each box's why named" || fail "both out: $out"
out="$(agyr "$(load '["c-394"]')")"
[[ -z "$out" ]] && pass "SPL-5078: this box out, the other box's only blocker from a dead lane: that box is in, not out everywhere" || fail "dead lane: $out"
out="$(agyr "$(load '["c-394"]' rows)")"
grep -q "agy on sat is at its quota limit until" <<<"$out" && pass "SPL-5078 control: rows only = liveness unknown: the blocker counts, out everywhere" || fail "rows only: $out"
out="$(agyr "")"
grep -q "agy on sat is at its quota limit until" <<<"$out" && pass "SPL-5078 control: no lane map = liveness unknown: the blocker counts, out everywhere" || fail "no load: $out"
rm -f "$WDM"/*; wdmsg a-958 sat $(( NOW - 60 )) $(( NOW - 600 ))
out="$(agyr "$(load '["a-958"]')")"
[[ -z "$out" ]] && pass "SPL-5078 control: this box out, the other box's blocker past its reset: the other box is in" || fail "remote past: $out"
rm -rf "$WDM" "$T/pc/spool/dispatch/vendor-probe" "$T/pc/spool/dispatch/wd/ctx.3"

# 13b4. SPL-4020: the agy row's TARGET box. On 2026-10-28 08:10Z sat's placer
# launched ask 0224b02b as a-097 onto the main box, whose agy seats had all
# shown "Individual quota reached" (reset 11-03) and been closed: the
# SPL-3998 hold reads live lanes only, so nothing held, and the box pick took
# the main box. Here the pick names sat, sat's blocker is for a live a-958: a
# closed lane's blocker no longer counts (SPL-5078, 13b3).
B1=bbbb0041-0000-4000-8000-000000000041; B2=bbbb0042-0000-4000-8000-000000000042
mkdir -p "$WDM"; wdmsg a-958 sat $(( NOW + 155 * 3600 )) $(( NOW - 60 ))
RESET13=$(date -u -d "@$(( NOW + 155 * 3600 ))" +%FT%TZ)
printf 'Kind: specs_and_docs\nReview csi-spl-doc/doc/md/agy-target.md\n%s\n' "$ES" >"$T/briefs/agy-target.md"
put "$B1" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy target"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-target >/dev/null 2>&1
DESK_FULL="BOX box-desk  load5 28.8  cpus 16  180%  full  band 50..85 (box)"
agyp() { on pc do_spl_spawn_place SPAWN_PLACE_LOAD_CMD="$T/bin/load" LOAD_JSON="$(load '["a-958","c-394"]')" "$@" 2>&1; }
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyp "PICK=sat reason=below its low mark" "PICK_BOXES=$DESK_FULL")"
[[ "$(jq -r .state <<<"$(hubrow "$B1")")" == queued && ! -s "$T/launch.log" && ! -e "$T/pc/spool/asks/.place.last" ]] &&
  grep -q "INFO hold: ask ${B1:0:8}: agy on sat is at its quota limit until $RESET13 (a-958@sat S2 kind=limit, its watchdog's blocker 330da055), and box box-desk at 180% is past its overflow mark" <<<"$out" &&
  [[ "$(grep "^$B1"$'\t' "$T/pc/spool/asks/.place.wait" | cut -f3)" == "agy on sat is at its quota limit until $RESET13 "* ]] &&
  pass "13b4. SPL-4020: the pick names sat, sat's agy on its limit (lane live), this box full: HOLD, queued, the reset in .place.wait" ||
  fail "13b4. target out, here full: $out | $(hubrow "$B1") | $(cat "$T/launch.log")"
out="$(agyp "PICK=sat reason=below its low mark" LAUNCH_ID=a-541)"
[[ "$(jq -r .reason <<<"$(hubrow "$B1")")" == "placed: a-541@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-target.md agy-target SPAWN_BOX=box-desk" "$T/launch.log" &&
  grep -q "INFO ask ${B1:0:8}: agy on sat is at its quota limit until $RESET13 .*: it launches on box-desk" <<<"$out" &&
  ! grep -q "^$B1"$'\t' "$T/pc/spool/asks/.place.wait" &&
  pass "13b4. SPL-4020: the pick names sat, sat's agy on its limit, this box has room: launched on this box (SPAWN_BOX=box-desk), not on sat" ||
  fail "13b4. target out, here free: $out | $(hubrow "$B1") | $(cat "$T/launch.log")"
put "$B2" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy pinned to sat"
on pc do_spl_spawn_enqueue ASK_ID="$B2" SPAWN_CLASS=bug SPAWN_PLACE=agy:hand-sat-agy-target >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyp "PICK=box-desk reason=below its low mark")"
[[ "$(jq -r .state <<<"$(hubrow "$B2")")" == queued && ! -s "$T/launch.log" ]] &&
  grep -q "INFO hold: ask ${B2:0:8}: agy on sat is at its quota limit until $RESET13 .*, and the row is pinned there" <<<"$out" &&
  pass "13b4. SPL-4020: a row pinned to sat while sat's agy is on its limit: HOLD, not launched there" ||
  fail "13b4. pinned out: $out | $(hubrow "$B2") | $(cat "$T/launch.log")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$B2" --by c-001@box-desk --reason "placed: a-599@sat" >/dev/null
B1=bbbb0043-0000-4000-8000-000000000043
put "$B1" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy target 2"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-target >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyp "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-542)"
[[ "$(jq -r .reason <<<"$(hubrow "$B1")")" == "placed: a-542@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-target.md agy-target SPAWN_BOX=box-desk" "$T/launch.log" &&
  pass "13b4. control: the pick names this box (agy in): launched there, the box judged is its SPAWN_BOX" ||
  fail "13b4. control target in: $out | $(cat "$T/launch.log")"
# SPL-5208 (R7 W3 on SPL-5078): sat's blocker is from a CLOSED lane (a-958 not
# in sat's busy_ids). It holds no box (W1), but the login it measured may still
# be on its limit, so a row the pick sends to sat still goes to a box with no
# blocker when one is in and has room (SPL-4020, the a-097 case).
agyc() { on pc do_spl_spawn_place SPAWN_PLACE_LOAD_CMD="$T/bin/load" LOAD_JSON="$(load '["c-394"]')" "$@" 2>&1; }
B1=bbbb0045-0000-4000-8000-000000000045
put "$B1" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy target closed"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-target >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyc "PICK=sat reason=below its low mark" LAUNCH_ID=a-544)"
[[ "$(jq -r .reason <<<"$(hubrow "$B1")")" == "placed: a-544@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-target.md agy-target SPAWN_BOX=box-desk" "$T/launch.log" &&
  grep -q "INFO ask ${B1:0:8}: agy on sat .*a closed lane's blocker.*: it launches on box-desk" <<<"$out" &&
  pass "13b4. SPL-5208: the pick names sat, sat's blocker from a closed lane, this box in with room: launched on this box, not on sat" ||
  fail "13b4. closed blocker, here free: $out | $(hubrow "$B1") | $(cat "$T/launch.log")"
B1=bbbb0046-0000-4000-8000-000000000046
put "$B1" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy target closed full"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-target >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyc "PICK=sat reason=below its low mark" "PICK_BOXES=$DESK_FULL" LAUNCH_ID=a-545)"
[[ "$(jq -r .reason <<<"$(hubrow "$B1")")" == "placed: a-545@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-target.md agy-target SPAWN_BOX=sat" "$T/launch.log" &&
  ! grep -q "INFO hold: ask ${B1:0:8}" <<<"$out" &&
  pass "13b4. SPL-5208 (W1 kept): sat's blocker from a closed lane, this box full: not held, launched on sat" ||
  fail "13b4. closed blocker, here full: $out | $(hubrow "$B1") | $(cat "$T/launch.log")"
WDH="$T/pc/spool/dispatch/wd/ctx.3/a-860"; mkdir -p "$WDH"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WDH/pane"
B1=bbbb0047-0000-4000-8000-000000000047
put "$B1" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy every box out closed"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-target >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyc "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-546)"
[[ "$(jq -r .reason <<<"$(hubrow "$B1")")" == "placed: a-546@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-target.md agy-target SPAWN_BOX=sat" "$T/launch.log" &&
  ! grep -q "INFO hold: ask ${B1:0:8}" <<<"$out" &&
  pass "13b4. SPL-5208 (W1 kept): this box out, sat only on a closed lane's blocker: not held, launched on sat" ||
  fail "13b4. every box out, closed only: $out | $(hubrow "$B1") | $(cat "$T/launch.log")"
rm -rf "$T/pc/spool/dispatch/wd/ctx.3" "$T/pc/spool/dispatch/vendor-probe/agy-limit-seen.tsv"
rm -f "$WDM"/*
B1=bbbb0044-0000-4000-8000-000000000044
put "$B1" c-002@box-desk dispatch-placer-agy-out-target-box "SPAWN REQUEST agy target 3"
on pc do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-target >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(agyp "PICK=sat reason=below its low mark" LAUNCH_ID=a-543)"
[[ "$(jq -r .reason <<<"$(hubrow "$B1")")" == "placed: a-543@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-target.md agy-target" "$T/launch.log" &&
  pass "13b4. control: no blocker on any box: launched as before, no SPAWN_BOX (spawn-window picks)" ||
  fail "13b4. control no blocker: $out | $(cat "$T/launch.log")"
rm -rf "$WDM"

# 13b5. SPL-5078: an agy hold names its box. On 2026-11-04 every agy row waited
# on a banner of one box while agy answered on the other; on 2026-11-06 one box
# lost the agy program and its login, and a launch there would fail and retry.
loadc() { printf '{"hub":"ok","load":[{"box":"sat","here":false,"live":true,"busy_ids":["a-958"],"clis":%s,"src":"box"}]}' "$1"; }
C1=bbbb0051-0000-4000-8000-000000000051
printf 'Kind: specs_and_docs\nReview csi-spl-doc/doc/md/agy-box.md\n%s\n' "$ES" >"$T/briefs/agy-box.md"
agyb() { on pc do_spl_spawn_place SPAWN_PLACE_LOAD_CMD="$T/bin/load" "$@" 2>&1; }
newc() { HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$C1" --by c-001@box-desk --reason "next case" >/dev/null 2>&1; C1="bbbb00$1-0000-4000-8000-0000000000$1"; put "$C1" c-002@box-desk dispatch-placer-agy-box "SPAWN REQUEST agy box $1"; on pc do_spl_spawn_enqueue ASK_ID="$C1" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-box >/dev/null 2>&1; rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; }
newc 52
WDC="$T/pc/spool/dispatch/wd/ctx.3/a-860"; mkdir -p "$WDC"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WDC/pane"
out="$(agyb LOAD_JSON="$(loadc '["claude","agy"]')" "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-551)"
[[ "$(jq -r .reason <<<"$(hubrow "$C1")")" == "placed: a-551@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-box.md agy-box SPAWN_BOX=sat" "$T/launch.log" &&
  pass "13b5. SPL-5078: this box out of quota, the other box in: the row launches on the other box" ||
  fail "13b5. out here, in there: $out | $(hubrow "$C1") | $(cat "$T/launch.log")"
newc 53
mkdir -p "$WDM"; wdmsg a-958 sat $(( NOW + 155 * 3600 )) $(( NOW - 60 ))
out="$(agyb LOAD_JSON="$(loadc '["claude","agy"]')" "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-552)"
[[ "$(jq -r .state <<<"$(hubrow "$C1")")" == queued && ! -s "$T/launch.log" ]] &&
  grep -q "INFO hold: ask ${C1:0:8}: placed as agy, and agy is out of quota until .*; agy on sat is at its quota limit until" <<<"$out" &&
  pass "13b5. SPL-5078: both boxes out: the row waits, no launch, each box named" ||
  fail "13b5. both out: $out | $(hubrow "$C1") | $(cat "$T/launch.log")"
rm -rf "$WDM" "$T/pc/spool/dispatch/wd/ctx.3"
out="$(agyb LOAD_JSON="" SPOOL_VENDOR_CLIS_CMD="echo claude,grok" "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-553)"
[[ "$(jq -r .state <<<"$(hubrow "$C1")")" == queued && ! -s "$T/launch.log" ]] &&
  grep -q "INFO hold: ask ${C1:0:8}: placed as agy, and the agy program or its login is missing on box-desk" <<<"$out" &&
  grep -q "^$C1"$'\t'".*the agy program or its login is missing on box-desk" "$T/pc/spool/asks/.place.wait" &&
  pass "13b5. SPL-5078: agy program or login missing on the only box, no banner: the row waits, no launch, the hold line says so" ||
  fail "13b5. missing here: $out | $(hubrow "$C1") | $(cat "$T/launch.log")"
out="$(agyb LOAD_JSON="$(loadc '["claude","grok"]')" "PICK=sat reason=below its low mark" LAUNCH_ID=a-554)"
[[ "$(jq -r .reason <<<"$(hubrow "$C1")")" == "placed: a-554@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-box.md agy-box SPAWN_BOX=box-desk" "$T/launch.log" &&
  ! grep -q "^$C1"$'\t' "$T/pc/spool/asks/.place.wait" &&
  pass "13b5. SPL-5078: the target measured without agy: the row launches on the box that has it, its wait line gone" ||
  fail "13b5. missing there: $out | $(hubrow "$C1") | $(cat "$T/launch.log")"
newc 55
out="$(agyb LOAD_JSON="$(loadc '["claude","agy"]')" "PICK=sat reason=below its low mark" LAUNCH_ID=a-555)"
[[ "$(jq -r .reason <<<"$(hubrow "$C1")")" == "placed: a-555@box-desk" ]] &&
  grep -qx "agy auto $T $T/briefs/agy-box.md agy-box" "$T/launch.log" &&
  pass "13b5. SPL-5078 control: no banner, agy measured on every box: placed as before" ||
  fail "13b5. all in: $out | $(cat "$T/launch.log")"
# SPL-5143, R7 W4: the box of this row comes from the agy box hold, not its slug
newc 56
rm -f "$T/pc/spool/asks/.place.dark"; mkdir -p "$WDC"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WDC/pane"
for n in 1 2 3; do agyb SPAWN_PLACE_DARK_RETRY_MIN=30 LAUNCH_DARK_SLUG=agy-box LOAD_JSON="$(loadc '["claude","agy"]')" "PICK=box-desk reason=below its low mark" >/dev/null; done
[[ "$(grep -c ' agy-box SPAWN_BOX=sat$' "$T/launch.log")" == 1 && "$(jq -r .state <<<"$(hubrow "$C1")")" == queued ]] &&
  pass "12e. a silent box named by the agy box hold is tried once per window too" ||
  fail "12e. agy box: $(cat "$T/launch.log")"
rm -rf "$T/pc/spool/asks/.place.dark" "$T/pc/spool/dispatch/wd/ctx.3"
# W2: no row placed as agy or mistral = no lane map this tick, by count.
printf '#!/usr/bin/env bash\necho x >>"$LOAD_COUNT"\nprintf "%%s\\n" "${LOAD_JSON:-}"\n' >"$T/bin/loadn"; chmod +x "$T/bin/loadn"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$C1" --by c-001@box-desk --reason "next case" >/dev/null 2>&1
printf 'Kind: simple_coding\nFix a line\n%s\n' "$ES" >"$T/briefs/no-agy.md"
D1=bbbb0061-0000-4000-8000-000000000061
put "$D1" c-002@box-desk dispatch-placer-no-agy "SPAWN REQUEST no agy"
on pc do_spl_spawn_enqueue ASK_ID="$D1" SPAWN_CLASS=bug SPAWN_PLACE=claude:no-agy >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last" "$T/loadn.count"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_LOAD_CMD="$T/bin/loadn" LOAD_COUNT="$T/loadn.count" LOAD_JSON="" "PICK=box-desk reason=below its low mark" LAUNCH_ID=c-561 2>&1)"
[[ ! -e "$T/loadn.count" && "$(jq -r .reason <<<"$(hubrow "$D1")")" == "placed: c-561@box-desk" ]] &&
  pass "SPL-5078: no row placed as agy or mistral: the row launches and the lane map is not called" ||
  fail "no agy row: count $(wc -l <"$T/loadn.count" 2>/dev/null) | $out | $(hubrow "$D1")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$D1" --by c-001@box-desk --reason "next case" >/dev/null 2>&1
D2=bbbb0062-0000-4000-8000-000000000062
put "$D2" c-002@box-desk dispatch-placer-agy-count "SPAWN REQUEST agy count"
on pc do_spl_spawn_enqueue ASK_ID="$D2" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-box >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last" "$T/loadn.count"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_LOAD_CMD="$T/bin/loadn" LOAD_COUNT="$T/loadn.count" LOAD_JSON="" "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-562 2>&1)"
[[ -s "$T/loadn.count" ]] && pass "SPL-5078 control: a row placed as agy: the lane map is called" || fail "agy row, no lane map: $out | $(hubrow "$D2")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$D2" --by c-001@box-desk --reason "next case" >/dev/null 2>&1
# SPL-5208 (R7 W4): the mistral half of the early return. A row placed as
# mistral whose swap is to agy (a Kind: i18n WUI brief, mistral_ui_allowed
# false) is judged by the agy box hold too: this box out, sat in -> it
# launches on sat. The lane-map count alone cannot pin it: the launch's own
# vendor swap (spl_spawn_place_vendor) reads the lane map for such a row.
printf 'Kind: i18n. Translate the hover in csi-spl-wui/src/components/w4.vue\n%s\n' "$ES" >"$T/briefs/w4-hover.md"
D3=bbbb0063-0000-4000-8000-000000000063
put "$D3" c-002@box-desk dispatch-placer-agy-count "SPAWN REQUEST mistral swapped to agy count"
on pc do_spl_spawn_enqueue ASK_ID="$D3" SPAWN_CLASS=bug SPAWN_PLACE=mistral:w4-hover >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last" "$T/loadn.count"; : >"$T/launch.log"
mkdir -p "$WDC"; printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WDC/pane"
out="$(on pc do_spl_spawn_place SPAWN_PLACE_LOAD_CMD="$T/bin/loadn" LOAD_COUNT="$T/loadn.count" LOAD_JSON="$(loadc '["claude","agy"]')" "PICK=box-desk reason=below its low mark" LAUNCH_ID=a-563 2>&1)"
[[ -s "$T/loadn.count" ]] && grep -qx "agy auto $T $T/briefs/w4-hover.md w4-hover SPAWN_BOX=sat" "$T/launch.log" &&
  pass "SPL-5208: a row placed as mistral, swapped to agy, this box out: the agy box hold sends it to sat" || fail "mistral->agy row: $out | $(hubrow "$D3") | $(cat "$T/launch.log")"
rm -rf "$T/pc/spool/dispatch/wd/ctx.3" "$T/pc/spool/dispatch/vendor-probe/agy-limit-seen.tsv"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$D3" --by c-001@box-desk --reason "next case" >/dev/null 2>&1
# The login half of the program-or-login hold, on the real spool_vendor_clis.
clis5078() { env -u SPOOL_VENDOR_CLIS_CMD HOME="$T/agyhome" SPOOL_AGENT_USER=x SPOOL_AGY_AUTH_MARKER=.agy-login AGY_BIN=true bash -c '
  source "'"$PROJ_ROOT"'/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  spool_resolve_bins() { :; }; spool_agent_exec() { bash -c "$1"; }; AGY_BIN=true
  spool_vendor_clis' 2>/dev/null; }
mkdir -p "$T/agyhome"; rm -f "$T/agyhome/.agy-login"
[[ ",$(clis5078)," != *,agy,* ]] && pass "13b5. SPL-5078: agy program but no login marker: agy does not count (so spawn-window and do_spl_box_pick leave the box out)" || fail "13b5. no login: $(clis5078)"
: >"$T/agyhome/.agy-login"
[[ ",$(clis5078)," == *,agy,* ]] && pass "13b5. SPL-5078 control: agy program and its login marker: agy counts" || fail "13b5. login: $(clis5078)"

# 13c. SPL-3024: a row placed directly as agy:<slug> (agy chosen on purpose,
# no swap) HOLDS while agy is out of quota, review or not: launching claude
# would change the vendor someone picked. CONTROL: agy in quota launches it
# as agy.
Q3=bbbb0003-0000-4000-8000-000000000003
mkdir -p "$WD13/ctx.3/a-860"
printf '⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 13h53m38s.\n' >"$WD13/ctx.3/a-860/pane"
printf 'Kind: specs_and_docs\nRewrite csi-spl-doc/doc/md/agy-direct.md\n%s\n' "$ES" >"$T/briefs/agy-direct.md"
put "$Q3" c-002@box-desk dispatch-placer-direct-agy "SPAWN REQUEST agy direct"
on pc do_spl_spawn_enqueue ASK_ID="$Q3" SPAWN_CLASS=bug SPAWN_PLACE=agy:agy-direct >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=a-514 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$Q3")")" == queued && ! -s "$T/launch.log" ]] &&
  [[ "$(grep -c "INFO hold: ask ${Q3:0:8}: placed as agy, and agy is out of quota until 20[0-9-]*T[0-9:]*Z (a-860 banner" <<<"$out")" == 1 ]] &&
  grep -q "^${Q3}"$'\t'".*agy is out of quota until" "$T/pc/spool/asks/.place.wait" &&
  pass "SPL-3024: agy out + a row placed as agy (not a review): held, queued, not launched, the reset named" || fail "agy direct out: $out | $(cat "$T/launch.log")"
rm -rf "$WD13/ctx.3"
# SPL-3138: agy back in quota but the row not launched this tick (ceiling
# full): its agy WAIT line is gone, and the line of an ask no longer queued
# is pruned. CONTROL: a non-agy reason of a row is kept.
printf 'dead0000-0000-4000-8000-000000000000\t1\twaiting: claude weekly\n' >>"$T/pc/spool/asks/.place.wait"
out="$(on pc do_spl_spawn_place WINDOWS=40 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$Q3")")" == queued && ! -s "$T/launch.log" ]] && grep -q "hold: agent windows 40" <<<"$out" &&
  ! grep -q "^${Q3}"$'\t' "$T/pc/spool/asks/.place.wait" && ! grep -q "agy is out of quota" "$T/pc/spool/asks/.place.wait" &&
  pass "SPL-3138: agy back, the row not launched (ceiling): its stale agy WAIT line is dropped" || fail "stale agy wait: $out | $(cat "$T/pc/spool/asks/.place.wait")"
! grep -q "^dead0000-" "$T/pc/spool/asks/.place.wait" &&
  pass "SPL-3138: the WAIT line of an ask no longer queued is pruned" || fail "dead wait line kept: $(cat "$T/pc/spool/asks/.place.wait")"
printf '%s\t1\tagy is out of quota until x\nbbbb0009-0000-4000-8000-000000000009\t1\tpinned to sat: overflow\n' "$Q3" >"$T/wait-keep.tsv"
out="$(on pc 'spl_asks_init; f="$(spool_asks_dir)/.place.wait"; cp "'"$T/wait-keep.tsv"'" "$f"; spl_spawn_place_wait_keep held ""; cat "$f"')"
[[ "$out" == "bbbb0009-0000-4000-8000-000000000009"$'\t1\tpinned to sat: overflow' ]] &&
  pass "SPL-3138 control: a non-agy WAIT reason is kept when the agy lines are dropped" || fail "wait keep: $out"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=a-515 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$Q3")")" == "placed: a-515@box-desk" ]] &&
  grep -q "^agy auto $T $T/briefs/agy-direct.md agy-direct$" "$T/launch.log" && ! grep -q "^${Q3}"$'\t' "$T/pc/spool/asks/.place.wait" &&
  pass "SPL-3024 control: agy in quota: the row placed as agy launches agy" || fail "agy direct in: $out | $(cat "$T/launch.log")"
rm -rf "$WD13"

# 13d. SPL-3470: the brief is on the box that queued the row ----------------------------
W1=bbbb0011-0000-4000-8000-000000000011; W2=bbbb0012-0000-4000-8000-000000000012; W3=bbbb0013-0000-4000-8000-000000000013
printf 'brief written on sat\n%s\n' "$ES" >"$T/briefs/away-brief.md"
printf 'brief written here\n%s\n' "$ES" >"$T/briefs/here-brief.md"
put "$W1" c-002@sat dispatch-placer-away "SPAWN REQUEST away brief"
on sat do_spl_spawn_enqueue ASK_ID="$W1" SPAWN_CLASS=bug SPAWN_PLACE=claude:away-brief >/dev/null 2>&1
put "$W2" c-002@box-desk dispatch-placer-away "SPAWN REQUEST here brief"
on pc do_spl_spawn_enqueue ASK_ID="$W2" SPAWN_CLASS=bug SPAWN_PLACE=claude:here-brief >/dev/null 2>&1
mv "$T/briefs/away-brief.md" "$T/away-brief.md"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-516 2>&1)"
[[ "$(jq -r .writer_box <<<"$(hubrow "$W1")")" == sat && "$(jq -r .state <<<"$(hubrow "$W1")")" == queued ]] &&
  ! grep -q "place ask ${W1:0:8} now" "$T/send.log" &&
  grep -q "INFO hold: ask ${W1:0:8}: its brief away-brief.md is not under $T/briefs on box-desk: it was queued on sat" <<<"$out" &&
  grep -q "^${W1}"$'\t'".*it was queued on sat" "$T/pc/spool/asks/.place.wait" &&
  pass "13d. SPL-3470: a row queued on sat, its brief not here: held, queued, not handed to the holder, sat named" ||
  fail "13d. away brief: $out | $(hubrow "$W1") | $(sends)"
[[ "$(jq -r .reason <<<"$(hubrow "$W2")")" == "placed: c-516@box-desk" ]] && grep -q "^claude auto $T $T/briefs/here-brief.md here-brief$" "$T/launch.log" &&
  pass "13d. SPL-3470: the held row blocks no other row: the launchable one behind it is placed" || fail "13d. here brief: $out | $(cat "$T/launch.log")"
mv "$T/away-brief.md" "$T/briefs/away-brief.md"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-517 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$W1")")" == "placed: c-517@box-desk" ]] && grep -q "^claude auto $T $T/briefs/away-brief.md away-brief$" "$T/launch.log" &&
  ! grep -q "^${W1}"$'\t' "$T/pc/spool/asks/.place.wait" &&
  pass "13d. SPL-3470: the brief copied here: it launches, its WAIT line is gone" || fail "13d. copied: $out | $(cat "$T/launch.log") | $(cat "$T/pc/spool/asks/.place.wait")"
printf 'brief written here, then lost\n%s\n' "$ES" >"$T/briefs/lost-brief.md"
put "$W3" c-002@box-desk dispatch-placer-away "SPAWN REQUEST lost brief"
on pc do_spl_spawn_enqueue ASK_ID="$W3" SPAWN_CLASS=bug SPAWN_PLACE=claude:lost-brief >/dev/null 2>&1
rm -f "$T/briefs/lost-brief.md" "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$W3")")" == acked && ! -s "$T/launch.log" ]] &&
  grep -q "place ask ${W3:0:8} now.*no brief file for lost-brief under $T/briefs" "$T/send.log" &&
  pass "13d. control: the same missing brief on a row queued from this box is handed to the holder, as before" ||
  fail "13d. control: $out | $(hubrow "$W3") | $(sends)"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$W3" --by c-001@box-desk --reason test >/dev/null
rm -f "$T/pc/spool/asks/.place.handed"

# 14. SPL-2429: a human sender's notes go to the dispatch lease holder -------------
H1=c1c1c1c1-0000-4000-8000-000000000001; H2=c2c2c2c2-0000-4000-8000-000000000002; H3=c3c3c3c3-0000-4000-8000-000000000003
put "$H1" HUM-10@sat "$OWNER_TOPIC" "SPAWN REQUEST from the owner"
: >"$T/send.log"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$H1" SPAWN_CLASS=bug 2>&1)"
if grep -qE "^c-001 c-002 note dispatch-c9beaa77 \*\*SPAWN QUEUE, for a human sender:\*\* the request of HUM-10@sat in topic $OWNER_TOPIC is queued, position [0-9]+ of [0-9]+," "$T/send.log" &&
   ! grep -q "WARN" <<<"$out"; then
  pass "human sender: 'queued' goes to the dispatch holder on dispatch-<topic8>, naming HUM-10@sat and the full owner topic"
else fail "human queued: $out | $(sends)"; fi
on pc do_spl_spawn_placed ASK_ID="$H1" PLACED_AS=c-701@sat >/dev/null 2>&1
grep -qE "^c-001 c-002 note dispatch-c9beaa77 \*\*SPAWN QUEUE, for a human sender:\*\* the request of HUM-10@sat in topic $OWNER_TOPIC is placed: c-701@sat\. .*In progress" "$T/send.log" &&
  pass "human sender: 'placed' goes to the dispatch holder with the lane id c-701@sat" || fail "human placed: $(sends)"
[[ -z "$(awk '$2 ~ /^HUM-/' "$T/send.log")" ]] &&
  pass "human sender: nothing was sent to a HUM id" || fail "a note went to a HUM id: $(sends)"
put "$H2" HUM-10 dispatch-5ea2e615-h "SPAWN REQUEST, bare human id"
: >"$T/send.log"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$H2" SPAWN_CLASS=bug SPAWN_SHARE_DISPATCH= 2>&1)"
[[ "$(jq -r .state <<<"$(hubrow "$H2")")" == queued && ! -s "$T/send.log" ]] &&
  grep -q "WARN the note to human sender HUM-10@box-desk (topic dispatch-5ea2e615-h) was NOT delivered: nobody holds the dispatch lease" <<<"$out" &&
  pass "human sender, no dispatch lease: queued, nothing sent, one WARN" || fail "human no lease: $out | $(sends)"
put "$H3" c-002@sat "$OWNER_TOPIC" "SPAWN REQUEST from an agent"
: >"$T/send.log"
on pc do_spl_spawn_enqueue ASK_ID="$H3" SPAWN_CLASS=bug >/dev/null 2>&1
grep -qE "^c-001 c-002@sat note dispatch-c9beaa77 queued, position [0-9]+ of [0-9]+," "$T/send.log" &&
  pass "control: an agent sender is still told itself, unchanged" || fail "agent sender: $(sends)"
# 15. the coding rule (owner HUM-10, t1 b61851fb, msg 91bf8278) ----------------
C1=e5e5e5e5-0000-4000-8000-000000000001; C2=e6e6e6e6-0000-4000-8000-000000000002
# the rows section 14 left queued would win the band pick: close them first
jq '(.[] | select(.state == "queued")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
printf 'Class: refactor. Kind: complex_coding (claude). Split the store.\n%s\n' "$ES" >"$T/briefs/code-x.md"
printf 'Fix the store.\n%s\n' "$ES" >"$T/briefs/nokind-x.md"
printf 'env:\n  box:\n    agent_split:\n      mistral_coding_allowed: true\n' >"$T/coding-on.yaml"
put "$C1" c-002@box-desk dispatch-b61851fb-c "SPAWN REQUEST code"
order='mistral writes no code, kind complex_coding (owner HUM-10 t1 b61851fb msg 91bf8278: mistral does docs and reviews only, no coding)'
out="$(on pc do_spl_spawn_enqueue ASK_ID="$C1" SPAWN_CLASS=refactor SPAWN_PLACE=mistral:code-x 2>&1)"; rc=$?
[[ $rc -ne 0 && "$(jq -r .state <<<"$(hubrow "$C1")")" == open ]] && grep -qF "FATAL SPAWN_PLACE=mistral:code-x refused: $order; place it as claude:code-x" <<<"$out" &&
  pass "15. enqueue refuses mistral for a brief of Kind: complex_coding, naming the owner order" || fail "15. enqueue code: rc=$rc $out | $(hubrow "$C1")"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$C1" SPAWN_CLASS=refactor SPAWN_PLACE=mistral:docs-x SPAWN_KIND=tests 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "refused: mistral writes no code, kind tests " <<<"$out" &&
  pass "15. SPAWN_KIND=tests beats a docs brief: refused" || fail "15. SPAWN_KIND: rc=$rc $out"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$C1" SPAWN_CLASS=refactor SPAWN_PLACE=mistral:nokind-x 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "refused: mistral writes no code, kind unset " <<<"$out" &&
  pass "15. a brief with no Kind: line is coding: refused" || fail "15. no kind: rc=$rc $out"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$C1" SPAWN_CLASS=refactor SPAWN_PLACE=mistral:code-x SPAWN_PLACE_CNF="$T/coding-on.yaml" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(jq -r .state <<<"$(hubrow "$C1")")" == queued ]] &&
  pass "15. control: mistral_coding_allowed true queues the same placement" || fail "15. control enqueue: rc=$rc $out"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-505 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$C1")")" == "placed: c-505@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/code-x.md code-x$" "$T/launch.log" &&
  grep -qF "placed as mistral, launched as claude: $order" <<<"$out" &&
  pass "15. a mistral coding row already queued launches claude" || fail "15. placement: $out | $(cat "$T/launch.log")"
put "$C2" c-002@box-desk dispatch-b61851fb-d "SPAWN REQUEST code 2"
on pc do_spl_spawn_enqueue ASK_ID="$C2" SPAWN_CLASS=refactor SPAWN_PLACE=mistral:code-x SPAWN_PLACE_CNF="$T/coding-on.yaml" >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=m-506 SPAWN_PLACE_CNF="$T/coding-on.yaml" 2>&1)"
grep -q "^mistral auto $T $T/briefs/code-x.md code-x$" "$T/launch.log" &&
  pass "15. control: with mistral_coding_allowed true the placer launches mistral" || fail "15. control placement: $out | $(cat "$T/launch.log")"

# 16. SPL-2508: the brief's epic must be open on the hub ------------------------------
E1=25080001-0000-4000-8000-000000000001; E2=25080002-0000-4000-8000-000000000002; E3=25080003-0000-4000-8000-000000000003
jq '(.[] | select(.state == "queued")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
# the do_spl_issue_status stub: <key>\t<status> rows; gone = the hub's not_found; no row = no answer
cat >"$T/bin/istatus" <<'STUB'
#!/usr/bin/env bash
st="$(awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$EPICS")"
case "$st" in
  "") exit 1 ;;
  gone) echo "FATAL spool issue get as c-002: spool: hub refused: not_found (no such issue)"; exit 1 ;;
  *) printf 'issue-status\t%s\t%s\n' "$1" "$st" ;;
esac
STUB
chmod +x "$T/bin/istatus"
printf 'SPL-7\tgone\nSPL-8\twip\nSPL-9\tdone\n' >"$T/epics.tsv"
printf 'Kind: complex_coding\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-7\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/tokens-tab.md"
printf 'Kind: complex_coding\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-9\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/done-epic.md"
printf 'Kind: complex_coding\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/open-epic.md"
printf 'Kind: complex_coding\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-6\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/no-answer.md"
EH=(LI_HUB_STATUS_CMD="$T/bin/istatus" EPICS="$T/epics.tsv")
put "$E1" c-002@box-desk dispatch-c002sat-e "SPAWN REQUEST tokens tab"
out="$(on pc do_spl_spawn_enqueue "${EH[@]}" ASK_ID="$E1" SPAWN_CLASS=feature SPAWN_PLACE=claude:tokens-tab 2>&1)"; rc=$?
[[ $rc -ne 0 && "$(jq -r .state <<<"$(hubrow "$E1")")" == open ]] &&
  grep -qF "FATAL ask not queued: brief $T/briefs/tokens-tab.md names epic SPL-7, but SPL-7 is not a live issue on the hub (archived, deleted or never filed): point its 'Epic:' line at an open epic, or reopen SPL-7 (SPL-2508)" <<<"$out" &&
  pass "16. enqueue: a brief whose epic is archived on the hub is not queued, one FATAL line names the brief, the epic and the fix" ||
  fail "16. archived epic enqueue: rc=$rc $out | $(hubrow "$E1")"
out="$(on pc do_spl_spawn_enqueue "${EH[@]}" ASK_ID="$E1" SPAWN_CLASS=feature SPAWN_PLACE=claude:done-epic 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -qF "names epic SPL-9, but SPL-9 is done on the hub" <<<"$out" &&
  pass "16. enqueue: a done epic is refused the same way" || fail "16. done epic: rc=$rc $out"
out="$(on pc do_spl_spawn_enqueue "${EH[@]}" ASK_ID="$E1" SPAWN_CLASS=feature SPAWN_PLACE=claude:open-epic 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(jq -r .state <<<"$(hubrow "$E1")")" == queued ]] &&
  pass "16. control: the same ask with an open epic (wip) queues" || fail "16. open epic: rc=$rc $out"
put "$E2" c-002@box-desk dispatch-c002sat-f "SPAWN REQUEST hub down"
out="$(on pc do_spl_spawn_enqueue "${EH[@]}" ASK_ID="$E2" SPAWN_CLASS=feature SPAWN_PLACE=claude:no-answer 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(jq -r .state <<<"$(hubrow "$E2")")" == queued ]] &&
  pass "16. control: a hub that does not answer refuses nothing" || fail "16. no answer: rc=$rc $out"
jq --arg a "$E2" '(.[] | select(.ask_id == $a)) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
# queued while SPL-8 was open; SPL-8 is archived since (the 2026-10-18 case)
printf 'SPL-7\tgone\nSPL-8\tgone\nSPL-9\tdone\n' >"$T/epics.tsv"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-507 2>&1)"
[[ ! -s "$T/launch.log" && "$(jq -r .state <<<"$(hubrow "$E1")")" == acked ]] &&
  grep -qF "c-001 c-001 blocker spawn-queue **SPAWN QUEUE: place ask ${E1:0:8} now** - it is next and the box has room" "$T/send.log" &&
  grep -qF "It needs you: brief $T/briefs/open-epic.md names epic SPL-8, but SPL-8 is not a live issue on the hub" "$T/send.log" &&
  pass "16. placer: a queued row whose epic was archived since is handed to the holder with the reason, nothing launched" ||
  fail "16. placer closed epic: $out | $(cat "$T/launch.log") | $(sends) | $(hubrow "$E1")"
put "$E3" c-002@box-desk dispatch-c002sat-g "SPAWN REQUEST open epic"
printf 'SPL-8\twip\n' >"$T/epics.tsv"
on pc do_spl_spawn_enqueue "${EH[@]}" ASK_ID="$E3" SPAWN_CLASS=feature SPAWN_PLACE=claude:open-epic >/dev/null 2>&1
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-508 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$E3")")" == "placed: c-508@box-desk" ]] && grep -q "^claude auto $T $T/briefs/open-epic.md open-epic$" "$T/launch.log" &&
  pass "16. control: the same brief with its epic open (wip) is launched" || fail "16. placer open epic: $out | $(cat "$T/launch.log") | $(hubrow "$E3")"

# 16c. C93, C94: spec 153 3.20 (SPL-4797; owner HUM-10, t1 f94e07bf msg 33f8eecb, t1
# 0c2d08a2 msg 08ac07da): the placer launches no lane that names no
# discussion or no issue. A row whose ask topic is no hub topic and whose brief
# names none is handed to the holder with "no discussion", nothing launched
# (CONTROL: the same brief on dispatch-<topic8> launches); a brief that lost
# its Epic:/Spec: pair after the enqueue is handed off with "no issue".
# RED on master 022055fe6: both rows were launched. Since SPL-5325 the enqueue
# refuses a brief with no discussion (case 1b), so E10's brief loses its
# Topic: line after the enqueue, as E12's loses its Epic:/Spec: pair.
E10=31700010-0000-4000-8000-000000000010; E11=31700011-0000-4000-8000-000000000011; E12=31700012-0000-4000-8000-000000000012
printf 'Kind: complex_coding\nReport on task dispatch-s169-rows.\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\n' >"$T/briefs/no-disc.md"
printf 'SPL-8\twip\n' >"$T/epics.tsv"
q16c() {  # ASK_ID ASK_TOPIC SLUG [ENV...]: the only queued row
  jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
  put "$1" c-002@box-desk "$2" "SPAWN REQUEST links"
  on pc do_spl_spawn_enqueue "${EH[@]}" ASK_ID="$1" SPAWN_CLASS=feature SPAWN_PLACE="claude:$3" "${@:4}" >/dev/null 2>&1
  rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"
}
printf 'Topic: 7c0de153-0000-4000-8000-000000004797\n' >>"$T/briefs/no-disc.md"
q16c "$E10" dispatch-s169-rows no-disc
printf 'Kind: complex_coding\nReport on task dispatch-s169-rows.\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\n' >"$T/briefs/no-disc.md"
out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-517 2>&1)"
[[ ! -s "$T/launch.log" && "$(jq -r .state <<<"$(hubrow "$E10")")" == acked ]] &&
  grep -qF "It needs you: lane refused, no discussion: the ask's topic 'dispatch-s169-rows' names no hub topic and brief $T/briefs/no-disc.md names none (add a 'Topic: <uuid>' line" "$T/send.log" &&
  pass "16c. placer: a row naming no discussion (ask topic dispatch-s169-rows, brief names none) is handed to the holder, nothing launched" ||
  fail "16c. no discussion: $out | $(cat "$T/launch.log") | $(sends) | $(hubrow "$E10")"
q16c "$E11" dispatch-1a2b3c4d no-disc
out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-518 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$E11")")" == "placed: c-518@box-desk" ]] && grep -q "^claude auto $T $T/briefs/no-disc.md no-disc$" "$T/launch.log" &&
  pass "16c. control: the same brief on ask topic dispatch-<topic8> is launched" || fail "16c. control: $out | $(cat "$T/launch.log") | $(hubrow "$E11")"
q16c "$E12" dispatch-1a2b3c4d no-disc
printf 'Kind: complex_coding\nReport on task dispatch-1a2b3c4d.\n' >"$T/briefs/no-disc.md"
out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-519 2>&1)"
[[ ! -s "$T/launch.log" && "$(jq -r .state <<<"$(hubrow "$E12")")" == acked ]] &&
  grep -qF "lane refused, no issue: brief $T/briefs/no-disc.md has no 'Issue: <KEY>' line and no 'Epic: SPL-<n>' + 'Spec: <folder>' pair" "$T/send.log" &&
  pass "16c. placer: a brief with no Issue: key and no Epic:/Spec: pair is handed off with 'no issue', nothing launched" ||
  fail "16c. no issue: $out | $(cat "$T/launch.log") | $(sends) | $(hubrow "$E12")"
# 16d. C97 (R7 c-343 W1): what the placer lets through is what the row gets.
# A brief naming its discussion as `Discussion: <uuid>` or `**Topic:** <uuid>`
# launches, and the spawn's row reader (_spawn_lane_topic) reads that same
# uuid; an ask whose discussion is set (topic dispatch-s169-rows) launches with
# SPAWN_LANE_TOPIC=<discussion>. RED before: both brief forms read row=[], and
# the .discussion row launched with SPAWN_LANE_TOPIC unset.
D16=0c2d08a2-b1c1-4bb7-983d-3237203a77ec; n16=13
SC="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh"
for form in "Discussion: $D16" "**Topic:** $D16"; do
  printf 'Kind: complex_coding\nReport on task dispatch-s169-rows.\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\n%s\n' "$form" >"$T/briefs/no-disc.md"
  e16="317000${n16}-0000-4000-8000-0000000000${n16}"; n16=$((n16 + 1))
  q16c "$e16" dispatch-s169-rows no-disc
  out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-520 2>&1)"
  row16="$(
    # shellcheck source=../features/spawn-agents/scripts/spawn-core.inc.sh
    . "$SC" 2>/dev/null
    _spawn_lane_topic "$T/briefs/no-disc.md")"
  [[ "$(jq -r .reason <<<"$(hubrow "$e16")")" == "placed: c-520@box-desk" && "$row16" == "$D16" ]] &&
    pass "16d. a brief '$form' passes the placer and the row reads the same topic" ||
    fail "16d. '$form': row=[$row16] $out | $(cat "$T/launch.log") | $(hubrow "$e16")"
done
E15=31700015-0000-4000-8000-000000000015
printf 'Kind: complex_coding\nReport on task dispatch-s169-rows.\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\n' >"$T/briefs/no-disc.md"
q16c "$E15" dispatch-s169-rows no-disc ASK_DISCUSSION="$D16"
: >"$T/launch.log.env"
out="$(on pc do_spl_spawn_place "${EH[@]}" LAUNCH_ID=c-521 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$E15")")" == "placed: c-521@box-desk" ]] && grep -qx "no-disc SPAWN_LANE_TOPIC=$D16" "$T/launch.log.env" &&
  pass "16d. an ask whose discussion is set launches with SPAWN_LANE_TOPIC=<discussion>" ||
  fail "16d. .discussion: $out | $(cat "$T/launch.log.env") | $(hubrow "$E15")"
jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"

# 17. SPL-2558: the placer reopens an epic the SPL-1729 close archived ------------------
# The closer on box A reopens only for a brief on A; this row's brief is on the
# placer's box B. The hub's get answers an archived epic with auto_closed
# (SPL-2607), do_spl_issue_status as a 4th field. RED on master: handed off.
E4=25580004-0000-4000-8000-000000000004; E5=25580005-0000-4000-8000-000000000005; E6=25580006-0000-4000-8000-000000000006
cat >"$T/bin/istatus2" <<'STUB'
#!/usr/bin/env bash
row="$(awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3 }' "$EPICS")"
[[ -n "$row" ]] || exit 1
printf 'issue-status\t%s\t%s\n' "$1" "${row%$'\t'}"
STUB
chmod +x "$T/bin/istatus2"
EH2=(LI_HUB_STATUS_CMD="$T/bin/istatus2" EPICS="$T/epics.tsv" DESK_CALLS="$T/desk.log")
# the desk: the lease's (spl_lane_issue_desk) and its hub calls, recorded; DESK_FAIL=<op> fails that op
DESK='spl_lane_issue_desk() { echo "desk $*" >>"$DESK_CALLS"; }
spl_desk_issue_run() { echo "$1 $2 $3 ${4:-} ${5:-} ${6:-}" >>"$DESK_CALLS"; [[ "$1" != "${DESK_FAIL:-none}" ]] || { echo "FATAL spool issue $1: hub refused" >&2; return 1; }; }
'
placeq() {  # ASK_ID EPIC_ROW: queue the open-epic brief while SPL-8 is open, then set SPL-8 to EPIC_ROW
  # rows an earlier case left queued or with the holder would be placed first
  jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
  put "$1" c-002@box-desk "dispatch-c002sat-${1:7:1}" "SPAWN REQUEST reopen"
  printf 'SPL-8\twip\n' >"$T/epics.tsv"
  on pc do_spl_spawn_enqueue "${EH2[@]}" ASK_ID="$1" SPAWN_CLASS=feature SPAWN_PLACE=claude:open-epic >/dev/null 2>&1
  printf 'SPL-8\t%s\n' "$2" >"$T/epics.tsv"
  rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"; : >"$T/desk.log"
}
placeq "$E4" $'done\tauto-closed'
out="$(on pc "${DESK}do_spl_spawn_place" "${EH2[@]}" LAUNCH_ID=c-509 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$E4")")" == "placed: c-509@box-desk" ]] && grep -q "^claude auto $T $T/briefs/open-epic.md open-epic$" "$T/launch.log" &&
  grep -qx "desk $T/pc/spool 0" "$T/desk.log" && grep -q '^unarchive --ref SPL-8 ' "$T/desk.log" && grep -q '^update --ref SPL-8 --status wip ' "$T/desk.log" &&
  grep -qF 'comment --ref SPL-8 --body Reopened by do_spl_spawn_place: auto-closed (SPL-1729), head brief open-epic names it' "$T/desk.log" &&
  grep -q 'OK SPL-8 reopened: it was auto-closed and brief open-epic names it' <<<"$out" && ! grep -q 'blocker' "$T/send.log" &&
  pass "17. placer: an epic the SPL-1729 close archived is reopened (unarchive, wip, comment) as the lease's desk, and the row launched" ||
  fail "17. auto-closed reopen: $out | $(cat "$T/launch.log") | $(cat "$T/desk.log") | $(sends) | $(hubrow "$E4")"
placeq "$E5" $'done\tarchived'
out="$(on pc "${DESK}do_spl_spawn_place" "${EH2[@]}" LAUNCH_ID=c-510 2>&1)"
[[ ! -s "$T/launch.log" && ! -s "$T/desk.log" && "$(jq -r .state <<<"$(hubrow "$E5")")" == acked ]] &&
  grep -qF "It needs you: brief $T/briefs/open-epic.md names epic SPL-8, but SPL-8 is done on the hub: point its 'Epic:' line" "$T/send.log" &&
  pass "17. control: the same row with an epic a person closed (archived, not auto_closed) is handed off, no unarchive, nothing launched" ||
  fail "17. human close: $out | $(cat "$T/launch.log") | $(cat "$T/desk.log") | $(sends) | $(hubrow "$E5")"
placeq "$E6" $'done\tauto-closed'
out="$(on pc "${DESK}do_spl_spawn_place" "${EH2[@]}" DESK_FAIL=unarchive LAUNCH_ID=c-511 2>&1)"
[[ ! -s "$T/launch.log" && "$(jq -r .state <<<"$(hubrow "$E6")")" == acked ]] && ! grep -q '^update ' "$T/desk.log" &&
  grep -qF "names epic SPL-8, but SPL-8 is done on the hub: point its 'Epic:' line at an open epic, or reopen SPL-8 (SPL-2508); reopening it failed: FATAL spool issue unarchive: hub refused" "$T/send.log" &&
  pass "17. a failed reopen hands the row off with the failure, nothing launched" ||
  fail "17. failed reopen: $out | $(cat "$T/launch.log") | $(cat "$T/desk.log") | $(sends) | $(hubrow "$E6")"

# 17b. SPL-3060: the enqueue reopens an auto-closed epic, never refuses it ---------------
# A spec epic is auto-closed (SPL-1729) the moment its spec-writing issue lands,
# before any build row is filed (SPL-3028, SPL-3030 on 2026-10-23); every brief
# naming it was refused at enqueue. RED on master: "FATAL ask not queued".
E7=30600007-0000-4000-8000-000000000007; E8=30600008-0000-4000-8000-000000000008; E9=30600009-0000-4000-8000-000000000009
enq() {  # ASK_ID EPIC_ROW [VAR=..]: enqueue the open-epic brief while SPL-8 is EPIC_ROW
  local a="$1" st="$2"; shift 2
  jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
  put "$a" c-002@box-desk "dispatch-c002sat-${a:7:1}" "SPAWN REQUEST build row"
  printf 'SPL-8\t%s\n' "$st" >"$T/epics.tsv"; : >"$T/desk.log"
  on pc "${DESK}do_spl_spawn_enqueue" "${EH2[@]}" "$@" ASK_ID="$a" SPAWN_CLASS=feature SPAWN_PLACE=claude:open-epic 2>&1
}
out="$(enq "$E7" $'done\tauto-closed')"; rc=$?
[[ $rc -eq 0 && "$(jq -r .state <<<"$(hubrow "$E7")")" == queued ]] && ! grep -q FATAL <<<"$out" &&
  grep -qx "desk $T/pc/spool 0" "$T/desk.log" && grep -q '^unarchive --ref SPL-8 ' "$T/desk.log" && grep -q '^update --ref SPL-8 --status wip ' "$T/desk.log" &&
  grep -qF 'comment --ref SPL-8 --body Reopened by do_spl_spawn_enqueue: auto-closed (SPL-1729), queued brief open-epic names it' "$T/desk.log" &&
  pass "17b. enqueue: an epic the SPL-1729 close archived is reopened (unarchive, wip, comment) as the lease's desk, and the ask queued" ||
  fail "17b. enqueue auto-closed: rc=$rc $out | $(cat "$T/desk.log") | $(hubrow "$E7")"
out="$(enq "$E8" $'done\tarchived')"; rc=$?
[[ $rc -ne 0 && "$(jq -r .state <<<"$(hubrow "$E8")")" == open && ! -s "$T/desk.log" ]] &&
  grep -qF "FATAL ask not queued: brief $T/briefs/open-epic.md names epic SPL-8, but SPL-8 is done on the hub: point its 'Epic:' line" <<<"$out" &&
  pass "17b. control: an epic a person closed (archived, not auto_closed) still refuses the ask, no unarchive" ||
  fail "17b. enqueue human close: rc=$rc $out | $(cat "$T/desk.log") | $(hubrow "$E8")"
out="$(enq "$E9" $'done\tauto-closed' DESK_FAIL=unarchive)"; rc=$?
[[ $rc -eq 0 && "$(jq -r .state <<<"$(hubrow "$E9")")" == queued ]] && ! grep -q '^update ' "$T/desk.log" &&
  grep -qF "WARN ask queued with its epic still closed: brief $T/briefs/open-epic.md names epic SPL-8, but SPL-8 is done on the hub" <<<"$out" &&
  grep -qF "reopening it failed: FATAL spool issue unarchive: hub refused; the placer tries the reopen again before it launches" <<<"$out" &&
  pass "17b. a failed reopen at enqueue is one WARN, the ask still queues (the placer retries the reopen)" ||
  fail "17b. enqueue failed reopen: rc=$rc $out | $(cat "$T/desk.log") | $(hubrow "$E9")"
jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"

# 18. spec 143 4.4 (SPL-2790): the brief's category on the request ----------------------
G1=21430001-0000-4000-8000-000000000001; G2=21430002-0000-4000-8000-000000000002; G3=21430003-0000-4000-8000-000000000003
printf 'Kind: complex_coding\nCategory: coding/hard\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/cat-hard.md"
printf 'No kind, no category.\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/cat-none.md"
printf 'Kind: tests\nCategory: coding/no_such_node\nSpec: csi-spl-doc/specs/135-work-process\nEpic: SPL-8\nTopic: 7c0de153-0000-4000-8000-000000003170\n' >"$T/briefs/cat-bad.md"
catq() {  # ASK_ID SLUG LAUNCH_ID: queue SLUG's brief alone, place it
  jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
  put "$1" c-002@box-desk "dispatch-c002sat-${1:7:1}" "SPAWN REQUEST $2"
  printf 'SPL-8\twip\n' >"$T/epics.tsv"
  on pc do_spl_spawn_enqueue "${EH2[@]}" ASK_ID="$1" SPAWN_CLASS=feature SPAWN_PLACE="claude:$2" >/dev/null 2>&1
  rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
  on pc do_spl_spawn_place "${EH2[@]}" LAUNCH_ID="$3" 2>&1
}
out="$(catq "$G1" cat-hard c-512)"
r="$(hubrow "$G1")"
[[ "$(jq -r .work_kind <<<"$r")" == complex_coding && "$(jq -r .category_path <<<"$r")" == coding/hard && "$(jq -r .reason <<<"$r")" == "placed: c-512@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/cat-hard.md cat-hard$" "$T/launch.log" && grep -q "work_kind complex_coding, category coding/hard recorded" <<<"$out" &&
  pass "18. placer: the brief's Kind: and Category: are recorded on the request (work_kind complex_coding, category_path coding/hard), then it is launched" ||
  fail "18. category recorded: $out | $r | $(cat "$T/launch.log")"
out="$(catq "$G2" cat-none c-513)"
r="$(hubrow "$G2")"
[[ "$(jq -r 'has("work_kind") or has("category_path")' <<<"$r")" == false && "$(jq -r .reason <<<"$r")" == "placed: c-513@box-desk" ]] &&
  grep -q "^claude auto $T $T/briefs/cat-none.md cat-none$" "$T/launch.log" && ! grep -q "category" <<<"$out" &&
  pass "18. control: a brief with no Kind: and no Category: sends no category op and places exactly as before" ||
  fail "18. no category: $out | $r | $(cat "$T/launch.log")"
out="$(catq "$G3" cat-bad c-514)"
r="$(hubrow "$G3")"
[[ "$(jq -r 'has("category_path")' <<<"$r")" == false && "$(jq -r .reason <<<"$r")" == "placed: c-514@box-desk" ]] &&
  grep -q "WARN ask ${G3:0:8}: its category was not recorded (tests coding/no_such_node): hub refused: unknown_category" <<<"$out" &&
  pass "18. a category the hub refuses (no such node) is one WARN line; the row is still placed" ||
  fail "18. refused category: $out | $r"

# 19. SPL-3349: the owner's review-seat GO (msg 994f2257) on a seat of any class -------
SEAT_GO=994f2257-8ad1-4010-88c8-4f0a16230937
S1=33490001-0000-4000-8000-000000000001; N1=33490002-0000-4000-8000-000000000002
O1=33490003-0000-4000-8000-000000000003; FE=33490004-0000-4000-8000-000000000004; S2=33490005-0000-4000-8000-000000000005
jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
for b in seat-r7-reviewer seat2-reviewer seat3-r7-reviewer bug-fix-x feat-x; do printf 'Class: bug\n%s\n' "$ES" >"$T/briefs/$b.md"; done
for i in "$S1" "$N1" "$O1" "$FE" "$S2"; do put "$i" c-002@box-desk "dispatch-enqueue-review-bypass" "SPAWN REQUEST ${i:0:8}"; done
out="$(on pc do_spl_spawn_enqueue ASK_ID="$S1" SPAWN_CLASS=bug SPAWN_BYPASS=$SEAT_GO SPAWN_PLACE=claude:seat-r7-reviewer 2>&1)"; rc=$?
r="$(hubrow "$S1")"
[[ $rc -eq 0 && "$(jq -r .state <<<"$r")" == queued && "$(jq -r '.flag // ""' <<<"$r")" == "" ]] &&
  grep -q "$S1"$'\t'"$SEAT_GO"$'\t'"c-001@box-desk" "$T/pc/spool/asks/bypass.tsv" && grep -q "is a bug review-seat BYPASS on owner msg 994f2257: recorded" <<<"$out" &&
  pass "19a. a bug review seat on the review-seat GO is queued, unflagged on the hub (bypass is a feature flag there), in the local bypass log" ||
  fail "19a. seat enqueue: rc=$rc $out | $r"
[[ "$(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>/dev/null | jq -r --arg a "$S1" '[.bypasses[] | select(.ask == $a) | "\(.msg) \(.state)"] | join(",")')" == "$SEAT_GO queued" ]] &&
  pass "19a. do_spl_spawn_share lists the review-seat bypass (owner msg, ask), its state from the hub row" || fail "19a. share: $(on pc do_spl_spawn_share SPAWN_SHARE_FORMAT=json 2>&1)"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$N1" SPAWN_CLASS=bug SPAWN_BYPASS=$SEAT_GO SPAWN_PLACE=claude:bug-fix-x 2>&1)"; rc=$?
[[ $rc -ne 0 && "$(jq -r .state <<<"$(hubrow "$N1")")" == open ]] && grep -q "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" <<<"$out" &&
  pass "19b. the review-seat GO on a bug that is no review seat: still refused, the ask stays open" || fail "19b. non-seat: rc=$rc $out"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$N1" SPAWN_CLASS=bug SPAWN_BYPASS=$SEAT_GO 2>&1)"; rc=$?
[[ $rc -ne 0 && "$(jq -r .state <<<"$(hubrow "$N1")")" == open ]] && grep -q "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" <<<"$out" &&
  pass "19b. the review-seat GO with no placement: refused" || fail "19b. no place: rc=$rc $out"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$O1" SPAWN_CLASS=bug SPAWN_BYPASS=$BYPASS_MSG SPAWN_PLACE=claude:seat2-reviewer 2>&1)"; rc=$?
[[ $rc -ne 0 && "$(jq -r .state <<<"$(hubrow "$O1")")" == open ]] && grep -q "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" <<<"$out" &&
  ! grep -q "$O1" "$T/pc/spool/asks/bypass.tsv" &&
  pass "19c. another owner msg id on a bug review seat: still refused, nothing logged" || fail "19c. other id: rc=$rc $out"
on pc do_spl_spawn_enqueue ASK_ID="$FE" SPAWN_CLASS=feature SPAWN_PLACE=claude:feat-x >/dev/null 2>&1
# live lanes: bug 2 of 4 (50%, OVER 20-30%), feature 1 (25%, UNDER 40%), refactor 1 (25%)
SEAT_LANES='[{"agent_id": "c-304", "agent_box": "box-desk", "state": "live"}, {"agent_id": "c-311", "agent_box": "box-desk", "state": "live"},
  {"agent_id": "c-305", "agent_box": "box-desk", "state": "live"}, {"agent_id": "c-301", "agent_box": "box-desk", "state": "live"}]'
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-521 LANES="$SEAT_LANES" 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$S1")")" == "placed: c-521@box-desk" && "$(jq -r .state <<<"$(hubrow "$FE")")" == queued ]] &&
  grep -q "^claude auto $T $T/briefs/seat-r7-reviewer.md seat-r7-reviewer$" "$T/launch.log" && grep -q "review-seat pick: ask ${S1:0:8} (bug claude:seat-r7-reviewer" <<<"$out" &&
  pass "19d. bug OVER its band, feature UNDER: the bypassed bug review seat is placed ahead of the queued feature row" ||
  fail "19d. seat pick: $out | $(hubrow "$S1") | $(cat "$T/launch.log")"
# 19e. SPL-3762: a review seat queued with NO SPAWN_BYPASS gets the standing GO at enqueue
# the run's real do_log (DO_LOG_REAL): it sets the global msg, the stub does not (c-001 msg d4bff1c7)
out="$(on pc do_spl_spawn_enqueue DO_LOG_REAL=1 LOG_DIR="$T/log" ASK_ID="$S2" SPAWN_CLASS=bug SPAWN_PLACE=claude:seat3-r7-reviewer 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(jq -r '.flag // ""' <<<"$(hubrow "$S2")")" == "" ]] && grep -q "$S2"$'\t'"$SEAT_GO"$'\t'"c-001@box-desk" "$T/pc/spool/asks/bypass.tsv" &&
  grep -q "ask ${S2:0:8} is a review seat (claude:seat3-r7-reviewer) with no SPAWN_BYPASS: the standing review-seat GO 994f2257 applies" <<<"$out" &&
  grep -q "ask ${S2:0:8} is a bug review-seat BYPASS on owner msg 994f2257: recorded" <<<"$out" && ! grep -q FATAL <<<"$out" &&
  pass "19e. a -reviewer placement queued without SPAWN_BYPASS (the real do_log): the standing review-seat GO is in the local bypass log, one INFO line" ||
  fail "19e. default GO: rc=$rc $out | $(hubrow "$S2")"
printf 'Class: bug\n%s\n' "$ES" >"$T/briefs/seat4-reviewer.md"
U1=37620001-0000-4000-8000-000000000001; put "$U1" c-002@box-desk "dispatch-enqueue-review-bypass" "SPAWN REQUEST ${U1:0:8}"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$U1" SPAWN_CLASS=bug SPAWN_URGENT=1 SPAWN_PLACE=claude:seat4-reviewer 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(jq -r '.flag // ""' <<<"$(hubrow "$U1")")" == urgent ]] && ! grep -q "$U1" "$T/pc/spool/asks/bypass.tsv" &&
  pass "19e. SPAWN_URGENT=1 on a review seat is unchanged: flagged urgent, no GO logged" || fail "19e. urgent seat: rc=$rc $out | $(hubrow "$U1")"
jq --arg u "$U1" '(.[] | select(.ask_id == $u)) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$N1" SPAWN_CLASS=bug SPAWN_PLACE=claude:bug-fix-x 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q "$N1" "$T/pc/spool/asks/bypass.tsv" && ! grep -q "standing review-seat GO" <<<"$out" &&
  pass "19e. a non-reviewer slug queued without SPAWN_BYPASS is unchanged: no GO logged" || fail "19e. non-seat: rc=$rc $out"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-522 LANES="$SEAT_LANES" 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$S2")")" == "placed: c-522@box-desk" && "$(jq -r .state <<<"$(hubrow "$FE")")" == queued ]] &&
  grep -q "review-seat pick: ask ${S2:0:8} (bug claude:seat3-r7-reviewer" <<<"$out" &&
  pass "19e. bug OVER its band, feature UNDER: the review seat queued without SPAWN_BYPASS is placed ahead of the feature" ||
  fail "19e. default seat pick: $out | $(hubrow "$S2") | $(cat "$T/launch.log")"
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place LAUNCH_ID=c-523 LANES="$SEAT_LANES" 2>&1)"
[[ "$(jq -r .reason <<<"$(hubrow "$FE")")" == "placed: c-523@box-desk" && "$(jq -r .state <<<"$(hubrow "$N1")")" == queued ]] && ! grep -q "review-seat pick" <<<"$out" &&
  grep -q "band pick: ask ${FE:0:8} (feature at 25%" <<<"$out" &&
  pass "19e. control: a non-reviewer bug queued without the GO waits; the band pick places the feature (bug 50% OVER, feature 25% UNDER)" ||
  fail "19e. control: $out | $(hubrow "$FE") | $(cat "$T/launch.log")"

# 20. spec 150 C405: the PRIO column ------------------------------------------------
# The hub's list carries each ask's discussion priority (1..5, 3 without one,
# B9); the table prints it next to POS (RED CONTROL: the column dropped).
D1=15050001-0000-4000-8000-000000000001; D5=15050005-0000-4000-8000-000000000005
P1=c4050001-0000-4000-8000-000000000001; P3=c4050003-0000-4000-8000-000000000003; P5=c4050005-0000-4000-8000-000000000005
for id in "$P1" "$P3" "$P5"; do put "$id" c-002@box-desk "dispatch-c405" "SPAWN REQUEST ${id:0:8}"; done
jq --arg a "$P1" --arg b "$P5" --arg d1 "$D1" --arg d5 "$D5" \
  'map(if .ask_id == $a then .discussion = $d1 elif .ask_id == $b then .discussion = $d5 else . end)' "$T/hub/main.json" >"$T/hub/main.json.new" &&
  mv "$T/hub/main.json.new" "$T/hub/main.json"
# Priority 1 is a feature, 3 and 5 are bugs: a class-first order would list
# the feature last (RED CONTROL: the hub sorting by class before priority).
on pc do_spl_spawn_enqueue ASK_ID="$P5" SPAWN_CLASS=bug >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$P3" SPAWN_CLASS=bug >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$P1" SPAWN_CLASS=feature >/dev/null 2>&1
out="$(on pc do_spl_spawn_queue SPAWN_QUEUE_SHARE=0 HUB_PRIOS="{\"$D1\": 1, \"$D5\": 5}" 2>&1)"
qpos() { grep -E "^[0-9]+/[0-9]+ +$2 +$3 +${1:0:8} " <<<"$out" | cut -d/ -f1; }
[[ "$(head -1 <<<"$out")" =~ ^POS\ +PRIO\ +CLASS\ +ASK ]] && [[ -n "$(qpos "$P1" 1 feature)" && -n "$(qpos "$P3" 3 bug)" && -n "$(qpos "$P5" 5 bug)" ]] &&
  (( $(qpos "$P1" 1 feature) < $(qpos "$P3" 3 bug) && $(qpos "$P3" 3 bug) < $(qpos "$P5" 5 bug) )) &&
  pass "20. C405: the PRIO column shows 1 (a feature), 3 (no discussion) and 5, priority ahead of class" || fail "20. C405 PRIO column: $out"
[[ "$(on pc do_spl_spawn_queue SPAWN_QUEUE_FORMAT=json HUB_PRIOS="{\"$D1\": 1}" 2>/dev/null | jq -r --arg a "$P1" '.queue[] | select(.ask_id == $a) | .priority')" == 1 ]] &&
  pass "20. C405: the json view carries priority" || fail "20. C405 json priority"
for id in "$P1" "$P3" "$P5"; do HUB_DIR="$T/hub" "$T/bin/hub" ask dead --fleet main --id "$id" --by c-001@box-desk --reason c405 >/dev/null; done

# 21. spec 150 row B10b: ASK_DISCUSSION at enqueue, the ask already on the hub ----------
# The request is on the hub before the enqueue, so the put fills discussion while
# it is NULL. RED CONTROL: no pass-through leaves the row's discussion empty.
DA=59f725e4-08ca-4e6e-8490-1902a708eba3; DB=59f725e4-08ca-4e6e-8490-1902a708eba4
K1=b10b0001-0000-4000-8000-000000000001; K2=b10b0002-0000-4000-8000-000000000002; K3=b10b0003-0000-4000-8000-000000000003
for id in "$K1" "$K2" "$K3"; do put "$id" c-002@box-desk "spawn-b10b" "SPAWN REQUEST ${id:0:8}"; done
kdisc() { jq -r --arg i "$1" '.[] | select(.ask_id == $i) | "\(.discussion // "")/\(.state)"' "$T/hub/main.json"; }
out="$(on pc do_spl_spawn_enqueue ASK_ID="${K1:0:8}" SPAWN_CLASS=bug ASK_DISCUSSION="$DA" 2>&1)"
[[ "$(kdisc "$K1")" == "$DA/queued" && "$(jq -r .discussion "$T/pc/spool/asks/$K1.json")" == "$DA" ]] &&
  pass "21. B10b: ASK_DISCUSSION reaches an ask already on the hub, and the journal; the ask is queued" ||
  fail "21. B10b discussion at enqueue: hub $(kdisc "$K1"), journal $(cat "$T/pc/spool/asks/$K1.json"): $out"
out="$(on pc do_spl_spawn_enqueue ASK_ID="$K1" SPAWN_CLASS=bug ASK_DISCUSSION="$DB" 2>&1)"
[[ "$(kdisc "$K1")" == "$DA/queued" && "$out" == *"keeps its discussion ${DA:0:8}"* ]] &&
  pass "21. B10b: a second discussion never overwrites, and says so (the ask stays queued)" || fail "21. B10b overwrite: $(kdisc "$K1"): $out"
on pc do_spl_spawn_enqueue ASK_ID="$K2" SPAWN_CLASS=bug >/dev/null 2>&1
on pc do_spl_spawn_enqueue ASK_ID="$K2" SPAWN_CLASS=bug ASK_DISCUSSION="$DA" >/dev/null 2>&1
[[ "$(kdisc "$K2")" == "$DA/queued" ]] && pass "21. B10b: an ask already queued gets it too, still queued" || fail "21. B10b queued ask: $(kdisc "$K2")"
rc=0; out="$(on pc do_spl_spawn_enqueue ASK_ID="$K3" SPAWN_CLASS=bug ASK_DISCUSSION=59f725e4 2>&1)" || rc=$?
[[ $rc != 0 && "$out" == *"ASK_DISCUSSION must be"* && "$(kdisc "$K3")" == /open ]] &&
  pass "21. B10b: a bad ASK_DISCUSSION is refused, the ask not queued" || fail "21. B10b bad id: rc $rc $(kdisc "$K3"): $out"
on pc do_spl_spawn_enqueue ASK_ID="$K3" SPAWN_CLASS=bug >/dev/null 2>&1
[[ "$(kdisc "$K3")" == /queued ]] && pass "21. B10b CONTROL: no ASK_DISCUSSION leaves the row's empty" || fail "21. B10b control: $(kdisc "$K3")"
for id in "$K1" "$K2" "$K3"; do HUB_DIR="$T/hub" "$T/bin/hub" ask dead --fleet main --id "$id" --by c-001@box-desk --reason b10b >/dev/null; done

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

# SPL-4955 (owner HUM-10, msg 51465f86; t1 2e46fcb6: archived 11-01, row 1bd6c305
# placed 11-06 as c-702): a row whose topic is archived is not placed; the next
# row is placed in the same tick. RED CONTROL: without spl_spawn_place_drop_archived
# H1 launches and the first check fails.
H1=71111111-0000-4000-8000-000000000001 H2=72222222-0000-4000-8000-000000000002 H3=73333333-0000-4000-8000-000000000003 H4=74444444-0000-4000-8000-000000000004
printf '#!/usr/bin/env bash\nif [ "$1" = aaaaaaaa ]; then echo "{\\"lanes\\":[],\\"topic_archived_at\\":\\"2026-11-01T08:59:43Z\\"}"; else echo "{\\"lanes\\":[]}"; fi\n' >"$T/bin/archived"; chmod +x "$T/bin/archived"
printf 'Kind: simple_coding\nEpic: SPL-8\nSpec: csi-spl-doc/specs/135-work-process\nbrief\n' | tee "$T/briefs/arch-a.md" "$T/briefs/arch-b.md" "$T/briefs/arch-c.md" "$T/briefs/arch-d.md" >/dev/null
archq() {  # ASK_ID TOPIC SLUG
  put "$1" c-002@box-desk "$2" "SPAWN REQUEST $3"
  on pc do_spl_spawn_enqueue "${EH2[@]}" ASK_ID="$1" SPAWN_CLASS=feature SPAWN_PLACE="claude:$3" >>"$T/enq.log" 2>&1
}
jq '(.[] | select(.state == "queued" or .state == "acked")) |= (.state = "dead")' "$T/hub/main.json" >"$T/hub/main.json.new" && mv "$T/hub/main.json.new" "$T/hub/main.json"
printf 'SPL-8\twip\n' >"$T/epics.tsv"
archq "$H1" dispatch-aaaaaaaa arch-a
archq "$H2" dispatch-bbbbbbbb arch-b
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"; : >"$T/send.log"
out="$(on pc do_spl_spawn_place "${EH2[@]}" SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived" LAUNCH_ID=c-731 2>&1)"
r="$(hubrow "$H1")"
[[ "$(jq -r .state <<<"$r")" == declined && "$(jq -r .reason <<<"$r")" == "discussion archived: topic aaaaaaaa was archived at 2026-11-01T08:59:43Z"* ]] && ! grep -q arch-a "$T/launch.log" &&
  pass "SPL-4955 a row of an archived topic is declined with the reason, not launched" || fail "SPL-4955 archived row: $(tail -3 "$T/enq.log") | $out | $r | $(cat "$T/launch.log")"
grep -q "arch-b" "$T/launch.log" && [[ "$(jq -r .reason <<<"$(hubrow "$H2")")" == "placed: c-731@box-desk" ]] &&
  pass "SPL-4955 CONTROL: the live row behind it is placed in the same tick" || fail "SPL-4955 live row: $out | $(hubrow "$H2") | $(cat "$T/launch.log")"
grep -q "c-001 c-002 note .*not placed: discussion archived" "$T/send.log" && grep -q "c-001 c-001 note spawn-queue .*ask ${H1:0:8} not placed" "$T/send.log" &&
  pass "SPL-4955 its sender and the holder are told" || fail "SPL-4955 told: $(sends)"
grep -qx 'Ask-Topic: bbbbbbbb' "$T/briefs/arch-b.md" && pass "SPL-4955 a launch writes the row's topic as the brief's Ask-Topic line" || fail "SPL-4955 Ask-Topic: $(cat "$T/briefs/arch-b.md")"
# a failed read places as before, one WARN
printf '#!/usr/bin/env bash\necho "flag provided but not defined: -topic"; exit 2\n' >"$T/bin/archived-old"; chmod +x "$T/bin/archived-old"
archq "$H3" dispatch-aaaaaaaa arch-c
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place "${EH2[@]}" SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived-old" LAUNCH_ID=c-732 2>&1)"
grep -q arch-c "$T/launch.log" && grep -q "the archive state of topic aaaaaaaa could not be read" <<<"$out" &&
  pass "SPL-4955 a failed read places as before, one WARN" || fail "SPL-4955 failed read: $out | $(cat "$T/launch.log")"
# N1: an older binary or hub ignores --topic and answers the fleet's lanes, no stamp
printf '#!/usr/bin/env bash\necho "{\\"lanes\\":[{\\"agent\\":\\"c-9\\"}]}"\n' >"$T/bin/archived-older"; chmod +x "$T/bin/archived-older"
archq "$H4" dispatch-aaaaaaaa arch-d
rm -f "$T/pc/spool/asks/.place.last"; : >"$T/launch.log"
out="$(on pc do_spl_spawn_place "${EH2[@]}" SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived-older" LAUNCH_ID=c-733 2>&1)"
grep -q arch-d "$T/launch.log" && grep -q "too old to read the archive state of topic aaaaaaaa" <<<"$out" &&
  pass "SPL-4955 lanes with no stamp prove old code: placed as before, one WARN" || fail "SPL-4955 old code: $out | $(cat "$T/launch.log")"
# 40. SPL-4966 (spec 146, what-broke-20261106 section 7 item 3). A logged review
# seat's launch carries the review-seat mark, any other row's does not; a seat
# a hold stops 30 min alarms once, through both channels: the blocker names the
# seat and the hold, the #alerts post neither.
AS="$T/asks-seat.log"; printf '#!/usr/bin/env bash\ncat >>"%s"; echo seat-alert-1\n' "$AS" >"$T/bin/alert"; chmod +x "$T/bin/alert"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/alert-no"; printf '#!/usr/bin/env bash\nexit 11\n' >"$T/bin/send-no"; chmod +x "$T/bin/alert-no" "$T/bin/send-no"
Q40="$T/pc/spool/asks"
seat_clear() {  # no other queued row in the way, no alarm or wait state
  jq 'map(if .state == "queued" or .state == "acked" then .state = "done" else . end)' "$T/hub/main.json" >"$T/h.$$" && mv "$T/h.$$" "$T/hub/main.json"
  rm -f "$Q40/.place.seat-alarm" "$Q40/.place.seat-alarm.last" "$Q40/.place.wait" "$Q40/.place.last" "$AS" "$T/send.log" "$T/launch.log.seat"
  N40=$((N40 + 1))  # the stub takes an ask id once: each case its own
  K1="$(printf '40%06d-0000-4000-8000-000000000001' "$N40")"; K2="$(printf '40%06d-0000-4000-8000-000000000002' "$N40")"; K3="$(printf '40%06d-0000-4000-8000-000000000003' "$N40")"
}
seat_q() {  # ASK SLUG MIN_IN_LINE [HEADING]: queue SLUG as enqueue does, MIN minutes ago
  printf '# Lane brief: %s\nClass: bug\n%s\n' "${4:-R7 reviewer, review only}" "$ES" >"$T/briefs/$2.md"
  put "$1" c-002@box-desk "dispatch-$2" "SPAWN REQUEST $2"
  on pc do_spl_spawn_enqueue ASK_ID="$1" SPAWN_CLASS=bug SPAWN_PLACE="claude:$2" >/dev/null 2>&1
  jq --arg i "$1" --argjson t "$(( $(date +%s) - $3 * 60 ))" 'map(if .ask_id == $i then .q = $t else . end)' "$T/hub/main.json" >"$T/h.$$" && mv "$T/h.$$" "$T/hub/main.json"
}
tick40() { on pc do_spl_spawn_place ASKS_ALERT_CMD="$T/bin/alert" LANES='[]' "$@" 2>&1; }
alarms() { grep -c 'review seat(s) held' "$T/send.log" 2>/dev/null; }
posts() { cat "$AS" 2>/dev/null | grep -c 'review seat(s) held'; }
N40=0

seat_clear; seat_q "$K1" k1-reviewer 0
tick40 LAUNCH_ID=c-541 >/dev/null
grep -q '^k1-reviewer BOX_PICK_REVIEW_SEAT=1$' "$T/launch.log.seat" && pass "40a. a logged review seat launches on the review-seat mark" || fail "40a. $(cat "$T/launch.log.seat")"
seat_clear; seat_q "$K1" k1-parser-reviewer 0 "fix the parser, commit and push"
out="$(tick40 LAUNCH_ID=c-541)"
grep -q '^k1-parser-reviewer BOX_PICK_REVIEW_SEAT=0$' "$T/launch.log.seat" && grep -q "first heading does not say review" <<<"$out" &&
  pass "40a. a coding lane named -reviewer is logged, and launches on the weekly mark" || fail "40a. forge: $(cat "$T/launch.log.seat") $out"
seat_clear; seat_q "$K2" k2-plain-fix 0
tick40 LAUNCH_ID=c-542 >/dev/null
grep -q '^k2-plain-fix BOX_PICK_REVIEW_SEAT=0$' "$T/launch.log.seat" && pass "40a. CONTROL any other row launches on the weekly mark" || fail "40a. control: $(cat "$T/launch.log.seat")"

seat_clear; seat_q "$K1" k1-reviewer 31
out="$(tick40 LAUNCH_HOLD_SLUG=k1-reviewer)"
[[ "$(alarms)" == 0 ]] && grep -q 'back in line' <<<"$out" && pass "40b. first HOLD of a seat 31 min in line: no hold was known at the check, nothing yet" || fail "40b. first: $(sends) | $out"
tick40 LAUNCH_HOLD_SLUG=k1-reviewer >/dev/null
[[ "$(alarms)" == 1 && "$(posts)" == 1 ]] && grep -q "c-001 c-002 blocker spawn-queue .*ask ${K1:0:8} (claude:k1-reviewer), 3[0-9] min in line: waiting: grok weekly >= 90% on box-a" "$T/send.log" &&
  grep -q "^- ask ${K1:0:8}, 3[0-9] min in line$" "$AS" && pass "40c. the next tick: one blocker to the dispatch holder naming the hold, and one #alerts post" || fail "40c. $(sends) | $(cat "$AS" 2>/dev/null)"
rm -f "$Q40/.place.seat-alarm.last"
tick40 LAUNCH_HOLD_SLUG=k1-reviewer >/dev/null
[[ "$(alarms)" == 1 && "$(posts)" == 1 ]] && pass "40d. the same seat, still held, past the alarm gap: no second alarm" || fail "40d. $(sends)"

seat_clear; seat_q "$K1" k1-reviewer 29
tick40 LAUNCH_HOLD_SLUG=k1-reviewer >/dev/null; tick40 LAUNCH_HOLD_SLUG=k1-reviewer >/dev/null
[[ "$(alarms)" == 0 && "$(posts)" == 0 ]] && pass "40e. CONTROL held but 29 min in line: no alarm" || fail "40e. $(sends)"
seat_clear; seat_q "$K2" k2-plain-fix 45
tick40 LAUNCH_HOLD_SLUG=k2-plain-fix >/dev/null; tick40 LAUNCH_HOLD_SLUG=k2-plain-fix >/dev/null
[[ "$(alarms)" == 0 ]] && pass "40e. CONTROL a row that is no logged seat, held 45 min: no alarm" || fail "40e. plain: $(sends)"

seat_clear; seat_q "$K1" k1-reviewer 31
out="$(tick40 WINDOWS=40)"
[[ "$(alarms)" == 1 ]] && grep -q 'agent windows 40 >= the ceiling 40' "$T/send.log" && pass "40f. no launcher line, the window ceiling holds it: the alarm names the ceiling" || fail "40f. $(sends) | $out"
seat_clear; seat_q "$K1" k1-reviewer 31
touch "$Q40/.place.last"
out="$(tick40 SPAWN_PLACE_GAP_MIN=10)"
[[ "$(alarms)" == 0 ]] && grep -q 'hold: the last placement started' <<<"$out" && pass "40g. CONTROL only the gap between launches holds it: a pace, no alarm" || fail "40g. $(sends) | $out"

seat_clear; seat_q "$K1" k1-reviewer 31; seat_q "$K3" k3-reviewer 33
tick40 WINDOWS=40 >/dev/null
[[ "$(alarms)" == 1 ]] && grep -q 'SPAWN QUEUE: 2 review seat(s) held' "$T/send.log" && pass "40h. two seats due in one tick: one alarm naming both" || fail "40h. $(sends)"
seat_clear; seat_q "$K1" k1-reviewer 31
tick40 WINDOWS=40 >/dev/null
seat_q "$K3" k3-reviewer 33
tick40 WINDOWS=40 >/dev/null
[[ "$(alarms)" == 1 ]] && pass "40i. a seat due inside the alarm gap waits for the next alarm" || fail "40i. $(sends)"
touch -d '31 minutes ago' "$Q40/.place.seat-alarm.last"
tick40 WINDOWS=40 >/dev/null
[[ "$(alarms)" == 2 ]] && grep -q "SPAWN QUEUE: 1 review seat(s) held.*ask ${K3:0:8}" "$T/send.log" && pass "40i. past the gap: it alarms, alone" || fail "40i. next: $(sends)"

seat_clear; seat_q "$K1" k1-reviewer 31
tick40 WINDOWS=40 SPAWN_QUEUE_SEND="$T/bin/send-no" ASKS_ALERT_CMD="$T/bin/alert-no" >/dev/null
[[ ! -s "$Q40/.place.seat-alarm" ]] && pass "40j. neither channel took it: not recorded" || fail "40j. $(cat "$Q40/.place.seat-alarm")"
tick40 WINDOWS=40 >/dev/null
[[ "$(alarms)" == 1 ]] && pass "40j. ... and the next tick retries it" || fail "40j. retry: $(sends)"
seat_clear; seat_q "$K1" k1-reviewer 31
tick40 WINDOWS=40 SPAWN_QUEUE_SEND="$T/bin/send-no" >/dev/null
[[ "$(posts)" == 1 && -s "$Q40/.place.seat-alarm" ]] && pass "40k. the blocker failed, #alerts took it: fired, recorded" || fail "40k. $(cat "$AS" 2>/dev/null)"
seat_clear; seat_q "$K1" k1-reviewer 31
out="$(tick40 WINDOWS=40 ASKS_ALERT_CMD="$T/bin/alert-no")"
[[ "$(alarms)" == 1 ]] && grep -q 'WARN the review-seat alarm did not post in #alerts' <<<"$out" && pass "40k. #alerts failed, the blocker went: fired, with a WARN" || fail "40k. alert: $(sends) | $out"
# A customer-style slug, and a hold line that names it, its brief path and a box:
# the blocker has them, the post has none. The post's seat lines are an allow-list:
# a ban list only finds what it guessed.
seat_clear; seat_q "$K1" acme-corp-portal-reviewer 31
printf '%s\t%s\t%s\n' "$K1" "$(date +%s)" "the launcher says acme-corp-portal-reviewer.md under /briefs/acme is held on box-acme" >"$Q40/.place.wait"
tick40 WINDOWS=40 >/dev/null
[[ "$(alarms)" == 1 && "$(posts)" == 1 ]] && grep -q "(claude:acme-corp-portal-reviewer), 3[0-9] min in line: the launcher says acme-corp-portal-reviewer.md under /briefs/acme" "$T/send.log" &&
  pass "40l. a customer-style slug and a hold line naming it reach the blocker" || fail "40l. blocker: $(sends)"
if grep -qiE 'acme|box-|/briefs' "$AS"; then fail "40l. the #alerts post carries the slug or the hold: $(cat "$AS")"
elif [[ "$(grep '^- ' "$AS" | grep -cvE "^- ask ${K1:0:8}, [0-9]+ min in line$")" != 0 || "$(grep -c '^- ' "$AS")" != 1 ]]; then fail "40l. a seat line of the post is more than id8 and minutes: $(cat "$AS")"
else pass "40l. ... and not the #alerts post: its seat line is id8 and minutes only"; fi
seat_clear

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
