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
id2="$(fill SPAWN_FILL=on DRY_RUN=0 | grep -c 'not empty (1 queued')"
[[ "$id2" == 1 && "$(asks)" == 1 ]] && pass "live: the next tick sees 1 queued and fills nothing" || fail "second tick: $id2 $(asks)"
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
BACKLOG=fcf09921-8f21-4518-a117-f8ddb41bfff5 OWN=11111111-2222-4333-8444-555555555555
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

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
