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
#  11. a dirty checkout behind trunk (SPL-2490, bug round 1 row 03): staged,
#      unstaged and untracked files. While another tick holds recover.lock
#      nothing moves; then the tick saves the staged + unstaged changes to
#      refs/rescue/desk-cron/<ts>, moves to trunk, leaves the untracked file on
#      disk and cites the ref in the blocker. A trunk file an untracked file
#      would overwrite: git refuses, the work stays in the ref, still stale.
#      Sections 2-3 run with DESK_DIRTY_RECOVER=0 (the off switch).
#  12. concurrent checkouts (SPL-2672, bug round 2 row 03): a mover moves origin
#      between two SIBLING commits and runs the installers' crontab prefix 30
#      times while ticks run beside it. With the shared lock
#      (lib spl-desk-cron-lock.func.sh) no tick reports or recovers the moving
#      checkout; without it (e2f26242e, n=6) 6..14 of ~15 ticks did.
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
tick DESK_DIRTY_RECOVER=0; rc=$?
[[ $rc -eq 1 ]] && grep -q "FATAL checkout $CO is NOT on trunk: HEAD ${old:0:8}, origin/master .* 1 commit(s) behind; dirty: .*run" "$T/o" &&
  pass "2. a checkout behind trunk: FATAL with shas, count and the dirty file; exit 1" || fail "2. rc=$rc $(cat "$T/o")"
[[ "$(grep -c -- '--to O-1 --kind blocker' "$T/sent" 2>/dev/null)" == 1 ]] &&
  pass "2. the orchestrator named in lease.conf is told" || fail "2. sent: $(cat "$T/sent" 2>&1)"
grep -q 'do_spl_dispatch_lease' "$T/calls" && grep -q 'do_spl_desk_up_all' "$T/calls" &&
  pass "2. the lease ensure and the reconcile still ran" || fail "2. calls: $(cat "$T/calls")"

# --- 3. told once -----------------------------------------------------------------------
tick DESK_DIRTY_RECOVER=0; rc=$?
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

# --- 11. a dirty checkout is recovered into a rescue ref, never cleaned --------------------
g() { git -C "$CO" -c user.name=t -c user.email=t@example.com "$@"; }
rescues() { git -C "$CO" for-each-ref --format='%(refname)' refs/rescue/desk-cron/; }
printf 'a1\n' >"$CO/fa"; printf 'b1\n' >"$CO/fb"; g add fa fb; g commit -q -m files
commit trunk-next; g update-ref refs/remotes/origin/master HEAD; next="$(g rev-parse HEAD)"
g checkout -q --detach HEAD~1; old="$(g rev-parse HEAD)"
printf 'a2 staged\n' >"$CO/fa"; printf 'n staged\n' >"$CO/fn"; g add fa fn
printf 'b2 unstaged\n' >"$CO/fb"; printf 'mine\n' >"$CO/untracked.txt"
sent_before="$(wc -l <"$T/sent")"
mkdir -p "$T/state"; exec 8>"$T/state/recover.lock"; flock -n 8
tick; rc=$?
exec 8>&-
[[ $rc -eq 1 && "$(g rev-parse HEAD)" == "$old" && -z "$(rescues)" ]] && grep -q 'another tick holds' "$T/o" &&
  [[ "$(cat "$CO/fb")" == "b2 unstaged" ]] && g diff --cached --quiet -- fa; [[ $? -eq 1 ]] &&
  pass "11. another tick holds recover.lock: nothing moved, no ref, still stale" || fail "11. lock: rc=$rc $(rescues) $(cat "$T/o")"
sent_before="$(wc -l <"$T/sent")"
tick; rc=$?
ref="$(rescues)"
[[ $rc -eq 0 && "$(g rev-parse HEAD)" == "$next" && -n "$ref" && -z "$(g status --porcelain --untracked-files=no)" ]] &&
  pass "11. a dirty checkout behind trunk is moved to trunk, exit 0" || fail "11. rc=$rc head=$(g rev-parse HEAD) ref=$ref $(cat "$T/o")"
[[ "$(g show "$ref:fa")" == "a2 staged" && "$(g show "$ref:fb")" == "b2 unstaged" && "$(g show "$ref^2:fa")" == "a2 staged" &&
   "$(g show "$ref^2:fn")" == "n staged" && "$(g show "$ref^2:fb")" == "b1" && "$(g rev-parse "$ref^1")" == "$old" ]] &&
  pass "11. the rescue ref holds the staged (index) and unstaged (tree) changes on the old HEAD" || fail "11. ref $ref: $(g show --stat "$ref" 2>&1)"
[[ "$(cat "$CO/untracked.txt" 2>/dev/null)" == "mine" ]] && ! g cat-file -e "$ref:untracked.txt" 2>/dev/null &&
  pass "11. the untracked file is untouched on disk (and not in the ref)" || fail "11. untracked: $(ls -la "$CO")"
[[ "$(wc -l <"$T/sent")" == $((sent_before + 1)) ]] && tail -1 "$T/sent" | grep -- "--kind blocker .*$ref" >/dev/null &&
  ! grep -q 'NOT on trunk' "$T/o" && pass "11. the blocker cites the rescue ref" || fail "11. sent: $(tail -1 "$T/sent")"
rm -f "$CO/untracked.txt"
g checkout -q --detach "$next"; commit adds-x; g update-ref refs/remotes/origin/master HEAD
g checkout -q --detach HEAD~1; head2="$(g rev-parse HEAD)"
printf 'local x\n' >"$CO/adds-x"; printf 'a3\n' >"$CO/fa"
tick; rc=$?
ref2="$(rescues | grep -vx "$ref")"
[[ $rc -eq 1 && "$(g rev-parse HEAD)" == "$head2" && "$(cat "$CO/adds-x")" == "local x" && -n "$ref2" &&
   "$(g show "$ref2:fa")" == "a3" ]] && grep -q 'NOT on trunk' "$T/o" && tail -1 "$T/sent" | grep -- "saved to $ref2" >/dev/null &&
  pass "11. an untracked file trunk would overwrite: git refuses, file kept, work in the ref, still stale and told" ||
  fail "11. conflict: rc=$rc ref2=$ref2 $(cat "$T/o") sent: $(tail -1 "$T/sent")"
rm -f "$CO/adds-x"; g checkout -q --detach origin/master

# --- 12. concurrent checkouts are serialised with the tick (bug round 2 row 03) -----------
# Several crontab lines fetch and check out the desk-cron checkout in the same minute.
# A mover moves a bare origin's master between two SIBLING commits (neither an ancestor
# of the other) and runs the installers' crontab prefix, while ticks run alongside.
# Unserialised, a tick reads HEAD and trunk between a fetch and its checkout (or a
# half-written tree) and reports a checkout that is only moving. With the shared lock
# (spl-desk-cron-lock.func.sh) every tick judges a settled tree: no report.
C12="$T/c12" B12="$T/c12-origin.git" O12="$T/c12/$ORC_NAME"
mkdir -p "$C12" && git -c init.defaultBranch=master -C "$C12" init -q
# No auto maintenance: git 2.55 (hosted runners) packs the ~800 loose objects in the
# background after a commit, and the local clone below then copies an object file that
# is gone ("failed to copy file", no origin, k12 < 3; 3 of 60 runs on ubuntu-24.04).
git -C "$C12" config maintenance.auto false && git -C "$C12" config gc.auto 0
mkdir -p "$O12/src/bash/scripts" "$O12/src/bash/features/spawn-agents/scripts" "$O12/lib/bash/funcs"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$O12/src/bash/scripts/"
LOCK_LIB="$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-lock.func.sh"
[[ -f "$LOCK_LIB" ]] && cp "$LOCK_LIB" "$O12/lib/bash/funcs/"
cp "$O/run" "$O12/run"; sed -i '/^dirt$/d' "$O12/run"
cp "$O/src/bash/features/spawn-agents/scripts/spool-send.sh" "$O12/src/bash/features/spawn-agents/scripts/"
chmod +x "$O12/run" "$O12/src/bash/scripts/desk-reconcile-cron.sh"
g12() { git -C "$C12" -c user.name=t -c user.email=t@example.com "$@"; }
g12 add . && g12 commit -q -m base; base12="$(g12 rev-parse HEAD)"
side12() {  # <name>: a commit on base12 rewriting 400 files, so a checkout takes time
  g12 checkout -q --detach "$base12" && mkdir -p "$C12/data"
  for i in $(seq 1 400); do echo "$1 $i" >"$C12/data/f$i"; done
  g12 add data && g12 commit -q -m "$1" && g12 rev-parse HEAD
}
s_x="$(side12 x)"; s_y="$(side12 y)"
g12 branch -q -f master "$s_x"
git clone -q --bare "$C12" "$B12"
g12 remote add origin "$B12" && g12 fetch -q origin && g12 checkout -q --detach origin/master
if [[ -f "$LOCK_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$LOCK_LIB"; PRE12="$(spl_desk_cron_update_pre "$C12" master)"
else
  PRE12="cd $C12 && git fetch -q origin master && git checkout -q --detach origin/master; "
fi
(
  for i in $(seq 1 30); do
    [[ $((i % 2)) == 1 ]] && s="$s_y" || s="$s_x"
    git -C "$B12" update-ref refs/heads/master "$s"
    sh -c "${PRE12}true" >/dev/null 2>&1
  done
) & mover=$!
: >"$T/o12"; k12=0
while kill -0 "$mover" 2>/dev/null; do
  env SPOOL_ROOT="$T/spool" DESK_CRON_TOOLS=git DESK_CRON_STATE_DIR="$T/state12" HOME="$T" \
    bash "$O12/src/bash/scripts/desk-reconcile-cron.sh" >>"$T/o12" 2>&1
  k12=$((k12 + 1))
done
wait "$mover"
n12="$(grep -c 'NOT on trunk\|saved the dirty' "$T/o12")"
[[ "$n12" == 0 && "$k12" -ge 3 ]] &&
  pass "12. ticks beside 30 concurrent checkouts of two sibling commits: $k12 ticks, none reports or recovers the moving checkout" ||
  fail "12. $n12 false report(s) or recoveries in $k12 ticks beside concurrent checkouts: $(grep 'NOT on trunk\|saved the dirty' "$T/o12" | sed -n 1,3p)"

echo "desk-cron-trunk: $fails failure(s)"
[[ $fails -eq 0 ]]
