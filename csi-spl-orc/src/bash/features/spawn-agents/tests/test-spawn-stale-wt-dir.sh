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
wt() {  # DRY TITLE
  SPAWN_DRY_RUN="$1" bash -c '
    . "$1/../lib/spool-env.inc.sh"; . "$1/spawn-core.inc.sh"
    _SP_DIR="$1" WORKDIR="$2" TITLE="$3" SLUG="stale dir"
    _spawn_worktree
    echo "RESULT branch=${BRANCH} rundir=${RUNDIR}"' _ "$T_SCRIPTS" "$T_TMP/repo" "$2" 2>&1
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

# --- 3. a real worktree is still reused unchanged ----------------------------
R="$T_TMP/repo-wt/c-092"
git -C "$T_TMP/repo" worktree add -q -b c-092-old "$R" origin/master 2>/dev/null
echo wip > "$R/untracked.txt"
out="$(wt 1 c-092)"
has "reuse dry: the plan reuses it" "PLAN worktree   reuse ${R} (branch c-092-old)" "$out"
out="$(wt 0 c-092)"
has "reuse live: the old branch is kept" "RESULT branch=c-092-old rundir=${R}" "$out"
eq "reuse live: ... still on it" c-092-old "$(git -C "$R" rev-parse --abbrev-ref HEAD 2>/dev/null)"
eq "reuse live: ... its files untouched" wip "$(cat "$R/untracked.txt" 2>/dev/null)"
eq "reuse live: nothing moved aside" "" "$(ls -d "$R".stale-* 2>/dev/null)"
eq "reuse live: no new branch" "" "$(git -C "$T_TMP/repo" branch --list 'c-092-stale-dir*')"

t_done
