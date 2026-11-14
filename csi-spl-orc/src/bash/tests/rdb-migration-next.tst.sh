#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_rdb_migration_next claims the next hub migration number on the
# remote, collision-free (SPL-5515).
#   1. DRY_RUN=1 (the default) prints head+1 and pushes no claim
#   2. DRY_RUN=0 claims head+1: refs/rdb-claims/NNNN exists on the remote
#   3. the next claim goes past the highest claim (head+2)
#   4. trunk moving past the claims: the next is the new head+1
#   5. RACE: 8 parallel claims from 8 clones get 8 DISTINCT numbers;
#      CONTROL: 8 parallel dry runs (the number computed with no lock)
#      all print the same one, so the check in (5) can see a collision
#   6. a claim to a remote that refuses the push is rc 1, never a number
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true
MIG="csi-spl-rdb/src/sql/postgres/spool-hub"

# act <clone> [env...] -> the action's stdout; stderr to $T/err
act() {
  local dir="$1"; shift
  env "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "'"$PROJ_ROOT"'/src/bash/run/rdb-migration-next.func.sh"
    APP_PATH="$1" do_rdb_migration_next' _ "$dir" 2>>"$T/err"
}
claims() { git -C "$T/remote.git" for-each-ref --format='%(refname:short)' 'refs/rdb-claims/' | sed 's#.*/##' | sort | tr '\n' ' ' | sed 's/ $//'; }

git init -q --bare "$T/remote.git"
git init -q "$T/w" && git -C "$T/w" remote add origin "$T/remote.git"
mkdir -p "$T/w/$MIG"
for f in 0001_a 0002_b 0003_c; do echo 'SELECT 1;' >"$T/w/$MIG/$f.sql"; done
git -C "$T/w" add -A && git -C "$T/w" commit -qm seed && git -C "$T/w" push -q origin HEAD:refs/heads/master

# 1.
got="$(act "$T/w")"
[[ "$got" == 0004 && -z "$(claims)" ]] && pass "1. dry run prints 0004 and claims nothing" || fail "1. dry run '$got' claims='$(claims)'"
# 2.
got="$(act "$T/w" DRY_RUN=0 AGENT_ID=c-999)"
[[ "$got" == 0004 && "$(claims)" == 0004 ]] && pass "2. DRY_RUN=0 claims 0004 on the remote" || fail "2. claim '$got' claims='$(claims)'"
grep -q '^agent: c-999$' <<<"$(git -C "$T/remote.git" log -1 --format=%B refs/rdb-claims/0004)" \
  && pass "2. ... the claim names its claimer" || fail "2. claimer missing: $(git -C "$T/remote.git" log -1 --format=%B refs/rdb-claims/0004)"
# 3.
got="$(act "$T/w" DRY_RUN=0)"
[[ "$got" == 0005 && "$(claims)" == "0004 0005" ]] && pass "3. the next claim is 0005" || fail "3. '$got' claims='$(claims)'"
# 4.
for f in 0004_d 0005_e 0006_f 0007_g; do echo 'SELECT 1;' >"$T/w/$MIG/$f.sql"; done
git -C "$T/w" add -A && git -C "$T/w" commit -qm head7 && git -C "$T/w" push -q origin HEAD:refs/heads/master
got="$(act "$T/w")"
[[ "$got" == 0008 ]] && pass "4. trunk at 0007 past the claims: next is 0008" || fail "4. '$got'"

# 5. one clone per claimer: the only shared state is the remote, the lock
for i in 1 2 3 4 5 6 7 8; do git clone -q "$T/remote.git" "$T/c$i"; done
for i in 1 2 3 4 5 6 7 8; do act "$T/c$i" DRY_RUN=0 >"$T/race.$i" & done; wait
race="$(cat "$T/race".* | sort | tr '\n' ' ' | sed 's/ $//')"
[[ "$race" == "0008 0009 0010 0011 0012 0013 0014 0015" ]] \
  && pass "5. RACE: 8 parallel claims got 8 distinct numbers ($race)" || fail "5. race '$race' err: $(tail -3 "$T/err")"
for i in 1 2 3 4 5 6 7 8; do act "$T/c$i" >"$T/ctl.$i" & done; wait
ctl="$(cat "$T/ctl".* | sort -u | tr '\n' ' ' | sed 's/ $//')"
[[ "$ctl" == 0016 ]] \
  && pass "5. CONTROL: 8 parallel unlocked computations all print 0016 (a collision the race check sees)" || fail "5. control '$ctl'"

# 6. a remote that refuses every push
printf '#!/bin/sh\nexit 1\n' >"$T/remote.git/hooks/pre-receive"; chmod +x "$T/remote.git/hooks/pre-receive"
got="$(act "$T/w" DRY_RUN=0)"; rc=$?
[[ "$rc" == 1 && -z "$got" ]] && grep -q 'FATAL the claim of 0016 was refused' "$T/err" \
  && pass "6. a refused push is rc 1 with no number" || fail "6. rc=$rc got='$got'"

echo "fails=$fails"
[[ "$fails" == 0 ]]
