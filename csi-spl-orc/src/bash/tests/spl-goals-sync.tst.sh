#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_goals_sync (spec 112 4.2 / 12.2 / 12.4, ORC-2), against a
#          stub route that answers like HUB-2's PUT /v1/calendar/sync: an
#          upsert by (workspace, source_key), 400 on an unknown wire field,
#          on an event without a workspace, on a goal: key whose goal is not
#          in goals[] of that workspace, and on a goal: key with an audience.
#   1. no goal.yaml: a no-op, rc 0, no call (the wf 20 step before any goal)
#   2. ENV other than dev / prd: refused before any call
#   3. two goals in two workspaces: ONE PUT; every goal and event names its
#      own workspace; roadmap_url = /roadmap?ws=<ws>&goal=G01#spec-089; the
#      deadline event carries the goal's specs and done_lines; no audience;
#      only HUB-2 wire fields (+ specs, done_lines)
#   4. a second run of the same tree adds 0 events (the same body)
#   5. CONTROL: a goal without `workspace` fails the run before any call
#   6. CONTROL: a batch carrying an `audience` on a goal: key turns the
#      no-audience check red, and the stub route answers it 400
#   7. DRY_RUN (the default) prints the batch and calls nothing
#   8. the func file sets no shell option at top level: ./run sources every
#      *.func.sh, so a top-level `set -e` would turn errexit on for every
#      action (c-001, msg 8af4b94b)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-goals-sync.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
U1=aaaaaaaa-0000-4000-8000-000000000001 U2=aaaaaaaa-0000-4000-8000-000000000002

# The HUB-2 wire fields of an event (calendarSyncEventIn) plus the two the
# deadline event adds for WUI-3.
wire_fields() { echo '["all_day","audience","description","done_lines","ends_at","kind","release_version","roadmap_url","source_key","specs","starts_at","time_zone","title","topic_id","workspace"]'; }

# hub_stub <body.json> <state.json>: HUB-2's checks and upsert; prints
# {status, created, updated, unchanged} and rewrites the state.
hub_stub() {
  jq -c --argjson wire "$(wire_fields)" --slurpfile st "$2" '
    . as $q | ($st[0] // {}) as $s
    | if (keys - ["events", "goals"]) != [] or any(.events[]; (keys - $wire) != []) then {status: 400, error: "bad_json"}
      elif any(.events[]; (.workspace // "") == "") then {status: 400, error: "event without workspace"}
      elif any(.events[]; (.source_key | startswith("goal:")) and has("audience")) then {status: 400, error: "a roadmap event carries no audience"}
      elif any(.events[] | select(.source_key | startswith("goal:")); . as $e
             | [$q.goals[] | select(.workspace == $e.workspace) | .id[0:3]] | index($e.source_key | split(":")[1]) | not)
        then {status: 400, error: "goal: key names no goal of its workspace"}
      else reduce .events[] as $e ({status: 200, created: 0, updated: 0, unchanged: 0, state: $s};
             ($e.workspace + "|" + $e.source_key) as $k
             | if .state[$k] == null then .created += 1 elif .state[$k] == $e then .unchanged += 1 else .updated += 1 end
             | .state[$k] = $e)
      end' "$1"
}

# run_sync <goals-dir> [VAR=val ...]: the action with the cloud stubbed; the
# stub route keeps the body it got in $T/sent.json and each call in $T/calls.
run_sync() {
  local dir="$1"; shift
  rm -f "$T/sent.json"; : >"$T/calls"
  env -u DRY_RUN HOME="$T" FUNC="$FUNC" T="$T" GOALS_DIR="$dir" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    spl_hub_operator_call() {
      echo "call $1 $2" >>"$T/calls"; cp "${3#@}" "$T/sent.json"
      local r; r="$(hub_stub "$T/sent.json" "$T/state.json")"
      SPL_HUB_OP_STATUS="$(jq -r .status <<<"$r")"; SPL_HUB_OP_BODY="$r"
      [[ "$SPL_HUB_OP_STATUS" != 200 ]] || jq .state <<<"$r" >"$T/state.json"
    }
    do_spl_goals_sync' >"$T/o" 2>"$T/e"
}
export -f hub_stub wire_fields

# no_audience <body.json>: no event of the batch carries an audience.
no_audience() { jq -e 'all(.events[]; has("audience") | not)' "$1" >/dev/null; }

# goal_yaml <dir> <id> <workspace|-> <deadline> <milestone-key> <milestone-date> <spec> <msg_id>
goal_yaml() {
  mkdir -p "$1/$2"
  {
    echo "id: \"$2\""
    [[ "$3" == - ]] || echo "workspace: \"$3\""
    printf 'owner_role: "biz_owner"\npublic: true\ndeadline: "%s"\n' "$4"
    printf 'milestones:\n  - key: "%s"\n    date: "%s"\n    title: "Kickoff of %s"\n' "$5" "$6" "$2"
    printf 'done_lines:\n  - "100%% of the specs of %s are [x]"\n  - "one paying workspace"\n' "$2"
    printf 'specs:\n  - %s\n  - "106"\napproval:\n  msg_id: "%s"\n' "$7" "$8"
  } >"$1/$2/goal.yaml"
}
G="$T/goals"; mkdir -p "$G"
printf 'id: "G<XX>-<slug>"\n' >"$G/template-goal.yaml"
echo '{}' >"$T/state.json"

# 1 --------------------------------------------------------------------------
run_sync "$G" ENV=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'no goal.yaml' "$T/e" &&
  pass "1. no goal.yaml: a no-op, rc 0, no call" || fail "1. rc=$rc $(cat "$T/calls" "$T/e")"

# 2 --------------------------------------------------------------------------
goal_yaml "$G" G01-first-million wsa 2026-12-31 start 2026-11-01 '"089"' "$U1"
goal_yaml "$G" G01-other-shop wsb 2027-01-31 mid 2026-12-15 107 "$U2"
run_sync "$G" ENV=lde DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. ENV=lde is refused before any call" || fail "2. rc=$rc $(cat "$T/calls")"

# 3 --------------------------------------------------------------------------
run_sync "$G" ENV=dev DRY_RUN=0; rc=$?
B1="$T/sent1.json"; cp "$T/sent.json" "$B1" 2>/dev/null
[[ $rc -eq 0 && "$(cat "$T/calls")" == "call PUT /v1/calendar/sync" ]] &&
  pass "3. two workspaces: ONE PUT /v1/calendar/sync" || fail "3. rc=$rc $(cat "$T/calls" "$T/e")"
[[ "$(jq -c '.goals' "$B1")" == "[{\"id\":\"G01-first-million\",\"workspace\":\"wsa\",\"approval\":{\"msg_id\":\"$U1\"}},{\"id\":\"G01-other-shop\",\"workspace\":\"wsb\",\"approval\":{\"msg_id\":\"$U2\"}}]" ]] &&
  pass "3. goals[] names each goal's own workspace and approval" || fail "3. goals: $(jq -c .goals "$B1")"
[[ "$(jq -c '[.events[] | [.workspace, .source_key, .kind, .starts_at, .all_day]]' "$B1")" == \
  '[["wsa","goal:G01:deadline","goal","2026-12-31T00:00:00Z",true],["wsa","goal:G01:m:start","milestone","2026-11-01T00:00:00Z",true],["wsb","goal:G01:deadline","goal","2027-01-31T00:00:00Z",true],["wsb","goal:G01:m:mid","milestone","2026-12-15T00:00:00Z",true]]' ]] &&
  pass "3. every event names its goal's workspace; the same goal:G01: key in two workspaces is two events" || fail "3. events: $(jq -c '[.events[] | [.workspace, .source_key]]' "$B1")"
[[ "$(jq -r '[.events[] | select(.workspace == "wsa") | .roadmap_url] | unique | join(" ")' "$B1")" == '/roadmap?ws=wsa&goal=G01#spec-089' &&
   "$(jq -r '[.events[] | select(.workspace == "wsb") | .roadmap_url] | unique | join(" ")' "$B1")" == '/roadmap?ws=wsb&goal=G01#spec-107' ]] &&
  pass "3. roadmap_url = /roadmap?ws=<ws>&goal=G01#spec-<first spec>" || fail "3. roadmap_url: $(jq -c '[.events[].roadmap_url]' "$B1")"
[[ "$(jq -c '.events[0] | [.specs, .done_lines]' "$B1")" == '[["089","106"],["100% of the specs of G01-first-million are [x]","one paying workspace"]]' &&
   "$(jq -c '[.events[] | select(.kind == "milestone") | has("specs") or has("done_lines")] | any' "$B1")" == false ]] &&
  pass "3. the deadline event carries the goal's specs and done_lines" || fail "3. specs: $(jq -c '.events[0]' "$B1")"
no_audience "$B1" && ! grep -q audience "$B1" && pass "3. the batch sends no audience" || fail "3. audience in $(cat "$B1")"
jq -e --argjson wire "$(wire_fields)" 'all(.events[]; (keys - $wire) == []) and all(.goals[]; keys == ["approval", "id", "workspace"])' "$B1" >/dev/null &&
  pass "3. only HUB-2 wire fields (+ specs, done_lines), no props, no remind_at" || fail "3. fields: $(jq -c '[.events[] | keys]' "$B1")"
grep -q '"created":4' "$T/e" && pass "3. the stub route created 4 events" || fail "3. log: $(cat "$T/e")"

# 4 --------------------------------------------------------------------------
run_sync "$G" ENV=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$B1" "$T/sent.json" && grep -q '"created":0,"updated":0,"unchanged":4' "$T/e" &&
  pass "4. a second run adds 0 events (the same body, 4 unchanged)" || fail "4. rc=$rc $(cat "$T/e")"

# 5 --------------------------------------------------------------------------
goal_yaml "$G" G03-no-workspace - 2027-02-28 end 2027-02-01 089 "$U1"
run_sync "$G" ENV=dev DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" && ! -e "$T/sent.json" ]] && grep -q "G03-no-workspace/goal.yaml: goal G03-no-workspace is missing 'workspace'" "$T/e" &&
  pass "5. CONTROL: a goal without workspace fails the run before any call" || fail "5. rc=$rc $(cat "$T/calls" "$T/e")"
run_sync "$G" ENV=dev; rc=$?
[[ $rc -ne 0 && ! -s "$T/o" ]] && pass "5. ... also in a DRY_RUN, which prints no batch" || fail "5. dry rc=$rc $(cat "$T/o")"
rm -rf "${G:?}/G03-no-workspace"

# 6 --------------------------------------------------------------------------
jq '.events[0].audience = "public"' "$B1" >"$T/planted.json"
! no_audience "$T/planted.json" && pass "6. CONTROL: an audience on a goal: key turns the no-audience check red" ||
  fail "6. the check did not see the planted audience"
[[ "$(hub_stub "$T/planted.json" "$T/state.json" | jq -r .status)" == 400 ]] &&
  pass "6. CONTROL: the stub route answers it 400, like HUB-2" || fail "6. the stub route took it"

# 7 --------------------------------------------------------------------------
run_sync "$G" ENV=prd; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && cmp -s <(jq -c . "$T/o") <(jq -c . "$B1") && grep -q 'DRY_RUN: 2 goal(s), 4 event(s)' "$T/e" &&
  pass "7. DRY_RUN (the default) prints the same batch and calls nothing" || fail "7. rc=$rc $(cat "$T/calls" "$T/e")"

# 8 --------------------------------------------------------------------------
top_opts() { grep -nE '^[[:space:]]*(set[[:space:]]+[-+]|shopt[[:space:]])' "$1"; }
printf '#!/bin/bash\nset -euo pipefail\nf() { :; }\n' >"$T/planted.func.sh"
[[ -z "$(top_opts "$FUNC")" ]] && pass "8. the func file sets no shell option at top level" || fail "8. $(top_opts "$FUNC")"
[[ -n "$(top_opts "$T/planted.func.sh")" ]] && pass "8. CONTROL: a planted top-level set -euo pipefail is seen" || fail "8. the check missed a planted set -e"

echo "---"
if ((fails)); then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: spl-goals-sync, all checks"
