#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the stalled-epic check (do_spl_epic_stall_check, SPL-2358; owner
#          HUM-10, t1 d4c0c0a8 msg 7432ecd3: "Why did they stop?"). The hub
#          (`spool ask list`), the epic and issue lists, the lane map and
#          spool-send are stubs. Fixture epics, all "two lanes at a time"
#          unless named otherwise:
#            SPL-100 stalled: 1 done 2 h ago, 1 todo, 1 wip held only by the
#                    dispatcher's role pane (not a lane)
#            SPL-200 a queue row's placement brief names its todo issue
#            SPL-300 a live lane's brief names its todo issue
#            SPL-400 a live lane is the assignee of its wip issue
#            SPL-500 every issue closed
#            SPL-600 its last issue landed 10 min ago
#            SPL-700 no pairs in the title (not checked) - unless EPIC_STALL_KEYS
#            SPL-800 nothing landed yet
#   1. a dry run plans ONE blocker, for SPL-100 only, and sends nothing
#   2. a live run sends ONE blocker to the dispatch holder on
#      dispatch-<topic8>, naming the epic, the topic and the next rows
#   3. the next tick (6 h dedup) sends nothing; 7 h later it sends again
#   4. a live run on a machine that does not hold the orch role sends nothing
#   5. EPIC_STALL_KEYS adds an epic the title rule leaves out
#   6. the filler's live tick runs the check (switch off); EPIC_STALL=off skips
#   7. control: the filler without the check (today's code before SPL-2358)
#      reports nothing for the same fixture
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
mkdir -p "$T/bin" "$T/briefs" "$T/spool/dispatch"
export SPOOL_TEST=1
NOW="$(date -u -d 2026-10-17T12:00:00Z +%s)"
at() { date -u -d "@$((NOW - $1 * 60))" +%Y-%m-%dT%H:%M:%S.000000Z; }  # MINUTES_AGO

# The hub stub: `spool ask list` answers the queue rows of rows.json.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "ask list" ] || { echo "hub refused: bad_frame (400)" >&2; exit 1; }
printf '{"fleet": "main", "asks": %s}\n' "$(cat "$HUB_DIR/rows.json")"
STUB
# shellcheck disable=SC2016 # expanded by the stubs, not here
{
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$SEND_LOG"\n' >"$T/bin/send"
printf '#!/usr/bin/env bash\ncat "%s/epics.json"\n' "$T" >"$T/bin/epics"
printf '#!/usr/bin/env bash\njq -c --arg k "$EPIC_KEY" '"'"'{result: {issues: [.[] | select(.epic == $k)]}}'"'"' "%s/kids.json"\n' "$T" >"$T/bin/issues"
printf '#!/usr/bin/env bash\ncat "%s/lanes.json"\n' "$T" >"$T/bin/lanes"
}
chmod +x "$T/bin/"*
printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$T/spool/dispatch/lease.conf"

epic() {  # KEY TITLE TOPIC
  jq -c -n --arg k "$1" --arg t "$2" --arg d "$3" \
    '{key: $k, kind: "epic", status: "wip", title: $t, discussions: [{task_id: $d}]}'
}
{
  epic SPL-100 "Repo review (8), two lanes at a time" 11111111-1111-4111-8111-111111111111
  epic SPL-200 "Queued epic, two lanes at a time" 22222222-2222-4222-8222-222222222222
  epic SPL-300 "Laned epic, two lanes at a time" 33333333-3333-4333-8333-333333333333
  epic SPL-400 "Assigned epic, two lanes at a time" 44444444-4444-4444-8444-444444444444
  epic SPL-500 "Done epic, two lanes at a time" 55555555-5555-4555-8555-555555555555
  epic SPL-600 "Fresh epic, two lanes at a time" 66666666-6666-4666-8666-666666666666
  epic SPL-700 "Spec 999 - a long-lived spec epic" 77777777-7777-4777-8777-777777777777
  epic SPL-800 "Unstarted epic, two lanes at a time" 88888888-8888-4888-8888-888888888888
} | jq -s '{result: {issues: .}}' >"$T/epics.json"
kid() {  # KEY EPIC STATUS [DONE_MIN_AGO] [ASSIGNEE]
  jq -c -n --arg k "$1" --arg e "$2" --arg s "$3" --arg c "${4:+$(at "${4:-0}")}" --arg a "${5:-}" \
    '{key: $k, number: ($k | sub("SPL-"; "") | tonumber), kind: "issue", epic: $e, parent: $e, status: $s,
      completed_at: $c, assignee: $a, title: "title of \($k)"}'
}
{
  kid SPL-101 SPL-100 "done" 120 c-002@box-desk; kid SPL-102 SPL-100 todo; kid SPL-103 SPL-100 wip "" c-002@box-desk
  kid SPL-104 SPL-100 diss
  kid SPL-201 SPL-200 "done" 120; kid SPL-202 SPL-200 todo
  kid SPL-301 SPL-300 "done" 120; kid SPL-302 SPL-300 todo
  kid SPL-401 SPL-400 "done" 120; kid SPL-402 SPL-400 wip "" c-410@box-b
  kid SPL-501 SPL-500 "done" 120; kid SPL-502 SPL-500 diss
  kid SPL-601 SPL-600 "done" 10; kid SPL-602 SPL-600 todo
  kid SPL-701 SPL-700 "done" 900; kid SPL-702 SPL-700 todo
  kid SPL-801 SPL-800 todo; kid SPL-802 SPL-800 todo
} | jq -s . >"$T/kids.json"
# a queue row whose placement brief names SPL-202; a live lane (other box)
# whose brief names SPL-302; the assignee of SPL-402; the dispatcher's role
# pane (its scope starts "role", so it is no lane); a lane whose brief has
# only an Epic: line for SPL-100
printf 'Issue: SPL-202\n' >"$T/briefs/r2-next.md"
printf 'Issue: SPL-302\nEpic: SPL-300\n' >"$T/briefs/r3-row2.md"
printf 'Epic: SPL-100 (the epic that showed it)\n' >"$T/briefs/bugfix.md"
printf '[{"ask_id": "aaaaaaaa-0000-4000-8000-000000000002", "state": "queued", "enqueued_at": "2026-10-17T11:00:00Z", "placement": "claude:r2-next", "summary": "QUEUE please, next pair"}]\n' >"$T/rows.json"
jq -n -c '{lanes: [
  {agent_id: "c-310", agent_box: "box-b", branch: "c-310-r3-row2", scope: "Lane brief: row 2", state: "live"},
  {agent_id: "c-410", agent_box: "box-b", branch: "c-410-x", scope: "Lane brief: x", state: "live"},
  {agent_id: "c-002", agent_box: "box-desk", branch: "c-002-rotate", scope: "role c-002 (rotation)", state: "live"},
  {agent_id: "c-373", agent_box: "box-desk", branch: "c-373-bugfix", scope: "Lane brief: bug", state: "live"},
  {agent_id: "c-999", agent_box: "box-b", branch: "c-999-r3-row2", scope: "SPL-302", state: "gone"}]}' >"$T/lanes.json"

run() {  # ACTION [env...]
  local action="$1"; shift
  # shellcheck disable=SC2016 # the action runs in the child shell
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=box-desk ASKS_HUB_CMD="$T/bin/hub" HUB_DIR="$T" SPOOL_ORCHESTRATOR_ID=c-001 \
    SPOOL_FLEET_RELAY=0 ASKS_HOLDER=c-001@box-desk SPAWN_QUEUE_SEND="$T/bin/send" SEND_LOG="$T/send.log" SPOOL_AGENT_ID= \
    SPAWN_SHARE_DISPATCH=c-002@box-desk SPAWN_PLACE_BRIEF_DIR="$T/briefs" EPIC_STALL_EPICS_CMD="$T/bin/epics" \
    EPIC_STALL_ISSUES_CMD="$T/bin/issues" EPIC_STALL_LANES_CMD="$T/bin/lanes" EPIC_STALL_NOW="$NOW" \
    SPAWN_FILL_CNF="$T/none.yaml" SPAWN_SHARE_LANES_CMD="$T/bin/lanes" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" \
    STALL_SRC="${STALL_SRC:-1}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-asks-tick spl-spawn-queue spl-spawn-share spl-spawn-enqueue spl-spawn-place spl-spawn-fill; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    [ "$STALL_SRC" = 1 ] && source "'"$PROJ_ROOT"'/src/bash/run/spl-epic-stall-check.func.sh"
    '"$action" 2>&1
}
sends() {  # [TASK]: the blockers sent (on TASK)
  local n; n="$(grep -cE -- "^--from .* --task ${1:-[a-z0-9-]+} " "$T/send.log" 2>/dev/null)"; printf '%s' "${n:-0}"
}

# 1. dry run -----------------------------------------------------------------------
out="$(run do_spl_epic_stall_check)"
plans="$(grep -oE '^PLAN would send a blocker to c-002@box-desk on dispatch-[0-9a-f]{8}: epic SPL-[0-9]+' <<<"$out" | awk '{print $NF}' | tr '\n' ' ')"
[[ "$plans" == "SPL-100 " && "$(sends)" == 0 ]] &&
  pass "dry run: one blocker planned, for the stalled SPL-100 only, nothing sent" || fail "dry run plans '$plans': $out"
before=$fails
for k in "200:a queue row holds it: aaaaaaaa" "300:a live lane holds it: c-310@box-b" "400:a live lane holds it: c-410@box-b" \
         "500:all 2 issue(s) closed" "600:SPL-601 landed 10 min ago" "800:no issue landed yet (2 open)"; do
  grep -qF "INFO epic SPL-${k%%:*}: ${k#*:}" <<<"$out" || fail "SPL-${k%%:*} not skipped with '${k#*:}': $out"
done
grep -q 'SPL-700' <<<"$out" && fail "SPL-700 (no pairs in the title) was checked: $out"
[[ $fails == "$before" ]] && pass "not stalled: a queue row, a live lane's brief, a live lane as assignee, all closed, landed 10 min ago, never started; a spec epic is not checked"

# 2. a live run --------------------------------------------------------------------
out="$(run do_spl_epic_stall_check DRY_RUN=0)"
line="$(cat "$T/send.log" 2>/dev/null)"
[[ "$(sends)" == 1 ]] && grep -q -- '--from c-001 --to c-002 --kind blocker --task dispatch-11111111 ' <<<"$line" &&
  grep -q 'OK epic SPL-100 stalled: blocker sent' <<<"$out" &&
  pass "live: one blocker, from the orch holder to the dispatch holder, on the epic's topic task" || fail "live send: $line | $out"
grep -q 'epic SPL-100 has stalled' <<<"$line" && grep -q '/t/11111111-1111-4111-8111-111111111111' <<<"$line" &&
  grep -q -- '- SPL-102 (todo): title of SPL-102' <<<"$line" && grep -q -- '- SPL-103 (wip)' <<<"$line" &&
  grep -q '2 of 4 issues open' <<<"$line" && grep -q 'last one landed was SPL-101' <<<"$line" &&
  pass "the body names the epic, the topic, the next rows (todo first) and the last landed issue" || fail "body: $line"

# 3. dedup -------------------------------------------------------------------------
out="$(run do_spl_epic_stall_check DRY_RUN=0 EPIC_STALL_NOW=$((NOW + 3600)))"
[[ "$(sends dispatch-11111111)" == 1 ]] && grep -q 'INFO epic SPL-100 is stalled; its blocker went out 60 min ago' <<<"$out" &&
  pass "dedup: the next tick, 1 h later, sends nothing" || fail "dedup: $(sends) sends: $out"
out="$(run do_spl_epic_stall_check DRY_RUN=0 EPIC_STALL_NOW=$((NOW + 7 * 3600)))"
[[ "$(sends dispatch-11111111)" == 2 ]] && [[ "$(grep -c '^SPL-100' "$T/spool/dispatch/epic-stall.state")" == 1 ]] &&
  pass "dedup: 7 h later (> 6 h) it sends again, one state line per epic" || fail "repeat: $(sends) sends: $out"

# 4. another machine holds the orch role -------------------------------------------
: >"$T/send.log"; rm -f "$T/spool/dispatch/epic-stall.state"
out="$(run do_spl_epic_stall_check DRY_RUN=0 ASKS_HOLDER=c-001@box-b)"
[[ "$(sends)" == 0 ]] && grep -q 'its machine checks the epics' <<<"$out" &&
  pass "a live run on a machine without the orch role sends nothing" || fail "holder: $out"

# 5. EPIC_STALL_KEYS ---------------------------------------------------------------
out="$(run do_spl_epic_stall_check EPIC_STALL_KEYS=SPL-700)"
grep -q 'PLAN would send a blocker .*epic SPL-700 stalled' <<<"$out" &&
  pass "EPIC_STALL_KEYS adds SPL-700, which the title rule leaves out" || fail "keys: $out"

# 6. the filler's tick --------------------------------------------------------------
: >"$T/send.log"; rm -f "$T/spool/dispatch/epic-stall.state"
out="$(run do_spl_spawn_fill DRY_RUN=0)"
[[ "$(sends)" == 1 ]] && grep -q 'the idle filler is off' <<<"$out" &&
  pass "the filler's live tick runs the check with its own switch off: one blocker" || fail "fill tick: $(sends) sends: $out"
: >"$T/send.log"; rm -f "$T/spool/dispatch/epic-stall.state"
out="$(run do_spl_spawn_fill DRY_RUN=0 EPIC_STALL=off)"
[[ "$(sends)" == 0 ]] && pass "EPIC_STALL=off: the filler's tick sends nothing" || fail "off: $out"

# 7. control: today's code (no check) -----------------------------------------------
out="$(STALL_SRC=0 run do_spl_spawn_fill DRY_RUN=0 PROJ_PATH="$T")"
[[ "$(sends)" == 0 ]] && ! grep -q 'epic SPL-100' <<<"$out" &&
  pass "control: the filler without the check reports nothing for the stalled SPL-100" || fail "control: $out"

if [[ $fails -gt 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
