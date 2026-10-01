#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_subscribe (2026-10-01: a fresh owner topic in a
#          50-agent channel reached ONLY the orchestrator, because the hub
#          delivers to a channel's subscribed agents and neither dispatcher was
#          one). The hub DB is fixture files (DISPATCH_SUBS_DIR), live agents
#          a fake /proc, and the add / remove runners stubs that record calls.
#   1. the plan: add the missing dispatchers per channel (defaults included),
#      remove the orchestrator on every box it sits on, leave right channels
#   2. dead subscriptions are REPORTED (no live process), never removed; any
#      agent kind counts as live; another box is not judged
#   3. DRY_RUN (default) calls no runner; DRY_RUN=0 calls exactly the planned
#      ones, the add with ALLOW_DEFAULT_CHANNEL=1
#   4. a failing runner fails the action; a missing workspace file fails it
#   5. a complete workspace plans nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

P="$T/proc" SUBS="$T/subs"
mkdir -p "$P" "$SUBS" "$T/state/desk/w1/box-desk" "$T/state/desk/w2/box-desk"
touch "$T/state/desk/w1/box-desk/pinned" "$T/state/desk/w2/box-desk/pinned"
proc() { mkdir -p "$P/$1"; echo "$3" >"$P/$1/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"; }
proc 101 CLE-8 claude; proc 102 AGY-5 agy

cat >"$SUBS/w1.txt" <<'EOF'
chan|alerts
chan|lobby
chan|devel
chan|ops
chan|right
sub|lobby|box-desk|CLE-002|invite
sub|devel|box-desk|CLE-001|invite
sub|devel|box-other|CLE-001|invite
sub|devel|box-desk|CLE-8|invite
sub|devel|box-desk|CLE-9|invite
sub|devel|box-desk|AGY-5|invite
sub|devel|box-other|CLE-7|invite
sub|ops|box-desk|CLE-002|invite
sub|ops|box-desk|CLE-003|invite
sub|ops|box-desk|CLE-001|invite
sub|right|box-desk|CLE-002|invite
sub|right|box-desk|CLE-003|invite
EOF
printf 'chan|lobby\nsub|lobby|box-desk|CLE-002|invite\nsub|lobby|box-desk|CLE-003|invite\n' >"$SUBS/w2.txt"

run() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/repo" SPL_STATE_DIR="$T/state" LEASE_PROC_ROOT="$P" \
    DISPATCH_SUBS_DIR="$SUBS" SPOOL_ROOT="$T/spool" ENV=prd CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/src/bash/run/spl-dispatch-*.func.sh; do source "$f"; done
    _spl_channel_agent_add_op_run() { echo "add $*" >>"$CALLS"; [[ "${FAIL_ADD:-}" != "$2" ]]; }
    _spl_channel_agent_remove_op_run() { echo "remove $*" >>"$CALLS"; }
    do_spl_dispatch_subscribe' >"$T/o" 2>&1
}

# --- 1. the plan ---------------------------------------------------------------------------
: >"$T/calls"
run DISPATCH_TENANTS=w1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && pass "3. DRY_RUN (default) calls no runner" || fail "3. dry: rc=$rc $(cat "$T/calls" "$T/o")"
grep -qx 'PLAN add w1 #alerts CLE-002 CLE-003' "$T/o" && grep -qx 'PLAN add w1 #lobby CLE-003' "$T/o" &&
  grep -qx 'PLAN add w1 #devel CLE-002 CLE-003' "$T/o" &&
  pass "1. the missing dispatchers are planned per channel, default channels included" || fail "1. adds: $(cat "$T/o")"
grep -qx 'PLAN remove w1 #devel CLE-001 (box-desk)' "$T/o" && grep -qx 'PLAN remove w1 #devel CLE-001 (box-other)' "$T/o" &&
  grep -qx 'PLAN remove w1 #ops CLE-001 (box-desk)' "$T/o" && ! grep -q 'PLAN add w1 #ops' "$T/o" &&
  pass "1. the orchestrator is removed on every box it sits on" || fail "1. removes: $(cat "$T/o")"
! grep -q '#right' <(grep '^PLAN' "$T/o") && grep -q 'SUM  w1: 5 channel(s), 1 already right, 3 to add the dispatchers, 3 orchestrator seat(s) to remove, 1 with dead subscriptions' "$T/o" &&
  pass "1. a right channel plans nothing; the summary counts it" || fail "1. sum: $(grep SUM "$T/o")"

# --- 2. dead subscriptions -----------------------------------------------------------------
grep -qx 'DEAD w1 #devel CLE-9 (no live process on this box; report only)' "$T/o" &&
  pass "2. a subscription with no live process is reported; a live agy agent is not; another box is not judged" ||
  fail "2. dead: $(grep DEAD "$T/o")"

# --- 3. apply ---------------------------------------------------------------------------------
: >"$T/calls"
run DISPATCH_TENANTS=w1 DRY_RUN=0; rc=$?
sort "$T/calls" >"$T/got"
printf '%s\n' 'add w1 alerts box-desk CLE-002 CLE-003 1' 'add w1 devel box-desk CLE-002 CLE-003 1' 'add w1 lobby box-desk CLE-003 1' \
  'remove w1 devel box-desk CLE-001' 'remove w1 devel box-other CLE-001' 'remove w1 ops box-desk CLE-001' | sort >"$T/want"
[[ $rc -eq 0 ]] && cmp -s "$T/got" "$T/want" &&
  pass "3. DRY_RUN=0 calls exactly the planned runners, the add with ALLOW_DEFAULT_CHANNEL=1" || fail "3. calls: $(diff "$T/want" "$T/got") rc=$rc"
grep -q 'CLE-9' "$T/calls" && fail "2. a dead subscription was acted on" || pass "2. a dead subscription is never removed"

# --- 4. failures -------------------------------------------------------------------------------
run DISPATCH_TENANTS=w1 DRY_RUN=0 FAIL_ADD=devel; rc=$?
[[ $rc -ne 0 ]] && grep -q '1 subscription change(s) failed' "$T/o" && pass "4. a failing runner fails the action" || fail "4. runner failure: rc=$rc $(cat "$T/o")"
run DISPATCH_TENANTS="w1 w3"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no $SUBS/w3.txt" "$T/o" && pass "4. a workspace that cannot be read fails the action" || fail "4. missing: rc=$rc"
run DISPATCH_TENANTS=w1 DRY_RUN=2; rc=$?
[[ $rc -ne 0 ]] && pass "4. DRY_RUN=2 refused" || fail "4. DRY_RUN=2 accepted"

# --- 5. complete workspace -----------------------------------------------------------------
: >"$T/calls"
run DISPATCH_TENANTS=w2 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && ! grep -q '^PLAN' "$T/o" && grep -q 'SUM  w2: 1 channel(s), 1 already right' "$T/o" &&
  pass "5. a complete workspace plans and changes nothing" || fail "5. w2: $(cat "$T/o")"

echo "dispatch-subscribe: $fails failure(s)"
[[ $fails -eq 0 ]]
