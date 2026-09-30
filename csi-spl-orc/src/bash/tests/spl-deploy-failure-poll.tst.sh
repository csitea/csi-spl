#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_deploy_failure_poll (SPL-1255 box-cron form) posts one blocker
#          per NEW failed 20/30 run and never re-posts one it has seen. Lister and
#          poster are injected; no gh, no hub.
#     1. two failed runs -> two posts, each carrying its run's fields
#     2. a second poll with the same rows -> no new posts (edge-dedup)
#     3. a third failed run appears -> exactly one new post
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-deploy-failure-poll.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/spl-deploy-failure-poll.func.sh
. "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STATE="$T/state"; POSTS="$T/posts"; ROWS="$T/rows"; : >"$POSTS"
ops_post_stub() { printf '%s|%s|%s\n' "${FAIL_RUN_URL:-}" "${FAIL_SHA:-}" "${FAIL_COMMIT_SUBJECT:-}" >>"$POSTS"; return 0; }
set_rows() { printf '%s\n' "$@" >"$ROWS"; }
poll() { FAIL_POLL_STATE="$STATE" OPS_POST_FN=ops_post_stub FAIL_POLL_LIST_CMD="cat '$ROWS'" do_spl_deploy_failure_poll >/dev/null 2>&1; }
nposts() { grep -c . "$POSTS"; }

# rows are TSV: run_id \t workflow \t url \t sha \t subject \t step
r1="$(printf '101\t20 hub\thttps://x/runs/101\tabc123\tfix(hub, CLE-1): a\trun-all-tests.sh')"
r2="$(printf '102\t30 wui\thttps://x/runs/102\tdef456\tfix(wui, CLE-2): b\tpnpm typecheck')"
r3="$(printf '103\t20 hub\thttps://x/runs/103\tghi789\tfix(hub, CLE-3): c\thub-pg')"

# 1. two failed runs -> two posts
set_rows "$r1" "$r2"; poll
eq "1. two new failures -> two posts" 2 "$(nposts)"
grep -q 'https://x/runs/101|abc123' "$POSTS" && pass "1. run 101 posted with its fields" || fail "1. run 101 posted"

# 2. same rows again -> no new posts
poll
eq "2. re-poll same runs -> still two (deduped)" 2 "$(nposts)"

# 3. a new failure appears -> exactly one more
set_rows "$r1" "$r2" "$r3"; poll
eq "3. a third failure -> exactly one new post" 3 "$(nposts)"
grep -q 'https://x/runs/103|ghi789' "$POSTS" && pass "3. run 103 posted" || fail "3. run 103 posted"

echo "-- spl-deploy-failure-poll.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
