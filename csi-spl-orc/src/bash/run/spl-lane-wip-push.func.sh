#!/bin/bash
#------------------------------------------------------------------------------
# @description Push a lane's unfinished work to its wip ref (spec 102 section 5.4):
# @description refs/heads/wip/<lane branch>, never any other ref. The dirty tree
# @description (the lane's index plus `git add -u`, plus its NEW source files:
# @description untracked, not ignored, under a csi-spl-*/ tree, SPL-2513; never
# @description its scratch: STATE-*.md, .lane-state-*.md, screenshots, SPL-2191;
# @description a new file over WIP_UNTRACKED_MAX_BYTES, a generated build dir such as
# @description .output.ppe-keep/ and an untracked dir over WIP_UNTRACKED_TREE_MAX_BYTES
# @description are skipped and logged, SPL-4296) is
# @description committed on top of HEAD in a TEMPORARY index, so the lane's own
# @description index, HEAD and working tree are
# @description never touched (no git stash), under the repo's canonical author,
# @description message "wip(<id>): <ts> handoff", and pushed --force-with-lease
# @description (the lease is the remote wip ref as read just before the push).
# @description Mid-rebase or mid-merge: ORIG_HEAD is pushed instead and the dirty
# @description diff goes to a patch file under <spool root>/<id>/lifetime/, never
# @description the conflicted tree. Nothing is pushed when HEAD, the tree and the
# @description patch are what the last push of this id carried (lifetime/wip.last),
# @description so the watchdog can call it at 30 min, 1 h and 1 h 50 without churn.
# @description The pre-push hook skips a push whose refs are all refs/heads/wip/*.
# @description Exit 0 pushed or unchanged, 1 refused or failed.
# @param ID (required) - the lane id, e.g. c-050
# @param WIP_WORKTREE (optional) - the lane's worktree; default its registry rundir
# @param WIP_REF (optional) - default refs/heads/wip/<lane branch>; anything outside refs/heads/wip/ is refused
# @param WIP_REMOTE (optional) - default origin
# @param WIP_GIT_NAME, WIP_GIT_EMAIL (optional) - default the repo's user.name / user.email, else the last commit's author
# @param WIP_UNTRACKED_MAX_BYTES (optional) - a new untracked file larger than this stays out, logged; default 1048576 (1 MB)
# @param WIP_UNTRACKED_TREE_MAX_BYTES (optional) - a new untracked dir whose files sum over this stays out, logged once; default 5242880 (5 MB)
# @param DRY_RUN (optional) - 1 prints the plan and writes nothing; default 0 (the watchdog's job)
# @example ID=c-050 ./run -a do_spl_lane_wip_push
# @example ID=c-050 DRY_RUN=1 ./run -a do_spl_lane_wip_push
#------------------------------------------------------------------------------

do_spl_lane_wip_push() {
  local -A w=([id]="${ID:-}" [root]="${SPOOL_ROOT:-/var/spool-hub}" [remote]="${WIP_REMOTE:-origin}")
  spl_lane_wip_checks w && spl_lane_wip_branch w || return 1
  w[ref]="${WIP_REF:-refs/heads/wip/${w[branch]}}"
  spl_lane_wip_ref_ok "${w[ref]}" || { do_log "FATAL WIP ${w[id]}: refused ref '${w[ref]}': only refs/heads/wip/<branch> is ever pushed"; return 1; }
  w[life]="${w[root]}/${w[id]}/lifetime"
  w[ts]="$(date -u +%Y%m%dT%H%M%SZ)"
  spl_lane_wip_key w || return 1
  if [[ -f "${w[life]}/wip.last" && "$(cat "${w[life]}/wip.last")" == "${w[key]}" ]]; then
    do_log "SKIP WIP ${w[id]}: unchanged since the last push (${w[ref]})"; return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    do_log "PLAN WIP ${w[id]}: push ${w[src]:-<a wip commit on HEAD>} -> ${w[remote]} ${w[ref]}${w[mid]:+ (mid-${w[mid]}: ORIG_HEAD, the dirty diff as a patch file)}"
    return 0
  fi
  spl_lane_wip_send w
}

# spl_lane_wip_checks STATE: refuse a bad id, the live spool root under
# SPOOL_TEST and a bad DRY_RUN; set STATE[wt], the worktree (WIP_WORKTREE,
# else the registry rundir), refused unless it is a git work tree.
spl_lane_wip_checks() {
  local -n _wc="$1"
  local id="${_wc[id]}" root="${_wc[root]}"
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { do_log "FATAL ID must be a lane id like c-050, got '$id'"; return 1; }
  if [[ "${SPOOL_TEST:-}" == 1 && "$(readlink -m -- "$root")" == "$(readlink -m -- "${SPOOL_LIVE_ROOT:-/var/spool-hub}")" ]]; then
    do_log "FATAL SPOOL_TEST=1 and SPOOL_ROOT is the live root: a test must give its own SPOOL_ROOT"; return 1
  fi
  [[ "${DRY_RUN:-0}" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local wt="${WIP_WORKTREE:-}"
  [[ -n "$wt" ]] || wt="$(awk -F'\t' -v id="$id" '$1 == id {r = $4} END {print r}' "$root/registry.tsv" 2>/dev/null || true)"
  if [[ -z "$wt" || ! -d "$wt" ]] || ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    do_log "FATAL WIP $id: no git worktree (WIP_WORKTREE or the registry rundir), got '$wt'"; return 1
  fi
  _wc[wt]="$wt"
}

# spl_lane_wip_branch STATE: set STATE[mid] (rebase, merge or empty) and
# STATE[branch], the lane branch, read from the rebase state when mid-rebase;
# a detached HEAD is refused.
spl_lane_wip_branch() {
  local -n _wb="$1"
  local id="${_wb[id]}" wt="${_wb[wt]}" gd mid="" branch
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)" || return 1
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then
    mid=rebase
    branch="$(cat "$gd/rebase-merge/head-name" "$gd/rebase-apply/head-name" 2>/dev/null | sed -n 1p)"
  else
    [[ -f "$gd/MERGE_HEAD" ]] && mid=merge
    branch="$(git -C "$wt" symbolic-ref -q HEAD)"
  fi
  branch="${branch#refs/heads/}"
  [[ -n "$branch" && "$branch" != detached* ]] || { do_log "FATAL WIP $id: no lane branch (detached HEAD in $wt)"; return 1; }
  _wb[mid]="$mid" _wb[branch]="$branch"
}

# spl_lane_wip_key STATE: set STATE[key], what wip.last compares, and
# STATE[src], the commit to push (empty: a wip commit of STATE[tree] on
# STATE[head] is still to write). Mid-rebase / mid-merge: ORIG_HEAD plus
# STATE[diff], the dirty diff; else the tree of a TEMPORARY index.
spl_lane_wip_key() {
  local -n _wk="$1"
  local id="${_wk[id]}" wt="${_wk[wt]}" mid="${_wk[mid]}" src key diff=""
  if [[ -n "$mid" ]]; then
    src="$(git -C "$wt" rev-parse -q --verify ORIG_HEAD)" || { do_log "FATAL WIP $id: mid-$mid without ORIG_HEAD"; return 1; }
    diff="$(git -C "$wt" diff --binary HEAD 2>/dev/null)"
    key="$mid $src $(printf '%s' "$diff" | git hash-object --stdin)"
  else
    local idx tree head
    head="$(git -C "$wt" rev-parse -q --verify HEAD)" || { do_log "FATAL WIP $id: no HEAD in $wt"; return 1; }
    idx="$(mktemp)" || return 1
    cp "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
    # -u, never -A: the ref is public and gitleaks scans every ref; untracked
    # lane scratch (STATE-*.md, screenshots) stays out, its state is the spool's;
    # new source files ride (SPL-2513), picked by spl_lane_wip_add_untracked
    tree="$(cd "$wt" && GIT_INDEX_FILE="$idx" git add -u . && GIT_INDEX_FILE="$idx" spl_lane_wip_add_untracked "$id" >&2 &&
      GIT_INDEX_FILE="$idx" git write-tree)"
    rm -f "$idx" "$idx.lock"
    [[ -n "$tree" ]] || { do_log "FATAL WIP $id: cannot write the wip tree"; return 1; }
    key="tree $head $tree"
    src="$head"
    [[ "$tree" == "$(git -C "$wt" rev-parse "$head^{tree}")" ]] || src=""
    _wk[tree]="$tree" _wk[head]="$head"
  fi
  _wk[src]="$src" _wk[key]="$key" _wk[diff]="$diff"
}

# spl_lane_wip_send STATE: write the wip commit under the canonical author
# (a noreply address is refused) when STATE[src] is empty, the patch file when
# there is a dirty diff, push with a lease on the remote wip ref, then record
# STATE[key] in lifetime/wip.last.
spl_lane_wip_send() {
  local -n _ws="$1"
  local id="${_ws[id]}" wt="${_ws[wt]}" life="${_ws[life]}" ts="${_ws[ts]}" ref="${_ws[ref]}" remote="${_ws[remote]}"
  local src="${_ws[src]}" diff="${_ws[diff]}" patch=""
  if [[ -z "$src" ]]; then
    local name="${WIP_GIT_NAME:-$(git -C "$wt" config user.name)}" email="${WIP_GIT_EMAIL:-$(git -C "$wt" config user.email)}"
    [[ -n "$name" ]] || name="$(git -C "$wt" log -1 --no-mailmap --format=%an)"
    [[ -n "$email" ]] || email="$(git -C "$wt" log -1 --no-mailmap --format=%ae)"
    [[ -n "$name" && -n "$email" && "$email" != *noreply* ]] || { do_log "FATAL WIP $id: no canonical author (set WIP_GIT_NAME / WIP_GIT_EMAIL)"; return 1; }
    src="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
      git -C "$wt" commit-tree "${_ws[tree]}" -p "${_ws[head]}" -m "wip($id): $ts handoff")" || { do_log "FATAL WIP $id: commit-tree failed"; return 1; }
  fi
  mkdir -p "$life" || { do_log "FATAL WIP $id: cannot create $life"; return 1; }
  if [[ -n "$diff" ]]; then
    patch="$life/wip-$ts.patch"
    printf '%s\n' "$diff" >"$patch" || { do_log "FATAL WIP $id: cannot write $patch"; return 1; }
  fi
  local lease
  lease="$(git -C "$wt" ls-remote "$remote" "$ref" 2>/dev/null | awk '{print $1; exit}')"
  git -C "$wt" push -q --force-with-lease="$ref:$lease" "$remote" "$src:$ref" ||
    { do_log "FATAL WIP $id: push to $remote $ref failed (lease '${lease:-absent}')"; return 1; }
  printf '%s\n' "${_ws[key]}" >"$life/wip.last"
  do_log "OK WIP $id: pushed ${src:0:12} -> $remote $ref${patch:+ patch=$patch}"
}

# spl_lane_wip_add_untracked ID: in the cwd's repo, stage into $GIT_INDEX_FILE
# the lane's NEW source files (SPL-2513: c-999's WIP of 2026-10-18 carried its
# 6 edits but not its 6 new files, so install.sh on it called a missing step):
# untracked and not ignored, under a top-level csi-spl-*/ tree, except the
# lane's scratch (SPL-2191: STATE-*.md, .lane-state-*.md, screenshots), a file
# over WIP_UNTRACKED_MAX_BYTES, anything under a generated build dir
# (SPL_LANE_WIP_BUILD_DIR_RX: c-954's fence wip of 2026-10-29 carried a
# left-behind .output.ppe-keep/, 1961 files, 93 MB, SPL-4296) and a whole
# untracked dir whose kept files sum over WIP_UNTRACKED_TREE_MAX_BYTES. Each
# skip is logged on stdout (the caller sends it to stderr, its stdout is the
# tree sha), once per dir. Paths are repo-root relative.
SPL_LANE_WIP_BUILD_DIR_RX='^(node_modules|\.nuxt|\.output(\..+)?|\.pnpm-store|\.cache)$'
spl_lane_wip_add_untracked() {
  local id="$1" cap="${WIP_UNTRACKED_MAX_BYTES:-1048576}" tcap="${WIP_UNTRACKED_TREE_MAX_BYTES:-5242880}" top p base size d
  [[ "$cap" =~ ^[0-9]+$ ]] || { do_log "FATAL WIP $id: WIP_UNTRACKED_MAX_BYTES must be a byte count, got '$cap'"; return 1; }
  [[ "$tcap" =~ ^[0-9]+$ ]] || { do_log "FATAL WIP $id: WIP_UNTRACKED_TREE_MAX_BYTES must be a byte count, got '$tcap'"; return 1; }
  top="$(git rev-parse --show-toplevel)" || return 1
  local -a add=() dirs=() keep=()
  local -A build=() tsum=() tcnt=() of=()
  mapfile -d '' dirs < <(git -C "$top" ls-files -z --others --exclude-standard --directory)
  while IFS= read -r -d '' p; do
    base="${p##*/}"
    [[ "$p" == csi-spl-*/* ]] || continue
    [[ "$base" == STATE-*.md || "$base" == .lane-state-*.md ]] && continue
    [[ "${base,,}" =~ \.(png|jpe?g|gif|webp|bmp)$ ]] && continue
    d="$(spl_lane_wip_build_dir "$p")"
    if [[ -n "$d" ]]; then build[$d]=$((${build[$d]:-0} + 1)); continue; fi
    size="$(stat -c %s -- "$top/$p" 2>/dev/null)" || continue
    if ((size > cap)); then
      do_log "SKIP WIP $id: new file $p is $size bytes, over the $cap cap; not in the wip commit"; continue
    fi
    d=""
    for base in "${dirs[@]}"; do [[ "$base" == */ && "$p" == "$base"* ]] && { d="$base"; break; }; done
    [[ -z "$d" ]] || { tsum[$d]=$((${tsum[$d]:-0} + size)); tcnt[$d]=$((${tcnt[$d]:-0} + 1)); }
    keep+=("$p") of[$p]="$d"
  done < <(git -C "$top" ls-files -z --others --exclude-standard)
  for d in "${!build[@]}"; do do_log "SKIP WIP $id: build dir $d (${build[$d]} files) is generated; not in the wip commit"; done
  for d in "${!tsum[@]}"; do
    ((${tsum[$d]} > tcap)) && do_log "SKIP WIP $id: new tree $d is ${tsum[$d]} bytes in ${tcnt[$d]} files, over the $tcap tree cap; not in the wip commit"
  done
  for p in "${keep[@]}"; do d="${of[$p]}"; [[ -n "$d" ]] && ((${tsum[$d]} > tcap)) && continue; add+=("$p"); done
  ((${#add[@]} == 0)) || printf '%s\0' "${add[@]}" | git --literal-pathspecs -C "$top" add --pathspec-from-file=- --pathspec-file-nul
}

# spl_lane_wip_build_dir PATH: print the PATH prefix up to and including its
# first component that is a generated build dir (SPL_LANE_WIP_BUILD_DIR_RX),
# with a trailing slash; print nothing when there is none.
spl_lane_wip_build_dir() {
  local p="$1" pre="" c
  local -a parts
  IFS=/ read -r -a parts <<<"$p"
  for c in "${parts[@]:0:${#parts[@]}-1}"; do
    pre+="$c/"
    [[ "$c" =~ $SPL_LANE_WIP_BUILD_DIR_RX ]] && { printf '%s' "$pre"; return 0; }
  done
}

# spl_lane_wip_ref_ok REF: the push wrapper's assertion: refs/heads/wip/<name>
# only, no "..", no refspec syntax.
spl_lane_wip_ref_ok() {
  [[ "$1" =~ ^refs/heads/wip/[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]
}
