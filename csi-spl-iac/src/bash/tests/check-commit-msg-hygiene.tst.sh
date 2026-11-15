#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5613 -- the commit MESSAGES a push carries are swept with the
#          file sweep's own patterns (the 10 ci "distribution-hygiene" Sweep
#          step, read out of the workflow), by do_check_commit_msg_hygiene,
#          by the pre-push hygiene part and by the pre-push hook itself.
#   ACTION
#   1. a clean outgoing commit body -> rc 0
#   2. a planted banned literal in an outgoing commit body -> rc 1, the output
#      names that commit's <sha>.msg and the pattern label, never the literal
#   3. the same literal in a commit already on origin/master -> not re-read
#      (origin/master..HEAD), rc 0
#   4. no range -> rc 0 (nothing to sweep); an unknown range -> REFUSED
#   PART
#   5. _pp_part_hygiene fails on the planted body (PRE_PUSH_BASE..HEAD) and
#      passes on the clean one
#   HOOK (real pushes through git into a bare remote, the real hook)
#   6. a wip-only push (the 2026-11-14 path) of the planted body -> REFUSED,
#      the stderr names the sha and the pattern, the remote ref is not made
#   7. a clean wip push, and a lane push over a remote that already holds
#      the planted commit, -> pushed (only <remote sha>..<local sha> is read)
#   8. SPL_PREPUSH_OVERRIDE=1 does not skip it, also on a poisoned shared
#      config (core.worktree in the common config; R7 g-252 W1)
#   The banned literal is assembled at run time, so this file carries none.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
for _v in $(compgen -v); do case "$_v" in SPL_PREPUSH_*|PRE_PUSH_*) unset "$_v" ;; esac; done
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-commit-msg-hygiene.func.sh"
DIST="$PROJ_ROOT/src/bash/run/check-dist-hygiene.func.sh"
PP="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
HOOK="$APP_ROOT/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
require_action "$FUNC"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# "y""sg" is the OS user the sweep bans as \bysg\b; assembled so this file is no hit
banned="y""sg"

# check <tree> <ranges> -> rc; output in $T/out
check() {
  env HYGIENE_TREE="$1" HYGIENE_MSG_RANGES="$2" HYGIENE_WORKFLOW="$WF" APP_PATH="$1" bash -c '
    do_log() { echo "$*"; }
    source "'"$DIST"'"; source "'"$FUNC"'"
    do_check_commit_msg_hygiene' >"$T/out" 2>&1
}
show() { sed 's/^/    | /' "$T/out"; }

# a repo: seed (clean) and a planted commit, both on origin/master
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q -b master
echo a >"$R/README.md"; git -C "$R" add README.md; git -C "$R" commit -qm "seed"
echo b >>"$R/README.md"; git -C "$R" commit -qam "old: run it as $banned on the box"
OLD=$(git -C "$R" rev-parse HEAD)
git -C "$R" update-ref refs/remotes/origin/master "$OLD"

# --- 1. clean outgoing body ---------------------------------------------------
echo c >>"$R/README.md"; git -C "$R" commit -qam "a clean subject" -m "a clean body line"
CLEAN=$(git -C "$R" rev-parse HEAD)
check "$R" "origin/master..HEAD"; rc=$?
[[ $rc -eq 0 ]] && pass "1. a clean outgoing commit message passes (rc 0)" || { fail "1. a clean message did NOT pass (rc=$rc)"; show; }

# --- 3. the planted commit already on origin/master is not re-read -----------
if [[ $rc -eq 0 ]] && ! grep -q "$OLD" "$T/out"; then
  pass "3. a banned literal in a commit already on origin/master is not re-read"
else
  fail "3. a commit already on origin/master was re-read"; show
fi

# --- 2. planted banned literal in an outgoing body ----------------------------
echo d >>"$R/README.md"; git -C "$R" commit -qam "a clean subject" -m "body: run it as $banned on the box"
BAD=$(git -C "$R" rev-parse HEAD)
check "$R" "origin/master..HEAD"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "\./$BAD\.msg:3" "$T/out" && grep -q 'literal OS user' "$T/out"; then
  pass "2. a planted literal in an outgoing body fails (rc=$rc), naming $BAD.msg:3 and the pattern label"
else
  fail "2. a planted literal in an outgoing body did NOT fail with sha + label (rc=$rc)"; show
fi
grep -qw "$banned" "$T/out" && { fail "2. the output prints the matched literal"; show; } \
  || pass "2. the output never prints the matched literal"
grep -q "$CLEAN" "$T/out" && fail "2. the clean commit was named too" || pass "2. only the offending commit is named"

# --- 4. no range / unknown range ----------------------------------------------
check "$R" ""; rc=$?
[[ $rc -eq 0 ]] && pass "4. no range -> rc 0, nothing to sweep" || { fail "4. no range did not pass (rc=$rc)"; show; }
check "$R" "no-such-ref..HEAD"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'nothing was swept' "$T/out" && pass "4. an unknown range is REFUSED (rc=$rc), not a vacuous pass" \
  || { fail "4. an unknown range did not refuse (rc=$rc)"; show; }

# --- 5. the pre-push hygiene part ---------------------------------------------
part() {  # <tree> -> rc of _pp_part_hygiene; output in $T/out
  ( cd "$PROJ_ROOT" && env PRE_PUSH_BASE=origin/master HYGIENE_WORKFLOW="$WF" APP_PATH="$1" bash -c '
      do_log() { echo "$*"; }
      source "'"$PP"'"; source "'"$DIST"'"; source "'"$FUNC"'"
      _pp_part_hygiene "'"$1"'"' ) >"$T/out" 2>&1
}
part "$R"; rc=$?
[[ $rc -ne 0 ]] && grep -q "\./$BAD\.msg" "$T/out" && pass "5. the hygiene part fails on the planted outgoing body (rc=$rc)" \
  || { fail "5. the hygiene part did NOT fail on the planted body (rc=$rc)"; show; }
git -C "$R" reset -q --hard "$CLEAN"
part "$R"; rc=$?
[[ $rc -eq 0 ]] && pass "5. the hygiene part passes on clean outgoing bodies" || { fail "5. the hygiene part failed on a clean tree (rc=$rc)"; show; }

# --- 6..8. the hook, on real pushes -------------------------------------------
# The lane tree carries the real action files (untracked) and a ./run that runs
# do_check_commit_msg_hygiene for real and passes any other action (the gate).
mkdir -p "$R/csi-spl-iac/src/bash/run"
cp "$FUNC" "$DIST" "$R/csi-spl-iac/src/bash/run/"
cat >"$R/csi-spl-iac/run" <<EOF
#!/usr/bin/env bash
[ "\$2" = do_check_commit_msg_hygiene ] || exit 0
do_log() { echo "\$*"; }
source "$DIST"; source "$FUNC"
HYGIENE_WORKFLOW="$WF" do_check_commit_msg_hygiene
EOF
chmod +x "$R/csi-spl-iac/run"
REM="$T/remote.git"; git init -q --bare "$REM"
git -C "$R" push -q --no-verify "$REM" "$OLD:refs/heads/master"
git -C "$R" fetch -q "$REM" "+refs/heads/master:refs/remotes/rem/master"
push() {  # <env...> -- <refspec...> -> rc; stderr in $T/out
  local -a e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  ( cd "$R" && env "${e[@]}" SPL_PREPUSH_LOG_DIR="$T/log" git -c core.hooksPath="$(dirname "$HOOK")" push -q rem "$@" ) >"$T/out" 2>&1
}
git -C "$R" remote add rem "$REM"
echo e >>"$R/README.md"; git -C "$R" commit -qam "wip" -m "body: run it as $banned on the box"
WBAD=$(git -C "$R" rev-parse HEAD)
push X=1 -- "$WBAD:refs/heads/wip/c-999-x"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "\./$WBAD\.msg:3" "$T/out" && grep -q 'literal OS user' "$T/out" \
   && ! git -C "$REM" rev-parse -q --verify refs/heads/wip/c-999-x >/dev/null; then
  pass "6. a wip-only push of a planted body is REFUSED, naming $WBAD.msg:3 and the pattern; nothing reached the remote"
else
  fail "6. the wip-only push of a planted body was NOT refused with sha + label (rc=$rc)"; show
fi
grep -qw "$banned" "$T/out" && fail "6. the hook output prints the matched literal" || pass "6. the hook output never prints the matched literal"
push SPL_PREPUSH_OVERRIDE=1 -- "$WBAD:refs/heads/wip/c-999-x"; rc=$?
[[ $rc -ne 0 ]] && grep -q "$WBAD" "$T/out" && pass "8. SPL_PREPUSH_OVERRIDE=1 does not skip it" \
  || { fail "8. the override skipped the message sweep (rc=$rc)"; show; }
# R7 g-252 W1: the override on a POISONED shared config (core.worktree in the
# common config) exits before the gate; the sweep runs before that guard
git -C "$R" config core.worktree "$R"
push SPL_PREPUSH_OVERRIDE=1 -- "$WBAD:refs/heads/wip/c-999-x"; rc=$?
git -C "$R" config --unset core.worktree
[[ $rc -ne 0 ]] && grep -q "\./$WBAD\.msg:3" "$T/out" && ! git -C "$REM" rev-parse -q --verify refs/heads/wip/c-999-x >/dev/null \
  && pass "8. SPL_PREPUSH_OVERRIDE=1 on a poisoned shared config does not skip it either" \
  || { fail "8. the override on a poisoned config skipped the message sweep (rc=$rc)"; show; }
# R7 g-266 W1: core.worktree pointing at ANOTHER (empty) dir makes
# show-toplevel that dir, which has no action; the sweep must still run
mkdir -p "$T/elsewhere"
git -C "$R" config core.worktree "$T/elsewhere"
push SPL_PREPUSH_OVERRIDE=1 -- "$WBAD:refs/heads/wip/c-999-x"; rc=$?
git -C "$R" config --unset core.worktree
[[ $rc -ne 0 ]] && grep -q "\./$WBAD\.msg:3" "$T/out" && ! git -C "$REM" rev-parse -q --verify refs/heads/wip/c-999-x >/dev/null \
  && pass "8. SPL_PREPUSH_OVERRIDE=1 with core.worktree on another dir does not skip it either" \
  || { fail "8. the override with core.worktree on another dir skipped the message sweep (rc=$rc)"; show; }
grep -qw "$banned" "$T/out" && fail "8. the hook output prints the matched literal (other-dir core.worktree)" \
  || pass "8. the hook output never prints the matched literal (other-dir core.worktree)"
push X=1 -- "$CLEAN:refs/heads/wip/c-999-y"; rc=$?
[[ $rc -eq 0 ]] && pass "7. a clean wip push goes through (the remote's master holds the planted commit: not re-read)" \
  || { fail "7. a clean wip push was refused (rc=$rc)"; show; }
# the remote already holds WBAD on a ref (pushed past the hook): a lane push on top reads only the new commit
git -C "$R" push -q --no-verify rem "$WBAD:refs/heads/lane"
echo f >>"$R/README.md"; git -C "$R" commit -qam "a clean follow-up"
push X=1 -- "HEAD:refs/heads/lane"; rc=$?
[[ $rc -eq 0 ]] && pass "7. a push over a remote ref that already holds a planted commit reads only <remote sha>..<local sha>" \
  || { fail "7. a commit the remote already had was re-read (rc=$rc)"; show; }

echo
[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
