#!/usr/bin/env bash
# wt-dirty-salvage.inc.sh - sourced by wt-dead-sweep.sh (SPL-2514): resolve a
# RETIRED lane's dirty worktree instead of keeping it forever. LOCAL ONLY:
# nothing is ever pushed (csi-spl is public; a scan of 53 unread trees cannot
# prove they hold no private data, c-001 551df3d5).
#
# salvage WT ID BRANCH, on a real run (DRY_RUN=0):
#   1. builds one wip commit on top of HEAD: the tracked edits plus the new
#      csi-spl-*/ source files (spl_lane_wip_add_untracked, SPL-2513), in a
#      THROWAWAY bare repo whose objects borrow the repo's (alternates) and a
#      throwaway index: the lane's index, the repo's object store and its refs
#      are never written;
#   2. writes it as a git bundle, <WT_SALVAGE_DIR>/<id>.<UTC>.bundle (the
#      wip commit and the lane's commits since its merge-base with WT_TRUNK),
#      checked with git bundle verify;
#   3. archives every other non-ignored file (lane scratch, a stray top-level
#      file) to <id>.<UTC>.tgz there, checked with tar -t; a residue over
#      WT_SALVAGE_RESIDUE_MAX_KB, or a nested repo, keeps the tree;
#   4. appends "utc id worktree bundle sha head state archive" to
#      WT_SALVAGE_LOG; the tree is KEPT on this pass.
# WT_SALVAGE_DIR is mode 700 with no default ACL, every file in it 600.
# A later pass sets sv_sha (the caller may then remove the tree) only when the
# newest row for the tree passes: git bundle verify, the bundle's tip is the
# logged sha, HEAD is the logged head, the archive lists, and the tree's
# non-ignored content (a throwaway index and object dir) is the logged state.
# A tree with a dir the sweep user cannot write is kept whole (no half removal).
# Mid-rebase/merge and detached trees are kept.
# Out: sv_why (a KEEP reason, empty when sv_sha is set) and sv_sha.
# The sweep's globals (self_dir repo trunk spool dry salvage_log salvage_dir
# residue_max_kb) are read here; sv_why / sv_sha are read there.
# shellcheck disable=SC2154,SC2034

declare -F do_log >/dev/null || do_log() { say "$*"; }
# spl_lane_wip_add_untracked (the new-source-file rule); its push is never called.
# shellcheck source=../run/spl-lane-wip-push.func.sh
. "$self_dir/../run/spl-lane-wip-push.func.sh"

# salvage_retired ID WT: no live registry.tsv row names ID, and a
# registry.retired.tsv row has WT as its rundir. An unreadable registry: no.
salvage_retired() {
  [[ -r "$spool/registry.tsv" && -r "$spool/registry.retired.tsv" ]] || return 1
  cut -f1 "$spool/registry.tsv" | sed -E 's/^.*: //; s/@.*//' | grep -qxF -- "$1" && return 1
  awk -F'\t' -v w="$2" '$4 == w {f = 1} END {exit !f}' "$spool/registry.retired.tsv"
}

# salvage_scratch WT OD: a throwaway bare repo at OD/r borrowing the repo's
# objects, and a copy of the lane's index at OD/index.
salvage_scratch() {
  local real
  real="$(g -C "$1" rev-parse --path-format=absolute --git-common-dir)/objects" || return 1
  g init -q --bare "$2/r" && printf '%s\n' "$real" >"$2/r/objects/info/alternates" || return 1
  cp "$(g -C "$1" rev-parse --path-format=absolute --git-path index)" "$2/index" 2>/dev/null || true
}

# sg WT OD GIT-ARGS...: git on the lane's work tree with the throwaway repo
# and index, so nothing of the lane's repo is written.
sg() { local wt="$1" od="$2"; shift 2; (cd "$wt" && GIT_DIR="$od/r" GIT_WORK_TREE="$wt" GIT_INDEX_FILE="$od/index" g "$@"); }

# salvage_state WT OD: the tree of every non-ignored file in WT.
salvage_state() {
  cp "$2/index" "$2/index.state" 2>/dev/null || return 1
  (cd "$1" && GIT_DIR="$2/r" GIT_WORK_TREE="$1" GIT_INDEX_FILE="$2/index.state" g add -A . >/dev/null 2>&1 &&
    GIT_DIR="$2/r" GIT_WORK_TREE="$1" GIT_INDEX_FILE="$2/index.state" g write-tree)
}

# salvage_wip_tree WT OD ID: the tree the wip push would carry (index + add -u
# + the new csi-spl-*/ source files).
salvage_wip_tree() {
  (cd "$1" && export GIT_DIR="$2/r" GIT_WORK_TREE="$1" GIT_INDEX_FILE="$2/index" &&
    g add -u . && spl_lane_wip_add_untracked "$3" >&2 && g write-tree)
}

# salvage_bundle_ok WT BUNDLE SHA: git bundle verify passes in the repo and
# the bundle's one tip is SHA.
salvage_bundle_ok() {
  [[ -f "$2" && "$3" =~ ^[0-9a-f]{40}$ ]] || return 1
  g -C "$repo" bundle verify -q "$2" >/dev/null 2>&1 || return 1
  [[ "$(g -C "$repo" bundle list-heads "$2" 2>/dev/null | awk '{print $1}' | sort -u)" == "$3" ]]
}

# salvage_residue WT OD WIPTREE STATE: NUL list of the paths STATE adds or
# changes against WIPTREE; exit 3 when one is a nested repo (a gitlink).
salvage_residue() {
  local meta p rc=0
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    [[ "$(cut -d' ' -f2 <<<"$meta")" == 160000 ]] && rc=3
    printf '%s\0' "$p"
  done < <(sg "$1" "$2" diff-tree -r -z --no-renames --diff-filter=AMT "$3" "$4")
  return "$rc"
}

salvage() {
  local wt="$1" id="$2" br="$3" gd od head state row sha rhead rstate bundle arch=""
  sv_why="" sv_sha=""
  gd="$(g -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { sv_why="dirty-retired-kept-no-git-dir"; return; }
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" ]]; then sv_why="dirty-retired-kept-mid-rebase-or-merge"; return; fi
  [[ -n "$br" ]] || { sv_why="dirty-retired-kept-detached"; return; }
  head="$(g -C "$wt" rev-parse -q --verify HEAD)" || { sv_why="dirty-retired-kept-no-head"; return; }
  od="$(mktemp -d)" || { sv_why="dirty-retired-kept-no-tmp"; return; }
  salvage_scratch "$wt" "$od" || { rm -rf "$od"; sv_why="dirty-retired-kept-no-scratch-repo"; return; }
  state="$(salvage_state "$wt" "$od")" || state=""
  [[ -n "$state" ]] || { rm -rf "$od"; sv_why="dirty-retired-kept-no-state"; return; }
  row="$(awk -F'\t' -v w="$wt" '$3 == w {r = $0} END {print r}' "$salvage_log" 2>/dev/null)"
  if [[ -n "$row" ]]; then
    IFS=$'\t' read -r _ _ _ bundle sha rhead rstate arch <<<"$row"
    if [[ "$rstate" == "$state" && "$rhead" == "$head" ]] && salvage_bundle_ok "$wt" "$bundle" "$sha" &&
      { [[ -z "$arch" || "$arch" == - ]] || tar -tzf "$arch" >/dev/null 2>&1; }; then
      rm -rf "$od"
      # every dir must be writable by us, or `worktree remove --force` stops
      # half way (a-115, 2026-10-18: another user's dir left 58 MB and
      # no worktree record). Kept whole instead.
      if [[ -n "$(find "$wt" -type d ! -writable -print -quit 2>/dev/null)" ]]; then
        sv_why="dirty-retired-salvaged-kept-unremovable (a dir not writable by $(id -un))"; return
      fi
      sv_sha="$sha"; return
    fi
    arch=""
  fi
  if [[ "$dry" == 1 ]]; then rm -rf "$od"; sv_why="dirty-retired-salvage-planned"; return; fi
  salvage_write "$wt" "$id" "$od" "$head" "$state"
  rm -rf "$od"
}

# salvage_write WT ID OD HEAD STATE: the bundle, the archive, the log row.
salvage_write() {
  local wt="$1" id="$2" od="$3" head="$4" state="$5" wtree sha base ts name email bundle arch="" kb=0 rc
  wtree="$(salvage_wip_tree "$wt" "$od" "$id")" || wtree=""
  [[ -n "$wtree" ]] || { sv_why="dirty-retired-kept-no-wip-tree"; return; }
  name="$(g -C "$wt" config user.name)"; email="$(g -C "$wt" config user.email)"
  [[ -n "$name" ]] || name="$(g -C "$wt" log -1 --no-mailmap --format=%an)"
  [[ -n "$email" ]] || email="$(g -C "$wt" log -1 --no-mailmap --format=%ae)"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  sha="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
    sg "$wt" "$od" commit-tree "$wtree" -p "$head" -m "wip($id): $ts salvage")" || { sv_why="dirty-retired-kept-commit-failed"; return; }
  base="$(g -C "$repo" merge-base "$head" "$trunk" 2>/dev/null)" || base=""
  [[ -n "$base" ]] || { sv_why="dirty-retired-kept-no-trunk-base"; return; }
  sg "$wt" "$od" update-ref "refs/heads/salvage/$id" "$sha" || { sv_why="dirty-retired-kept-ref-failed"; return; }
  # 700 / 600 by chmod, and no default ACL: the spool root's default ACL
  # beats the umask (sat, 2026-10-18: the first live pass wrote 660 files)
  (umask 077 && mkdir -p "$salvage_dir") && chmod 700 "$salvage_dir" || { sv_why="dirty-retired-kept-no-salvage-dir"; return; }
  if command -v setfacl >/dev/null; then setfacl -k "$salvage_dir" 2>/dev/null || true; fi
  bundle="$salvage_dir/$id.$ts.bundle"
  { (umask 077 && sg "$wt" "$od" bundle create -q "$bundle" "refs/heads/salvage/$id" "^$base" >/dev/null 2>&1) &&
    chmod 600 "$bundle" && salvage_bundle_ok "$wt" "$bundle" "$sha"; } || { rm -f "$bundle"; sv_why="dirty-retired-kept-bundle-failed"; return; }

  local -a res=(); local p
  while IFS= read -r -d '' p; do res+=("$p"); done < <(salvage_residue "$wt" "$od" "$wtree" "$state"; echo $? >"$od/rc")
  rc="$(cat "$od/rc")"
  (( rc == 0 )) || { rm -f "$bundle"; sv_why="dirty-retired-kept-nested-repo"; return; }
  if (( ${#res[@]} )); then
    kb="$( (cd "$wt" && du -ck -- "${res[@]}" 2>/dev/null) | tail -1 | cut -f1)"
    (( ${kb:-0} <= residue_max_kb )) || { rm -f "$bundle"; sv_why="dirty-retired-kept-residue-${kb}KB-over-cap"; return; }
    arch="$salvage_dir/$id.$ts.tgz"
    { printf '%s\0' "${res[@]}" | (umask 077 && tar -czf "$arch" -C "$wt" --null --no-recursion -T -) &&
      chmod 600 "$arch" && [[ "$(tar -tzf "$arch" | wc -l)" == "${#res[@]}" ]]; } ||
      { rm -f "$arch" "$bundle"; sv_why="dirty-retired-kept-archive-failed"; return; }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$id" "$wt" "$bundle" "$sha" "$head" "$state" "${arch:--}" >>"$salvage_log" ||
    { rm -f "$arch" "$bundle"; sv_why="dirty-retired-kept-log-unwritable"; return; }
  say "SALVAGE $id $sha -> $bundle residue=${#res[@]} archive=${arch:--}"
  sv_why="dirty-retired-salvaged (removed on a later pass)"
}
