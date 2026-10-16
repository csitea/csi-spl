#!/usr/bin/env bash
# test-pre-push-lane-push.sh (SPL-2211) — the pre-push hook REFUSES a lane's
# hand `git push` to master within a second, before the gate, and lets
# do_spl_push_master's own (marked) push reach the gate. Real `git push` into a
# bare temp remote with the hook as core.hooksPath; the scratch repo carries
# the real spl-push-master.func.sh (the hook sources it from the tree) and a
# STUB gate (csi-spl-iac/run) that records that it ran.
#   1. a lane worktree (c-999) hand-pushes master    -> REFUSED < 2 s, gate not run
#   2. ... with SPL_PREPUSH_OVERRIDE=1                -> still REFUSED
#   3. ... the worker's marked push (lock held)       -> the gate runs, pushed
#   4. ... the token copied, no worker holds the lock -> REFUSED
#   5. ... a wrong token                              -> REFUSED
#   6. ... a lane push to review/* and wip/*          -> not asked (as today)
#   7. the main checkout hand-pushes master           -> the gate runs (as today)
#   8. a linked worktree not named after an agent     -> the gate runs (as today)
#   9. CONTROL: the hook without the block lets the lane's hand push reach the gate
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
unset SPL_PREPUSH_OVERRIDE SPL_PUSH_MASTER_TOKEN SPL_PUSH_MASTER_STATE 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/../hooks" && pwd)/pre-push"
HELPER="$(cd "$HERE/../../../run" && pwd)/spl-push-master.func.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export SPL_PREPUSH_LOG_DIR="$ROOT/log" GATE_LOG="$ROOT/gate.log"

NEW="$ROOT/hooks-new"; OLD="$ROOT/hooks-old"; mkdir -p "$NEW" "$OLD"
install -m 0755 "$HOOK" "$NEW/pre-push"
sed '/^# A lane.s hand push to master (SPL-2211)/,/^fi$/d' "$HOOK" >"$OLD/pre-push"; chmod +x "$OLD/pre-push"
grep -q '_spl_push_master_lane_tree' "$OLD/pre-push" && fail "control hook still carries the block" || pass "control hook has no block"

git init -q --bare "$ROOT/remote.git"
M="$ROOT/main"; git clone -q "$ROOT/remote.git" "$M" 2>/dev/null
git -C "$M" checkout -q -b master
mkdir -p "$M/csi-spl-orc/src/bash/run" "$M/csi-spl-iac"; cp "$HELPER" "$M/csi-spl-orc/src/bash/run/"
printf '#!/usr/bin/env bash\necho GATE-RAN >>"$GATE_LOG"\nexit 0\n' >"$M/csi-spl-iac/run"; chmod +x "$M/csi-spl-iac/run"
git -C "$M" add csi-spl-orc csi-spl-iac; git -C "$M" commit -q -m base; git -C "$M" push -q origin master 2>/dev/null
L="$ROOT/wt/c-999"; mkdir -p "$ROOT/wt"; git -C "$M" worktree add -q -b lane "$L" origin/master 2>/dev/null
H="$ROOT/wt/scratch"; git -C "$M" worktree add -q -b human "$H" origin/master 2>/dev/null

rtip() { git -C "$ROOT/remote.git" rev-parse "$1" 2>/dev/null; }
gate() { grep -c GATE-RAN "$GATE_LOG" 2>/dev/null || true; }
push() {  # <tree> <hooksdir> [env...] -- <push args...>
  local t="$1" hd="$2"; shift 2; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : >"$GATE_LOG"; git -C "$t" fetch -q origin; git -C "$t" rebase -q origin/master >/dev/null 2>&1
  git -C "$t" commit -q --allow-empty -m "c $RANDOM"
  env "${e[@]}" git -C "$t" -c core.hooksPath="$hd" push -q origin "$@" 2>"$ROOT/err"
}
redo() { git -C "$1" reset -q --hard origin/master; }

# 1. a lane's hand push to master: refused fast, before the gate
before="$(rtip master)"; t0=$(date +%s%N)
push "$L" "$NEW" -- HEAD:master; rc=$?; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
eq "1. lane hand push to master -> refused" 1 "$(( rc != 0 ))"
grep -q 'pre-push: REFUSED -- push master only via: cd csi-spl-orc && sudo -u .* env AGENT_ID=c-999 ./run -a do_spl_push_master (returns at once; poll PUSH_CMD=status)' "$ROOT/err" \
  && pass "1. ... with the one line naming do_spl_push_master" || fail "1. ... the line" "$(cat "$ROOT/err")"
[ "$ms" -lt 2000 ] && pass "1. ... in ${ms} ms (< 2 s)" || fail "1. ... in < 2 s" "${ms} ms"
eq "1. ... the gate never ran" 0 "$(gate)"
eq "1. ... remote unchanged" "$before" "$(rtip master)"
grep -q 'REFUSE .*lane=c-999 .*not via do_spl_push_master' "$SPL_PREPUSH_LOG_DIR/pre-push.log" && pass "1. ... logged" || fail "1. ... logged"

# 2. the override does not skip it
redo "$L"; push "$L" "$NEW" SPL_PREPUSH_OVERRIDE=1 -- HEAD:master; eq "2. ... SPL_PREPUSH_OVERRIDE=1 -> still refused" 1 "$(( $? != 0 ))"
grep -q 'push master only via' "$ROOT/err" && pass "2. ... by the lane guard" || fail "2. ... by the lane guard" "$(cat "$ROOT/err")"
eq "2. ... the gate never ran" 0 "$(gate)"

# 3. the worker's push: lock held, token marked -> the gate runs, pushed
S="$ROOT/state"; mkdir -p "$S"
worker_push() {  # [token override] -- the worker's _spl_push_master_git_push, lock held
  # shellcheck source=/dev/null
  ( cd "$L" && exec 9>"$S/lock" && flock -n 9 && source "$HELPER" \
    && export PUSH_STATE="$S" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$NEW" \
    && _spl_push_master_git_push origin master "$ROOT/err" )
}
redo "$L"; : >"$GATE_LOG"; git -C "$L" commit -q --allow-empty -m worker
worker_push; eq "3. the worker's marked push -> pushed" 0 "$?"
eq "3. ... the gate ran" 1 "$(gate)"
eq "3. ... remote at the lane's HEAD" "$(git -C "$L" rev-parse HEAD)" "$(rtip master)"
[ ! -e "$S/push.token" ] && pass "3. ... the token is gone after the push" || fail "3. ... token left behind"

# 4. the env copied but no worker holds the lock -> refused
redo "$L"; echo tok4 >"$S/push.token"
push "$L" "$NEW" SPL_PUSH_MASTER_TOKEN=tok4 SPL_PUSH_MASTER_STATE="$S" -- HEAD:master; eq "4. token right, lock free -> refused" 1 "$(( $? != 0 ))"
eq "4. ... the gate never ran" 0 "$(gate)"

# 5. a wrong token, lock held -> refused
redo "$L"; echo tok5 >"$S/push.token"
( exec 9>"$S/lock"; flock -n 9; push "$L" "$NEW" SPL_PUSH_MASTER_TOKEN=nope SPL_PUSH_MASTER_STATE="$S" -- HEAD:master ); eq "5. wrong token -> refused" 1 "$(( $? != 0 ))"
rm -f "$S/push.token"

# 6. non-master refs from the lane are not asked
redo "$L"; push "$L" "$NEW" -- HEAD:refs/heads/review/r99-01; eq "6. lane push to review/* -> pushed" 0 "$?"
eq "6. ... through the gate, as today" 1 "$(gate)"
push "$L" "$NEW" -- HEAD:refs/heads/wip/c-999; eq "6. lane push to wip/* -> pushed" 0 "$?"

# 7. the main checkout's hand push: as today
push "$M" "$NEW" -- master; eq "7. main checkout hand push -> pushed" 0 "$?"
eq "7. ... through the gate" 1 "$(gate)"

# 8. a linked worktree not named after an agent: as today
push "$H" "$NEW" -- HEAD:master; eq "8. non-agent worktree hand push -> pushed" 0 "$?"
eq "8. ... through the gate" 1 "$(gate)"

# 9. CONTROL: without the block, the lane's hand push reaches the gate
redo "$L"; push "$L" "$OLD" -- HEAD:master; eq "9. CONTROL: no block -> the hand push lands" 0 "$?"
eq "9. ... after the gate ran" 1 "$(gate)"

echo "-- test-pre-push-lane-push.sh: $fails failed"
[ "$fails" -eq 0 ]
