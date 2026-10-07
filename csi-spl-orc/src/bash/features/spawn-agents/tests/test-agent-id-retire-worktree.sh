#!/usr/bin/env bash
# agent-id-retire.sh step 7: after the window is closed and the id retired,
# the lane's worktree and branch go, ONLY when the tree is clean AND HEAD is an
# ancestor of origin/<trunk>; otherwise both stay with one line naming why.
# Defect (n=3): a-526, a-528, a-530 (agy) left clean, landed worktrees behind:
# teardown was the seed prompt's step (8), which only the model ran.
# A sandbox origin + repo + worktrees; the live repo is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
CLOSE="$T_SCRIPTS/tmux-close-window.sh"
export CLOSE_LOG_DIR="$T_TMP/logs" RETIRE_WORKTREE=1; mkdir -p "$CLOSE_LOG_DIR"
R="$SPOOL_ROOT"
G=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master -c advice.detachedHead=false)

# origin (bare), the shared checkout on master, worktrees <repo>-wt/<id>
"${G[@]}" init -q --bare "$T_TMP/origin.git"
"${G[@]}" clone -q "$T_TMP/origin.git" "$T_TMP/repo" 2>/dev/null
"${G[@]}" -C "$T_TMP/repo" commit -q --allow-empty -m base
"${G[@]}" -C "$T_TMP/repo" push -q origin HEAD:master
"${G[@]}" -C "$T_TMP/repo" fetch -q origin
WTD="$T_TMP/repo-wt"
lane() {  # ID -> a worktree on branch <ID>-x off origin/master, a registry row
  "${G[@]}" -C "$T_TMP/repo" worktree add -q -b "$1-x" "$WTD/$1" origin/master >/dev/null 2>&1
  mkdir -p "$R/$1/inbox"
  printf '%s\tclaude\t%%1\t%s\t20261002T080000Z\n' "$1" "$WTD/$1" >>"$R/registry.tsv"
}
has_branch() { "${G[@]}" -C "$T_TMP/repo" show-ref --verify --quiet "refs/heads/$1"; }

# 1. clean + landed (its commit pushed to origin/master): removed.
lane c-101
"${G[@]}" -C "$WTD/c-101" commit -q --allow-empty -m landed
"${G[@]}" -C "$WTD/c-101" push -q origin HEAD:master
out="$(bash "$RET" c-101 2>&1)"
has "1. the dry run plans the removal" "PLAN worktree" "$out"
check "1. ...and removes nothing" test -d "$WTD/c-101"
bash "$RET" --apply c-101 >"$T_TMP/o" 2>&1; eq "1. retire exits 0" 0 "$?"
check "1. clean + landed: the worktree is gone" test ! -e "$WTD/c-101"
check "1. ...and its branch" bash -c "! git -C '$T_TMP/repo' show-ref --verify --quiet refs/heads/c-101-x"
has "1. the DO line names it" "DO worktree" "$(cat "$T_TMP/o")"

# 2. dirty (an untracked file): kept, one line why.
lane c-102
: >"$WTD/c-102/wip.txt"
bash "$RET" --apply c-102 >"$T_TMP/o" 2>&1; eq "2. retire still exits 0" 0 "$?"
check "2. dirty: the worktree stays" test -e "$WTD/c-102/wip.txt"
check "2. ...and its branch" has_branch c-102-x
has "2. one line names why" "worktree $WTD/c-102 kept: dirty" "$(cat "$T_TMP/o")"
check "2. ...the id is retired anyway" test ! -e "$R/c-102"

# 3. an unlanded commit: kept.
lane c-103
"${G[@]}" -C "$WTD/c-103" commit -q --allow-empty -m unlanded
bash "$RET" --apply c-103 >"$T_TMP/o" 2>&1
check "3. unlanded: the worktree stays" test -d "$WTD/c-103"
check "3. ...and its branch" has_branch c-103-x
has "3. one line names why" "kept: HEAD is not on origin/master" "$(cat "$T_TMP/o")"

# 4. never the main checkout, never a dir not named for the id.
mkdir -p "$R/c-104/inbox"; printf 'c-104\tclaude\t%%1\t%s\t20261002T080000Z\n' "$T_TMP/repo" >>"$R/registry.tsv"
bash "$RET" --apply c-104 >"$T_TMP/o" 2>&1
check "4. a main checkout is never removed" test -d "$T_TMP/repo/.git"
has "4. ...one line says so" "not a linked worktree" "$(cat "$T_TMP/o")"
"${G[@]}" -C "$T_TMP/repo" worktree add -q -b other "$WTD/other" origin/master >/dev/null 2>&1
mkdir -p "$R/c-105/inbox"; printf 'c-105\tclaude\t%%1\t%s\t20261002T080000Z\n' "$WTD/other" >>"$R/registry.tsv"
bash "$RET" --apply c-105 >"$T_TMP/o" 2>&1
check "4. a worktree named for another id stays" test -d "$WTD/other"

# 5. RETIRE_WORKTREE=0 (the SPOOL_TEST default) touches nothing.
lane c-106
RETIRE_WORKTREE=0 bash "$RET" --apply c-106 >/dev/null 2>&1
check "5. RETIRE_WORKTREE=0 keeps a clean, landed worktree" test -d "$WTD/c-106"

# 6. the whole /exit-clean path: tmux-close-window.sh --defer --retire, the
#    identity record's worktree (an agy lane: no registry rundir).
t_tmux
export SPOOL_BOX_TAG=tg
"${G[@]}" -C "$T_TMP/repo" worktree add -q -b a-107-x "$WTD/a-107" origin/master >/dev/null 2>&1
mkdir -p "$R/a-107/inbox" "$R/agents"
printf '{"id":"a-107","worktree":"%s"}\n' "$WTD/a-107" >"$R/agents/a-107.json"
P="$(t_window 'tg: a-107 done' 'sleep 600')"
AGY_TMUX_PANE="$P" bash "$CLOSE" --agent a-107 --defer --retire --timeout 10 >/dev/null 2>&1; eq "6. --defer --retire returns 0" 0 "$?"
for _ in $(seq 1 40); do [ -e "$WTD/a-107" ] || break; sleep 0.5; done
check "6. after the close + retire the agy lane's worktree is gone" test ! -e "$WTD/a-107"
check "6. ...and its branch" bash -c "! git -C '$T_TMP/repo' show-ref --verify --quiet refs/heads/a-107-x"

# CONTROL: the code before this fix leaves the clean, landed worktree behind.
fix="$(git -c safe.directory='*' -C "$T_REPO" log -1 --format=%H -S'wt_reap()' -- "${RET#"$T_REPO"/}" 2>/dev/null)"
ref="${fix:+${fix}^}"; ref="${ref:-HEAD}"
OLD="$T_TMP/old/src/bash/features/spawn-agents/scripts"; mkdir -p "$OLD"
ln -s "$T_FEAT/lib" "$T_TMP/old/src/bash/features/spawn-agents/lib"
ln -s "$(cd "$T_FEAT/../../../../lib" && pwd)" "$T_TMP/old/lib"
if git -c safe.directory='*' -C "$T_REPO" show "${ref}:${RET#"$T_REPO"/}" >"$OLD/agent-id-retire.sh" 2>/dev/null \
    && ! grep -q 'wt_reap()' "$OLD/agent-id-retire.sh"; then
  lane c-108
  bash "$OLD/agent-id-retire.sh" --apply c-108 >/dev/null 2>&1
  check "CONTROL: the old retire ($ref) leaves the clean, landed worktree (red)" test -d "$WTD/c-108"
  lane c-109
  bash "$RET" --apply c-109 >/dev/null 2>&1
  check "CONTROL: the new retire removes the same shape (green)" test ! -e "$WTD/c-109"
else
  echo "skip - CONTROL: no git history for the pre-fix code here"
fi

t_done
