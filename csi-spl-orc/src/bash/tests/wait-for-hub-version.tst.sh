#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: CLE-35057 guard - wait-for-hub-version.sh lets a WUI deploy through
#          only when the env's hub reports a version >= the repo's .version,
#          and the WUI workflow runs it before `firebase deploy`. The hub is
#          faked with a file:// base (curl reads <base>/version from disk).
#          CONTROL: a hub one patch behind must be REFUSED (exit 1).
#          CONTROL (c-316): past the 9.9.9 wrap (cycle 2) hub 1.0.8 against
#          the cycle-1 floor 1.1.3 must PASS, and the workflow must feed the
#          cycle in.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
S="$PROJ_ROOT/src/bash/scripts/wait-for-hub-version.sh"
WF="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
hub_at() { printf '{"built_at":"2026-09-27T20:45:04Z","commit":"0000000","version":"%s"}\n' "$1" > "$tmp/version"; }
run() { HUB_URL="file://$tmp" WANT_VERSION="$1" TIMEOUT_S="${2:-0}" INTERVAL_S=1 bash "$S" >"$tmp/out" 2>&1; echo $?; }

hub_at 1.1.0
[[ $(run 1.1.0) == 0 ]] && pass "hub 1.1.0, WUI needs 1.1.0 -> deploy" || fail "equal version refused: $(cat "$tmp/out")"
[[ $(run 1.0.9) == 0 ]] && pass "hub 1.1.0, WUI needs 1.0.9 -> deploy (a newer hub serves an older WUI)" || fail "newer hub refused"
hub_at 1.10.0
[[ $(run 1.9.9) == 0 ]] && pass "numeric compare: 1.10.0 >= 1.9.9" || fail "1.10.0 read as older than 1.9.9 (string compare)"

# CONTROL - the incident: the WUI's roll is ahead of the hub
hub_at 1.0.1
[[ $(run 1.1.0) == 1 ]] && pass "CONTROL hub 1.0.1, WUI needs 1.1.0 -> refused (exit 1)" || fail "CONTROL: a WUI ahead of its hub was let through"
grep -q 'NOT deploying the WUI ahead of its hub' "$tmp/out" && pass "the refusal names the reason" || fail "refusal text: $(cat "$tmp/out")"
hub_at 1.1.0
[[ $(run 1.1.1) == 1 ]] && pass "CONTROL one patch behind -> refused" || fail "one patch behind let through"

rm -f "$tmp/version"
[[ $(run 1.1.0) == 1 ]] && pass "unreachable hub -> refused" || fail "unreachable hub let through"

# the hub catches up while the job waits
hub_at 1.0.1
( sleep 2; hub_at 1.1.0 ) &
[[ $(run 1.1.0 20) == 0 ]] && pass "hub rolls while waiting -> deploy" || fail "did not see the hub roll: $(cat "$tmp/out")"
wait

# The 9.9.9 wrap (c-316, runs 37272855171 / 37275178867): .version 1.1.3 is a
# cycle-1 floor; the hub at v1.0.8-c2 shows 1.0.8, which is LATER than it.
hub_at 1.0.8
[[ $(RELEASE_CYCLE=2 run 1.1.3) == 0 ]] && pass "CONTROL cycle 2: hub 1.0.8 is past the cycle-1 floor 1.1.3 -> deploy" || fail "CONTROL cycle 2: hub 1.0.8 refused against the cycle-1 floor: $(cat "$tmp/out")"
grep -q 'release cycle 2' "$tmp/out" && pass "the pass names the cycle" || fail "cycle pass text: $(cat "$tmp/out")"
[[ $(RELEASE_CYCLE=1 run 1.1.3) == 1 ]] && pass "same pair in cycle 1 -> still refused" || fail "cycle 1 lost the floor"
rm -f "$tmp/version"
[[ $(RELEASE_CYCLE=2 run 1.1.3) == 1 ]] && pass "cycle 2, unreachable hub -> refused" || fail "cycle 2 let an unreachable hub through"
[[ $(HUB_URL="file://$tmp" WANT_VERSION=1.1.3 RELEASE_CYCLE=c2 TIMEOUT_S=0 bash "$S" >/dev/null 2>&1; echo $?) == 2 ]] && pass "bad RELEASE_CYCLE -> exit 2" || fail "bad RELEASE_CYCLE accepted"

[[ $(HUB_URL="file://$tmp" WANT_VERSION=v1.1 bash "$S" >/dev/null 2>&1; echo $?) == 2 ]] && pass "bad WANT_VERSION -> exit 2" || fail "bad WANT_VERSION accepted"
[[ $(WANT_VERSION=1.1.0 bash "$S" >/dev/null 2>&1; echo $?) == 2 ]] && pass "no HUB_URL -> exit 2 (no default)" || fail "missing HUB_URL accepted"

# the workflow runs the guard, with the repo .version, BEFORE firebase deploy
g=$(grep -n 'wait-for-hub-version.sh' "$WF" | sed -n 1p | cut -d: -f1)
d=$(grep -n 'firebase-tools@13 deploy' "$WF" | sed -n 1p | cut -d: -f1)
[[ -n "$g" && -n "$d" && "$g" -lt "$d" ]] && pass "30_wui-build-deploy.yml waits for the hub before firebase deploy" || fail "workflow 30 does not run the guard before the deploy"
grep -q 'WANT_VERSION: \${{ steps.cfg.outputs.want_version }}' "$WF" && pass "the guard reads the repo .version via cnf step" || fail "workflow 30 guard is not fed the repo .version"

grep -q 'RELEASE_CYCLE="$(spl_release_cycle_now .)" bash csi-spl-orc/src/bash/scripts/wait-for-hub-version.sh' "$WF" && pass "the guard is fed the release cycle of the v-tags" || fail "workflow 30 guard is not cycle-aware (every WUI deploy refused past the 9.9.9 wrap)"

echo "---"; (( fails == 0 )) && echo "wait-for-hub-version: all passed" || { echo "wait-for-hub-version: $fails failed"; exit 1; }
