#!/usr/bin/env bash
# SPL-2281: a spawn reuses "<repo>-wt/<TITLE>" only when it is a git work
# tree. A reused retired id whose worktree the 24 h sweep removed, but whose
# dir (holding only .claude/) stayed, spawned with no worktree and no branch
# (c-293@sat, c-298@sat, 2026-10-16). The leftover dir is moved aside to
# "<dir>.stale-<UTC>", never deleted, and a fresh worktree is made.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null
git -C "$T_TMP/repo" fetch -q origin 2>/dev/null

# _spawn_worktree on its own, live or dry: prints the plan, then the result.
wt() {  # DRY TITLE [SLUG]
  SPAWN_DRY_RUN="$1" bash -c '
    . "$1/../lib/spool-env.inc.sh"; . "$1/spawn-core.inc.sh"
    _SP_DIR="$1" WORKDIR="$2" TITLE="$3" SLUG="$4"
    _spawn_worktree
    echo "RESULT branch=${BRANCH} rundir=${RUNDIR}"' _ "$T_SCRIPTS" "$T_TMP/repo" "$2" "${3:-stale dir}" 2>&1
}
is_wt() { [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; }

# --- 1. a .claude-only leftover dir: dry run plans the move, touches nothing --
W="$T_TMP/repo-wt/c-091"
mkdir -p "$W/.claude" && echo transcript > "$W/.claude/marker"
out="$(wt 1 c-091)"
has "dry: the plan says the leftover dir is moved aside" "PLAN worktree   stale ${W}: not a git work tree, move to ${W}.stale-" "$out"
has "dry: ... and a fresh worktree is added" "PLAN worktree   add ${W} -b c-091-stale-dir origin/master" "$out"
hasnt "dry: ... never a reuse" "reuse ${W}" "$out"
eq "dry: the leftover dir is untouched" transcript "$(cat "$W/.claude/marker" 2>/dev/null)"
eq "dry: nothing moved aside" "" "$(ls -d "$W".stale-* 2>/dev/null)"

# --- 2. the same dir, live: a real worktree on its own branch ----------------
out="$(wt 0 c-091)"
check "live: ${W} is a git work tree" is_wt "$W"
eq "live: ... on its own branch" c-091-stale-dir "$(git -C "$W" rev-parse --abbrev-ref HEAD 2>/dev/null)"
has "live: the result names that branch" "RESULT branch=c-091-stale-dir rundir=${W}" "$out"
stale="$(ls -d "$W".stale-* 2>/dev/null)"
eq "live: exactly one dir moved aside" 1 "$(printf '%s' "$stale" | grep -c .)"
eq "live: ... it keeps the transcript" transcript "$(cat "$stale/.claude/marker" 2>/dev/null)"
has "live: ... named by its UTC time" "$W.stale-20" "$stale"

# --- 3. a reused worktree, clean: the NEW lane's branch, off trunk ----------
# c-770 (c-001 msg e97c945e, 2026-10-17): the respawn kept the previous
# life's branch, the lane map row carried it while the agent worked on its
# own one. The old branch and its commits stay, the dir is reused (SPL-2281).
R="$T_TMP/repo-wt/c-092"
git -C "$T_TMP/repo" worktree add -q -b c-092-old "$R" origin/master 2>/dev/null
git -C "$R" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m "old life wip"
old_tip="$(git -C "$R" rev-parse HEAD)"
echo wip > "$R/untracked.txt"
out="$(wt 1 c-092)"
has "reuse dry: the plan reuses it" "PLAN worktree   reuse ${R} (branch c-092-old -> c-092-stale-dir off origin/master)" "$out"
eq "reuse dry: ... still on the old branch" c-092-old "$(git -C "$R" rev-parse --abbrev-ref HEAD 2>/dev/null)"
out="$(wt 0 c-092)"
has "reuse live: the result names the new lane's branch" "RESULT branch=c-092-stale-dir rundir=${R}" "$out"
eq "reuse live: ... the worktree is on it" c-092-stale-dir "$(git -C "$R" rev-parse --abbrev-ref HEAD 2>/dev/null)"
eq "reuse live: ... off trunk, not the old life's tip" "$(git -C "$T_TMP/repo" rev-parse origin/master)" "$(git -C "$R" rev-parse HEAD)"
eq "reuse live: the old branch keeps its commit" "$old_tip" "$(git -C "$T_TMP/repo" rev-parse c-092-old 2>/dev/null)"
eq "reuse live: ... untracked files untouched" wip "$(cat "$R/untracked.txt" 2>/dev/null)"
eq "reuse live: nothing moved aside" "" "$(ls -d "$R".stale-* 2>/dev/null)"

# --- 4. the same lane again: its own branch is kept, no "-2" -----------------
out="$(wt 0 c-092)"
has "same slug: the branch is kept" "RESULT branch=c-092-stale-dir rundir=${R}" "$out"
eq "same slug: no second branch" "" "$(git -C "$T_TMP/repo" branch --list 'c-092-stale-dir-*')"

# --- 5. tracked edits of the old life: never carried, the old branch stays ---
D="$T_TMP/repo-wt/c-093"
git -C "$T_TMP/repo" worktree add -q -b c-093-old "$D" origin/master 2>/dev/null
echo a > "$D/f.txt" && git -C "$D" add f.txt
out="$(wt 0 c-093)"
has "dirty: a WARN names the kept branch" "WARN: ${D} has tracked changes on c-093-old" "$out"
has "dirty: the result is the branch the tree is really on" "RESULT branch=c-093-old rundir=${D}" "$out"
eq "dirty: ... no new branch" "" "$(git -C "$T_TMP/repo" branch --list 'c-093-stale-dir*')"
# --- 6. a lane handover (lane-handover.md 5B): <TO>-handover AT the WIP ref,
# spawned with slug "handover", stays on that ref --------------------------
H="$T_TMP/repo-wt/c-094"
git -C "$T_TMP/repo" worktree add -q -b c-094-handover "$H" origin/master 2>/dev/null
git -C "$H" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m "wip handover"
wip="$(git -C "$H" rev-parse HEAD)"
out="$(wt 0 c-094 handover)"
has "handover: the branch is kept" "RESULT branch=c-094-handover rundir=${H}" "$out"
eq "handover: ... at the WIP commit" "$wip" "$(git -C "$H" rev-parse HEAD)"

t_done
