#!/usr/bin/env bash
# tmp-wt-reap.sh --unproven (SPL-6431): the /tmp trees with NO ownership
# proof, which no sweep took: agent-id named clones and worktrees (g164-r7,
# g306-s181-b12) and r<N>-* / rc<N>-* round scratch (r86-base01, rc01-scratch).
# Defect: on one box 59 such id trees (313931 inodes) and 16 round dirs (~136k)
# sat idle > 24 h on the /tmp tmpfs, one of them holding a commit that is on
# no origin ref. They go only when idle 24 h, unheld, unmounted, of no live id
# or round, and holding no commit missing from origin.
# A sandbox origin, main checkout, tmp root and spool; the real /tmp and the
# real checkout are never touched. The script's clock is pinned 25 h ahead
# (TMP_WT_NOW): a test cannot age a ctime, so every tree made here is 25 h
# old by its ctime, and `ago` sets the mtime back from that clock.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/tmp-wt-reap.sh"
UTL_RUN="$T_REPO/csi-spl-utl/src/bash/run/sweep-tmp-worktrees.func.sh"
R="$SPOOL_ROOT" O="$T_TMP/origin.git" M="$T_TMP/main" TR="$T_TMP/tmp"
NOW=$(( $(date +%s) + 25 * 3600 ))
export TMP_WT_REPO="$M" TMP_WT_ROOT="$TR" TMP_WT_SUDO=0 TMP_WT_LIVE_IDS="" TMP_WT_LIVE_LANES="" TMP_WT_NOW="$NOW"
mkdir -p "$TR"
G=(git -c user.name=t -c user.email=t@example.com -c advice.detachedHead=false)
"${G[@]}" init -q --bare "$O" && "${G[@]}" clone -q "$O" "$M" 2>/dev/null
echo a >"$M/f" && "${G[@]}" -C "$M" add f && "${G[@]}" -C "$M" commit -qm init && "${G[@]}" -C "$M" push -q origin HEAD:master 2>/dev/null
"${G[@]}" -C "$M" fetch -q origin

ago() { find "$2" -exec touch -h -d "@$(( NOW - $1 * 3600 ))" {} +; }  # HOURS PATH (by the pinned clock)
clone() { "${G[@]}" clone -q "$M" "$1" 2>/dev/null; }
commit() { echo "$2" >"$1/f" && "${G[@]}" -C "$1" commit -qam "$2"; }
reap() { bash "$REAP" --unproven "$@" 2>&1; }
snap() { find "$TR" -printf '%p %T@\n' | LC_ALL=C sort | md5sum; }
listed() { "${G[@]}" -C "$M" worktree list --porcelain | grep -xF "worktree $1" >/dev/null; }
unlisted() { ! listed "$1"; }

# 1. (a) a retired id's clean plain clone, idle 25 h: listed by the dry run,
#    removed by --apply; both spellings (g601-r7, g-602-s1).
clone "$TR/g601-r7"; clone "$TR/g-602-s1"; ago 25 "$TR/g601-r7"; ago 25 "$TR/g-602-s1"
out="$(reap)"
check "1. (a) the dry run plans the clone's removal, class and inodes" \
  grep -qE "PLAN remove [0-9]+KB class=agent-id id=g-601 inodes=[0-9]+ $TR/g601-r7\$" <<<"$out"
check "1. (a) ...the g-NNN spelling too" grep -qE "PLAN remove [0-9]+KB class=agent-id id=g-602 inodes=[0-9]+ $TR/g-602-s1\$" <<<"$out"
check "1. (a) ...and removes nothing" test -d "$TR/g601-r7/.git"
out="$(reap --apply)"; eq "1. --apply exits 0" 0 "$?"
check "1. (a) the clone is gone" test ! -e "$TR/g601-r7"
check "1. (a) ...a DO line names it" grep -qE "DO remove [0-9]+KB class=agent-id id=g-601 inodes=[0-9]+ $TR/g601-r7\$" <<<"$out"
check "1. (a) the g-NNN spelling is gone too" test ! -e "$TR/g-602-s1"

# 2. (b) the same clone with a commit on no origin ref is KEPT, reason named;
#    so is a nested worktree whose detached HEAD is on no origin ref (the
#    g164-r7 shape), while a nested clean worktree on origin goes by git.
clone "$TR/g603-r7"; commit "$TR/g603-r7" local-only; ago 25 "$TR/g603-r7"
sha="$("${G[@]}" -C "$TR/g603-r7" rev-parse HEAD)"
mkdir -p "$TR/g604-r7"
"${G[@]}" -C "$M" worktree add -q --detach "$TR/g604-r7/head" HEAD 2>/dev/null
commit "$TR/g604-r7/head" detached-only
"${G[@]}" -C "$M" worktree add -q --detach "$TR/g604-r7/master" HEAD 2>/dev/null
ago 25 "$TR/g604-r7"
mkdir -p "$TR/g605-r7" && "${G[@]}" -C "$M" worktree add -q --detach "$TR/g605-r7/master" HEAD 2>/dev/null; ago 25 "$TR/g605-r7"
out="$(reap --apply)"
check "2. (b) the clone with an unpushed commit stays" test -d "$TR/g603-r7/.git"
has "2. (b) ...KEEP unpushed, the sha named" "KEEP unpushed ${sha:0:9} in g603-r7 (on no origin ref) class=agent-id id=g-603" "$out"
check "2. (b) the tree whose nested worktree has an unpushed detached HEAD stays" test -d "$TR/g604-r7/head"
has "2. (b) ...KEEP unpushed in g604-r7/head" "in g604-r7/head (on no origin ref) class=agent-id id=g-604" "$out"
check "2. a nested clean worktree on origin goes" test ! -e "$TR/g605-r7"
check "2. ...by git: the main checkout no longer lists it" unlisted "$TR/g605-r7/master"

# 3. (c) a LIVE id's tree with a matching prefix is never touched; nor a tree
#    whose spl-owner marker names a live id.
clone "$TR/g606-x"; ago 25 "$TR/g606-x"
"${G[@]}" -C "$M" worktree add -q --detach "$TR/g607-x" HEAD 2>/dev/null
printf 'c-900\t2026-11-24T00:00:00Z\t%s\n' "$TR/g607-x" >"$M/.git/worktrees/g607-x/spl-owner"; ago 25 "$TR/g607-x"
out="$(TMP_WT_LIVE_IDS="g-606 c-900" reap --apply)"
check "3. (c) the live id's clone stays" test -d "$TR/g606-x/.git"
has "3. (c) ...KEEP live-id" "KEEP live-id g-606 class=agent-id id=g-606" "$out"
check "3. (c) a tree whose marker names a live id stays" test -f "$TR/g607-x/.git"
has "3. (c) ...KEEP live-id by the marker" "KEEP live-id c-900 (its spl-owner marker) class=agent-id id=g-607" "$out"

# 4. (d) idle 23 h is kept; (e) a process with its cwd inside keeps it.
clone "$TR/g608-x"; ago 23 "$TR/g608-x"
clone "$TR/g609-x"; ago 25 "$TR/g609-x"
( cd "$TR/g609-x" && exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/cwd")" = "$TR/g609-x" ] && break; sleep 0.1; done
out="$(reap --apply)"
check "4. (d) a tree changed 23 h ago stays" test -d "$TR/g608-x/.git"
has "4. (d) ...KEEP recent" "KEEP recent (changed in the last 24 h) class=agent-id id=g-608" "$out"
check "4. (e) a tree a process works in stays" test -d "$TR/g609-x/.git"
has "4. (e) ...KEEP in-use" "KEEP in-use (a process has its cwd or an open file under it) class=agent-id id=g-609" "$out"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null

# 5. (f) round scratch: a plain copy r86-base01 and rc01-scratch with no live
#    round lane go; r87-base01 stays while a live lane's branch names round 87.
mkdir -p "$TR/r86-base01/sub" "$TR/r87-base01" "$TR/rc01-scratch"; echo x >"$TR/r86-base01/sub/f"
ago 25 "$TR/r86-base01"; ago 25 "$TR/r87-base01"; ago 25 "$TR/rc01-scratch"
out="$(TMP_WT_LIVE_LANES="c-123-perf-round-87 perf round 87 plan" reap --apply)"
check "5. (f) r86-base01 with no live round lane is gone" test ! -e "$TR/r86-base01"
check "5. (f) ...DO line, class round" grep -qE "DO remove [0-9]+KB class=round round=86 inodes=3 $TR/r86-base01\$" <<<"$out"
check "5. (f) rc01-scratch is gone" test ! -e "$TR/rc01-scratch"
check "5. (f) r87-base01 stays while a live lane names round 87" test -d "$TR/r87-base01"
has "5. (f) ...KEEP live-round" "KEEP live-round 87 (a live lane or window names it) class=round round=87" "$out"

# 6. dirty clones: a red copy goes by --force, any other dirty one stays; an
#    id dir with no git in it is not listed at all.
clone "$TR/g610-r9-red"; echo edit >"$TR/g610-r9-red/f"; ago 25 "$TR/g610-r9-red"
clone "$TR/g611-notes"; echo edit >"$TR/g611-notes/f"; ago 25 "$TR/g611-notes"
mkdir -p "$TR/g612-logs"; ago 25 "$TR/g612-logs"
out="$(reap --apply)"
check "6. a dirty red copy is gone" test ! -e "$TR/g610-r9-red"
has "6. ...forced" "dirty red-copy --force class=agent-id id=g-610" "$out"
check "6. a dirty clone that is no red copy stays" test -f "$TR/g611-notes/f"
has "6. ...KEEP dirty" "KEEP dirty g611-notes (not a red-control or parent copy)" "$out"
hasnt "6. an id dir with no git is not listed" "$TR/g612-logs" "$out"

# 7. a clone with a worktree in another top dir: the dry run keeps the clone;
#    --apply removes the worktree first, then the clone, in one run.
clone "$TR/g613-head"; "${G[@]}" -C "$TR/g613-head" worktree add -q --detach "$TR/g613-head-wt" HEAD 2>/dev/null
ago 25 "$TR/g613-head"; ago 25 "$TR/g613-head-wt"
out="$(reap)"
has "7. the dry run keeps the clone: worktree-outside" "KEEP worktree-outside $TR/g613-head-wt (of g613-head)" "$out"
out="$(reap --apply)"
check "7. --apply removes the worktree" test ! -e "$TR/g613-head-wt"
check "7. ...and then the clone" test ! -e "$TR/g613-head"

# 8. (g) .pnpm-store is never listed, never touched.
mkdir -p "$TR/.pnpm-store/v3"; ago 25 "$TR/.pnpm-store"
out="$(reap --apply)"
hasnt "8. (g) .pnpm-store is not listed" ".pnpm-store" "$out"
check "8. (g) ...and stays" test -d "$TR/.pnpm-store/v3"

# 9. (h) the lane map unanswered, or the hub down: REFUSE, nothing removed.
clone "$TR/g614-x"; ago 25 "$TR/g614-x"
printf 'g-501\tgrok\t%%1\t%s\t20261124T000000Z\n' "$T_TMP/wt" >"$R/registry.tsv"
t_tmux
printf '#!/bin/sh\nexit 1\n' >"$T_TMP/lm-fail.sh"
printf '#!/bin/sh\necho %s\n' "'{\"hub\":\"down\",\"lanes\":[]}'" >"$T_TMP/lm-down.sh"
before="$(snap)"
out="$(env -u TMP_WT_LIVE_IDS TMP_WT_LANE_MAP="$T_TMP/lm-fail.sh" bash "$REAP" --unproven --apply 2>&1)"; eq "9. (h) lane map silent: exit 2" 2 "$?"
has "9. (h) ...REFUSE" "REFUSE the fleet lane map did not answer" "$out"
out="$(env -u TMP_WT_LIVE_IDS TMP_WT_LANE_MAP="$T_TMP/lm-down.sh" bash "$REAP" --unproven --apply 2>&1)"; eq "9. (h) hub down: exit 2" 2 "$?"
has "9. (h) ...REFUSE" "REFUSE the hub did not answer the lane map" "$out"
eq "9. (h) ...and nothing changed under the tmp root" "$before" "$(snap)"

# 10. (i) the utl action with DRY_RUN unset writes nothing and plans.
out="$(unset DRY_RUN; PROJ_PATH="$T_REPO/csi-spl-utl" TMP_WT_MODE=unproven bash -c ". '$UTL_RUN'; do_sweep_tmp_worktrees" 2>&1)"
check "10. (i) the plan names the idle clone" grep -qE "PLAN remove [0-9]+KB class=agent-id id=g-614 inodes=[0-9]+ $TR/g614-x\$" <<<"$out"
has "10. (i) ...a DONE line per class" "DONE class=round would-remove=0" "$out"
eq "10. (i) ...and nothing changed under the tmp root" "$before" "$(snap)"
out="$(PROJ_PATH="$T_REPO/csi-spl-utl" TMP_WT_MODE=bogus bash -c ". '$UTL_RUN'; do_sweep_tmp_worktrees" 2>&1)"; eq "10. a bad TMP_WT_MODE: exit 2" 2 "$?"
out="$(PROJ_PATH="$T_REPO/csi-spl-utl" TMP_WT_MODE=unproven DRY_RUN=0 bash -c ". '$UTL_RUN'; do_sweep_tmp_worktrees" 2>&1)"
check "10. DRY_RUN=0 removes it" test ! -e "$TR/g614-x"

# 11. a bare repo anywhere in a tree keeps the tree: find's `.git` prune never
#     sees one (remote.git, or a bare dir of any name), so its commits would go
#     unchecked; both classes, an id tree that holds a clean clone too.
clone "$TR/g615-b"; "${G[@]}" clone -q --bare "$M" "$TR/g615-b/remote.git" 2>/dev/null
clone "$T_TMP/w615"; commit "$T_TMP/w615" bare-only; "${G[@]}" -C "$T_TMP/w615" push -q "$TR/g615-b/remote.git" HEAD:side 2>/dev/null
mkdir -p "$TR/r88-bare" && "${G[@]}" clone -q --bare "$M" "$TR/r88-bare/store" 2>/dev/null
mkdir -p "$TR/g616-b" && "${G[@]}" clone -q --bare "$M" "$TR/g616-b/store" 2>/dev/null
ago 25 "$TR/g615-b"; ago 25 "$TR/r88-bare"; ago 25 "$TR/g616-b"
out="$(reap --apply)"
check "11. an id tree holding a bare repo stays" test -d "$TR/g615-b/remote.git/objects"
has "11. ...KEEP bare-repo, the repo named" "KEEP bare-repo g615-b/remote.git (never removed) class=agent-id id=g-615" "$out"
check "11. a round dir holding a bare repo stays" test -d "$TR/r88-bare/store/objects"
has "11. ...KEEP bare-repo" "KEEP bare-repo r88-bare/store (never removed) class=round round=88" "$out"
has "11. an id dir with only a bare repo is listed, KEEP" "KEEP bare-repo g616-b/store (never removed) class=agent-id id=g-616" "$out"

# 12. a fresh copy (cp -a, rsync -a, tar -x) keeps its old mtimes (48 h by
#     the real clock: 73 by the pinned one): its ctime
#     is now, so it is recent; the clock unpinned, the ctimes are seconds old.
mkdir -p "$TR/r89-copy/sub"; echo x >"$TR/r89-copy/sub/f"; ago 73 "$TR/r89-copy"
clone "$TR/g617-cp"; ago 73 "$TR/g617-cp"
out="$(TMP_WT_NOW="$(date +%s)" reap --apply)"
check "12. a round copy with old mtimes but a new ctime stays" test -f "$TR/r89-copy/sub/f"
has "12. ...KEEP recent" "KEEP recent (changed in the last 24 h) class=round round=89" "$out"
check "12. an id clone the same" test -d "$TR/g617-cp/.git"
has "12. ...KEEP recent" "KEEP recent (changed in the last 24 h) class=agent-id id=g-617" "$out"
out="$(TMP_WT_SUDO=1 TMP_WT_NOW="$NOW" bash "$REAP" --unproven 2>&1)"; eq "12. TMP_WT_NOW with sudo: exit 2" 2 "$?"
has "12. ...REFUSE" "REFUSE TMP_WT_NOW is for tests" "$out"

# 13. round scratch is r<N>-* / rc<N>-* or a bare r<N>: r76lib is no round.
mkdir -p "$TR/r76lib" "$TR/r90"; ago 25 "$TR/r76lib"; ago 25 "$TR/r90"
out="$(reap --apply)"
hasnt "13. r76lib is not listed" "$TR/r76lib" "$out"
check "13. ...and stays" test -d "$TR/r76lib"
check "13. a bare r90 goes" test ! -e "$TR/r90"

t_done
