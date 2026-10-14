#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: wui-deploy-guard.sh -- workflow 30 never deploys an older commit
#          over the one the site serves (SPL-1829; csi-web 2026-10-14:
#          9a001f1 over 240c6cf).
#   Against a SYNTHETIC repo, with a fake served commit:
#     1. an ancestor of the served commit stands down (exit 10)
#     2. the served commit itself, a newer one, a sibling, an unknown or
#        unreadable served commit all deploy (exit 0)
#     3. a SHA that is no commit is bad input (exit 2)
#     4. 30 runs the guard right before firebase deploy, and the deploy, the
#        probe, the live proof and the note ingest all wait for its ok
#   GUARD=<path> runs it against another copy (red control).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
G="${GUARD:-$PROJ_ROOT/src/bash/scripts/wui-deploy-guard.sh}"
WF="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

R="$T/repo"
git init -q -b master "$R"
c() { git -C "$R" -c user.email=t@example.com -c user.name="FirstName LastName" commit -q --allow-empty -m "$1" && git -C "$R" rev-parse HEAD; }
OLD=$(c old)
NEW=$(c new)
git -C "$R" checkout -q -b side "$OLD"
SIDE=$(c side)

# rc <sha> <served> -> the exit code of decide
rc() { APP_PATH="$R" SHA="$1" SERVED="$2" bash "$G" decide >/dev/null 2>&1; echo $?; }
expect() { [[ "$(rc "$2" "$3")" == "$1" ]] && pass "$4" || fail "$4 (want rc $1, got $(rc "$2" "$3"))"; }

# --- 1. older than served -> stand down ---------------------------------------
expect 10 "$OLD" "$NEW" "an ancestor of the served commit stands down"

# --- 2. everything else deploys -------------------------------------------------
expect 0 "$NEW" "$NEW" "the served commit itself deploys (a re-run)"
expect 0 "$NEW" "$OLD" "a newer commit than the served one deploys"
expect 0 "$SIDE" "$NEW" "a sibling of the served commit deploys"
expect 0 "$OLD" "" "an unreadable served commit deploys"
expect 0 "$OLD" "0123456789abcdef0123456789abcdef01234567" "an unknown served commit deploys"
expect 0 "$OLD" "${NEW:0:8}" "a served value that is not 40 hex deploys"

# --- 3. bad input --------------------------------------------------------------
expect 2 "not-a-commit" "$NEW" "a SHA that is no commit is bad input"

# --- 4. workflow 30 wiring -------------------------------------------------------
if [[ -z "${GUARD:-}" ]]; then
  ln_guard=$(grep -n 'wui-deploy-guard.sh decide' "$WF" | sed -n 1p | cut -d: -f1)
  ln_deploy=$(grep -n -- '- name: firebase deploy --only hosting' "$WF" | sed -n 1p | cut -d: -f1)
  ln_wait=$(grep -n -- '- name: Wait for the hub this WUI needs' "$WF" | sed -n 1p | cut -d: -f1)
  [[ -n "$ln_guard" && -n "$ln_deploy" && -n "$ln_wait" ]] && ((ln_wait < ln_guard && ln_guard < ln_deploy)) &&
    pass "30 runs the guard after the hub wait, right before firebase deploy" ||
    fail "30 does not run the guard between the hub wait and firebase deploy"
  for step in 'firebase deploy --only hosting' 'Probe the deployed commit' \
              'Live proof, signed in' 'Ingest the release notes'; do
    awk -v s="- name: $step" 'index($0, s) { f = 1; next } f && /^ *if:/ { print; exit }' "$WF" |
      grep "steps.fwd.outputs.ok == 'true'" >/dev/null && pass "'$step' waits for the guard" ||
      fail "'$step' runs even when the guard stands down"
  done
  grep -qx "      - 'csi-spl-orc/src/bash/scripts/wui-deploy-guard.sh'" "$WF" &&
    pass "a guard change triggers 30" || fail "30's push paths miss wui-deploy-guard.sh"
fi

echo "wui-deploy-guard: $fails failure(s)"
exit $((fails > 0))
