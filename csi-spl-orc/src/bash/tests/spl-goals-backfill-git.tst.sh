#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_goals_backfill_git (spec 112 8.1 + 12.7, ORC-5), against a
#          fixture git repo and a stub sync route (the cloud is stubbed; the
#          stub keeps the keys it has seen, as the route's upsert by key does).
#   1. no WORKSPACE: exits non-zero with "WORKSPACE must be set (no default)"
#      before any call; a non-slug WORKSPACE and ENV=lde are refused too
#   2. the batch: {events} only; the first event is 2026-09-17 spool-hub
#      started; tags v1.2.0, v1.2.1, v1.3.0 give EXACTLY 2 release events
#      (v1.2.0 with its release note, v1.3.0); the done spec and the
#      milestones.yaml line are events, the open spec is not; every event
#      names the workspace and NONE carries an audience
#   3. a second run adds 0 events (same keys, same bytes)
#   4. CONTROL: a patch tag counted as major (a mutant of the tag rule) turns
#      the 2-release check red, and the action itself refuses it, no call
#   5. CONTROL: a batch with an audience turns the no-audience check red, and
#      the action refuses it, no call
#   6. CONTROL: the WORKSPACE guard removed (a mutant): check 1 turns red
#   7. DRY_RUN=1 prints the batch, no call; a non-200 answer fails
#   8. the func sets no shell option at top level (./run sources it into
#      every action); CONTROL: a mutant with one turns the check red
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-goals-backfill-git.func.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
SPROG="$PROJ_ROOT/src/bash/run/spl-spec-progress.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The fixture repo -------------------------------------------------------------
R="$T/repo"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
mkdir -p "$R/csi-spl-doc/goals" "$R/csi-spl-doc/specs/001-alpha" "$R/csi-spl-doc/specs/002-beta"
git init -q "$R"
printf '# Major milestones\n\n2026-09-17 spool-hub started (git: b588b50c2)\n# 2026-10-01 commented out (spec: 000)\n2026-10-05 Calendar sync (spec: 089)\n' \
  >"$R/csi-spl-doc/goals/milestones.yaml"
printf '# Alpha spec\n' >"$R/csi-spl-doc/specs/001-alpha/spec.md"
printf -- '- [x] T1\n- [X] T2\n' >"$R/csi-spl-doc/specs/001-alpha/tasks.md"
printf '# Beta spec\n' >"$R/csi-spl-doc/specs/002-beta/spec.md"
printf -- '- [x] T1\n- [ ] T2\n' >"$R/csi-spl-doc/specs/002-beta/tasks.md"
g add -A && GIT_COMMITTER_DATE=2026-10-01T10:00:00Z g commit -q -m one
GIT_COMMITTER_DATE=2026-10-01T10:00:00Z g tag -a v1.2.0 -m v1.2.0
g notes --ref=release-notes add -m $'Release-Note: yes\nLay-Why: So a goal shows its dates.\nLay-What: Roadmap and calendar sync' HEAD
GIT_COMMITTER_DATE=2026-10-02T10:00:00Z g commit -q --allow-empty -m two
GIT_COMMITTER_DATE=2026-10-02T10:00:00Z g tag v1.2.1
GIT_COMMITTER_DATE=2026-10-03T10:00:00Z g commit -q --allow-empty -m three
GIT_COMMITTER_DATE=2026-10-03T10:00:00Z g tag -a v1.3.0 -m v1.3.0

# run <func> [VAR=val ...]: the action with the cloud stubbed. The stub route
# keeps the body in $T/sent.json and the keys it has seen in $T/route.keys.
: >"$T/route.keys"
run() {
  local func="$1"; shift
  rm -f "$T/sent.json"; : >"$T/calls"
  env -u WORKSPACE -u DRY_RUN -u BACKFILL_REPO FUNC="$func" LIB="$LIB" SPROG="$SPROG" T="$T" BACKFILL_REPO="$R" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "$LIB"
    source "$SPROG"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    spl_hub_operator_call() {
      echo "call $*" >>"$T/calls"; cp "${3#@}" "$T/sent.json"
      local c; c=$(jq -r ".events[].source_key" "$T/sent.json" | sort -u | comm -23 - <(sort -u "$T/route.keys") | wc -l)
      jq -r ".events[].source_key" "$T/sent.json" >>"$T/route.keys"
      SPL_HUB_OP_STATUS="${STUB_STATUS:-200}"
      SPL_HUB_OP_BODY="{\"error\":\"bad_calendar\",\"created\":$c,\"updated\":0,\"unchanged\":0,\"deleted\":0,\"carried\":0}"
    }
    ${STUB_BODY:+eval "$STUB_BODY"}
    do_spl_goals_backfill_git' >"$T/o" 2>"$T/e"
}
# body <func>: the batch the func builds from the fixture, for workspace ta
body() { bash -c 'do_log() { echo "$*" >&2; }; source "$3"; source "$1"; SPL_GOALS_BACKFILL_GIT_START=2026-09-17; spl_goals_backfill_git_body "$2" ta' _ "$1" "$R" "$SPROG"; }
# The checks, as functions so each control can show it turns red.
two_releases() { [[ "$(jq -c '[.events[] | select(.kind == "release") | .source_key]' "$1")" == '["release:v1.2.0","release:v1.3.0"]' ]]; }
no_audience() { jq -e '[.. | objects | has("audience")] | any | not' "$1" >/dev/null; }
guard_refuses() { [[ $1 -ne 0 && ! -s "$T/calls" ]] && grep -q 'WORKSPACE must be set (no default)' "$T/e"; }

# 1 -----------------------------------------------------------------------------
run "$FUNC" ENV=dev; rc=$?
guard_refuses "$rc" && pass "1. no WORKSPACE: exits non-zero before any call" || fail "1. rc=$rc $(cat "$T/calls" "$T/e")"
run "$FUNC" ENV=dev WORKSPACE='T1;x'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "1. a non-slug WORKSPACE is refused" || fail "1. slug rc=$rc"
run "$FUNC" ENV=lde WORKSPACE=ta; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "1. ENV=lde is refused" || fail "1. lde rc=$rc"

# 2 -----------------------------------------------------------------------------
run "$FUNC" ENV=dev WORKSPACE=ta; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == "call PUT /v1/calendar/sync @"* ]] && grep -q 'OK 5 git event(s) of workspace ta synced in dev' "$T/e" &&
  pass "2. one PUT /v1/calendar/sync, the body as @<file>" || fail "2. rc=$rc $(cat "$T/calls" "$T/e")"
cp "$T/sent.json" "$T/first.json" 2>/dev/null
[[ "$(jq -c 'keys' "$T/first.json")" == '["events"]' ]] && pass "2. the batch is {events} only" || fail "2. keys: $(jq -c keys "$T/first.json")"
[[ "$(jq -c '.events[0] | [.source_key, .title, .starts_at, .kind]' "$T/first.json")" == '["milestone:spool-hub-started","spool-hub started","2026-09-17T00:00:00Z","milestone"]' ]] &&
  pass "2. the first event is 2026-09-17 spool-hub started" || fail "2. first: $(jq -c '.events[0]' "$T/first.json")"
two_releases "$T/first.json" && pass "2. tags v1.2.0, v1.2.1, v1.3.0 give exactly 2 release events" || fail "2. releases: $(jq -c '[.events[].source_key]' "$T/first.json")"
[[ "$(jq -r '.events[] | select(.source_key == "release:v1.2.0") | [.release_version, .description] | join("|")' "$T/first.json")" == 'v1.2.0|Roadmap and calendar sync' ]] &&
  pass "2. a release carries its version and its release note's Lay-What line" || fail "2. v1.2.0: $(jq -c '.events[]' "$T/first.json")"
[[ "$(jq -c '[.events[].source_key]' "$T/first.json")" == '["milestone:spool-hub-started","release:v1.2.0","spec:001:done","release:v1.3.0","milestone:calendar-sync"]' ]] &&
  pass "2. the done spec and the milestones.yaml line are events, the open spec and the comment are not, in date order" || fail "2. keys: $(jq -c '[.events[].source_key]' "$T/first.json")"
jq -e 'all(.events[]; .workspace == "ta")' "$T/first.json" >/dev/null && pass "2. every event names the workspace" || fail "2. workspace"
no_audience "$T/first.json" && pass "2. no event carries an audience (HUB-2 sets it)" || fail "2. audience: $(jq -c '.events[]' "$T/first.json")"

# 3 -----------------------------------------------------------------------------
run "$FUNC" ENV=dev WORKSPACE=ta; rc=$?
[[ $rc -eq 0 ]] && grep -q '"created":0' "$T/e" && cmp -s "$T/first.json" "$T/sent.json" &&
  pass "3. a second run adds 0 events (same keys, same bytes)" || fail "3. rc=$rc $(cat "$T/e")"

# 4 -----------------------------------------------------------------------------
sed 's/\[\[ "\$tag" =~ \^v\[0-9\]+\\.\[0-9\]+\\.0\$ \]\]/[[ "$tag" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]/' "$FUNC" >"$T/patch.func.sh"
if cmp -s "$FUNC" "$T/patch.func.sh"; then fail "4. CONTROL: the patch-tag mutant did not apply"; else
  body "$T/patch.func.sh" >"$T/patch.json"
  ! two_releases "$T/patch.json" && [[ "$(jq '[.events[] | select(.kind == "release")] | length' "$T/patch.json")" == 3 ]] &&
    pass "4. CONTROL: a patch tag counted as major turns the 2-release check red" || fail "4. control: $(jq -c '[.events[].source_key]' "$T/patch.json")"
  run "$T/patch.func.sh" ENV=dev WORKSPACE=ta; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'breaks its contract' "$T/e" &&
    pass "4. CONTROL: the action refuses a patch release itself, no call" || fail "4. guard rc=$rc $(cat "$T/calls" "$T/e")"
fi
body "$FUNC" >"$T/body.json"; two_releases "$T/body.json" && pass "4. and green on the real rule" || fail "4. green: $(cat "$T/body.json")"

# 5 -----------------------------------------------------------------------------
jq '.events[1].audience = "internal"' "$T/first.json" >"$T/aud.json"
! no_audience "$T/aud.json" && pass "5. CONTROL: a batch with an audience turns the no-audience check red" || fail "5. control: no_audience passed"
run "$FUNC" ENV=dev WORKSPACE=ta STUB_BODY='spl_goals_backfill_git_body() { jq -c ".events[1].audience = \"internal\"" "$T/first.json"; }'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'breaks its contract' "$T/e" &&
  pass "5. CONTROL: the action refuses an audience itself, no call" || fail "5. guard rc=$rc $(cat "$T/calls" "$T/e")"

# 6 -----------------------------------------------------------------------------
grep -v 'WORKSPACE:?WORKSPACE must be set (no default)' "$FUNC" >"$T/noguard.func.sh"
run "$T/noguard.func.sh" ENV=dev; rc=$?
! guard_refuses "$rc" && pass "6. CONTROL: the WORKSPACE guard removed turns check 1 red" || fail "6. control: check 1 still green without the guard"

# 7 -----------------------------------------------------------------------------
run "$FUNC" ENV=dev WORKSPACE=ta DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && cmp -s <(jq -c . "$T/o") "$T/first.json" &&
  pass "7. DRY_RUN=1 prints the batch, no call" || fail "7. dry rc=$rc $(cat "$T/calls" "$T/e")"
run "$FUNC" ENV=dev WORKSPACE=ta STUB_STATUS=400; rc=$?
[[ $rc -ne 0 ]] && grep -q 'answered 400 bad_calendar' "$T/e" && pass "7. a non-200 answer fails" || fail "7. 400 rc=$rc $(cat "$T/e")"

# 8 -----------------------------------------------------------------------------
no_top_level_opts() { ! grep -qE '^(set|shopt)[[:space:]]' "$1"; }
no_top_level_opts "$FUNC" && pass "8. the func sets no shell option at top level" || fail "8. $(grep -nE '^(set|shopt)[[:space:]]' "$FUNC")"
{ echo 'set -euo pipefail'; cat "$FUNC"; } >"$T/opts.func.sh"
! no_top_level_opts "$T/opts.func.sh" && pass "8. CONTROL: a top-level set -euo pipefail turns the check red" || fail "8. control"

(( fails == 0 )) && echo "OK spl-goals-backfill-git: all checks passed" || { echo "$fails FAILED"; exit 1; }
