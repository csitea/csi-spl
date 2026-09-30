#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_deploy_failure_post (SPL-1255) builds one #spool-hub-ops
#          blocker from a failed 20/30 run's fields, naming the run, the failing
#          step, the breaking commit and the agent that landed it. The poster is
#          injected (OPS_POST_FN); nothing real is sent.
#     1. FAIL_RUN_URL is required
#     2. the body carries the run link, the failing step and the short sha
#     3. the agent is parsed from the commit subject tag (CLE/GRK/AGY/QWN/SPL)
#     4. no tag -> falls back to the commit author
#     5. the post is a blocker on the ops channel
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-deploy-failure-post.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "'$3' not in: $2" ;; esac; }

do_log() { :; }
# shellcheck source=../run/spl-deploy-failure-post.func.sh
. "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CAP="$T/cap"
ops_post_stub() { printf '%s|%s|%s\n' "${DESK_CHANNEL:-}" "${DESK_KIND:-}" "${DESK_BODY:-}" >"$CAP"; return 0; }

# 1. url required
FAIL_RUN_URL="" OPS_POST_FN=ops_post_stub do_spl_deploy_failure_post >/dev/null 2>&1
eq "1. FAIL_RUN_URL required -> rc 2" 2 "$?"

# 2 + 3 + 5. a tagged commit
FAIL_RUN_URL="https://github.com/o/r/actions/runs/42" FAIL_WORKFLOW="20 ci-cd: spool hub build + deploy" \
  FAIL_SHA="abcd1234ef567890" FAIL_COMMIT_SUBJECT="fix(hub, CLE-77790): name the reason" \
  FAIL_STEP="run-all-tests.sh" OPS_POST_FN=ops_post_stub do_spl_deploy_failure_post >/dev/null 2>&1
body="$(cut -d'|' -f3 "$CAP")"
has "2. body carries the run link" "$body" "https://github.com/o/r/actions/runs/42"
has "2. body names the failing step" "$body" "run-all-tests.sh"
has "2. body carries the short sha" "$body" "abcd1234"
has "3. agent parsed from the commit tag" "$body" "From: **CLE-77790**"
eq "5. it is a blocker on the ops channel" "spool-hub-ops|blocker" "$(cut -d'|' -f1,2 "$CAP")"

# 3b. an SPL- issue tag is also recognised, case-insensitively
FAIL_RUN_URL="https://x/runs/9" FAIL_COMMIT_SUBJECT="feat(iac, spl-1251): pre-push gate" \
  OPS_POST_FN=ops_post_stub do_spl_deploy_failure_post >/dev/null 2>&1
has "3b. a lowercase spl- tag is upper-cased" "$(cut -d'|' -f3 "$CAP")" "From: **SPL-1251**"

# 4. no tag -> author fallback
FAIL_RUN_URL="https://x/runs/7" FAIL_COMMIT_SUBJECT="merge branch main" FAIL_AUTHOR="FirstName LastName" \
  OPS_POST_FN=ops_post_stub do_spl_deploy_failure_post >/dev/null 2>&1
has "4. untagged commit falls back to the author" "$(cut -d'|' -f3 "$CAP")" "From: **FirstName LastName**"

echo "-- spl-deploy-failure-post.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
