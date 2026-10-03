#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: desk-reconcile-cron.sh fails LOUDLY when its checkout is not on
#          trunk (2026-09-30: four dirty files kept the cron's checkout 27
#          commits behind for ~18 h, and the failed `git checkout` was silent).
#          A scratch git checkout with a fake origin/master; ./run and
#          spool-send.sh are stubs that record their calls.
#   1. HEAD == trunk: no FATAL, exit 0, nobody told
#   2. HEAD behind trunk (dirty file too): FATAL with both shas, the count and
#      the dirty path; the orchestrator from lease.conf told; exit 1; the
#      reconcile and the lease ensure still ran
#   3. the next tick in the same state: FATAL again, but told only once
#   4. DESK_TRUNK_CHECK=0 turns it off
#   6. a CLEAN HEAD that trunk moved past after this tick's checkout (another
#      lane's fetch, 2026-10-03) is NOT reported: exit 0, nobody told
#   7. CONTROL: the same HEAD still behind on the next tick (the checkout is
#      stuck) IS reported and told
#   8. HEAD moved by the next checkout but trunk raced again: not reported
#   9. a HEAD that is not an ancestor of trunk is reported at once
#  10. a fresh <spool root>/dispatch/lease.pause (do_spl_pool_ctl stop, spec
#      071 4.4) stops the dev AND prd tick re-taking the lease; a stale one is
#      ignored with a WARN. CONTROL: no marker, the lease is ensured
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ORC_NAME="$(basename "$PROJ_ROOT")"
CO="$T/checkout" O="$T/checkout/$ORC_NAME"
mkdir -p "$O/src/bash/scripts" "$O/src/bash/features/spawn-agents/scripts" "$T/spool/dispatch"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$O/src/bash/scripts/"
printf '#!/bin/sh\necho "run $*" >>"%s/calls"\nexit 0\n' "$T" >"$O/run"
printf '#!/bin/sh\necho "send $*" >>"%s/sent"\n' "$T" >"$O/src/bash/features/spawn-agents/scripts/spool-send.sh"
chmod +x "$O/run" "$O/src/bash/scripts/desk-reconcile-cron.sh"
echo 'LEASE_ORCH=O-1' >"$T/spool/dispatch/lease.conf"
git -C "$CO" init -q && git -C "$CO" add . && git -C "$CO" -c user.name=t -c user.email=t@example.com commit -q -m one
git -C "$CO" update-ref refs/remotes/origin/master HEAD

tick() {
  env SPOOL_ROOT="$T/spool" DESK_CRON_TOOLS=git DESK_CRON_STATE_DIR="$T/state" HOME="$T" "$@" \
    bash "$O/src/bash/scripts/desk-reconcile-cron.sh" >"$T/o" 2>&1
}

# --- 1. on trunk -----------------------------------------------------------------------
tick; rc=$?
[[ $rc -eq 0 && ! -s "$T/sent" ]] && ! grep -q 'NOT on trunk' "$T/o" &&
  pass "1. a checkout on trunk: no alarm, exit 0" || fail "1. rc=$rc $(cat "$T/o")"

# --- 2. behind trunk -------------------------------------------------------------------
old="$(git -C "$CO" rev-parse HEAD)"
echo x >"$CO/new" && git -C "$CO" add new && git -C "$CO" -c user.name=t -c user.email=t@example.com commit -q -m two
git -C "$CO" update-ref refs/remotes/origin/master HEAD
git -C "$CO" checkout -q --detach "$old"
echo dirt >>"$O/run"
: >"$T/calls"
tick; rc=$?
[[ $rc -eq 1 ]] && grep -q "FATAL checkout $CO is NOT on trunk: HEAD ${old:0:8}, origin/master .* 1 commit(s) behind; dirty: .*run" "$T/o" &&
  pass "2. a checkout behind trunk: FATAL with shas, count and the dirty file; exit 1" || fail "2. rc=$rc $(cat "$T/o")"
[[ "$(grep -c -- '--to O-1 --kind blocker' "$T/sent" 2>/dev/null)" == 1 ]] &&
  pass "2. the orchestrator named in lease.conf is told" || fail "2. sent: $(cat "$T/sent" 2>&1)"
grep -q 'do_spl_dispatch_lease' "$T/calls" && grep -q 'do_spl_desk_up_all' "$T/calls" &&
  pass "2. the lease ensure and the reconcile still ran" || fail "2. calls: $(cat "$T/calls")"

# --- 3. told once -----------------------------------------------------------------------
tick; rc=$?
[[ $rc -eq 1 && "$(grep -c -- '--to O-1' "$T/sent")" == 1 ]] && grep -q 'NOT on trunk' "$T/o" &&
  pass "3. the next tick logs it again but tells only once" || fail "3. rc=$rc sent: $(cat "$T/sent")"

# --- 4. off switch --------------------------------------------------------------------------
tick DESK_TRUNK_CHECK=0; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'NOT on trunk' "$T/o" && pass "4. DESK_TRUNK_CHECK=0 turns it off" || fail "4. rc=$rc $(cat "$T/o")"

# --- 5. the rebox pause (specs/058 6.5) -----------------------------------------------------
P="$T/spool/.desk-reconcile.dev.pause"
echo "do_spl_desk_rebox drain" >"$P"; : >"$T/calls"
tick DESK_TRUNK_CHECK=0 ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q 'desks PAUSED' "$T/o" && ! grep -q 'do_spl_desk_up_all\|do_spl_desk_up_tenants' "$T/calls" &&
  grep -q 'do_spl_dispatch_lease' "$T/calls" &&
  pass "5. a fresh pause skips the seat steps (the lease still runs)" || fail "5. rc=$rc calls: $(cat "$T/calls") $(cat "$T/o")"
: >"$T/calls"; tick DESK_TRUNK_CHECK=0 ENV=prd
grep -q 'do_spl_desk_up_all' "$T/calls" && pass "5. the pause is per env: prd still reconciles" || fail "5. prd: $(cat "$T/calls")"
touch -d '2 hours ago' "$P"; : >"$T/calls"; tick DESK_TRUNK_CHECK=0 ENV=dev
grep -q 'do_spl_desk_up_all' "$T/calls" && grep -q "WARN .*ignored" "$T/o" &&
  pass "5. a pause older than DESK_PAUSE_MAX_SECS is ignored with a WARN" || fail "5. stale pause: $(cat "$T/o")"
rm -f "$P"

# --- 10. the box lease pause (spec 071 4.4, do_spl_pool_ctl stop) --------------------------
L="$T/spool/dispatch/lease.pause"
echo "pool-ctl stop" >"$L"
for e in dev prd; do
  : >"$T/calls"; tick DESK_TRUNK_CHECK=0 ENV=$e; rc=$?
  [[ $rc -eq 0 ]] && grep -q 'lease PAUSED' "$T/o" && ! grep -q 'do_spl_dispatch_lease' "$T/calls" &&
    grep -q 'do_spl_desk_up_all' "$T/calls" &&
    pass "10. a fresh lease pause: the $e tick does not re-take the lease (the desks still reconcile)" ||
    fail "10. $e: rc=$rc calls: $(cat "$T/calls") $(cat "$T/o")"
done
touch -d '2 hours ago' "$L"; : >"$T/calls"; tick DESK_TRUNK_CHECK=0 ENV=prd
grep -q 'do_spl_dispatch_lease' "$T/calls" && grep -q "WARN .*lease.pause.*ignored" "$T/o" &&
  pass "10. a lease pause older than DESK_PAUSE_MAX_SECS is ignored with a WARN" || fail "10. stale: $(cat "$T/o")"
rm -f "$L"; : >"$T/calls"; tick DESK_TRUNK_CHECK=0 ENV=prd
grep -q 'do_spl_dispatch_lease' "$T/calls" && ! grep -q 'lease PAUSED' "$T/o" &&
  pass "10. CONTROL: no lease pause, the same tick ensures the lease" || fail "10. CONTROL: calls: $(cat "$T/calls")"

# --- 6..9. a fetch race is not a stale checkout -------------------------------------------
commit() { echo "$1" >"$CO/$1" && git -C "$CO" add "$1" && git -C "$CO" -c user.name=t -c user.email=t@example.com commit -q -m "$1"; }
git -C "$CO" checkout -q -- . && git -C "$CO" checkout -q --detach origin/master
commit three; three="$(git -C "$CO" rev-parse HEAD)"
git -C "$CO" update-ref refs/remotes/origin/master HEAD
git -C "$CO" checkout -q --detach HEAD~1
sent_before="$(wc -l <"$T/sent")"
tick; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$T/sent")" == "$sent_before" ]] && ! grep -q 'NOT on trunk' "$T/o" && grep -q 'fetch race' "$T/o" &&
  pass "6. trunk moved after this tick's checkout (clean tree): no alarm, exit 0" || fail "6. rc=$rc $(cat "$T/o")"

tick; rc=$?
[[ $rc -eq 1 && "$(wc -l <"$T/sent")" == $((sent_before + 1)) ]] && grep -q 'NOT on trunk' "$T/o" &&
  pass "7. CONTROL: the same HEAD still behind next tick (stuck checkout) is reported and told" || fail "7. rc=$rc $(cat "$T/o")"

git -C "$CO" checkout -q --detach "$three"; commit four
git -C "$CO" update-ref refs/remotes/origin/master HEAD
git -C "$CO" checkout -q --detach "$three"
tick; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'NOT on trunk' "$T/o" &&
  pass "8. HEAD moved, trunk raced again: no alarm" || fail "8. rc=$rc $(cat "$T/o")"

commit diverged
tick; rc=$?
[[ $rc -eq 1 ]] && grep -q 'NOT on trunk' "$T/o" &&
  pass "9. a HEAD that is not an ancestor of trunk is reported at once" || fail "9. rc=$rc $(cat "$T/o")"

git -C "$CO" checkout -q --detach origin/master
tick; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'NOT on trunk' "$T/o" && ! compgen -G "$T/state/behind-head.*" >/dev/null &&
  pass "9. back on trunk: no alarm, the remembered HEAD is forgotten" || fail "9b. rc=$rc $(ls "$T/state") $(cat "$T/o")"

echo "desk-cron-trunk: $fails failure(s)"
[[ $fails -eq 0 ]]
