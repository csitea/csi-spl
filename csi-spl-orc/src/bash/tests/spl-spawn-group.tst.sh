#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: work groups (SPL-2370; owner HUM-10, t1 d4c0c0a8 msgs 09958ea6,
#          e8b2b36a: "When there is one, there will always be many"). A group
#          (do_spl_spawn_group_put) holds ordered rows and a width N; the
#          placer (do_spl_spawn_place) keeps N rows in flight by feeding the
#          one spawn queue. The hub (`spool ask`, rdb 0097 + 0180 + 0195), the
#          lane map, the issues, spool-send and the launcher are stubs; each
#          machine dir is a temp SPOOL_ROOT.
#   1. put: 4 rows at width 2 -> the group file, one derived ask id per row
#      (the same on a re-put); a bad class, placement, key or duplicate slug
#      is refused
#   2. CONTROL: today's placer (no group feed) places none of the 4 rows
#   3. width 2 runs to the end with no hand step: 2 in flight, a landed
#      lane (issue done) and a closed one (lane gone) each free a slot, 4
#      launches, each row once, 0 blockers to the holder
#   4. width 1 = today's single row: the group row's hub row has the same
#      state, class and placement as a do_spl_spawn_enqueue row; a second
#      row waits until the first ends
#   5. a failed lane (ask declined) frees its slot
#   6. bands still apply: a bug ask under its band goes before the group's
#      queued feature row
#   7. no duplicate placement: a second machine with the same group feeds
#      no new row; a re-put keeps a running row running; a placed lane not
#      yet in the lane map is running within SPAWN_GROUP_GRACE_MIN
#   8. do_spl_spawn_group_list shows done / running / waiting per group
#   9. the stall check: a group with waiting rows and fewer than N in
#      flight for EPIC_STALL_IDLE_MIN gets ONE blocker (CONTROL: a group
#      with its width in flight gets none)
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
mkdir -p "$T/bin" "$T/briefs"
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
# the launcher stub: the next id c-3NN; the new lane joins the lane map
# (LAUNCH_NO_LANE=1: not yet)
cat >"$T/bin/launch" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$LAUNCH_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$LAUNCH_LOG.n"
id="c-3$(printf %02d "$n")"
echo "$5 $id" >>"$LAUNCH_LOG"
[ "${LAUNCH_NO_LANE:-0}" = 1 ] || { jq -c --arg i "$id" '.lanes += [{agent_id: $i, agent_box: "box-desk", state: "live", scope: "", branch: ""}]' "$LANES_FILE" >"$LANES_FILE.n" && mv "$LANES_FILE.n" "$LANES_FILE"; }
echo "$id %42"
STUB
# shellcheck disable=SC2016 # expanded by the stubs, not here
{
printf '#!/usr/bin/env bash\necho "${WINDOWS:-12}"\n' >"$T/bin/windows"
printf '#!/usr/bin/env bash\necho "pick=box-desk reason=below its low mark"\n' >"$T/bin/pick"
printf '#!/usr/bin/env bash\ncat "$LANES_FILE"\n' >"$T/bin/lanes"
printf '#!/usr/bin/env bash\njq -c --arg k "$EPIC_KEY" '"'"'{result: {issues: [.[] | select(.epic == $k)]}}'"'"' "$ISSUES_FILE"\n' >"$T/bin/issues"
printf '#!/usr/bin/env bash\necho "{\\"result\\": {\\"issues\\": []}}"\n' >"$T/bin/epics"
}
chmod +x "$T/bin/"*
for s in one two three four solo solo2 w1a w1b f1 f2 feat bugfix d1 d2 s1 s2 s3 full; do echo "brief of g-$s" >"$T/briefs/g-$s.md"; done

# Each machine M: its own spool root and lane map; the hub dir is HUB_M
# (default M), so two machines may share one hub.
menv() {
  local m="$1"
  mkdir -p "$T/$m/spool/dispatch" "$T/hub-${HUB_M:-$m}"
  [[ -f "$T/$m/spool/dispatch/lease.conf" ]] || printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$T/$m/spool/dispatch/lease.conf"
  [[ -f "$T/$m/lanes.json" ]] || echo '{"lanes": []}' >"$T/$m/lanes.json"
  [[ -f "$T/$m/issues.json" ]] || echo '[]' >"$T/$m/issues.json"
  printf '%s\n' "SPOOL_ROOT=$T/$m/spool" "SPOOL_BOX_ENV=$T/$m/spool/box.env" "SPOOL_DESK_BOX=box-desk" \
    "ASKS_HUB_CMD=$T/bin/hub" "HUB_DIR=$T/hub-${HUB_M:-$m}" "SPOOL_ORCHESTRATOR_ID=c-001" "SPOOL_FLEET_RELAY=0" \
    "ASKS_HOLDER=c-001@box-desk" "SPAWN_QUEUE_SEND=$T/bin/send" "ASKS_SEND=$T/bin/send" "SEND_LOG=$T/$m/send.log" \
    "SPAWN_PLACE_WINDOWS_CMD=$T/bin/windows" "SPAWN_PLACE_PICK_CMD=$T/bin/pick" "SPAWN_PLACE_LAUNCH_CMD=$T/bin/launch" \
    "LAUNCH_LOG=$T/$m/launch.log" "SPAWN_PLACE_BRIEF_DIR=$T/briefs" "SPAWN_PLACE_WORKDIR=$T" "SPAWN_PLACE_GAP_MIN=0" "SPOOL_AGENT_ID=" \
    "SPAWN_SHARE_LANES_CMD=$T/bin/lanes" "SPAWN_SHARE_DISPATCH=c-002@box-desk" "SPAWN_SHARE_SUPPLY_MIN=99999" \
    "LANES_FILE=$T/$m/lanes.json" "ISSUES_FILE=$T/$m/issues.json" "EPIC_STALL_LANES_CMD=$T/bin/lanes" \
    "EPIC_STALL_ISSUES_CMD=$T/bin/issues" "EPIC_STALL_EPICS_CMD=$T/bin/epics" "SPAWN_FILL_CNF=$T/none.yaml" \
    "SPAWN_GROUP_POLL_MIN=0" "SPAWN_GROUP_GRACE_MIN=0" "ASK_BY=c-002@box-desk"
}
on() {  # <machine> <action> [env...]
  local m="$1" a="$2"; shift 2
  local -a e; mapfile -t e < <(menv "$m")
  # shellcheck disable=SC2016 # the action runs in the child shell
  env "${e[@]}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-ask-ack spl-asks-tick spl-spawn-queue spl-spawn-share spl-spawn-enqueue spl-spawn-placed spl-spawn-place spl-spawn-group-put spl-spawn-group-list spl-epic-stall-check spl-spawn-fill; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    '"$a" 2>&1
}
hub() { mkdir -p "$T/hub-$1"; HUB_DIR="$T/hub-$1" "$T/bin/hub" ask "${@:2}"; }
hubrows() { jq -c '.' "$T/hub-$1/main.json" 2>/dev/null || echo '[]'; }
launched() { cut -d' ' -f1 "$T/$1/launch.log" 2>/dev/null | xargs -r -n1 basename | sed 's/\.md$//' | tr '\n' ' '; }
nlaunch() { grep -c . "$T/$1/launch.log" 2>/dev/null || echo 0; }
issue() {  # MACHINE KEY EPIC STATUS
  jq -c --arg k "$2" --arg e "$3" --arg s "$4" '[.[] | select(.key != $k)] + [{key: $k, epic: $e, kind: "issue", status: $s}]' \
    "$T/$1/issues.json" >"$T/$1/i.json" && mv "$T/$1/i.json" "$T/$1/issues.json"
}
lane_gone() { jq -c --arg i "$2" '.lanes |= map(select(.agent_id != $i))' "$T/$1/lanes.json" >"$T/$1/l.json" && mv "$T/$1/l.json" "$T/$1/lanes.json"; }
gstate() { on "$1" do_spl_spawn_group_list GROUP_FORMAT=json GROUP_EPIC="$2" "${@:3}" | grep -E '^\{"groups"' | tail -1; }
rows() { printf '%s\n' "$@" >"$T/rows.txt"; }

# 1. put -------------------------------------------------------------------------
rows "# epic SPL-2151, two at a time" "feature claude:g-one SPL-2152" "feature claude:g-two SPL-2153" "" \
  "feature claude:g-three SPL-2154" "feature claude:g-four SPL-2155"
out="$(on pc do_spl_spawn_group_put GROUP_EPIC=SPL-2151 GROUP_WIDTH=2 GROUP_ROWS="$T/rows.txt")"
g="$T/pc/spool/dispatch/groups/SPL-2151.json"
if [[ "$(jq -r '"\(.width) \(.rows | length) \([.rows[].slug] | join(","))"' "$g" 2>/dev/null)" == "2 4 g-one,g-two,g-three,g-four" ]] &&
   [[ "$(jq -r '[.rows[].ask_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")] | all' "$g")" == true ]] &&
   [[ "$(jq -r '[.rows[].ask_id] | unique | length' "$g")" == 4 ]] && grep -q "OK work group SPL-2151: 4 row(s), width 2" <<<"$out"; then
  pass "put: 4 rows at width 2 in the group file, each with its own lowercase UUID ask id"
else fail "put: $out | $(cat "$g" 2>&1)"; fi
ids1="$(jq -r '[.rows[].ask_id] | join(" ")' "$g")"
on pc do_spl_spawn_group_put GROUP_EPIC=SPL-2151 GROUP_WIDTH=2 GROUP_ROWS="$T/rows.txt" >/dev/null
[[ "$(jq -r '[.rows[].ask_id] | join(" ")' "$g")" == "$ids1" ]] && pass "put: a re-put derives the same ask ids" || fail "re-put ids changed"
before=$fails
for bad in "chore claude:g-x SPL-1" "feature claude:G-X SPL-1" "feature claude:g-x spl-1" "feature claude:g-x SPL-1 urgent" \
           "bug claude:g-x SPL-1 8cb6cc7d-7628-4ac3-be00-86e427bb3487"; do
  rows "$bad"
  on pc do_spl_spawn_group_put GROUP_EPIC=SPL-9 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null && fail "put took '$bad'"
done
rows "bug claude:g-x SPL-1" "bug claude:g-x SPL-2"
on pc do_spl_spawn_group_put GROUP_EPIC=SPL-9 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null && fail "put took a duplicate slug"
rows "bug claude:g-x SPL-1"
on pc do_spl_spawn_group_put GROUP_EPIC=SPL-9 GROUP_WIDTH=0 GROUP_ROWS="$T/rows.txt" >/dev/null && fail "put took width 0"
[[ $fails == "$before" && ! -e "$T/pc/spool/dispatch/groups/SPL-9.json" ]] &&
  pass "put refuses a bad class, an upper-case slug, a bad key, an urgent feature, a bypass bug, a duplicate slug, width 0"

# 2. CONTROL: today's placer -------------------------------------------------------
mkdir -p "$T/ctl/spool/dispatch/groups"; cp "$g" "$T/ctl/spool/dispatch/groups/"
for _ in 1 2 3; do on ctl 'spl_spawn_group_feed() { :; }; do_spl_spawn_place' >/dev/null; done
[[ "$(nlaunch ctl)" == 0 && "$(hubrows ctl)" == "[]" ]] &&
  pass "control: today's placer (no group feed), 3 ticks: 0 of the 4 rows queued or placed - a group needs a hand step per row" ||
  fail "control: $(nlaunch ctl) launches, hub $(hubrows ctl)"

# 3. width 2 runs to the end -----------------------------------------------------------
on pc do_spl_spawn_place >/dev/null
st="$(gstate pc SPL-2151)"
[[ "$(launched pc)" == "g-one " && "$(jq -r '.groups[0] | "\(.counts.running) \(.counts.queued) \(.counts.waiting)"' <<<"$st")" == "1 1 2" ]] &&
  pass "tick 1: rows 1 and 2 fed (width 2), row 1 placed (one at a time), 2 waiting" || fail "tick 1: $(launched pc) | $st"
on pc do_spl_spawn_place >/dev/null
on pc do_spl_spawn_place >/dev/null
st="$(gstate pc SPL-2151)"
[[ "$(launched pc)" == "g-one g-two " && "$(jq -r '.groups[0] | "\(.counts.running) \(.counts.waiting)"' <<<"$st")" == "2 2" ]] &&
  [[ "$(jq '[.[] | select(.summary | test("SPL-2151 row [34]/"))] | length' <<<"$(hubrows pc)")" == 0 ]] &&
  pass "ticks 2-3: row 2 placed; 2 running = width, rows 3 and 4 not even on the hub" || fail "ticks 2-3: $(launched pc) | $st"
issue pc SPL-2152 SPL-2151 "done"
on pc do_spl_spawn_place >/dev/null
[[ "$(launched pc)" == "g-one g-two g-three " ]] && pass "row 1 lands (issue done): its slot frees, row 3 is fed and placed at once" ||
  fail "after landing: $(launched pc)"
lane_gone pc c-302
on pc do_spl_spawn_place >/dev/null
st="$(gstate pc SPL-2151)"
[[ "$(launched pc)" == "g-one g-two g-three g-four " && "$(jq -r '.groups[0].rows[1] | "\(.state) \(.agent)"' <<<"$st")" == "closed c-302@box-desk" ]] &&
  pass "row 2's lane closes unlanded (gone from the lane map): its slot frees, row 4 is placed" || fail "after close: $(launched pc) | $st"
issue pc SPL-2154 SPL-2151 "done"; issue pc SPL-2155 SPL-2151 "done"
on pc do_spl_spawn_place >/dev/null; on pc do_spl_spawn_place >/dev/null
st="$(gstate pc SPL-2151)"
if [[ "$(nlaunch pc)" == 4 && "$(jq -r '.groups[0] | "\(.counts.done) \(.counts.closed) \(.counts.waiting) \(.inflight)"' <<<"$st")" == "3 1 0 0" ]] &&
   ! grep -q "SPAWN QUEUE: place ask" "$T/pc/send.log" 2>/dev/null; then
  pass "the group ran to the end with no hand step: 4 launches, each row once, 3 done + 1 closed, 0 blockers to the holder"
else fail "end: $(nlaunch pc) launches | $st | $(cat "$T/pc/send.log" 2>/dev/null)"; fi
[[ "$(jq -r '[.rows[] | "\(.end) \(.agent)"] | join(",")' "$g")" == "done c-301@box-desk,closed c-302@box-desk,done c-303@box-desk,done c-304@box-desk" ]] &&
  pass "the ends are kept in the group file (the hub prunes closed asks after a week)" || fail "ends: $(cat "$g")"

# 4. width 1 = today's single row ------------------------------------------------------
A1=a1a1a1a1-0000-4000-8000-000000000001
hub w1 put --fleet main --id "$A1" --kind task --role orch --from c-002@box-desk --topic t --summary "SPAWN REQUEST solo" >/dev/null
on w1 do_spl_spawn_enqueue ASK_ID="$A1" SPAWN_CLASS=bug SPAWN_PLACE=claude:g-solo >/dev/null
rows "bug claude:g-solo2 SPL-4001"
on w1 do_spl_spawn_group_put GROUP_EPIC=SPL-4000 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null
on w1 do_spl_spawn_place WINDOWS=40 >/dev/null
pick='[.[] | {state, class, flag: (.flag // ""), placement: (.placement | sub(":g-solo2?$"; ":<slug>"))}] | unique | length'
[[ "$(jq "$pick" <<<"$(hubrows w1)")" == 1 && "$(jq -r '[.[].state] | join(",")' <<<"$(hubrows w1)")" == "queued,queued" ]] &&
  pass "width 1, one row: the group's hub row is queued with the same state, class, flag and placement as a do_spl_spawn_enqueue row" ||
  fail "width 1 row: $(hubrows w1)"
rows "bug claude:g-w1a SPL-4101" "bug claude:g-w1b SPL-4102"
on w1 do_spl_spawn_group_put GROUP_EPIC=SPL-4100 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null
for _ in 1 2 3 4; do on w1 do_spl_spawn_place >/dev/null; done
[[ "$(launched w1)" == "g-solo g-solo2 g-w1a " ]] && pass "width 1, two rows: the second waits while the first runs" ||
  fail "width 1 serial: $(launched w1)"
issue w1 SPL-4101 SPL-4100 "done"
on w1 do_spl_spawn_place >/dev/null
[[ "$(launched w1)" == "g-solo g-solo2 g-w1a g-w1b " ]] && pass "width 1: the first lands, the second is placed" || fail "width 1 next: $(launched w1)"

# 5. a failed lane frees its slot --------------------------------------------------------
rows "bug claude:g-f1 SPL-5001" "bug claude:g-f2 SPL-5002"
on fl do_spl_spawn_group_put GROUP_EPIC=SPL-5000 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null
on fl do_spl_spawn_place WINDOWS=40 >/dev/null
id1="$(jq -r '.rows[0].ask_id' "$T/fl/spool/dispatch/groups/SPL-5000.json")"
hub fl decline --fleet main --id "$id1" --by c-001@box-desk --reason "not needed" >/dev/null
on fl do_spl_spawn_place >/dev/null
st="$(gstate fl SPL-5000)"
[[ "$(launched fl)" == "g-f2 " && "$(jq -r '.groups[0].rows[0].state' <<<"$st")" == failed ]] &&
  pass "a failed row (its ask declined) frees its slot: the next row is placed" || fail "failed: $(launched fl) | $st"

# 6. bands still apply ---------------------------------------------------------------------
n=0
for c in refactor refactor refactor bug feature feature feature feature feature feature; do
  n=$((n + 1)); id="$(printf 'b%07d-0000-4000-8000-%012d' "$n" "$n")"
  hub bd put --fleet main --id "$id" --kind task --role orch --from c-002@box-desk --topic t --summary "lane $n" >/dev/null
  hub bd queue --fleet main --id "$id" --by c-001@box-desk --class "$c" >/dev/null
  hub bd "done" --fleet main --id "$id" --by c-001@box-desk --reason "placed: c-2$(printf %02d "$n")@box-desk" >/dev/null
done
menv bd >/dev/null
jq -n -c '{lanes: [range(1; 11) | {agent_id: "c-2\(. | tostring | if length < 2 then "0" + . else . end)", agent_box: "box-desk", state: "live", scope: "", branch: ""}]}' >"$T/bd/lanes.json"
rows "feature claude:g-feat SPL-6001"
on bd do_spl_spawn_group_put GROUP_EPIC=SPL-6000 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null
on bd do_spl_spawn_place WINDOWS=40 >/dev/null
B1=b1b1b1b1-0000-4000-8000-000000000001
hub bd put --fleet main --id "$B1" --kind task --role orch --from c-002@box-desk --topic t --summary "SPAWN REQUEST a bug" >/dev/null
on bd do_spl_spawn_enqueue ASK_ID="$B1" SPAWN_CLASS=bug SPAWN_PLACE=claude:g-bugfix >/dev/null
out="$(on bd do_spl_spawn_place)"
[[ "$(launched bd)" == "g-bugfix " ]] && grep -q "band pick: ask ${B1:0:8} (bug at 10%" <<<"$out" &&
  [[ "$(jq -r '.groups[0].rows[0].state' <<<"$(gstate bd SPL-6000)")" == queued ]] &&
  pass "bands: the bug under its band (10%) is placed before the group's older feature row, which stays queued" ||
  fail "bands: $(launched bd) | $out"

# 7. no duplicate placement ------------------------------------------------------------------
rows "bug claude:g-d1 SPL-7001" "bug claude:g-d2 SPL-7002"
on dp do_spl_spawn_group_put GROUP_EPIC=SPL-7000 GROUP_WIDTH=2 GROUP_ROWS="$T/rows.txt" >/dev/null
mkdir -p "$T/dq/spool/dispatch/groups"; cp "$T/dp/spool/dispatch/groups/SPL-7000.json" "$T/dq/spool/dispatch/groups/"
on dp do_spl_spawn_place LAUNCH_NO_LANE=1 SPAWN_GROUP_GRACE_MIN=15 >/dev/null
HUB_M=dp on dq 'spl_spawn_q_init && spl_spawn_group_feed c-001@box-desk' >/dev/null
HUB_M=dp on dq 'spl_spawn_q_init && spl_spawn_group_feed c-001@box-desk' >/dev/null
[[ "$(jq length <<<"$(hubrows dp)")" == 2 && "$(launched dp)" == "g-d1 " ]] &&
  pass "a second machine with the same group feeds the same 2 asks: no new hub row, row 1 placed once" || fail "dedup: $(hubrows dp)"
on dp do_spl_spawn_group_put GROUP_EPIC=SPL-7000 GROUP_WIDTH=2 GROUP_ROWS="$T/rows.txt" >/dev/null
on dp do_spl_spawn_place LAUNCH_NO_LANE=1 SPAWN_GROUP_GRACE_MIN=15 >/dev/null
on dp do_spl_spawn_place LAUNCH_NO_LANE=1 SPAWN_GROUP_GRACE_MIN=15 >/dev/null
st="$(gstate dp SPL-7000 SPAWN_GROUP_GRACE_MIN=15)"
[[ "$(launched dp)" == "g-d1 g-d2 " && "$(jq -r '[.groups[0].rows[].state] | join(",")' <<<"$st")" == "running,running" ]] &&
  pass "a re-put keeps a placed row running; lanes not yet in the lane map count as running within the grace: each row placed once" ||
  fail "re-put/grace: $(launched dp) | $st"
st="$(gstate dp SPL-7000)"
[[ "$(jq -r '[.groups[0].rows[].state] | join(",")' <<<"$st")" == "closed,closed" ]] &&
  pass "control: past the grace (0 min) the same lanes, absent from the lane map, read closed" || fail "grace control: $st"

# 8. the list ---------------------------------------------------------------------------------
out="$(on pc do_spl_spawn_group_list)"
grep -q "GROUP SPL-2151 width 2: 3 done, 0 running, 0 in line, 0 waiting, 1 closed or failed (4 rows)" <<<"$out" &&
  grep -qE "^ +2 +closed +SPL-2153 +feature +claude:g-two +[0-9a-f]{8} +c-302@box-desk" <<<"$out" &&
  pass "the list: one line per group, one per row with its state and lane" || fail "list: $out"

# 9. the stall check ----------------------------------------------------------------------------
NOW="$(date -u +%s)"
rows "bug claude:g-s1 SPL-8001" "bug claude:g-s2 SPL-8002" "bug claude:g-s3 SPL-8003"
on st do_spl_spawn_group_put GROUP_EPIC=SPL-8000 GROUP_WIDTH=2 GROUP_ROWS="$T/rows.txt" >/dev/null
rows "bug claude:g-full SPL-8101"
on st do_spl_spawn_group_put GROUP_EPIC=SPL-8100 GROUP_WIDTH=1 GROUP_ROWS="$T/rows.txt" >/dev/null
on st 'spl_spawn_q_init && spl_spawn_group_tick c-001@box-desk "$SPOOL_ROOT/dispatch/groups/SPL-8100.json" "$(spl_asks_hub_list)"' >/dev/null
out="$(on st do_spl_epic_stall_check DRY_RUN=0 EPIC_STALL_NOW="$NOW")"
[[ ! -s "$T/st/send.log" ]] && grep -q "work group SPL-8000 is short (0 of 2 in flight, 3 waiting) for 0 min" <<<"$out" &&
  pass "stall check: a short group is first remembered, no blocker yet" || fail "stall first: $out"
out="$(on st do_spl_epic_stall_check DRY_RUN=0 EPIC_STALL_NOW="$((NOW + 31 * 60))")"
if [[ "$(grep -c 'blocker' "$T/st/send.log" 2>/dev/null)" == 1 ]] && grep -q "^c-001 c-002 blocker spawn-queue \*\*Blocker: work group SPL-8000 has stalled\*\*" "$T/st/send.log" &&
   grep -q -- "- 1. SPL-8001 claude:g-s1 (bug)" "$T/st/send.log"; then
  pass "stall check: waiting rows and 0 of width 2 in flight for 31 min: ONE blocker naming the group and its next rows"
else fail "stall: $out | $(cat "$T/st/send.log" 2>/dev/null)"; fi
grep -q "work group SPL-8100: 1 of width 1 in flight, 0 waiting" <<<"$out" && ! grep -q "SPL-8100 has stalled" "$T/st/send.log" &&
  pass "control: the group with its width in flight is not stalled" || fail "stall control: $out"
on st do_spl_epic_stall_check DRY_RUN=0 EPIC_STALL_NOW="$((NOW + 40 * 60))" >/dev/null
[[ "$(grep -c 'blocker' "$T/st/send.log")" == 1 ]] && pass "stall check: one blocker per group per EPIC_STALL_REPEAT_H" ||
  fail "stall repeat: $(cat "$T/st/send.log")"

if [[ $fails -gt 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
