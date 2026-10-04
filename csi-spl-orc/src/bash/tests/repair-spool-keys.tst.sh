#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: 002 NFR-002 residual -- do_repair_spool_keys moves a LEGACY box
#          private key out of a keys dir inside $SPOOL_ROOT, safely.
#   1. DRY_RUN unset (dry run): prints the plan, changes nothing, never
#      prints the key
#   2. DRY_RUN=0: the key is at the target 0600 in a 0700 dir, byte-identical,
#      gone from the spool root
#   3. CONTROL: a DIFFERENT key already at the target -> refused, both kept;
#      a target inside the root -> refused; a keys dir outside the root -> no-op
#   4. an identical key already at the target -> only the source is removed
# No sudo, no network: everything under a temp dir.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/repair-spool-keys.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

KEY='c2VjcmV0LWtleS1ieXRlcy1ub3QtYS1yZWFsLWtleQ=='
# fixture: a spool root holding a legacy keys dir with box-a's key, as keygen wrote it before dab3161
fixture() {
  rm -rf "$T/root" "$T/home"; mkdir -p "$T/root/keys" "$T/home"
  (umask 077; echo "$KEY" >"$T/root/keys/box-a.key")
}
run_action() {
  env -u SPOOL_KEYS_DIR -u SPOOL_KEYS_DIR_NEW -u DRY_RUN HOME="$T/home" SPOOL_ROOT="$T/root" ACTION="$ACTION" "$@" \
    bash -c 'do_log() { echo "$*"; }; source "$ACTION"; do_repair_spool_keys' >"$T/out.log" 2>&1
}

# --- 1. dry run -------------------------------------------------------------------
fixture; run_action; rc=$?
[[ $rc -eq 0 && -f "$T/root/keys/box-a.key" && ! -e "$T/home/.spool" ]] && grep -q 'move .*box-a.key' "$T/out.log" \
  && pass "dry run (default): plan printed, nothing moved or created" || fail "dry run: rc=$rc $(cat "$T/out.log")"
! grep -qF "$KEY" "$T/out.log" && pass "the key is never printed" || fail "key content in the output"

# --- 2. move ----------------------------------------------------------------------
fixture; run_action DRY_RUN=0; rc=$?
n="$T/home/.spool/keys/box-a.key"
[[ $rc -eq 0 && -f "$n" && ! -e "$T/root/keys/box-a.key" && "$(cat "$n")" == "$KEY" ]] \
  && pass "DRY_RUN=0: the key moved out of the spool root, byte-identical" || fail "move: rc=$rc $(cat "$T/out.log")"
[[ "$(stat -c %a "$n" 2>/dev/null)" == 600 && "$(stat -c %a "$T/home/.spool/keys")" == 700 ]] \
  && pass "DRY_RUN=0: key 0600 in a 0700 dir" || fail "modes: $(stat -c %a "$n" 2>/dev/null) $(stat -c %a "$T/home/.spool/keys" 2>/dev/null)"
grep -q 'unset SPOOL_KEYS_DIR' "$T/out.log" && pass "DRY_RUN=0: says how to point the box at the new dir" || fail "no follow-up hint"
! ls -A "$T/home/.spool/keys" | grep '\.tmp$' >/dev/null && pass "no temp file left behind" || fail "temp file left"

# --- 3. CONTROLs ------------------------------------------------------------------
fixture; mkdir -p "$T/home/.spool/keys"; echo other >"$T/home/.spool/keys/box-a.key"
run_action DRY_RUN=0; rc=$?
[[ $rc -ne 0 && "$(cat "$T/root/keys/box-a.key")" == "$KEY" && "$(cat "$T/home/.spool/keys/box-a.key")" == other ]] \
  && pass "CONTROL: a different key at the target -> refused, both kept" || fail "clobber: rc=$rc $(cat "$T/out.log")"
fixture; run_action DRY_RUN=0 SPOOL_KEYS_DIR_NEW="$T/root/private"; rc=$?
[[ $rc -ne 0 && -f "$T/root/keys/box-a.key" && ! -e "$T/root/private" ]] \
  && pass "CONTROL: a target inside SPOOL_ROOT -> refused" || fail "target inside root: rc=$rc"
fixture; mkdir -p "$T/out-keys"; echo x >"$T/out-keys/box-b.key"
run_action DRY_RUN=0 SPOOL_KEYS_DIR="$T/out-keys"; rc=$?
[[ $rc -eq 0 && -f "$T/out-keys/box-b.key" && ! -e "$T/home/.spool" ]] && grep -q 'nothing to repair' "$T/out.log" \
  && pass "CONTROL: a keys dir outside the root -> no-op" || fail "outside: rc=$rc $(cat "$T/out.log")"
ln -s "$T/root" "$T/root-link"
fixture; run_action DRY_RUN=0 SPOOL_KEYS_DIR="$T/root-link/keys"; rc=$?
[[ $rc -eq 0 && ! -e "$T/root/keys/box-a.key" && -f "$T/home/.spool/keys/box-a.key" ]] \
  && pass "a keys dir reached through a symlink into the root is still repaired" || fail "symlink: rc=$rc $(cat "$T/out.log")"

# --- 4. identical copy already there ------------------------------------------------
fixture; mkdir -p "$T/home/.spool/keys"; cp "$T/root/keys/box-a.key" "$T/home/.spool/keys/"
run_action DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -e "$T/root/keys/box-a.key" && "$(cat "$T/home/.spool/keys/box-a.key")" == "$KEY" ]] \
  && pass "an identical key at the target: only the source is removed" || fail "identical: rc=$rc $(cat "$T/out.log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
