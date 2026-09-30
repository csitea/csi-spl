#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_deploy_lag_alarm (SPL-1254) posts to #spool-hub-ops only on a
#          verdict EDGE, per env+component, so a lag episode is one alarm + one
#          recovery, never a post every run. The lag-check and the poster are
#          injected (OPS_LAG_CMD, OPS_POST_FN); nothing real is called.
#     1. first sight of lagging            -> one blocker
#     2. still lagging (same)              -> silent
#     3. back to current                   -> one recovery note
#     4. still current                     -> silent
#     5. unknown                           -> no post, state unchanged
#     6. hub and wui are independent keys  -> only the one that flips posts
#     7. the post carries the ops channel and the detail line
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-deploy-lag-alarm.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/spl-deploy-lag-alarm.func.sh
. "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STATE="$T/state"; POSTS="$T/posts"; LAG="$T/lag"; : >"$POSTS"

# a stub poster: record "<channel>|<kind>|<body>"
ops_post_stub() { printf '%s|%s|%s\n' "${DESK_CHANNEL:-}" "${DESK_KIND:-}" "${DESK_BODY:-}" >>"$POSTS"; return 0; }
set_lag() { printf '%s\n' "$@" >"$LAG"; }
run_alarm() { ENV="$1" OPS_STATE_FILE="$STATE" OPS_POST_FN=ops_post_stub OPS_LAG_CMD="cat '$LAG'" do_spl_deploy_lag_alarm >/dev/null 2>&1; }
nposts() { wc -l <"$POSTS" | tr -d ' '; }
last_post() { tail -1 "$POSTS"; }

# 1. first sight of lagging -> one blocker
set_lag "dev hub lagging served=aaaa sha=bbbb n=3 age=50m grace=45m url=https://x/version"
run_alarm dev
eq "1. first lagging posts once" 1 "$(nposts)"
eq "1. ... a blocker on the ops channel" "spool-hub-ops|blocker" "$(last_post | cut -d'|' -f1,2)"

# 2. still lagging -> silent
run_alarm dev
eq "2. still lagging is silent" 1 "$(nposts)"

# 3. back to current -> recovery note
set_lag "dev hub current served=bbbb sha=bbbb n=0"
run_alarm dev
eq "3. recovery posts once" 2 "$(nposts)"
eq "3. ... a note" "spool-hub-ops|note" "$(last_post | cut -d'|' -f1,2)"

# 4. still current -> silent
run_alarm dev
eq "4. still current is silent" 2 "$(nposts)"

# 5. unknown -> no post, state unchanged (still ok)
set_lag "dev hub unknown reason=endpoint unreachable"
run_alarm dev
eq "5. unknown never posts" 2 "$(nposts)"
eq "5. ... state stays ok for dev/hub" "dev/hub=ok" "$(grep '^dev/hub=' "$STATE" | tail -1)"

# 6. hub and wui independent: hub flips to lag, wui stays current -> one post
set_lag "dev hub lagging served=cccc sha=dddd n=1 age=90m grace=45m" "dev wui current served=dddd sha=dddd n=0"
run_alarm dev
eq "6. only the flipped key (hub) posts" 3 "$(nposts)"
eq "6. ... and it is the hub blocker" "spool-hub-ops|blocker" "$(last_post | cut -d'|' -f1,2)"
# wui stayed at its default ok, so it correctly triggers no post and needs no
# state row (an absent key is read as ok; only edges are recorded).
eq "6. wui (ok, no edge) posts nothing" 0 "$(grep -c 'wui' "$POSTS")"

# 7. the body carries the detail line
grep -q 'is lagging.*age=90m' "$POSTS" && pass "7. the alarm body carries the lag detail" || fail "7. the alarm body carries the lag detail"

echo "-- spl-deploy-lag-alarm.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
