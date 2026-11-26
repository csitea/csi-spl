#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the idle filler (do_spl_spawn_fill; owner HUM-10, t1 71dbbf15 msg
#          3c91b4c1): spare box capacity becomes queued lanes from open
#          issues, within the share bands. The hub (`spool ask`), the box
#          pick, the issue list, the lane mix and the lane map are stubs.
#   1. the switch: off (SPAWN_FILL unset, no cnf key) + DRY_RUN=0 queues
#      nothing; DRY_RUN=1 still plans
#   2. the gate: a queued row -> nothing; a box pick that is not "below its
#      low mark" -> nothing; a live run on a machine that does not hold the
#      orch role -> nothing
#   3. the choice: bug OVER its band is never taken; todo before eval; the
#      skips (needs-owner, blocker, epic kind, no bug/feature label, a human
#      assignee, a live lane's assignee, a live lane's own key, a key an ask
#      names); a secret-naming issue whose mix pick is agy is skipped
#   4. how many: ceil(low% * cpus / 100 - load5) / cores per lane, capped by
#      SPAWN_FILL_MAX (default 1)
#   5. bug UNDER its band comes before feature
#   6. a live run: the brief (Issue: + Class:), the ask (an id derived from
#      the key) queued with its class and placement; the next tick sees the
#      queue and fills nothing; the closed ask still holds its key
#   7. do_spl_spawn_fill_install_cron: one line with DRY_RUN=0, PATH with
#      /usr/local/bin, flock -n; idempotent; remove takes only its line
#   8. fill by phase (spec 166 row B4, poll Q2 B): at night (winter and
#      summer, do_spl_rhythm_phase on RHYTHM_NOW) one feature and one bug
#      issue todo -> only the bug is planned and queued; by day both; a night
#      with bug over its band fills nothing; an unreadable phase fills nothing
#      (every other case runs at a fixed day moment, with no inherited
#      RHYTHM_CNF); the class pick with no phase takes no class
#   9. the lane's discussion (SPL-5860): an issue that links only the t1
#      default (backlog) topic gets a NEW hub topic, opened by one desk note
#      and linked to the issue, and the brief names it, never the backlog;
#      an issue with a topic of its own keeps it and opens nothing; a hub
#      that refuses the link queues nothing, and the next tick reuses the
#      same topic id (sha256 of the key, v4-shaped); a refused open links
#      nothing and queues nothing
#  10. the open reaches the hub (b16-01): through the real spl_desk_spool and
#      a fake spool with the client's same-box rule, the open is mirrored to
#      the hub, so the link is taken; the link runs with the mirror unset
#  13. a set plan passes the queue gate (spec 153 Q8, owner H4 A): with a
#      queued row, a priority 2 feature queues one, priority 3 none, a bug at
#      its class default 2 (or an alert at 1) none, a bug raised to 1 one;
#      still one a tick and still behind the box pick; an empty queue fills
#      a priority 3 issue as before
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
mkdir -p "$T/bin" "$T/hub" "$T/hub-b4" "$T/briefs" "$T/spool/dispatch"
export SPOOL_TEST=1

# The hub stub: `spool ask` list / put / queue / done over one JSON file.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]; assert a[0] == "ask"; op = a[1]; kv = {}; i = 2
while i < len(a):
    if a[i] == "--all": kv["all"] = True; i += 1
    else: kv[a[i][2:]] = a[i + 1]; i += 2
path = os.path.join(os.environ["HUB_DIR"], kv["fleet"] + ".json")
rows = json.load(open(path)) if os.path.exists(path) else []
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
OPEN = ("open", "acked", "queued")
def answer(sel):
    q = [r for r in rows if r["state"] == "queued"]
    for r in rows: r["position"], r["queue_len"] = (q.index(r) + 1, len(q)) if r in q else (0, 0)
    print(json.dumps({"fleet": kv["fleet"], "asks": sel})); sys.exit(0)
if op == "list":
    answer([r for r in rows if kv.get("all") or r["state"] in OPEN])
if op == "put":
    for r in rows:
        if r["ask_id"] == kv["id"]: answer([r])
    r = {"ask_id": kv["id"], "role": kv.get("role") or "orch", "kind": kv["kind"], "from": kv["from"], "topic": kv.get("topic", ""),
         "summary": kv.get("summary", ""), "state": "open", "raised_n": 0, "created_at": now, "updated_at": now}
    rows.append(r); json.dump(rows, open(path, "w")); answer([r])
for r in rows:
    if r["ask_id"] != kv["id"]: continue
    if r["state"] not in OPEN: print("hub refused: ask_closed (409)", file=sys.stderr); sys.exit(1)
    if op == "queue":
        r.update(state="queued", enqueued_at=now, **{k: kv[k] for k in ("class", "placement") if kv.get(k)})
    elif op == "done": r.update(state="done", closed_by=kv["by"], reason=kv.get("reason", ""))
    else: print("hub refused: bad_frame (400)", file=sys.stderr); sys.exit(1)
    json.dump(rows, open(path, "w")); answer([r])
print("hub refused: unknown_ask (404)", file=sys.stderr); sys.exit(1)
STUB
chmod +x "$T/bin/hub"
# The desk spool stub (SPAWN_FILL_HUB_CMD): logs each call; HUB_FAIL=link refuses the link.
cat >"$T/bin/spoolhub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SPOOL_HUB_LOG"
[[ "$1" == issue && "${HUB_FAIL:-}" == link ]] && { echo "hub refused: unknown_discussion (400)" >&2; exit 1; }
[[ "$1" == send && "${HUB_FAIL:-}" == open ]] && { echo "hub refused: from_not_announced (403)" >&2; exit 1; }
[[ "$1" == send ]] && echo '{"msg_id":"m-1","delivery":"sent"}'
exit 0
STUB
chmod +x "$T/bin/spoolhub"
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SEND_LOG"
STUB
chmod +x "$T/bin/send"
# shellcheck disable=SC2016 # expanded by the stubs, not here
{
  printf '#!/usr/bin/env bash\necho "{\\"lanes\\": ${LANES:-[]}}"\n' >"$T/bin/lanes"
  printf '#!/usr/bin/env bash\necho "BOX box-desk  load5 ${LOAD5:-4.43}  cpus 16  ${PCT:-27}%%  under  band 50..85 (box)  <- pick"\necho "pick=${PICK:-box-desk reason=box-desk is the first box in order below its low mark (27%% < 50%%)}"\n' >"$T/bin/pick"
  printf '#!/usr/bin/env bash\necho "$LANE_MIX_KIND $LANE_MIX_SENSITIVE" >>"$MIX_LOG"\nif [ "$LANE_MIX_SENSITIVE" = 1 ]; then echo "pick=${MIX_SECRET:-agy} launcher=/x-spawn"; else echo "pick=claude launcher=/claude-spawn kind=$LANE_MIX_KIND reason=main"; fi\n' >"$T/bin/mix"
  printf '#!/usr/bin/env bash\ncat "%s/issues.json"\n' "$T" >"$T/bin/issues"
}
chmod +x "$T/bin/lanes" "$T/bin/pick" "$T/bin/mix" "$T/bin/issues"
printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$T/spool/dispatch/lease.conf"

iss() {  # KEY STATUS PRIORITY LABELS(json) [ASSIGNEE] [KIND] [DESC] [CREATED]
  jq -c -n --arg k "$1" --arg s "$2" --argjson p "$3" --argjson l "$4" --arg a "${5:-}" --arg kind "${6:-issue}" \
    --arg d "${7:-}" --arg c "${8:-2026-10-01T00:00:00Z}" \
    '{key: $k, status: $s, priority: $p, labels: $l, assignee: $a, kind: $kind, description: $d, created_at: $c, title: "title of \($k)",
      discussions: [{task_id: "fcf09921-0000-4000-8000-000000001922"}]}'
}
{
  iss SPL-1 todo 2 '["bug"]'
  iss SPL-2 eval 3 '["feature"]' "" issue "" 2026-09-01T00:00:00Z
  iss SPL-3 todo 4 '["feature"]'
  iss SPL-4 todo 1 '["feature","needs-owner"]'
  iss SPL-5 todo 1 '["feature"]' c-200
  iss SPL-6 todo 1 '["feature"]' HUM-10
  iss SPL-7 todo 1 '["feature"]' "" epic
  iss SPL-8 todo 1 '["task"]'
  iss SPL-9 todo 1 '["feature"]'
  iss SPL-10 todo 1 '["feature"]' "" issue "rotate the api key of the relay"
  iss SPL-11 todo 1 '["feature"]'
  iss SPL-12 todo 1 '["feature","blocker"]'
} | jq -s '{result: {issues: .}}' >"$T/issues.json"
# lanes: c-200 (assignee of SPL-5), c-201 (carries SPL-11), classes from briefs
lanebrief() { mkdir -p "$T/spool/$1/lifetime"; printf 'Class: %s\n' "$2" >"$T/spool/$1/lifetime/brief.md"; }
lanebrief c-200 bug; lanebrief c-201 bug; lanebrief c-202 bug; lanebrief c-203 refactor; lanebrief c-204 feature
echo SPL-11 >"$T/spool/c-201/lifetime/issue"
LANES_OVER='[{"agent_id":"c-200","agent_box":"box-desk","state":"live"},{"agent_id":"c-201","agent_box":"box-desk","state":"live"},{"agent_id":"c-202","agent_box":"box-desk","state":"live"},{"agent_id":"c-203","agent_box":"box-desk","state":"live"},{"agent_id":"c-204","agent_box":"box-desk","state":"live"}]'
LANES_BUG_OVER="$LANES_OVER"
put() { HUB_DIR="$T/hub" "$T/bin/hub" ask put --fleet main --id "$1" --kind task --role orch --from c-002@box-desk --topic x --summary "$2" >/dev/null; }
put 99999999-0000-4000-8000-000000000009 "SPAWN REQUEST fix SPL-9 by hand"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id 99999999-0000-4000-8000-000000000009 --by c-001@box-desk >/dev/null

fill() {  # [env...]
  # shellcheck disable=SC2016 # the action runs in the child shell
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=box-desk ASKS_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" SPOOL_ORCHESTRATOR_ID=c-001 \
    SPOOL_FLEET_RELAY=0 ASKS_HOLDER=c-001@box-desk SPAWN_QUEUE_SEND="$T/bin/send" SEND_LOG="$T/send.log" SPOOL_AGENT_ID= \
    SPAWN_SHARE_LANES_CMD="$T/bin/lanes" SPAWN_SHARE_DISPATCH=c-002@box-desk SPAWN_FILL_PICK_CMD="$T/bin/pick" \
    SPAWN_FILL_ISSUES_CMD="$T/bin/issues" SPAWN_FILL_MIX_CMD="$T/bin/mix" MIX_LOG="$T/mix.log" SPAWN_PLACE_BRIEF_DIR="$T/briefs" \
    SPAWN_FILL_CNF="$T/none.yaml" EPIC_STALL=off LANES="$LANES_OVER" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" \
    RHYTHM_NOW="$DAY" RHYTHM_CNF= ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 DESK_BOX=box-desk \
    SPAWN_FILL_HUB_CMD="$T/bin/spoolhub" SPOOL_HUB_LOG="$T/spoolhub.log" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-asks-tick spl-spawn-queue spl-spawn-share spl-spawn-enqueue spl-spawn-place spl-lane-issue spl-spawn-fill; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    spl_desk_action_hop_to() { return 1; }  # as under SPOOL_TEST=1: the desk is this one
    do_spl_spawn_fill' 2>&1
}
asks() { jq -c '[.[] | select(.state != "done")] | length' "$T/hub/main.json"; }
DAY=2026-01-15T12:00Z

# 1. the switch ------------------------------------------------------------------
out="$(fill DRY_RUN=0)"
grep -q 'the idle filler is off' <<<"$out" && [[ "$(asks)" == 0 ]] &&
  pass "switch: unset (no cnf key) + DRY_RUN=0 -> off, nothing queued" || fail "switch off: $out"
out="$(fill SPAWN_FILL_MAX=10)"
plans="$(grep -oE '^PLAN would queue SPL-[0-9]+' <<<"$out" | awk '{print $4}' | tr '\n' ' ')"
[[ "$plans" == "SPL-3 SPL-2 " ]] && [[ "$(asks)" == 0 ]] && grep -q 'switch off' <<<"$out" &&
  pass "dry run (the default) plans with the switch off and queues nothing: $plans" || fail "dry plan '$plans': $out"

# 3. the choice --------------------------------------------------------------------
grep -q 'classes in order: feature (' <<<"$out" && ! grep -q 'SPL-1 ' <<<"$(grep PLAN <<<"$out")" &&
  pass "bug OVER its band (3 of 5 live lanes) is never queued; feature (UNDER) is" || fail "bands: $out"
grep -q 'INFO skip SPL-10: no vendor (it names a secret' <<<"$out" && grep -q 'complex_coding 1' "$T/mix.log" &&
  pass "data rule: an issue naming an api key asks the mix sensitive; an agy pick is skipped" || fail "secret: $out | $(cat "$T/mix.log")"
for k in 4:needs-owner 5:live-assignee 6:human-assignee 7:epic 8:no-label 9:named-by-an-ask 11:a-live-lane-key 12:blocker; do
  grep -q "PLAN would queue SPL-${k%%:*} " <<<"$out" && fail "SPL-${k%%:*} (${k#*:}) was planned"
done
pass "skips: needs-owner, a live lane's assignee, HUM-*, epic, no bug/feature label, a key an ask names, a live lane's key, blocker"
out="$(fill SPAWN_FILL_MAX=10 MIX_SECRET=mistral)"
grep -q 'PLAN would queue SPL-10 (feature, todo, priority 1) as mistral:fill-spl-10' <<<"$out" &&
  pass "data rule: the same issue goes when the sensitive pick is mistral" || fail "secret mistral: $out"

# 4. how many ---------------------------------------------------------------------
n1="$(fill MIX_SECRET=claude | grep -c '^PLAN')"; n2="$(fill SPAWN_FILL_MAX=10 SPAWN_FILL_CORES_PER_LANE=4 MIX_SECRET=claude | grep -c '^PLAN')"
n3="$(fill SPAWN_FILL_MAX=10 LOAD5=7.5 MIX_SECRET=claude | grep -c '^PLAN')"
[[ "$n1" == 1 && "$n2" == 1 && "$n3" == 1 ]] && grep -q '4 lane(s) this tick' <<<"$(fill SPAWN_FILL_MAX=10)" &&
  pass "count: default max 1; 8 - 4.43 cores = 4 lanes at 1 core, 1 at 4 cores, 1 at load5 7.5" || fail "count: $n1 $n2 $n3"

# 2. the gate ---------------------------------------------------------------------
out="$(fill PICK='box-desk reason=box-desk is the first box in order below its high mark (55% < 85%), every box is at or above its low mark')"
grep -q 'no box is below its low mark' <<<"$out" && ! grep -q PLAN <<<"$out" &&
  pass "gate: a box in band (below high, not low) -> nothing" || fail "gate high: $out"
out="$(fill PICK='hold reason=no box with a sample is below its overflow mark')"
grep -q 'no box is below its low mark' <<<"$out" && pass "gate: pick=hold -> nothing" || fail "gate hold: $out"
out="$(fill SPAWN_FILL=on DRY_RUN=0 ASKS_HOLDER=c-001@sat)"
grep -q 'held on sat' <<<"$out" && [[ "$(asks)" == 0 ]] && pass "gate: a live run off the orch holder's machine queues nothing" || fail "holder: $out"

# 5. bug under its band ------------------------------------------------------------
LANES_OVER='[{"agent_id":"c-203","agent_box":"box-desk","state":"live"},{"agent_id":"c-204","agent_box":"box-desk","state":"live"}]'
out="$(fill)"
grep -q 'classes in order: bug feature' <<<"$out" && grep -q '^PLAN would queue SPL-1 (bug, todo, priority 2)' <<<"$out" &&
  pass "bug UNDER its band (0 of 2) comes first: SPL-1" || fail "bug under: $out"

# 6. a live run --------------------------------------------------------------------
out="$(fill SPAWN_FILL=on DRY_RUN=0)"
id="$(jq -r '.[] | select(.summary | startswith("SPAWN FILL SPL-1 ")) | .ask_id' "$T/hub/main.json")"
row="$(jq -c --arg i "$id" '.[] | select(.ask_id == $i)' "$T/hub/main.json")"
if [[ "$(jq -r .state <<<"$row")" == queued && "$(jq -r .class <<<"$row")" == bug && "$(jq -r .placement <<<"$row")" == claude:fill-spl-1 ]] &&
   [[ "$(jq -r .from <<<"$row")" == c-002@box-desk ]] && grep -q 'OK 1 row(s) queued' <<<"$out"; then
  pass "live: SPL-1 is one queued ask (class bug, placement claude:fill-spl-1, from the dispatch holder)"
else fail "live: $out | $row"; fi
. "$PROJ_ROOT/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
grep -qx 'Class: bug' "$T/briefs/fill-spl-1.md" && [[ "$(li_key_from_brief "$T/briefs/fill-spl-1.md")" == SPL-1 ]] &&
  pass "live: the brief carries Issue: SPL-1 (the spawn links it) and Class: bug (the share reads it)" || fail "brief: $(cat "$T/briefs/fill-spl-1.md")"
[[ "$(li_discussion_from_brief "$T/briefs/fill-spl-1.md")" == fcf09921-0000-4000-8000-000000001922 ]] &&
  pass "live: the brief names the issue's linked topic (SPL-5325: the enqueue refuses a brief with no discussion)" || fail "brief topic: $(cat "$T/briefs/fill-spl-1.md")"
[[ ! -s "$T/spoolhub.log" ]] && pass "live: an issue with a topic of its own opens no hub topic" || fail "hub calls: $(cat "$T/spoolhub.log")"
jq '.result.issues |= map(select(.key == "SPL-1"))' "$T/issues.json" >"$T/issues-1.json"
printf '#!/usr/bin/env bash\ncat "%s/issues-1.json"\n' "$T" >"$T/bin/issues-1"; chmod +x "$T/bin/issues-1"
id2="$(fill SPAWN_FILL=on DRY_RUN=0 SPAWN_FILL_ISSUES_CMD="$T/bin/issues-1" | grep -c 'not empty (1 queued')"
[[ "$id2" == 1 && "$(asks)" == 1 ]] && pass "live: the next tick sees 1 queued and fills nothing (SPL-1 is a bug at its default 2)" || fail "second tick: $id2 $(asks)"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$id" --by c-001@box-desk --reason "placed: c-300@box-desk" >/dev/null
out="$(fill)"
! grep -q 'PLAN would queue SPL-1 ' <<<"$out" && grep -q '^PLAN would queue SPL-5 ' <<<"$out" &&
  pass "live: the closed ask still holds SPL-1; the next is SPL-5 (its assignee c-200 is no longer live)" || fail "after done: $out"
want_id="$(printf 'spawn-fill:SPL-1' | sha1sum | cut -c1-8)"
[[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$ && "${id:0:8}" == "$want_id" ]] &&
  pass "live: the ask id is a UUID derived from the key (a replay is the same ask)" || fail "ask id: $id"

# bad knobs -----------------------------------------------------------------------
for kv in SPAWN_FILL=yes SPAWN_FILL_MAX=0 SPAWN_FILL_MAX=11 SPAWN_FILL_CORES_PER_LANE=x SPAWN_FILL_STATUS=wip DRY_RUN=2; do
  fill "$kv" >/dev/null && fail "$kv was taken"
done
pass "knobs: a bad switch, max, cores, status or DRY_RUN is refused"

# 8. fill by phase (spec 166 row B4) ------------------------------------------------
{ iss SPL-20 todo 2 '["feature"]'; iss SPL-21 todo 2 '["bug"]'; } | jq -s '{result: {issues: .}}' >"$T/issues-b4.json"
printf '#!/usr/bin/env bash\ncat "%s/issues-b4.json"\n' "$T" >"$T/bin/issues-b4"; chmod +x "$T/bin/issues-b4"
LANES_B4='[{"agent_id":"c-203","agent_box":"box-desk","state":"live"},{"agent_id":"c-204","agent_box":"box-desk","state":"live"}]'
b4() { fill SPAWN_FILL_MAX=10 SPAWN_FILL_ISSUES_CMD="$T/bin/issues-b4" LANES="$LANES_B4" "$@"; }
b4plans() { grep -oE '^PLAN would queue SPL-[0-9]+' <<<"$1" | awk '{print $4}' | tr '\n' ' '; }
for now in 2026-01-15T19:00Z 2026-01-16T02:00Z 2026-07-15T18:00Z; do
  out="$(b4 RHYTHM_NOW="$now")"
  [[ "$(b4plans "$out")" == "SPL-21 " ]] && grep -q 'night, classes in order: bug (' <<<"$out" &&
    pass "phase: night at $now -> only the bug (SPL-21) is planned, the feature waits" || fail "night $now: '$(b4plans "$out")' $out"
done
for now in 2026-01-15T18:59Z 2026-01-15T06:00Z 2026-07-15T05:00Z; do
  out="$(b4 RHYTHM_NOW="$now")"
  [[ "$(b4plans "$out")" == "SPL-21 SPL-20 " ]] && grep -q 'day, classes in order: bug feature (' <<<"$out" &&
    pass "phase: day at $now -> bug and feature, as before" || fail "day $now: '$(b4plans "$out")' $out"
done
out="$(b4 RHYTHM_NOW=2026-01-15T19:00Z SPAWN_FILL=on DRY_RUN=0 HUB_DIR="$T/hub-b4")"
q="$(jq -r '[.[] | select(.state == "queued") | .class + ":" + (.summary | split(" ")[2])] | join(" ")' "$T/hub-b4/main.json" 2>/dev/null)"
[[ "$q" == "bug:SPL-21" ]] && grep -q 'OK 1 row(s) queued' <<<"$out" &&
  pass "phase: a live night tick queues the bug ask only ($q)" || fail "night live: '$q' $out"
out="$(b4 RHYTHM_NOW=2026-01-15T19:00Z LANES="$LANES_BUG_OVER")"
grep -q 'every class the filler takes by night (bug) is over its band' <<<"$out" && ! grep -q '^PLAN' <<<"$out" &&
  pass "phase: at night with bug over its band nothing is filled (no feature fallback)" || fail "night over: $out"
out="$(b4 RHYTHM_NOW=not-a-date)"
grep -q 'WARN the rhythm phase could not be read' <<<"$out" && ! grep -q '^PLAN' <<<"$out" &&
  pass "phase: an unreadable phase fills nothing" || fail "bad phase: $out"
share='{"by":{"bug":{"verdict":"UNDER","pct":0,"lo":20,"hi":30},"feature":{"verdict":"ok","pct":50,"lo":40,"hi":100}}}'
got="$(PROJ_PATH="$PROJ_ROOT" bash -c 'source "$PROJ_PATH/src/bash/run/spl-spawn-fill.func.sh"
  for p in day night "" dusk; do printf "%s=[%s] " "${p:-none}" "$(spl_spawn_fill_classes "$1" "$p")"; done' _ "$share")"
[[ "$got" == "day=[bug feature] night=[bug] none=[] dusk=[] " ]] &&
  pass "phase: the class pick with no or an unknown phase takes no class ($got)" || fail "classes by phase: $got"

# 9. the lane's discussion (SPL-5860) ----------------------------------------------
# t1's default: its "Issue backlog" topic since rdb 0310 (SPL-6212)
BACKLOG=8af34b9c-d2e7-e4e9-65b1-9b765c75ca9d OWN=11111111-2222-4333-8444-555555555555
{ iss SPL-30 todo 1 '["bug"]' | jq -c --arg b "$BACKLOG" '.discussions = [{task_id: $b}]'
  iss SPL-31 todo 2 '["bug"]' | jq -c --arg b "$BACKLOG" --arg o "$OWN" '.discussions = [{task_id: $b}, {task_id: $o}]'
} | jq -s '{result: {issues: .}}' >"$T/issues-9.json"
printf '#!/usr/bin/env bash\ncat "%s/issues-9.json"\n' "$T" >"$T/bin/issues-9"; chmod +x "$T/bin/issues-9"
f9() { : >"$T/spoolhub.log"; rm -rf "$T/hub-9" "$T/briefs"; mkdir -p "$T/hub-9" "$T/briefs"
  fill SPAWN_FILL=on DRY_RUN=0 SPAWN_FILL_ISSUES_CMD="$T/bin/issues-9" HUB_DIR="$T/hub-9" "$@"; }
out="$(f9)"
topic="$(li_discussion_from_brief "$T/briefs/fill-spl-30.md" 2>/dev/null)"
send="$(grep '^send ' "$T/spoolhub.log")"; link="$(grep '^issue link ' "$T/spoolhub.log")"
if [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ && "$topic" != "$BACKLOG" ]] &&
   [[ "$send" == "send --from c-002 --to c-002 --to-box box-desk --task $topic --kind note --body SPAWN FILL SPL-30: "* ]] &&
   [[ "$link" == "issue link --as c-002 --ref SPL-30 --discussion $topic" ]] && grep -q 'OK 1 row(s) queued' <<<"$out"; then
  pass "topic: SPL-30 links only the backlog topic -> a new topic ${topic:0:8} (a v4 uuid) opened by one desk note, linked to SPL-30, named by the brief"
else fail "topic new: brief '$topic' | $(cat "$T/spoolhub.log") | $out"; fi
grep -q "Topic: $BACKLOG" "$T/briefs/fill-spl-30.md" && fail "the brief names the backlog topic"
out="$(f9 SPAWN_FILL_ISSUES_CMD="$T/bin/issues-9" HUB_FAIL=link)"
[[ ! -e "$T/hub-9/main.json" || "$(jq '[.[] | select(.state == "queued")] | length' "$T/hub-9/main.json")" == 0 ]] && [[ ! -e "$T/briefs/fill-spl-30.md" ]] &&
  grep -q 'WARN SPL-30: the hub did not link topic' <<<"$out" && grep -q 'WARN SPL-30: no discussion of its own for the lane: not queued' <<<"$out" &&
  pass "topic: a hub that refuses the link queues nothing and writes no brief" || fail "link refused: $out"
t1="$(grep -oE -- '--task [0-9a-f-]{36}' "$T/spoolhub.log")"
f9 HUB_FAIL=link >/dev/null; t2="$(grep -oE -- '--task [0-9a-f-]{36}' "$T/spoolhub.log")"
[[ -n "$t1" && "$t1" == "$t2" && "${t1#--task }" == "$topic" ]] &&
  pass "topic: a refused link twice -> one topic id (${topic:0:8}, from the key), the retry opens no second topic" || fail "retry topic: '$t1' vs '$t2' vs '$topic'"
out="$(f9 HUB_FAIL=open)"
! grep -q '^issue link' "$T/spoolhub.log" && [[ ! -e "$T/briefs/fill-spl-30.md" ]] && grep -q 'WARN SPL-30: the hub did not open topic' <<<"$out" &&
  grep -q 'OK 0 row(s) queued' <<<"$out" && pass "topic: a refused open links nothing, writes no brief, queues nothing" || fail "open refused: $(cat "$T/spoolhub.log") | $out"
jq '.result.issues |= map(select(.key == "SPL-31"))' "$T/issues-9.json" >"$T/issues-9b.json"
printf '#!/usr/bin/env bash\ncat "%s/issues-9b.json"\n' "$T" >"$T/bin/issues-9b"; chmod +x "$T/bin/issues-9b"
out="$(f9 SPAWN_FILL_ISSUES_CMD="$T/bin/issues-9b")"
[[ "$(li_discussion_from_brief "$T/briefs/fill-spl-31.md")" == "$OWN" && ! -s "$T/spoolhub.log" ]] && grep -q 'OK 1 row(s) queued' <<<"$out" &&
  pass "topic: SPL-31 links the backlog first and a topic of its own second -> the brief names its own, no hub call" || fail "topic own: $(cat "$T/briefs/fill-spl-31.md" 2>&1) | $(cat "$T/spoolhub.log") | $out"
out="$(f9 TENANT_ID=)"
grep -q 'WARN SPL-30: no ENV / TENANT_ID' <<<"$out" && [[ ! -s "$T/spoolhub.log" && ! -e "$T/briefs/fill-spl-30.md" ]] &&
  pass "topic: with no tenant the default topic is unknown: nothing is opened or queued" || fail "no tenant: $out"

# 10. the open reaches the hub (b16-01) ----------------------------------------
# Through the REAL spl_desk_spool with a fake spool (SPL_SPOOL) that keeps the
# client's same-box rule (hubclient/flush.go): a send to its own box stays
# local unless SPOOL_MIRROR_LOCAL=1; `issue link` is refused unknown_discussion
# unless a hub send carried the topic. The SPAWN_FILL_HUB_CMD stub of case 9
# bypasses spl_desk_spool and cannot see its env, which is why 9 stayed green.
cat >"$T/bin/fakespool" <<'STUB'
#!/usr/bin/env bash
op="$1"; shift; tobox="" task="" disc=""
while (($#)); do case "$1" in --to-box) tobox="$2"; shift ;; --task) task="$2"; shift ;; --discussion) disc="$2"; shift ;; esac; shift; done
echo "$op mirror=${SPOOL_MIRROR_LOCAL-unset}" >>"$HUB_LOG"
case "$op" in
  send) if [[ "$tobox" == "$SPOOL_BOX_ID" && "${SPOOL_MIRROR_LOCAL:-}" != 1 ]]; then echo '{"delivery":"local"}'
        else echo "$task" >>"$HUB_TOPICS"; echo '{"delivery":"sent"}'; fi ;;
  issue) grep -qx "$disc" "$HUB_TOPICS" && { echo '{"ok":true}'; exit 0; }
         echo "spool: hub refused: unknown_discussion (no such discussion: $disc)" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/fakespool"
hub10() {  # [env...]: open then link SPL-65 as the desk; prints "open=<rc> link=<rc>"
  : >"$T/hub10.log"; : >"$T/hub10.topics"
  # shellcheck disable=SC2016 # expanded in the child shell
  env "$@" SPL_SPOOL="$T/bin/fakespool" SPL_HUB_URL=https://hub.example.com HUB_LOG="$T/hub10.log" HUB_TOPICS="$T/hub10.topics" \
    TENANT_ID=t1 SPOOL_ROOT="$T/spool" DESK_BOX=box-desk DESK_AGENT=c-002 DESKDIR="$T/desk10" PROJ_PATH="$PROJ_ROOT" bash -c '
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/src/bash/run/spl-desk-up.func.sh" 2>/dev/null
    source "$PROJ_PATH/src/bash/run/spl-spawn-fill.func.sh"
    spl_lane_issue_desk() { return 0; }; spl_desk_issue_once() { return 0; }
    spl_desk_dir() { printf %s "$DESKDIR"; }
    t="$(spl_spawn_fill_topic_id SPL-65)"
    spl_spawn_fill_hub open "$t" "SPAWN FILL SPL-65: test" >/dev/null 2>&1; o=$?
    spl_spawn_fill_hub link "$t" SPL-65 >/dev/null 2>&1; l=$?
    echo "open=$o link=$l"'
}
out="$(hub10)"
[[ "$out" == "open=0 link=0" && "$(tr '\n' ' ' <"$T/hub10.log")" == "send mirror=1 issue mirror=unset " ]] &&
  pass "topic: the desk's open reaches the hub (mirrored), so the link of SPL-65 is taken; the link runs unmirrored" ||
  fail "open/link via spl_desk_spool: $out | $(cat "$T/hub10.log")"
out="$(hub10 SPOOL_MIRROR_LOCAL=1)"
[[ "$out" == "open=0 link=0" && "$(tr '\n' ' ' <"$T/hub10.log")" == "send mirror=1 issue mirror=unset " ]] &&
  pass "topic: a caller's SPOOL_MIRROR_LOCAL=1 does not reach the link" || fail "inherited mirror: $out | $(cat "$T/hub10.log")"

# 13. a set plan passes the queue gate (spec 153 Q8, owner H4 A) --------------------
# A queued row is in the hub. Only an issue a person set to priority 1 or 2
# passes; a bug at its class default 2 (issue_prio_default.go) does not.
q13() {  # ISSUE-LINES(json, one a line) [env...]: a live tick over a queue of one (its log: $T/out13.log); prints the queued keys
  local lines="$1"; shift
  rm -rf "$T/hub-13" "$T/briefs"; mkdir -p "$T/hub-13" "$T/briefs"
  HUB_DIR="$T/hub-13" "$T/bin/hub" ask put --fleet main --id 13131313-0000-4000-8000-000000000013 --kind task --role orch \
    --from c-002@box-desk --topic x --summary "SPAWN REQUEST other work" >/dev/null
  HUB_DIR="$T/hub-13" "$T/bin/hub" ask queue --fleet main --id 13131313-0000-4000-8000-000000000013 --class bug >/dev/null
  jq -s '{result: {issues: .}}' <<<"$lines" >"$T/issues-13.json"
  printf '#!/usr/bin/env bash\ncat "%s/issues-13.json"\n' "$T" >"$T/bin/issues-13"; chmod +x "$T/bin/issues-13"
  fill SPAWN_FILL=on DRY_RUN=0 SPAWN_FILL_ISSUES_CMD="$T/bin/issues-13" HUB_DIR="$T/hub-13" LANES="$LANES_B4" "$@" >"$T/out13.log"
  jq -r '[.[] | select(.state == "queued") | .summary | split(" ")[2] | select(startswith("SPL-"))] | join(" ")' "$T/hub-13/main.json"
}
got="$(q13 "$(iss SPL-50 todo 2 '["feature"]')")"
[[ "$got" == SPL-50 ]] && grep -q 'not empty (1 queued, 0 placing): only an issue a person set to priority 1 or 2 passes' "$T/out13.log" &&
  grep -q 'OK 1 row(s) queued' "$T/out13.log" &&
  pass "13. set plan: a priority 2 feature with a non-empty queue queues one ($got)" || fail "13. prio 2: '$got' $(cat "$T/out13.log")"
got="$(q13 "$(iss SPL-51 todo 3 '["feature"]')")"
[[ -z "$got" ]] && grep -q 'with a queue: priority 1 or 2 set by a person): nothing to fill' "$T/out13.log" &&
  pass "13. set plan: a priority 3 issue with a non-empty queue queues none" || fail "13. prio 3: '$got' $(cat "$T/out13.log")"
got="$(q13 "$(iss SPL-52 todo 2 '["bug"]')")"
[[ -z "$got" ]] && grep -q 'nothing to fill' "$T/out13.log" &&
  pass "13. set plan (H4 A): a bug at its class default 2 with a non-empty queue queues none" || fail "13. bug default: '$got' $(cat "$T/out13.log")"
got="$(q13 "$(iss SPL-54 todo 1 '["bug","alert"]')")"
[[ -z "$got" ]] && pass "13. set plan (H4 A): an alert at its class default 1 queues none" || fail "13. alert default: '$got' $(cat "$T/out13.log")"
got="$(q13 "$(iss SPL-53 todo 1 '["bug"]')")"
[[ "$got" == SPL-53 ]] && pass "13. set plan: a bug a person raised to 1 queues one ($got)" || fail "13. bug 1: '$got' $(cat "$T/out13.log")"
got="$(q13 "$(iss SPL-50 todo 2 '["feature"]'; iss SPL-55 todo 1 '["feature"]')")"
[[ "$got" == SPL-55 ]] && pass "13. set plan: still SPAWN_FILL_MAX (1) a tick, priority 1 first ($got)" || fail "13. max: '$got' $(cat "$T/out13.log")"
got="$(q13 "$(iss SPL-50 todo 2 '["feature"]')" PICK='hold reason=no box with a sample is below its overflow mark')"
[[ -z "$got" ]] && grep -q 'no box is below its low mark' "$T/out13.log" &&
  pass "13. set plan: the box pick still gates it" || fail "13. pick: '$got' $(cat "$T/out13.log")"
mkdir -p "$T/hub-13-empty"
iss SPL-51 todo 3 '["feature"]' | jq -s '{result: {issues: .}}' >"$T/issues-13.json"
out="$(fill SPAWN_FILL_ISSUES_CMD="$T/bin/issues-13" HUB_DIR="$T/hub-13-empty" LANES="$LANES_B4")"
grep -q '^PLAN would queue SPL-51 (feature, todo, priority 3)' <<<"$out" &&
  pass "13. set plan: with an empty queue a priority 3 issue still fills, as before" || fail "13. empty queue: $out"

# 7. the cron installer ------------------------------------------------------------
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc"; printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
cat >"$T/bin/crontab" <<'EOF2'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF2
chmod +x "$T/bin/crontab"
printf '* * * * * x # csi-spl:spawn-place\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the action runs in the child shell
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" SPAWN_FILL_CRON_LOG_DIR="$T/cronlog" \
    PROJ_PATH="$PROJ_ROOT" SPL_ORG_APP=csi-spl "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-spawn-fill-install-cron.func.sh"
    do_spl_spawn_fill_install_cron'
}
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
line="$(grep '# csi-spl:spawn-fill$' "$T/crontab")"
# shellcheck disable=SC2016 # $HOME stays literal in the cron line
want='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin'
[[ $rc -eq 0 && "$line" == "*/10 * * * * cd $SRC/csi-spl-orc && $want DRY_RUN=0 flock -n $T/cronlog/spawn-fill.lock ./run -a do_spl_spawn_fill >> $T/cronlog/cron.out 2>&1 # csi-spl:spawn-fill" ]] &&
  grep -q 'spawn-place' "$T/crontab" &&
  pass "cron: one line every 10 min, DRY_RUN=0, PATH has /usr/local/bin, flock -n, other lines kept" || fail "cron install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:spawn-fill$' "$T/crontab")" == 1 ]] && pass "cron: a second install is a no-op" || fail "cron lines: $(cat "$T/crontab")"
cron SPAWN_FILL_CRON_ACTION=check >"$T/o" 2>&1 && grep -q 'OK the idle filler is installed' "$T/o" &&
  pass "cron: check says installed" || fail "cron check: $(cat "$T/o")"
cron DRY_RUN=0 SPAWN_FILL_CRON_ACTION=remove >/dev/null 2>&1
! grep -q 'spawn-fill' "$T/crontab" && grep -q 'spawn-place' "$T/crontab" && pass "cron: remove takes only its line" || fail "cron remove: $(cat "$T/crontab")"
cron SPAWN_FILL_CRON_MIN=60 >/dev/null 2>&1 && fail "cron: a 60 min gap was taken" || pass "cron: SPAWN_FILL_CRON_MIN past 59 is refused"
# --- 7b. no override: the log dir derives from SPL_VAR_APP_DIR (r74-01) ----------
cron SPAWN_FILL_CRON_LOG_DIR= SPL_VAR_APP_DIR="$T/var" DRY_RUN=1 >"$T/o" 2>&1; rc=$?
(( rc == 0 )) && grep -qF "flock -n $T/var/spawn-fill/spawn-fill.lock " "$T/o" && grep -qF ">> $T/var/spawn-fill/cron.out 2>&1" "$T/o" && [[ ! -e "$T/var" ]] &&
  pass "7b. no override: the lock and cron.out sit under \$SPL_VAR_APP_DIR/spawn-fill, a dry run creates nothing" || fail "7b. derived log dir rc=$rc $(cat "$T/o")"

# --- 11. _spl_run_cron_apply and wave-1 delegation (r05-02 one copy) --------------
printf '%s\n' '# keep me' >"$T/crontab.s11"
cp "$T/crontab.s11" "$T/crontab.s11.orig"
out="$(env PROJ_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SRC="$SRC" T="$T" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply check "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc1=$?"
  DRY_RUN=1 _spl_run_cron_apply install "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc2=$?"
  _spl_run_cron_apply install "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc3=$?"
  _spl_run_cron_apply check "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc4=$?"
  _spl_run_cron_apply check "csi-spl:widget" "$SRC" master "$T/no-such-run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc5=$?"
  _spl_run_cron_apply remove "csi-spl:widget" "$SRC" master "$SRC/csi-spl-orc/run" "$T/wlog" "* * * * * true # csi-spl:widget" "widget" "runs every 1m" ": no widget"
  echo "rc6=$?"' 2>&1)"
[[ "$out" == *"FAIL the widget is NOT installed (no line tagged csi-spl:widget): no widget"* && "$out" == *"rc1=1"* \
  && "$out" == *"OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the widget runs every 1m:"* && "$out" == *"rc3=0"* \
  && "$out" == *"OK the widget is installed"* && "$out" == *"rc4=0"* \
  && "$out" == *"FAIL $T/no-such-run is gone or not executable"* && "$out" == *"rc5=1"* \
  && "$out" == *"OK the widget is out of the crontab"* && "$out" == *"rc6=0"* ]] &&
  cmp -s "$T/crontab.s11" "$T/crontab.s11.orig" &&
  pass "11. _spl_run_cron_apply covers check-missing, dry-run, install, check-ok, check-bad-run and remove" || fail "11. helper lifecycle: $out"

sf_f="$PROJ_ROOT/src/bash/run/spl-spawn-fill-install-cron.func.sh"
sr_f="$PROJ_ROOT/src/bash/run/spl-security-round-install-cron.func.sh"
pa_f="$PROJ_ROOT/src/bash/run/spl-desk-poll-ack-install-cron.func.sh"
ac_f="$PROJ_ROOT/src/bash/run/spl-accepted-close-install-cron.func.sh"
sf_old="$(grep -n 'spl_spawn_fill_cron_check' "$sf_f" || true)"
[[ -z "$sf_old" && "$(grep -c 'the crontab does not read back what was written' "$sf_f")" -eq 1 && "$(grep -c '_spl_run_cron_apply ' "$sf_f")" -ge 1 ]] &&
  pass "11. one copy: spl-spawn-fill-install-cron.func.sh hosts the single _spl_run_cron_apply helper" || fail "11. host one copy: old=[$sf_old]"
for sib in "$sr_f" "$pa_f" "$ac_f"; do
  own="$(grep -nE "spl_(security_round|poll_ack|accepted_close)_cron_check|the crontab does not read back what was written|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_run_cron_apply " "$sib" &&
    pass "11. one copy: $(basename "$sib") delegates apply to _spl_run_cron_apply" || fail "11. one copy $(basename "$sib"): own=[$own]"
done

out="$(env -u SECURITY_ROUND_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SECURITY_ROUND_CRON_LOG_DIR="$T/log-sr" SECURITY_ROUND_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-security-round-install-cron.func.sh"
  do_spl_security_round_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the weekly security round is NOT installed (no line tagged csi-spl:security-round): Friday's round is not queued"* && "$out" != *"command not found"* ]] &&
  pass "11. lazy load: spl-security-round-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "11. lazy sr (rc=$rc): $out"

out="$(env -u SECURITY_ROUND_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SECURITY_ROUND_CRON_LOG_DIR="$T/log-sr" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-security-round-install-cron.func.sh"
  do_spl_security_round_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the weekly security round runs Friday at :30 in the night phase (UTC Friday, do_spl_rhythm_phase night) as the box user (it queues only on the orch holder's machine, while its switch is on):"* ]] &&
  pass "11. security-round install keeps exact ok_msg" || fail "11. sr ok (rc=$rc): $out"

out="$(env -u POLL_ACK_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" POLL_ACK_CRON_LOG_DIR="$T/log-pa" POLL_ACK_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-desk-poll-ack-install-cron.func.sh"
  do_spl_desk_poll_ack_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the poll acknowledgement is NOT installed (no line tagged csi-spl:poll-ack): an owner poll answer waits for a model to notice it"* && "$out" != *"command not found"* ]] &&
  pass "11. lazy load: spl-desk-poll-ack-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "11. lazy pa (rc=$rc): $out"

out="$(env -u POLL_ACK_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" POLL_ACK_CRON_LOG_DIR="$T/log-pa" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-desk-poll-ack-install-cron.func.sh"
  do_spl_desk_poll_ack_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the poll acknowledgement runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"* ]] &&
  pass "11. poll-ack install keeps exact ok_msg" || fail "11. pa ok (rc=$rc): $out"

out="$(env -u ACCEPT_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ACCEPT_CRON_LOG_DIR="$T/log-ac" ACCEPT_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-accepted-close-install-cron.func.sh"
  do_spl_accepted_close_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the accepted close is NOT installed (no line tagged csi-spl:accepted-close): a landed, reviewed lane waits for a model to send its ACCEPTED"* && "$out" != *"command not found"* ]] &&
  pass "11. lazy load: spl-accepted-close-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "11. lazy ac (rc=$rc): $out"

out="$(env -u ACCEPT_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s11" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ACCEPT_CRON_LOG_DIR="$T/log-ac" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-accepted-close-install-cron.func.sh"
  do_spl_accepted_close_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the accepted close runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"* ]] &&
  pass "11. accepted-close install keeps exact ok_msg" || fail "11. ac ok (rc=$rc): $out"

# --- 12. _spl_run_cron_apply mode=r and wave-2 delegation (r06-01 one copy) -------
printf '%s\n' '# keep me' >"$T/crontab.s12"
cp "$T/crontab.s12" "$T/crontab.s12.orig"
mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
: >"$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
chmod 644 "$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
out="$(env PROJ_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SRC="$SRC" T="$T" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-fill-install-cron.func.sh"
  scr="$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
  _spl_run_cron_apply install "csi-spl:rjob" "$SRC" master "$T/no-such-script" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc1=$?"
  _spl_run_cron_apply install "csi-spl:rjob" "$SRC" master "$scr" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc2=$?"
  _spl_run_cron_apply check "csi-spl:rjob" "$SRC" master "$scr" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc3=$?"
  _spl_run_cron_apply check "csi-spl:rjob" "$SRC" master "$T/no-such-script" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc4=$?"
  _spl_run_cron_apply remove "csi-spl:rjob" "$SRC" master "$scr" "$T/rlog" "* * * * * true # csi-spl:rjob" "rjob" "runs hourly" "" r
  echo "rc5=$?"' 2>&1)"
[[ "$out" == *"FATAL $T/no-such-script is missing in $SRC"* && "$out" != *"not executable"* && "$out" == *"rc1=1"* \
  && "$out" == *"OK the rjob runs hourly:"* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the rjob is installed"* && "$out" == *"rc3=0"* \
  && "$out" == *"FAIL $T/no-such-script is gone"* && "$out" == *"rc4=1"* \
  && "$out" == *"OK the rjob is out of the crontab"* && "$out" == *"rc5=0"* ]] &&
  cmp -s "$T/crontab.s12" "$T/crontab.s12.orig" &&
  pass "12. _spl_run_cron_apply mode=r accepts a readable non-exec script and emits exact missing/gone wording" || fail "12. mode=r lifecycle: $out"

sp_f="$PROJ_ROOT/src/bash/run/spl-spawn-place-install-cron.func.sh"
rg_f="$PROJ_ROOT/src/bash/run/spl-review-go-install-cron.func.sh"
as_f="$PROJ_ROOT/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh"
for sib in "$sp_f" "$rg_f" "$as_f"; do
  own="$(grep -nE "spl_(spawn_place|review_go|archive_suggest)_cron_check|the crontab does not read back what was written|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_run_cron_apply " "$sib" &&
    pass "12. one copy: $(basename "$sib") delegates apply to _spl_run_cron_apply" || fail "12. one copy $(basename "$sib"): own=[$own]"
done

out="$(env -u SPAWN_PLACE_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SPAWN_PLACE_CRON_LOG_DIR="$T/log-sp" SPAWN_PLACE_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-place-install-cron.func.sh"
  do_spl_spawn_place_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the spawn placer is NOT installed (no line tagged csi-spl:spawn-place): queued spawn requests wait for a hand placement"* && "$out" != *"command not found"* ]] &&
  pass "12. lazy load: spl-spawn-place-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "12. lazy sp (rc=$rc): $out"

out="$(env -u SPAWN_PLACE_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" SPAWN_PLACE_CRON_LOG_DIR="$T/log-sp" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-place-install-cron.func.sh"
  do_spl_spawn_place_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the spawn placer runs every minute as the box user (it acts only while this machine holds the orch role):"* ]] &&
  pass "12. spawn-place install keeps exact ok_msg" || fail "12. sp ok (rc=$rc): $out"

out="$(env -u REVIEW_GO_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" REVIEW_GO_CRON_LOG_DIR="$T/log-rg" REVIEW_GO_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-review-go-install-cron.func.sh"
  do_spl_review_go_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the review GO is NOT installed (no line tagged csi-spl:review-go): a review PASS waits for a model to send the GO"* && "$out" != *"command not found"* ]] &&
  pass "12. lazy load: spl-review-go-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "12. lazy rg (rc=$rc): $out"

out="$(env -u REVIEW_GO_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" REVIEW_GO_CRON_LOG_DIR="$T/log-rg" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-review-go-install-cron.func.sh"
  do_spl_review_go_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the review GO runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"* ]] &&
  pass "12. review-go install keeps exact ok_msg" || fail "12. rg ok (rc=$rc): $out"

out="$(env -u ARCHIVE_SUGGEST_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ARCHIVE_SUGGEST_CRON_LOG_DIR="$T/log-as" ARCHIVE_SUGGEST_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh"
  do_spl_topic_archive_suggest_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the archive suggestion is NOT installed (no line tagged csi-spl:topic-archive-suggest)" && "$out" != *"command not found"* ]] &&
  pass "12. lazy load: spl-topic-archive-suggest-install-cron.func.sh loads _spl_run_cron_apply standalone" || fail "12. lazy as (rc=$rc): $out"

out="$(env -u ARCHIVE_SUGGEST_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s12" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SRC" ARCHIVE_SUGGEST_CRON_LOG_DIR="$T/log-as" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh"
  do_spl_topic_archive_suggest_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the archive suggestion runs hourly as $(id -un) (dry until lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0):"* ]] &&
  pass "12. topic-archive-suggest install keeps exact ok_msg on readable non-exec script" || fail "12. as ok (rc=$rc): $out"

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
