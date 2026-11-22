#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_claude_project_slug (csi-spl-orc/lib/bash/funcs/
# spl-claude-project-slug.func.sh, r88-01, SPL-6245), the one copy of Claude
# Code's project slug rule: the cwd with every non letter or digit a dash.
#   1. the helper maps a worktree path and a path with a space, _ and .
#   2. spl-agent-login-check.func.sh sourced ALONE (no ./run, no lib preload)
#      finds a transcript by the slug: its declare -F guard loads the helper.
#   3. the src/bash/run/*.func.sh files that still spell the sed are exactly
#      the list below; it only shrinks.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
LIB="$PROJ_ROOT/lib/bash/funcs/spl-claude-project-slug.func.sh"
RUN="$PROJ_ROOT/src/bash/run"

# 1. the helper
got="$(bash -c 'source "$0"; spl_claude_project_slug /srv/acme/acme-app-wt/c-170' "$LIB" 2>&1)"
[[ "$got" == "-srv-acme-acme-app-wt-c-170" ]] && pass "1. a worktree path -> $got" || fail "1. worktree path: $got"
got="$(bash -c 'source "$0"; spl_claude_project_slug "/a b/c_d.e"' "$LIB" 2>&1)"
[[ "$got" == "-a-b-c-d-e" ]] && pass "1. space, _ and . -> $got" || fail "1. space, _ and .: $got"

# 2. login check sourced alone: the guard loads the helper
H="$T/home"; W="$T/wt/c-170"; A="$T/adapters"
mkdir -p "$W" "$A" && : >"$A/restore-claude.sh"
mkdir -p "$H/.claude/projects/$(printf '%s' "$W" | sed 's/[^A-Za-z0-9]/-/g')"
: >"$H/.claude/projects/$(printf '%s' "$W" | sed 's/[^A-Za-z0-9]/-/g')/0000.jsonl"
out="$(env W="$W" LOGIN_AGENT_HOME="$H" IDENTITY_RESTORE_ADAPTER_DIR="$A" bash -c '
  set -uo pipefail
  source "$0"
  ai_field() { case "$2" in session_id) echo 0000;; worktree) echo "$W";; kind) echo claude;; esac; }
  _lc_restorable c-170' "$RUN/spl-agent-login-check.func.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "2. sourced alone, _lc_restorable finds the transcript by the slug" || fail "2. rc $rc: $out"

# 3. the copies left
want="spl-dispatch-lease.func.sh "
got="$(grep -lF 's/[^A-Za-z0-9]/-/g' "$RUN"/*.func.sh | xargs -n1 basename | sort | tr '\n' ' ')"
[[ "$got" == "$want" ]] && pass "3. the inline copies left: $want" || fail "3. want '$want', got '$got'"

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
