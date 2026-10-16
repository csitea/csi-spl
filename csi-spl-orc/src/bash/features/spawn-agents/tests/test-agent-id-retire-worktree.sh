#!/usr/bin/env bash
# agent-id-retire.sh step 7: after the window is closed and the id retired,
# the lane's worktree and branch are LISTED in the box's workdir table
# ($SPOOL_ROOT/workdirs.tsv), not removed (owner HUM-10, t1 37349c9b msg
# ec060ebc, SPL-2110: a fix after the push still needs them); the disk sweep
# (csi-spl-utl workdir-sweep.sh) removes a clean one after 24 h and keeps a
# dirty one. Earlier defect (n=3): a-526, a-528, a-530 (agy) left clean,
# landed worktrees behind when teardown was only the model's step; the
# listing keeps them reachable for the sweep the same way.
# A sandbox origin + repo + worktrees; the live repo is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
CLOSE="$T_SCRIPTS/tmux-close-window.sh"
SWEEP="$(cd "$T_FEAT/../../../../.." && pwd)/csi-spl-utl/src/bash/scripts/workdir-sweep.sh"
export CLOSE_LOG_DIR="$T_TMP/logs" RETIRE_WORKTREE=1; mkdir -p "$CLOSE_LOG_DIR"
R="$SPOOL_ROOT"
TB="$R/workdirs.tsv"
G=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master -c advice.detachedHead=false)
# sweep_at <hours after the retire clock>: the disk sweep, live, this user only
sweep_at() {
  env SPOOL_NOW="$(date -u -d "@$(( $(date -u -d "$SPOOL_NOW" +%s) + $1 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    WORKDIR_SWEEP_SUDO=0 WORKDIR_SWEEP_FREE_PCT=50 DRY_RUN=0 bash "$SWEEP" 2>&1
}
listed() { awk -F'\t' -v p="$1" -v k="$2" -v b="$3" '$1 == p && $2 == k && $5 == b { f = 1 } END { exit !f }' "$TB" 2>/dev/null; }

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

# 1. clean + landed (its commit pushed to origin/master): listed, kept 24 h.
lane c-101
"${G[@]}" -C "$WTD/c-101" commit -q --allow-empty -m landed
"${G[@]}" -C "$WTD/c-101" push -q origin HEAD:master
"${G[@]}" -C "$T_TMP/repo" fetch -q origin; "${G[@]}" -C "$T_TMP/repo" merge -q --ff-only origin/master
out="$(bash "$RET" c-101 2>&1)"
has "1. the dry run plans the listing" "PLAN worktree  list $WTD/c-101 (branch c-101-x)" "$out"
check "1. ...and writes no table" test ! -e "$TB"
bash "$RET" --apply c-101 >"$T_TMP/o" 2>&1; eq "1. retire exits 0" 0 "$?"
check "1. clean + landed: the worktree stays after the retire" test -d "$WTD/c-101"
check "1. ...and its branch" has_branch c-101-x
check "1. ...listed as a worktree with its branch" listed "$WTD/c-101" worktree c-101-x
has "1. the DO line names it" "DO worktree" "$(cat "$T_TMP/o")"
out="$(sweep_at 23)"
check "1. 23 h later the sweep keeps it" test -d "$WTD/c-101"
out="$(sweep_at 25)"
check "1. 25 h later the sweep removes it (git worktree remove)" test ! -e "$WTD/c-101"
check "1. ...and its merged branch" bash -c "! git -C '$T_TMP/repo' show-ref --verify --quiet refs/heads/c-101-x"
check "1. ...and its row" bash -c "! grep -qF '$WTD/c-101' '$TB'"

# 2. dirty (an untracked file): listed; the sweep keeps it, one line why.
lane c-102
: >"$WTD/c-102/wip.txt"
bash "$RET" --apply c-102 >"$T_TMP/o" 2>&1; eq "2. retire still exits 0" 0 "$?"
check "2. dirty: listed too" listed "$WTD/c-102" worktree c-102-x
check "2. ...the id is retired anyway" test ! -e "$R/c-102"
out="$(sweep_at 25)"
check "2. 25 h later a dirty worktree stays" test -e "$WTD/c-102/wip.txt"
check "2. ...and its branch" has_branch c-102-x
has "2. one line names why" "KEEP dirty (git status not empty; branch c-102-x not removed) worktree $WTD/c-102" "$out"

# 3. an unlanded commit, clean: the sweep removes the dir, the branch keeps the commit.
lane c-103
"${G[@]}" -C "$WTD/c-103" commit -q --allow-empty -m unlanded
bash "$RET" --apply c-103 >"$T_TMP/o" 2>&1
check "3. unlanded: the worktree stays after the retire" test -d "$WTD/c-103"
out="$(sweep_at 25)"
check "3. 25 h later the clean dir goes" test ! -e "$WTD/c-103"
check "3. ...its unmerged branch stays, with the commit" has_branch c-103-x

# 4. never the main checkout, never a dir not named for the id.
mkdir -p "$R/c-104/inbox"; printf 'c-104\tclaude\t%%1\t%s\t20261002T080000Z\n' "$T_TMP/repo" >>"$R/registry.tsv"
bash "$RET" --apply c-104 >"$T_TMP/o" 2>&1
check "4. a main checkout is never listed" bash -c "! grep -qP '^\Q$T_TMP/repo\E\t' '$TB'"
has "4. ...one line says so" "not a linked worktree" "$(cat "$T_TMP/o")"
"${G[@]}" -C "$T_TMP/repo" worktree add -q -b other "$WTD/other" origin/master >/dev/null 2>&1
mkdir -p "$R/c-105/inbox"; printf 'c-105\tclaude\t%%1\t%s\t20261002T080000Z\n' "$WTD/other" >>"$R/registry.tsv"
bash "$RET" --apply c-105 >"$T_TMP/o" 2>&1
check "4. a worktree named for another id is not listed" bash -c "! grep -qF '$WTD/other' '$TB'"

# 5. RETIRE_WORKTREE=0 (the SPOOL_TEST default) lists nothing.
lane c-106
RETIRE_WORKTREE=0 bash "$RET" --apply c-106 >/dev/null 2>&1
check "5. RETIRE_WORKTREE=0 lists nothing" bash -c "! grep -qF '$WTD/c-106' '$TB'"

# 5b. the allocator holds an id a row names (rule 6): a new lane never
#     inherits an old lane's worktree; the quarantine (rule 5) is off here.
printf '%s\tworktree\tc-150\ttb\tc-150-x\t2026-10-02T11:00:00Z\n' "$WTD/c-150" >>"$TB"
printf '149' >"$R/agent-id.cursor"
out="$(SPOOL_ID_QUARANTINE_H=0 bash "$T_SCRIPTS/next-agent-id.sh" --kind claude --no-reserve --explain 2>&1)"
has "5b. a listed id is skipped by rule 6" "skip c-150: rule 6:workdir c-150" "$out"
eq "5b. ...the next free one is chosen" c-151 "$(tail -1 <<<"$out")"

# 6. the whole /exit-clean path: tmux-close-window.sh --defer --retire, the
#    identity record's worktree (an agy lane: no registry rundir).
t_tmux
export SPOOL_BOX_TAG=tg
"${G[@]}" -C "$T_TMP/repo" worktree add -q -b a-107-x "$WTD/a-107" origin/master >/dev/null 2>&1
mkdir -p "$R/a-107/inbox" "$R/agents"
t_accepted a-107
printf '{"id":"a-107","worktree":"%s"}\n' "$WTD/a-107" >"$R/agents/a-107.json"
P="$(t_window 'tg: a-107 done' 'sleep 600')"
AGY_TMUX_PANE="$P" bash "$CLOSE" --agent a-107 --defer --retire --timeout 10 >/dev/null 2>&1; eq "6. --defer --retire returns 0" 0 "$?"
# Wait on the LAST side effect: the retire lists the worktree, then logs
# "retired" to the close log (bounded, 30 s).
for _ in $(seq 1 60); do grep -qs 'agent-id-retire: a-107 retired' "$CLOSE_LOG_DIR"/kill-your-self-close-*.log && break; sleep 0.5; done
check "6. after the close + retire the agy lane's worktree stays" test -d "$WTD/a-107"
check "6. ...listed for the disk sweep" listed "$WTD/a-107" worktree a-107-x

# CONTROL: the retire before SPL-2110 removes the clean, landed worktree at
# once (red: a fix after the push finds nothing); the new one keeps it.
fix="$(git -c safe.directory='*' -C "$T_REPO" log -1 --format=%H -S'workdir-register.sh' -- "${RET#"$T_REPO"/}" 2>/dev/null)"
ref="${fix:+${fix}^}"; ref="${ref:-HEAD}"
OLD="$T_TMP/old/src/bash/features/spawn-agents/scripts"; mkdir -p "$OLD"
ln -s "$T_FEAT/lib" "$T_TMP/old/src/bash/features/spawn-agents/lib"
ln -s "$(cd "$T_FEAT/../../../../lib" && pwd)" "$T_TMP/old/lib"
for f in desk-seat-drop.sh lane-scratch-reap.sh lane-map.sh agent-identity.py; do ln -s "$T_SCRIPTS/$f" "$OLD/$f"; done
if git -c safe.directory='*' -C "$T_REPO" show "${ref}:${RET#"$T_REPO"/}" >"$OLD/agent-id-retire.sh" 2>/dev/null \
    && grep -q 'wt_reap()' "$OLD/agent-id-retire.sh" && ! grep -q 'workdir-register' "$OLD/agent-id-retire.sh"; then
  lane c-108
  bash "$OLD/agent-id-retire.sh" --apply c-108 >/dev/null 2>&1
  check "CONTROL: the old retire ($ref) removes the clean, landed worktree at once (red)" test ! -e "$WTD/c-108"
  lane c-109
  bash "$RET" --apply c-109 >/dev/null 2>&1
  check "CONTROL: the new retire keeps the same shape (green)" test -d "$WTD/c-109"
else
  echo "skip - CONTROL: no git history for the pre-fix code here"
fi

t_done
