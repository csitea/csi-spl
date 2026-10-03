#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lease_rank (spec 064 L1) sets the fleet lease's per-role
#          ranking (LEASE_PRIORITY_ORCH / LEASE_PRIORITY_DISPATCH) in this
#          machine's lease.conf.
#   1. the action exists
#   2. dry run (the default) prints the diff and changes nothing, no backup
#   3. APPLY=1 sets exactly the two keys, keeps every other line and the
#      file mode, and leaves a byte-identical backup lease.conf.bak-<UTC>
#   4. idempotent: a second APPLY=1 reports OK, writes nothing, no new backup
#   5. existing ranking lines are replaced in place, never duplicated;
#      LEASE_RANK_ORCH / LEASE_RANK_DISPATCH rank one role on its own
#   6. the fleet loop reads it: spl_fleet_ids accepts the file, spl_fleet_rank
#      puts the first machine at rank 0 per role, and the loop version
#      (spl_lease_code_ver) changes, so ensure restarts the loop on it
#   7. refusals change nothing: this machine missing from a ranking (the loop
#      would refuse to start), a malformed or duplicated ranking, no ranking,
#      APPLY not 0/1, no lease.conf, a lease.conf not in fleet mode
#  Fixtures only in a mktemp root: never the live /var/spool-hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-lease-rank.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac

# --- 1. the action exists ------------------------------------------------------
[[ -f "$ACTION" ]] && pass "1. $ACTION exists" || { fail "1. $ACTION is missing"; exit 1; }

C="$T/spool/dispatch/lease.conf"
seed() {
  rm -rf "$T/spool"; mkdir -p "$T/spool/dispatch"
  printf '%s\n' LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH=c-001 LEASE_FLEET=main \
    LEASE_PRIORITY=pc,box-desk,sat LEASE_ENV=prd LEASE_TENANT=t1 ASKS_OWNER=HUM-10 "$@" >"$C"
  chmod 664 "$C"
}
# rank [env...]: run the action on machine sat
rank() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" LEASE_MACHINE=sat "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$ACTION"'"
    do_spl_lease_rank' >"$T/out" 2>&1
}
baks() { find "$T/spool/dispatch" -name 'lease.conf.bak-*' | wc -l; }
key() { sed -n "s/^$1=//p" "$C"; }

# --- 2. dry run ----------------------------------------------------------------
seed; cp "$C" "$T/orig"
rank LEASE_RANK=sat,pc,box-desk; rc=$?
[[ $rc == 0 ]] && cmp -s "$C" "$T/orig" && [[ "$(baks)" == 0 ]] &&
  grep -q '^+LEASE_PRIORITY_ORCH=sat,pc,box-desk$' "$T/out" && grep -q '^+LEASE_PRIORITY_DISPATCH=sat,pc,box-desk$' "$T/out" &&
  grep -q '^PLAN lease-conf' "$T/out" &&
  pass "2. dry run prints the diff + PLAN and changes nothing" || fail "2. rc=$rc baks=$(baks): $(cat "$T/out"; diff "$T/orig" "$C")"

# --- 3. apply ------------------------------------------------------------------
rank LEASE_RANK=sat,pc,box-desk APPLY=1; rc=$?
[[ $rc == 0 && "$(key LEASE_PRIORITY_ORCH)" == sat,pc,box-desk && "$(key LEASE_PRIORITY_DISPATCH)" == sat,pc,box-desk ]] &&
  pass "3. APPLY=1 sets both keys" || fail "3. rc=$rc: $(cat "$T/out"; cat "$C")"
diff <(grep -vE '^LEASE_PRIORITY_(ORCH|DISPATCH)=' "$C") "$T/orig" >/dev/null && [[ $(wc -l <"$C") == $(( $(wc -l <"$T/orig") + 2 )) ]] &&
  pass "3. every other line kept, in order, and only two lines added" || fail "3. $(diff "$T/orig" "$C")"
[[ "$(stat -c %a "$C")" == 664 && "$(baks)" == 1 ]] && cmp -s "$(find "$T/spool/dispatch" -name 'lease.conf.bak-*')" "$T/orig" &&
  [[ "$(find "$T/spool/dispatch" -name 'lease.conf.bak-*' -printf '%f')" =~ ^lease\.conf\.bak-[0-9]{8}T[0-9]{6}Z$ ]] &&
  [[ -z "$(find "$T/spool/dispatch" -name '.lease.conf.*')" ]] &&
  pass "3. mode kept, one byte-identical backup lease.conf.bak-<UTC>, no temp file left" ||
  fail "3. mode $(stat -c %a "$C"), baks $(baks): $(ls -A "$T/spool/dispatch")"
grep -q 'RANK orch sat,pc,box-desk, dispatch sat,pc,box-desk set on sat' "$T/spool/dispatch/lease.log" &&
  pass "3. lease.log records the change" || fail "3. lease.log: $(cat "$T/spool/dispatch/lease.log" 2>&1)"

# --- 4. idempotent -------------------------------------------------------------
cp "$C" "$T/ranked"
rank LEASE_RANK=sat,pc,box-desk APPLY=1; rc=$?
[[ $rc == 0 && "$(baks)" == 1 ]] && cmp -s "$C" "$T/ranked" && grep -q '^OK lease-conf' "$T/out" &&
  pass "4. a second APPLY=1 is OK: nothing written, no new backup" || fail "4. rc=$rc baks=$(baks): $(cat "$T/out")"

# --- 5. replace in place; one role on its own ----------------------------------
seed LEASE_PRIORITY_ORCH=pc,sat LEASE_PRIORITY_DISPATCH=pc,sat LEASE_PRIORITY_ORCH=pc,sat
rank LEASE_RANK=sat,pc LEASE_RANK_DISPATCH=pc,sat APPLY=1; rc=$?
[[ $rc == 0 && "$(grep -c '^LEASE_PRIORITY_ORCH=' "$C")" == 1 && "$(grep -c '^LEASE_PRIORITY_DISPATCH=' "$C")" == 1 &&
   "$(key LEASE_PRIORITY_ORCH)" == sat,pc && "$(key LEASE_PRIORITY_DISPATCH)" == pc,sat &&
   "$(sed -n 9p "$C")" == LEASE_PRIORITY_ORCH=sat,pc && "$(key LEASE_PRIORITY)" == pc,box-desk,sat ]] &&
  pass "5. existing lines replaced in place, duplicates dropped, LEASE_RANK_DISPATCH ranks dispatch alone, LEASE_PRIORITY untouched" ||
  fail "5. rc=$rc: $(cat "$T/out"; cat "$C")"

# --- 6. the fleet loop reads it ------------------------------------------------
seed
ver() {
  env SPOOL_ROOT="$T/spool" LEASE_MACHINE=sat bash -c '
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init ro && spl_lease_code_ver'
}
v0="$(ver)"
rank LEASE_RANK=sat,pc,box-desk APPLY=1
got="$(env SPOOL_ROOT="$T/spool" LEASE_MACHINE=sat bash -c '
  do_log() { echo "$*"; }
  source "'"$PROJ_ROOT"'/src/bash/run/spl-dispatch-lease.func.sh"
  spl_lease_init ro && spl_fleet_ids &&
    echo "$(spl_fleet_rank sat orch) $(spl_fleet_rank sat dispatch) $(spl_fleet_rank pc orch) $(spl_fleet_rank pc dispatch) $(spl_fleet_rank pc)"' 2>&1)"
[[ "$got" == "0 0 1 1 0" ]] &&
  pass "6. spl_fleet_ids accepts it; sat is rank 0 for orch and dispatch, LEASE_PRIORITY still ranks pc first" ||
  fail "6. ranks (sat-orch sat-dispatch pc-orch pc-dispatch pc-default): $got"
[[ -n "$v0" && "$(ver)" != "$v0" ]] && pass "6. the loop version changes, so ensure restarts the loop on it" ||
  fail "6. loop version $v0 -> $(ver)"

# --- 7. refusals change nothing ------------------------------------------------
refused() {
  local label="$1"; shift
  cp "$C" "$T/before"
  rank APPLY=1 "$@"; local rc=$?
  [[ $rc != 0 ]] && cmp -s "$C" "$T/before" && grep -q FATAL "$T/out" &&
    pass "7. refused, unchanged: $label" || fail "7. $label: rc=$rc $(cat "$T/out")"
}
seed
refused "this machine missing from the ranking" LEASE_RANK=pc,box-desk
refused "this machine missing from the orch ranking only" LEASE_RANK=sat,pc LEASE_RANK_ORCH=pc
refused "a malformed ranking" "LEASE_RANK=sat, pc"
refused "a machine named twice" LEASE_RANK=sat,pc,sat
refused "no ranking"
refused "APPLY=2" LEASE_RANK=sat,pc APPLY=2
[[ "$(baks)" == 0 ]] && pass "7. no refusal left a backup" || fail "7. backups: $(baks)"
seed; grep -v '^LEASE_FLEET=' "$C" >"$T/nf"; cat "$T/nf" >"$C"
refused "lease.conf not in fleet mode" LEASE_RANK=sat,pc
rm -f "$C"
rank LEASE_RANK=sat,pc APPLY=1; rc=$?
[[ $rc != 0 && ! -e "$C" ]] && grep -q FATAL "$T/out" && pass "7. refused, nothing created: no lease.conf" ||
  fail "7. no lease.conf: rc=$rc $(cat "$T/out")"

echo
[[ $fails == 0 ]] && { echo "ALL PASS: spl-lease-rank"; exit 0; }
echo "FAILED: $fails"; exit 1
