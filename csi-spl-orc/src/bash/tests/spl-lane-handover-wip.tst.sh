#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_handover_wip (t1 ba8104f6), offline: a bare repo plays
#          origin, a clone plays the lane's worktree.
#   1. DRY_RUN is the default: the plan line, nothing on origin
#   2. DRY_RUN=0: the wip ref carries tracked + untracked changes on HEAD,
#      parent = HEAD, the repo's author, no trailer; the lane's HEAD, index
#      and files are untouched; an unpushed local commit rides along
#   3. a second run with the same tree reuses the ref; another tree = exit 4
#   4. RED CONTROL: key material in the WIP -> exit 3, the file NAMED, its
#      bytes never printed, NOTHING pushed
#   5. a 0600 file, a bank credential file and key material inside an
#      unpushed commit (not the WIP) are refused the same way
#   6. CONTROL: with the scanner stubbed to pass, the same planted file IS
#      pushed: the refusal in 4 comes from the scan, not from the setup
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v zstd >/dev/null && command -v jq >/dev/null || { echo "SKIP: no zstd or jq"; exit 0; }

export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME"
git config --global init.defaultBranch master
git config --global safe.directory '*'
# the key header is built at run time: no-key-material-in-tree.tst.sh scans this file
KEYLINE="$(printf -- '-----%s %s %s-----' BEGIN PRIVATE KEY)"
SECRET="Zm9vYmFy$RANDOM$RANDOM"

# new_lane <name> -> $T/<name>/{origin.git,wt}: one commit on master, pushed
new_lane() {
  local d="$T/$1"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/wt" 2>/dev/null
  git -C "$d/wt" config user.name "FirstName LastName"
  git -C "$d/wt" config user.email "owner@example.com"
  echo base >"$d/wt/a.txt"
  git -C "$d/wt" add a.txt && git -C "$d/wt" commit -qm base && git -C "$d/wt" push -q origin master
  git -C "$d/wt" remote set-head origin master >/dev/null
}
run_wip() {  # <lane> [VAR=value]...
  local lane="$1"; shift
  SNIPPET=do_spl_lane_handover_wip in_orc SPOOL_ROOT="$T/spool" ID=c-050 WIP_WORKTREE="$T/$lane/wt" "$@" >"$T/o" 2>&1
}
remote_ref() { git -C "$T/$1/origin.git" rev-parse -q --verify refs/heads/wip/handover/c-050 2>/dev/null; }

# --- 1. dry run by default --------------------------------------------------------------
new_lane l1
echo wip >>"$T/l1/wt/a.txt"; echo new >"$T/l1/wt/untracked.txt"
run_wip l1; rc=$?
[[ $rc -eq 0 ]] && grep -q '^PLAN HANDOVER-WIP c-050' "$T/o" && [[ -z "$(remote_ref l1)" ]] &&
  pass "1: DRY_RUN default: the plan, nothing on origin" || fail "1: rc=$rc $(cat "$T/o")"

# --- 2. the push ------------------------------------------------------------------------
echo local >"$T/l1/wt/b.txt"; git -C "$T/l1/wt" add b.txt; git -C "$T/l1/wt" commit -qm "unpushed local"
echo wip2 >"$T/l1/wt/c.txt"
head="$(git -C "$T/l1/wt" rev-parse HEAD)"; before="$(git -C "$T/l1/wt" status --porcelain)"
run_wip l1 DRY_RUN=0; rc=$?
sha="$(remote_ref l1)"
[[ $rc -eq 0 && -n "$sha" ]] && grep -q "^OK HANDOVER-WIP c-050 sha=$sha ref=refs/heads/wip/handover/c-050 files=4" "$T/o" &&
  pass "2a: pushed to refs/heads/wip/handover/c-050, 4 files past origin/master" || fail "2a: rc=$rc sha=$sha $(cat "$T/o")"
O="$T/l1/origin.git"
[[ "$(git -C "$O" rev-parse "$sha^")" == "$head" ]] && pass "2b: parent = the lane's HEAD (the unpushed commit rides along)" || fail "2b: parent"
[[ "$(git -C "$O" show "$sha:untracked.txt")" == new && "$(git -C "$O" show "$sha:c.txt")" == wip2 && "$(git -C "$O" show "$sha:a.txt")" == $'base\nwip' ]] &&
  pass "2c: tracked + untracked changes are in the commit" || fail "2c: tree content"
[[ "$(git -C "$O" log -1 --format='%an <%ae>|%cn <%ce>' "$sha")" == "FirstName LastName <owner@example.com>|FirstName LastName <owner@example.com>" ]] &&
  ! grep -qiE '^(Co-Authored-By|Claude-Session|Generated with)' <<<"$(git -C "$O" log -1 --format=%B "$sha")" &&
  pass "2d: the repo's author and committer, no trailer" || fail "2d: $(git -C "$O" log -1 --format='%an %ae %B' "$sha")"
[[ "$(git -C "$T/l1/wt" rev-parse HEAD)" == "$head" && "$(git -C "$T/l1/wt" status --porcelain)" == "$before" ]] &&
  pass "2e: the lane's HEAD, index and files are untouched" || fail "2e: lane changed"

# --- 3. idempotent; another tree refused ------------------------------------------------
run_wip l1 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(remote_ref l1)" == "$sha" ]] && grep -q 'already there' "$T/o" &&
  pass "3a: same tree again: the ref is reused" || fail "3a: rc=$rc $(cat "$T/o")"
echo more >>"$T/l1/wt/c.txt"
run_wip l1 DRY_RUN=0; rc=$?
[[ $rc -eq 4 && "$(remote_ref l1)" == "$sha" ]] && pass "3b: another tree: exit 4, the ref is not rewritten" || fail "3b: rc=$rc $(cat "$T/o")"

# --- 4. RED CONTROL: key material in the WIP --------------------------------------------
new_lane l4
printf '%s\n%s\n' "$KEYLINE" "$SECRET" >"$T/l4/wt/notes.txt"
run_wip l4 DRY_RUN=0; rc=$?
[[ $rc -eq 3 ]] && grep -qx 'HIT notes.txt key' "$T/o" && pass "4a: key material: exit 3, the file named" || fail "4a: rc=$rc $(cat "$T/o")"
[[ -z "$(remote_ref l4)" ]] && pass "4b: nothing pushed when the scan fails" || fail "4b: a ref was pushed"
! grep -qF "$SECRET" "$T/o" && pass "4c: the bytes are never printed" || fail "4c: leaked"

# --- 5. 0600, a bank credential file, key material in an unpushed commit -----------------
new_lane l5
echo x >"$T/l5/wt/plain.txt"; chmod 600 "$T/l5/wt/plain.txt"
run_wip l5 DRY_RUN=0; rc=$?
[[ $rc -eq 3 && -z "$(remote_ref l5)" ]] && grep -qx 'HIT plain.txt 0600' "$T/o" && pass "5a: a 0600 file is refused" || fail "5a: rc=$rc $(cat "$T/o")"
rm -f "$T/l5/wt/plain.txt"; echo x >"$T/l5/wt/bank-credentials.json"
run_wip l5 DRY_RUN=0; rc=$?
[[ $rc -eq 3 && -z "$(remote_ref l5)" ]] && grep -qx 'HIT bank-credentials.json cred' "$T/o" && pass "5b: a bank credential file is refused" || fail "5b: rc=$rc $(cat "$T/o")"
rm -f "$T/l5/wt/bank-credentials.json"
printf '%s\n' "$KEYLINE" >"$T/l5/wt/k.txt"; git -C "$T/l5/wt" add k.txt; git -C "$T/l5/wt" commit -qm k
run_wip l5 DRY_RUN=0; rc=$?
[[ $rc -eq 3 && -z "$(remote_ref l5)" ]] && grep -qx 'HIT k.txt key' "$T/o" && pass "5c: key material in an unpushed commit is refused" || fail "5c: rc=$rc $(cat "$T/o")"

# --- 6. CONTROL: the scan is the verdict ------------------------------------------------
printf '#!/bin/sh\nexit 0\n' >"$T/pass-scan.sh"
run_wip l4 DRY_RUN=0 HANDOVER_PACK_SH="$T/pass-scan.sh"; rc=$?
[[ $rc -eq 0 && -n "$(remote_ref l4)" ]] && pass "6: CONTROL: with the scan stubbed to pass, the planted file is pushed" || fail "6: CONTROL rc=$rc $(cat "$T/o")"

echo "spl-lane-handover-wip: $fails failure(s)"
[[ $fails -eq 0 ]]
