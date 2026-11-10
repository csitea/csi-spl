#!/usr/bin/env bash
# Purpose: review-worktree-sweep.sh on a throwaway repo in a mktemp dir (a
# bare origin, its clone, real git, no network), the lane map a fixture file:
#   - the refusals: a bad DRY_RUN, a REVIEW_WT_REPO that is no checkout
#   - planned: a detached worktree on an origin review/* commit (on-origin),
#     a local review/* branch whose one unpushed commit has a patch-id twin
#     on origin/master (patch-equal:1), one named for a lane that is done
#   - KEEP: not-review (a lane branch; a checkout detached on master, which
#     every review branch cut later contains), unpushed, dirty (an untracked file), locked, in-use
#     (a process cwd), live-owner (dir name = a live lane id), live-branch,
#     registry-row; owner-unknown for all when the hub did not answer
#   - the dry run removes nothing; DRY_RUN=0 removes the three planned ones
#     through git worktree remove, keeps their branches and every kept one
#   - red controls: with each keep check deleted from a copy of the script,
#     the worktree it guarded is planned
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/review-worktree-sweep.sh"
T="$(mktemp -d)"
trap 'kill "${hp:-}" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
bash -n "$SCRIPT" || { echo "FAIL bash -n"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
q() { git -C "$@" >/dev/null 2>&1; }
commit() { echo "$3" >"$1/$2"; q "$1" add "$2"; q "$1" commit -m "$2 $3"; }

git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/main" 2>/dev/null
M="$T/main"; W="$T/wt"; mkdir -p "$W"
commit "$M" base 1; q "$M" push origin master
q "$M" switch -c review/a; commit "$M" ra 1; q "$M" push origin review/a
q "$M" switch master; q "$M" branch -D review/a
q "$M" fetch origin
ra="$(git -C "$M" rev-parse origin/review/a)"
for d in wt-det c-503-review wt-dirty c-501-review wt-locked wt-held wt-reg; do q "$M" worktree add --detach "$W/$d" "$ra"; done
q "$M" worktree add -b review/b "$W/wt-br" origin/master; commit "$W/wt-br" pb 1
q "$M" cherry-pick -x "$(git -C "$W/wt-br" rev-parse HEAD)"; q "$M" push origin master; q "$M" fetch origin
q "$M" worktree add -b review/c "$W/wt-unpushed" origin/master; commit "$W/wt-unpushed" pc 1
q "$M" worktree add -b review/d "$W/wt-livebr" "$ra"
q "$M" worktree add -b c-500-feat "$W/c-500" origin/master
q "$M" worktree add --detach "$W/wt-master" "$ra~1"
echo x >"$W/wt-dirty/untracked"
q "$M" worktree lock "$W/wt-locked"
mkdir -p "$T/spool"; printf 'c-600\tclaude\t%%9\t%s\t20261001T000000Z\n' "$W/wt-reg" >"$T/spool/registry.tsv"
lanes='{"hub":"ok","lanes":[{"agent_id":"c-501","branch":"c-501-x","state":"live"},{"agent_id":"c-502","branch":"review/d","state":"live"},{"agent_id":"c-503","branch":"c-503-x","state":"done"}]}'
echo "$lanes" >"$T/lanes.json"; echo '{"hub":"down","lanes":[]}' >"$T/lanes-down.json"
(cd "$W/wt-held" && exec sleep 300) & hp=$!
sleep 0.3

run() { env REVIEW_WT_SUDO=0 REVIEW_WT_REPO="$M" REVIEW_WT_LANES="${LANES:-$T/lanes.json}" SPOOL_ROOT="$T/spool" "$@" bash "${S:-$SCRIPT}" >"$T/out" 2>&1; }
has() { grep -qE -- "$1" "$T/out"; }

run DRY_RUN=2; [[ $? == 2 ]] && has REFUSE && pass "1. a bad DRY_RUN is refused" || fail "1. DRY_RUN=2 ($(cat "$T/out"))"
mkdir -p "$T/nogit"; env REVIEW_WT_SUDO=0 REVIEW_WT_REPO="$T/nogit" bash "$SCRIPT" >"$T/out" 2>&1
[[ $? == 2 ]] && has REFUSE && pass "1. a repo that is no checkout is refused" || fail "1. no checkout ($(cat "$T/out"))"

run; rc=$?
[[ $rc == 0 ]] && pass "2. dry run exits 0" || fail "2. dry run rc=$rc ($(tail -3 "$T/out"))"
has "PLAN remove [0-9]+MB $W/wt-det branch=detached ref=origin/review/a proof=on-origin$" && pass "2. a detached worktree on origin review/a is planned (on-origin)" || fail "2. wt-det ($(grep wt-det "$T/out"))"
has "PLAN remove [0-9]+MB $W/c-503-review branch=detached " && pass "2. a done lane's id owns nothing (c-503-review planned)" || fail "2. c-503-review ($(grep c-503 "$T/out"))"
has "PLAN remove [0-9]+MB $W/wt-br branch=review/b ref=review/b proof=patch-equal:1$" && pass "2. an unpushed commit with a patch twin on master is planned (patch-equal:1)" || fail "2. wt-br ($(grep wt-br "$T/out"))"
for e in "not-review -MB $W/c-500" "not-review -MB $W/wt-master" "unpushed [0-9a-f]{12} [0-9]+MB $W/wt-unpushed" "dirty [0-9]+MB $W/wt-dirty" \
  "locked [0-9]+MB $W/wt-locked" "in-use [0-9]+MB $W/wt-held" "live-owner c-501 [0-9]+MB $W/c-501-review" \
  "live-branch review/d [0-9]+MB $W/wt-livebr" "registry-row [0-9]+MB $W/wt-reg"; do
  has "KEEP $e$" && pass "3. KEEP ${e%% *}" || fail "3. KEEP $e ($(grep "${e##* }" "$T/out"))"
done
has "DONE would-remove=3 " && pass "2. the dry run counts 3" || fail "2. count ($(tail -1 "$T/out"))"
[[ -d "$W/wt-det" && -d "$W/wt-br" ]] && pass "2. the dry run removed nothing" || fail "2. the dry run removed something"

LANES="$T/lanes-down.json" run
has "DONE would-remove=0 " && has "KEEP owner-unknown [0-9]+MB $W/wt-det$" && pass "4. hub silent: every worktree is kept (owner-unknown)" || fail "4. hub down ($(grep -E 'wt-det|DONE' "$T/out"))"

# control <label> <sed -E script> <worktree>: with that check cut from a copy
# of the script, the guarded worktree is planned
control() {
  sed -E "$2" "$SCRIPT" >"$T/ctl.sh"
  if cmp -s "$SCRIPT" "$T/ctl.sh"; then fail "5. control $1: pattern matched nothing"; return; fi
  S="$T/ctl.sh" run
  has "PLAN remove [0-9]+MB $W/$3 " && pass "5. control: without the $1 check, $3 is planned" || fail "5. control $1 ($(grep "$3" "$T/out"))"
}
control review 's/\[\[ "\$br" == review\/\* \]\] && //' c-500
control on-master '/merge-base --is-ancestor HEAD origin\/master/d' wt-master
control unpushed 's/grep -qxF -- "- \$sha" <<<"\$twins" \|\|/true ||/' wt-unpushed
control dirty '/why="dirty"/d' wt-dirty
control locked '/why="locked"/d' wt-locked
control in-use '/why="in-use"/d' wt-held
control live-owner '/why="live-owner/d' c-501-review
control live-branch '/why="live-branch/d' wt-livebr
control registry-row '/why="registry-row"/d' wt-reg

run DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && pass "6. real run exits 0" || fail "6. real run rc=$rc ($(tail -3 "$T/out"))"
[[ ! -e "$W/wt-det" && ! -e "$W/wt-br" && ! -e "$W/c-503-review" ]] && has "REMOVE [0-9]+MB $W/wt-det " && pass "6. the three planned worktrees are removed" || fail "6. not removed ($(ls "$W"))"
grep -qF "$W/wt-det" <<<"$(git -C "$M" worktree list --porcelain)" && fail "6. git still lists wt-det" || pass "6. git no longer lists them (git worktree remove)"
git -C "$M" rev-parse -q --verify refs/heads/review/b >/dev/null && pass "6. the branch review/b stays" || fail "6. review/b deleted"
for d in c-500 wt-master wt-unpushed wt-dirty wt-locked wt-held c-501-review wt-livebr wt-reg; do
  [[ -d "$W/$d" ]] || fail "6. kept worktree $d was removed"
done
[[ -f "$W/wt-dirty/untracked" ]] && pass "6. every kept worktree is still there" || fail "6. untracked file lost"
has "DONE removed=3 " && pass "6. the real run counts 3" || fail "6. count ($(tail -1 "$T/out"))"

echo "review-worktree-sweep: ${fails} failure(s)"
[[ "$fails" -eq 0 ]]
