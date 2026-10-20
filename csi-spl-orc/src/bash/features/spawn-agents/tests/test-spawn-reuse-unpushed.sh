#!/usr/bin/env bash
# SPL-2692: a respawn of the same lane (SPAWN_REUSE_ID=1, a rotation with
# slug "rotate") keeps the branch it is on when that branch has commits not
# on origin/<trunk>. A rotation moved c-594 off its brief branch onto a fresh
# "<id>-rotate" off trunk: its commits stayed behind and its running pre-push
# gate was void (c-594 note 864cb54a, 2026-10-20). A clean branch already on
# trunk still moves, and a NEW lane reusing a dir still moves (SPL-2281,
# test-spawn-stale-wt-dir.sh case 3).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
id() { git -c user.name=FirstName\ LastName -c user.email=dev@example.com "$@"; }
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && id -C "$T_TMP/repo" commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null
git -C "$T_TMP/repo" fetch -q origin 2>/dev/null

# _spawn_worktree as a rotation calls it. CORE is the spawn-core to load
# (the red control loads the pre-fix copy).
wt() {  # DRY TITLE REUSE [CORE]
  SPAWN_DRY_RUN="$1" SPAWN_REUSE_ID="$3" bash -c '
    . "$1/../lib/spool-env.inc.sh"; . "$5"
    _SP_DIR="$1" WORKDIR="$2" TITLE="$3" SLUG="$4"
    _spawn_worktree
    echo "RESULT branch=${BRANCH} rundir=${RUNDIR}"' _ "$T_SCRIPTS" "$T_TMP/repo" "$2" rotate "${4:-$T_SCRIPTS/spawn-core.inc.sh}" 2>&1
}
lane() {  # TITLE BRANCH: a lane worktree on its brief branch, off trunk
  git -C "$T_TMP/repo" worktree add -q -b "$2" "$T_TMP/repo-wt/$1" origin/master 2>/dev/null
}
head_of() { git -C "$T_TMP/repo-wt/$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }

# --- 1. one committed, unpushed commit on the brief branch: kept -----------
lane c-301 c-301-c002-build-lane-a
W="$T_TMP/repo-wt/c-301"
id -C "$W" commit -q --allow-empty -m "lane work, not pushed"
tip="$(git -C "$W" rev-parse HEAD)"
out="$(wt 1 c-301 1)"
has "unpushed dry: the plan keeps the branch" "PLAN worktree   reuse ${W} (branch c-301-c002-build-lane-a, 1 unpushed commits kept)" "$out"
out="$(wt 0 c-301 1)"
has "unpushed live: the result is the brief branch" "RESULT branch=c-301-c002-build-lane-a rundir=${W}" "$out"
eq "unpushed live: ... the worktree is still on it" c-301-c002-build-lane-a "$(head_of c-301)"
eq "unpushed live: ... at the lane's commit" "$tip" "$(git -C "$W" rev-parse HEAD)"
eq "unpushed live: no rotate branch made" "" "$(git -C "$T_TMP/repo" branch --list 'c-301-rotate*')"

# --- 2. the lane landed its work: a clean branch on trunk still moves ------
lane c-302 c-302-c002-build-lane-b
M="$T_TMP/repo-wt/c-302"
id -C "$M" commit -q --allow-empty -m "lane work, landed"
git -C "$M" push -q origin HEAD:master 2>/dev/null
git -C "$T_TMP/repo" fetch -q origin 2>/dev/null
out="$(wt 0 c-302 1)"
has "landed: the result is the rotate branch" "RESULT branch=c-302-rotate rundir=${M}" "$out"
eq "landed: ... the worktree moved to it" c-302-rotate "$(head_of c-302)"
eq "landed: ... off trunk" "$(git -C "$T_TMP/repo" rev-parse origin/master)" "$(git -C "$M" rev-parse HEAD)"

# --- 3. a NEW lane (no SPAWN_REUSE_ID) on a dir with unpushed commits moves -
lane c-303 c-303-old-life
N="$T_TMP/repo-wt/c-303"
id -C "$N" commit -q --allow-empty -m "old life wip"
old="$(git -C "$N" rev-parse HEAD)"
out="$(wt 0 c-303 0)"
has "new lane: the result is its own branch" "RESULT branch=c-303-rotate rundir=${N}" "$out"
eq "new lane: the old branch keeps its commit" "$old" "$(git -C "$T_TMP/repo" rev-parse c-303-old-life)"

# --- 4. RED control: the pre-fix _spawn_reuse_branch moves case 1 ---------
old_core="$T_TMP/spawn-core.old.inc.sh"
awk '
  /^# SPL-2692: a respawn of the SAME lane/ { skip = 1 }
  skip && /^_spawn_reuse_branch\(\)/ { skip = 0 }
  skip { next }
  /^  ahead=".*rev-list --count/ { drop = 6 }
  drop { drop--; next }
  { sub(/local cur cand n ahead/, "local cur cand n"); print }
' "$T_SCRIPTS/spawn-core.inc.sh" > "$old_core"
hasnt "control: the old copy has no unpushed check" "unpushed commits kept" "$(cat "$old_core")"
lane c-304 c-304-c002-build-lane-c
R="$T_TMP/repo-wt/c-304"
id -C "$R" commit -q --allow-empty -m "lane work, not pushed"
out="$(wt 0 c-304 1 "$old_core")"
has "control: the old code moves the lane to rotate" "RESULT branch=c-304-rotate rundir=${R}" "$out"
eq "control: ... off its brief branch" c-304-rotate "$(head_of c-304)"

t_done
