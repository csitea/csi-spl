#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_subscribe (owner 2026-10-03: "Of course every OD
#          should be a member of every channel"; the hub delivers to a
#          channel's subscribed agents). The hub DB is fixture files
#          (DISPATCH_SUBS_DIR), live agents a fake /proc, and the add / remove
#          runners stubs that record calls.
#   1. the plan: add the missing OD seats (orchestrator, master, failover) per
#      channel (defaults included), remove none, leave right channels
#   2. dead subscriptions are REPORTED (no live process), never removed; any
#      agent kind counts as live; another box is not judged
#   3. DRY_RUN (default) calls no runner; DRY_RUN=0 calls exactly the planned
#      ones, the add with ALLOW_DEFAULT_CHANNEL=1
#   4. a failing runner fails the action; a missing workspace file fails it
#   5. a complete workspace plans nothing
#   8. fleet mode: every box of the lease rankings gets its rostered OD seats;
#      an unrostered one is UNSEATED (report only), never added
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
ros|box-desk|c-001
ros|box-desk|c-002
ros|box-desk|c-003
ros|box-other|c-001
sub|lobby|box-desk|c-002|invite
sub|devel|box-desk|c-001|invite
sub|devel|box-other|c-001|invite
sub|devel|box-desk|CLE-8|invite
sub|devel|box-desk|CLE-9|invite
sub|devel|box-desk|AGY-5|invite
sub|devel|box-other|CLE-7|invite
sub|ops|box-desk|c-002|invite
sub|ops|box-desk|c-003|invite
sub|ops|box-desk|c-001|invite
sub|right|box-desk|c-001|invite
sub|right|box-desk|c-002|invite
sub|right|box-desk|c-003|invite
EOF
ODS='ros|box-desk|c-001\nros|box-desk|c-002\nros|box-desk|c-003\n'
printf "chan|lobby\n${ODS}sub|lobby|box-desk|c-001|invite\nsub|lobby|box-desk|c-002|invite\nsub|lobby|box-desk|c-003|invite\n" >"$SUBS/w2.txt"

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
grep -qx 'PLAN add w1 #alerts c-001 c-002 c-003 (box-desk)' "$T/o" && grep -qx 'PLAN add w1 #lobby c-001 c-003 (box-desk)' "$T/o" &&
  grep -qx 'PLAN add w1 #devel c-002 c-003 (box-desk)' "$T/o" &&
  pass "1. the missing OD seats are planned per channel, the orchestrator too, default channels included" || fail "1. adds: $(cat "$T/o")"
! grep -q '^PLAN remove' "$T/o" && ! grep -q 'PLAN add w1 #ops' "$T/o" && ! grep -q 'box-other' <(grep '^PLAN' "$T/o") &&
  pass "1. the orchestrator is never removed; a box outside the fleet is not touched" || fail "1. removes: $(cat "$T/o")"
! grep -q '#right' <(grep '^PLAN' "$T/o") && grep -q 'SUM  w1: 5 channel(s), 2 already right, 3 OD seat add(s), 0 legacy role row(s) to remove, 1 with dead subscriptions, 0 OD seat(s) unseated' "$T/o" &&
  pass "1. a right channel plans nothing; the summary counts it" || fail "1. sum: $(grep SUM "$T/o")"

# --- 2. dead subscriptions -----------------------------------------------------------------
grep -qx 'DEAD w1 #devel CLE-9 (no live process on this box; report only)' "$T/o" &&
  pass "2. a subscription with no live process is reported; a live agy agent is not; another box is not judged" ||
  fail "2. dead: $(grep DEAD "$T/o")"

# --- 3. apply ---------------------------------------------------------------------------------
: >"$T/calls"
run DISPATCH_TENANTS=w1 DRY_RUN=0; rc=$?
sort "$T/calls" >"$T/got"
printf '%s\n' 'add w1 alerts box-desk c-001 c-002 c-003 1' 'add w1 devel box-desk c-002 c-003 1' 'add w1 lobby box-desk c-001 c-003 1' | sort >"$T/want"
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

# --- 6. inbound silence (CLE-77876) -----------------------------------------------------------
# w4: people posted, the seated dispatchers received nothing, 3 posts unsigned.
# w5: people posted and the desk got a file. w6: one post only. e2e: a test workspace.
for w in w4 w5 w6 e2e; do
  mkdir -p "$T/state/desk/$w/box-desk/spool/c-002/inbox" "$T/state/desk/$w/box-desk/spool/c-002/archive"
done
touch -d '1 day ago' "$T/state/desk/w4/box-desk/spool/c-002/inbox/old.json"
touch "$T/state/desk/w5/box-desk/spool/c-002/archive/new.json"
printf 'chan|lobby\nsub|lobby|box-desk|c-002|invite\nsub|lobby|box-desk|c-003|invite\nhum|5|3\n' >"$SUBS/w4.txt"
printf 'chan|lobby\nsub|lobby|box-desk|c-002|invite\nsub|lobby|box-desk|c-003|invite\nhum|5|0\n' >"$SUBS/w5.txt"
printf 'chan|lobby\nsub|lobby|box-desk|c-002|invite\nsub|lobby|box-desk|c-003|invite\nhum|1|0\n' >"$SUBS/w6.txt"
cp "$SUBS/w4.txt" "$SUBS/e2e.txt"
run DISPATCH_TENANTS="w4 w5 w6 e2e"; rc=$?
[[ $rc -eq 0 ]] && grep -qx "SILENT w4 5 human posts in 120 min, 0 inbound files on the dispatchers' desk: the workspace receives nothing" "$T/o" &&
  grep -qx 'UNSIGNED w4 3 of 5 human posts in 120 min stored unsigned, no agent got them: no box-wui pin, see do_spl_check_box_wui_pins' "$T/o" &&
  pass "6. people post, the desk receives nothing: SILENT, and the unsigned posts named" || fail "6. w4: rc=$rc $(cat "$T/o")"
grep -qE '^(SILENT|UNSIGNED) (w5|w6|e2e) ' "$T/o" && fail "6. a healthy / quiet / test workspace was flagged: $(grep -E '^(SILENT|UNSIGNED)' "$T/o")" ||
  pass "6. a desk that received, a single post and a test workspace are not flagged"
run DISPATCH_TENANTS=w2; grep -qE '^(SILENT|UNSIGNED)' "$T/o" && fail "6. no hum line flagged w2" || pass "6. no hum line = nothing to judge"

# --- 7. spec 061 L6: a role's legacy rows go where its new id is subscribed ---------------------
mkdir -p "$T/spool"; printf 'CLE-002\tc-002\tclaude\tbox-desk\t2026-10-02T16:35:05Z\nCLE-003\tc-003\tclaude\tbox-desk\t2026-10-02T16:35:05Z\n' >"$T/spool/agent-id-aliases.tsv"
printf "chan|lobby\nchan|ops\n${ODS}sub|lobby|box-desk|c-001|invite\nsub|lobby|box-desk|c-002|invite\nsub|lobby|box-desk|c-003|invite\nsub|lobby|box-desk|CLE-002|invite\nsub|lobby|box-desk|CLE-003|invite\nsub|ops|box-desk|CLE-002|invite\n" >"$SUBS/w7.txt"
: >"$T/calls"
run DISPATCH_TENANTS=w7; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'PLAN remove w7 #lobby CLE-002 (box-desk; legacy id of c-002, which is subscribed)' "$T/o" &&
  grep -qx 'PLAN remove w7 #lobby CLE-003 (box-desk; legacy id of c-003, which is subscribed)' "$T/o" &&
  pass "7. the legacy role rows are planned for removal where the new ids are subscribed" || fail "7. legacy plan: rc=$rc $(cat "$T/o")"
grep -q 'PLAN remove w7 #ops CLE-002' "$T/o" && fail "7. a legacy row with NO new row beside it was removed" ||
  pass "7. ... and kept where the new id is not subscribed yet (#ops: add first)"
grep -qx 'PLAN add w7 #ops c-001 c-002 c-003 (box-desk)' "$T/o" && pass "7. ... #ops adds the new ids" || fail "7. ops add: $(cat "$T/o")"
grep -q '^DEAD w7 #lobby' "$T/o" && fail "7. legacy role rows reported DEAD too" || pass "7. ... not reported DEAD"
grep -q 'SUM  w7: 2 channel(s), 1 already right, 1 OD seat add(s), 2 legacy role row(s) to remove' "$T/o" &&
  pass "7. the summary counts them" || fail "7. sum: $(grep SUM "$T/o")"
run DISPATCH_TENANTS=w7 DRY_RUN=0
grep -q 'remove w7 lobby box-desk CLE-002' "$T/calls" && grep -q 'remove w7 lobby box-desk CLE-003' "$T/calls" &&
  pass "7. DRY_RUN=0 removes them through the remove op" || fail "7. calls: $(cat "$T/calls")"

# --- 8. fleet mode: every box of the lease rankings ---------------------------------------
mkdir -p "$T/spool/dispatch"
printf 'LEASE_FLEET=main\nLEASE_PRIORITY=box-desk,box-sat\nLEASE_PRIORITY_ORCH=box-sat,box-desk\n' >"$T/spool/dispatch/lease.conf"
printf "chan|lobby\n${ODS}ros|box-sat|c-001\nros|box-sat|c-002\nsub|lobby|box-desk|c-001|invite\nsub|lobby|box-desk|c-002|invite\nsub|lobby|box-desk|c-003|invite\nsub|lobby|box-sat|c-002|invite\n" >"$SUBS/w8.txt"
: >"$T/calls"
run DISPATCH_TENANTS=w8; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'PLAN add w8 #lobby c-001 (box-sat)' "$T/o" && ! grep -q 'PLAN add w8 #lobby .*(box-desk)' "$T/o" &&
  pass "8. fleet mode: the other box's rostered OD seats are added, this box's complete one is not" || fail "8. fleet plan: rc=$rc $(cat "$T/o")"
grep -qx 'UNSEATED w8 c-003@box-sat (no roster row in w8: seat it with do_spl_desk_up; report only)' "$T/o" &&
  ! grep -q 'PLAN add w8 .*c-003 (box-sat)' "$T/o" &&
  pass "8. an OD seat the workspace does not roster is reported UNSEATED, never added" || fail "8. unseated: $(cat "$T/o")"
run DISPATCH_TENANTS=w8 DRY_RUN=0
[[ "$(cat "$T/calls")" == 'add w8 lobby box-sat c-001 1' ]] && pass "8. DRY_RUN=0 adds exactly that seat" || fail "8. calls: $(cat "$T/calls")"
run DISPATCH_TENANTS=w8 DISPATCH_FLEET_BOXES=box-desk
! grep -q 'box-sat' "$T/o" && pass "8. DISPATCH_FLEET_BOXES overrides the rankings" || fail "8. override: $(cat "$T/o")"
rm -f "$T/spool/dispatch/lease.conf"

echo "dispatch-subscribe: $fails failure(s)"
[[ $fails -eq 0 ]]
