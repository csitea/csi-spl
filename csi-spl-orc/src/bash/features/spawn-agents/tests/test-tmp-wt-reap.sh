#!/usr/bin/env bash
# tmp-wt-reap.sh and agent-id-retire.sh step 8b (SPL-6347): the git worktrees
# a seat left directly under /tmp (its review checkout, its red-control copy)
# are removed at retire when proven its own, and the orphans of retired ids by
# the default-off sweep. Defect: review seats left 31 worktrees of the main
# checkout under one box's /tmp, 18 of them dirty red copies of seats already
# gone, and the tmpfs reached 99% inodes (ENOSPC for every seat): no sweep
# took a dirty one, nothing took one outside the worktree root.
# A sandbox main checkout, tmp root, spool and registry; the real /tmp and the
# real checkout are never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/tmp-wt-reap.sh" RET="$T_SCRIPTS/agent-id-retire.sh"
HOOK="$T_FEAT/hooks/post-checkout"
UTL_RUN="$T_REPO/csi-spl-utl/src/bash/run/sweep-tmp-worktrees.func.sh"
R="$SPOOL_ROOT" M="$T_TMP/main" TR="$T_TMP/tmp"
export TMP_WT_REPO="$M" TMP_WT_ROOT="$TR" TMP_WT_SUDO=0
export RETIRE_WORKTREE=0 RETIRE_DESKS=0 RETIRE_LANE=0 RETIRE_SCRATCH=0 RETIRE_SERVERS=0 RETIRE_VARTMP=0 RETIRE_TMPWT=1
mkdir -p "$TR" "$T_TMP/elsewhere"
G=(git -c user.name=t -c user.email=t@example.com)
"${G[@]}" init -q "$M" && echo a >"$M/f" && "${G[@]}" -C "$M" add f && "${G[@]}" -C "$M" commit -qm init

# wt PATH [MARKER-ID] [dirty]: a linked worktree, its spl-owner marker, an edit
wt() {
  "${G[@]}" -C "$M" worktree add -q --detach "$1" HEAD 2>/dev/null
  [ -n "${2:-}" ] && printf '%s\t2026-11-24T00:00:00Z\t%s\n' "$2" "$1" >"$("${G[@]}" -C "$1" rev-parse --absolute-git-dir)/spl-owner"
  [ "${3:-}" = dirty ] && echo reverted >"$1/f"
  return 0
}
old() { find "$1" -exec touch -h -d "@$(( $(date +%s) - 10800 ))" {} +; }  # idle 3 h
seat() {  # ID: a spool dir and a registry row, so the retire has a holder
  mkdir -p "$R/$1/inbox" "$R/$1/outbox"
  printf '%s\tgrok\t%%1\t%s\t20261124T000000Z\n' "$1" "$T_TMP/wt/$1" >>"$R/registry.tsv"
}
retired() { printf '%s\tgrok\t\t\t20261101T000000Z\t20261102T000000Z\n' "$1" >>"$R/registry.retired.tsv"; }
listed() { "${G[@]}" -C "$M" worktree list --porcelain | grep -xF "worktree $1" >/dev/null; }
unlisted() { ! listed "$1"; }

# 1. (a)+(b)+(c) the retire: its clean review tree and its OWN dirty red copy
#    go (the red copy by --force); its dirty tree that is no red copy stays.
seat g-501
wt "$TR/g-501-review" g-501; wt "$TR/g-501-red" g-501 dirty; wt "$TR/g-501-notes" g-501 dirty
out="$(bash "$RET" g-501 2>&1)"
check "1. the dry run plans the clean tree's removal" grep -qE "^PLAN tmp-wt +remove [0-9]+KB proof=marker $TR/g-501-review\$" <<<"$out"
check "1. ...and the red copy's, forced" grep -qE "^PLAN tmp-wt +remove [0-9]+KB proof=marker dirty red-copy --force $TR/g-501-red\$" <<<"$out"
check "1. ...and removes nothing" test -d "$TR/g-501-review"
bash "$RET" --apply g-501 >"$T_TMP/o" 2>&1; eq "1. retire exits 0" 0 "$?"
check "1. (a) the clean /tmp worktree is gone" test ! -e "$TR/g-501-review"
check "1. (a) ...and git no longer lists it" unlisted "$TR/g-501-review"
check "1. (b) its own dirty red copy is gone (--force)" test ! -e "$TR/g-501-red"
check "1. (b) ...a DO line names the force" grep -qE "^DO tmp-wt +remove [0-9]+KB proof=marker dirty red-copy --force $TR/g-501-red\$" "$T_TMP/o"
check "1. (c) a dirty tree that is no red copy stays" test -f "$TR/g-501-notes/f"
check "1. (c) ...KEEP dirty, never forced" grep -qF "KEEP dirty (not a red-control or parent copy: never forced) $TR/g-501-notes" "$T_TMP/o"

# 2. (d) a live id's tree is never touched: the orphan sweep keeps a retired
#    id that is live again; a retire of g-503 leaves a tree named g-503-red
#    whose marker names g-504.
retired g-502; wt "$TR/g-502-red" g-502 dirty; old "$TR/g-502-red"
out="$(TMP_WT_LIVE_IDS="g-502 c-900" bash "$REAP" --orphans --apply 2>&1)"
check "2. (d) the live id's red copy stays" test -f "$TR/g-502-red/f"
has "2. (d) ...KEEP live-id" "KEEP live-id g-502 $TR/g-502-red" "$out"
wt "$TR/g-503-red" g-504 dirty
out="$(bash "$REAP" --agent g-503 --apply 2>&1)"
check "2. (d) a matching prefix with another id's marker stays" test -f "$TR/g-503-red/f"
has "2. (d) ...KEEP marker-other" "KEEP marker-other (g-504) $TR/g-503-red" "$out"

# 3. (e) the orphan sweep with DRY_RUN unset (the utl action) writes nothing
#    and lists the plan; DRY_RUN=0 removes it.
retired g-505; wt "$TR/g505-r9-parent" g-505 dirty; old "$TR/g505-r9-parent"
out="$(unset DRY_RUN; PROJ_PATH="$T_REPO/csi-spl-utl" TMP_WT_LIVE_IDS="" bash -c ". '$UTL_RUN'; do_sweep_tmp_worktrees" 2>&1)"
check "3. (e) the plan names the orphan red copy" grep -qE "PLAN remove [0-9]+KB proof=marker dirty red-copy --force $TR/g505-r9-parent\$" <<<"$out"
check "3. (e) ...and it is still there" test -f "$TR/g505-r9-parent/f"
check "3. (e) ...and still listed by git" listed "$TR/g505-r9-parent"
has "3. (e) the DONE line says would-remove" "DONE would-remove=" "$out"
out="$(PROJ_PATH="$T_REPO/csi-spl-utl" TMP_WT_LIVE_IDS="" DRY_RUN=0 bash -c ". '$UTL_RUN'; do_sweep_tmp_worktrees" 2>&1)"
check "3. DRY_RUN=0 removes it" test ! -e "$TR/g505-r9-parent"

# 4. (f) a name-only match is kept: no marker, no message of the id; a message
#    of ANOTHER agent naming the path is no proof; the id's own sent message is.
retired g-506; wt "$TR/g-506-red" "" dirty; old "$TR/g-506-red"
mkdir -p "$R/c-381/outbox" && printf '{"body":"red copy at %s here"}\n' "$TR/g-506-red" >"$R/c-381/outbox/m1.json"
out="$(TMP_WT_LIVE_IDS="" bash "$REAP" --orphans --apply 2>&1)"
check "4. (f) the name-only red copy stays" test -f "$TR/g-506-red/f"
has "4. (f) ...KEEP name-only" "KEEP name-only (no spl-owner marker, no message of g-506 names it) $TR/g-506-red" "$out"
mkdir -p "$R/.retired/g-506.20261101T000000Z/outbox"
printf '{"body":"ran in %s-old and %s/x"}\n' "$TR/g-506-red" "$TR/g-506-redx" >"$R/.retired/g-506.20261101T000000Z/outbox/m2.json"
out="$(TMP_WT_LIVE_IDS="" bash "$REAP" --orphans --apply 2>&1)"
check "4. (f) a longer path in its message is no proof" test -f "$TR/g-506-red/f"
for pre in /var x _ . -; do  # R7 W1: a path character BEFORE the path
  printf '{"body":"copy at %s%s"}\n' "$pre" "$TR/g-506-red" >"$R/.retired/g-506.20261101T000000Z/outbox/m-pre.json"
  out="$(TMP_WT_LIVE_IDS="" bash "$REAP" --orphans --apply 2>&1)"
  check "4. (f) a path with '$pre' before it is no proof" test -f "$TR/g-506-red/f"
  has "4. (f) ...KEEP name-only" "KEEP name-only (no spl-owner marker, no message of g-506 names it) $TR/g-506-red" "$out"
done
rm -f "$R/.retired/g-506.20261101T000000Z/outbox/m-pre.json"
printf '{"body":"red control in %s: exit 1"}\n' "$TR/g-506-red" >"$R/.retired/g-506.20261101T000000Z/outbox/m3.json"
out="$(TMP_WT_LIVE_IDS="" bash "$REAP" --orphans --apply 2>&1)"
check "4. its own sent message naming the path proves it: removed" test ! -e "$TR/g-506-red"
has "4. ...proof=outbox" "proof=outbox dirty red-copy --force $TR/g-506-red" "$out"

# 5. a held tree stays (cwd); an idle-guard keeps a fresh orphan; a tree
#    outside the tmp root and an id never retired are never touched.
retired g-507; wt "$TR/g-507-red" g-507 dirty; old "$TR/g-507-red"
( cd "$TR/g-507-red" && exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/cwd")" = "$TR/g-507-red" ] && break; sleep 0.1; done
retired g-508; wt "$TR/g-508-red" g-508 dirty
wt "$TR/g-509-red" g-509 dirty; old "$TR/g-509-red"
wt "$T_TMP/elsewhere/g-501-x" g-501 dirty
out="$(TMP_WT_LIVE_IDS="" bash "$REAP" --orphans --apply 2>&1)"
check "5. a tree a process works in stays" test -f "$TR/g-507-red/f"
has "5. ...KEEP in-use" "KEEP in-use (a process has its cwd or an open file under it) $TR/g-507-red" "$out"
has "5. a tree changed in the last 2 h stays" "KEEP recent (changed in the last 2 h) $TR/g-508-red" "$out"
has "5. an id never retired stays" "KEEP not-retired g-509 $TR/g-509-red" "$out"
bash "$REAP" --agent g-501 --apply >/dev/null 2>&1
check "5. a tree outside the tmp root is never touched" test -f "$T_TMP/elsewhere/g-501-x/f"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null

# 6. without a live guard the orphan sweep removes nothing (exit 2).
retired g-510; wt "$TR/g-510-red" g-510 dirty; old "$TR/g-510-red"
mv "$R/registry.tsv" "$R/registry.tsv.off"
out="$(bash "$REAP" --orphans --apply 2>&1)"; eq "6. no registry: exit 2" 2 "$?"
has "6. ...REFUSE" "REFUSE cannot read $R/registry.tsv" "$out"
check "6. ...and the tree stays" test -f "$TR/g-510-red/f"
mv "$R/registry.tsv.off" "$R/registry.tsv"

# 7. the post-checkout hook writes the marker at `git worktree add`: the
#    agent's own SPOOL_AGENT_ID, else its nearest ancestor's (a `sudo -u`
#    hop drops it from the env), else none (the add still passes).
cp "$HOOK" "$M/.git/hooks/post-checkout" && chmod +x "$M/.git/hooks/post-checkout"
SPOOL_AGENT_ID=g-511 "${G[@]}" -C "$M" worktree add -q --detach "$TR/g-511-red" HEAD 2>/dev/null
eq "7. the marker names the adding agent" g-511 "$(cut -f1 "$M/.git/worktrees/g-511-red/spl-owner" 2>/dev/null)"
eq "7. ...and the path" "$(cd "$TR/g-511-red" && pwd -P)" "$(cut -f3 "$M/.git/worktrees/g-511-red/spl-owner" 2>/dev/null)"
SPOOL_AGENT_ID=g-512 bash -c 'env -u SPOOL_AGENT_ID "$@"; exit $?' _ "${G[@]}" -C "$M" worktree add -q --detach "$TR/g-512-red" HEAD 2>/dev/null
eq "7. an ancestor's id when the env dropped it" g-512 "$(cut -f1 "$M/.git/worktrees/g-512-red/spl-owner" 2>/dev/null)"
( unset SPOOL_AGENT_ID; SPL_OWNER_WALK=0 "${G[@]}" -C "$M" worktree add -q --detach "$TR/plain" HEAD 2>/dev/null ); eq "7. no agent id: the add passes" 0 "$?"
check "7. ...with no marker" test ! -e "$M/.git/worktrees/plain/spl-owner"

t_done
