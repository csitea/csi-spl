#!/usr/bin/env bash
# wt-dirty-salvage.inc.sh - sourced by wt-dead-sweep.sh (SPL-2514): resolve a
# RETIRED lane's dirty worktree instead of keeping it forever.
#
# salvage WT ID BRANCH, on a real run (DRY_RUN=0):
#   1. pushes the tree's work with do_spl_lane_wip_push (tracked edits plus its
#      new source files, SPL-2513) to refs/heads/wip/<branch>, then verifies
#      it: the remote ref holds that sha (git ls-remote), the commit exists
#      (git cat-file -e) and contains the tree's HEAD;
#   2. archives every other non-ignored file the wip commit does not carry
#      (lane scratch, a stray top-level file: the wip push keeps them off the
#      public ref) to <WT_SALVAGE_DIR>/<id>.<UTC>.tgz, verified with tar -t;
#      a residue over WT_SALVAGE_RESIDUE_MAX_KB, or a nested repo, keeps the tree;
#   3. appends "utc id worktree ref sha state archive" to WT_SALVAGE_LOG, and
#      the tree is KEPT on this pass.
# A later pass sets sv_sha (the caller may then remove the tree) only when the
# newest row for the tree still verifies AND its state (the tree of every
# non-ignored file, built in a throwaway index and object dir, so the tree,
# its index and the object store are never written) is the recorded one.
# A push failure writes no row. Mid-rebase/merge and detached trees are kept.
# Out: sv_why (a KEEP reason, empty when sv_sha is set) and sv_sha.
# The sweep's globals (self_dir spool dry salvage_log salvage_dir residue_max_kb)
# are read here; sv_why / sv_sha are read there.
# shellcheck disable=SC2154,SC2034

# The wip push function; its do_log goes to the sweep's log lines.
declare -F do_log >/dev/null || do_log() { say "$*"; }
# shellcheck source=../run/spl-lane-wip-push.func.sh
. "$self_dir/../run/spl-lane-wip-push.func.sh"

# salvage_retired ID WT: no live registry.tsv row names ID, and a
# registry.retired.tsv row has WT as its rundir. An unreadable registry: no.
salvage_retired() {
  [[ -r "$spool/registry.tsv" && -r "$spool/registry.retired.tsv" ]] || return 1
  cut -f1 "$spool/registry.tsv" | sed -E 's/^.*: //; s/@.*//' | grep -qxF -- "$1" && return 1
  awk -F'\t' -v w="$2" '$4 == w {f = 1} END {exit !f}' "$spool/registry.retired.tsv"
}

# salvage_state WT OBJDIR: the tree of every non-ignored file in WT, written
# to a throwaway index and OBJDIR only (the repo's objects as an alternate).
salvage_state() {
  local wt="$1" od="$2" real idx="$2/index"
  real="$(g -C "$wt" rev-parse --path-format=absolute --git-common-dir)/objects" || return 1
  mkdir -p "$od/objects" || return 1
  cp "$(g -C "$wt" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
  (cd "$wt" && export GIT_INDEX_FILE="$idx" GIT_OBJECT_DIRECTORY="$od/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$real" &&
    g add -A . >/dev/null 2>&1 && g write-tree)
}

# salvage_verified WT REF SHA: origin's REF is SHA, the commit exists here and
# contains the tree's HEAD.
salvage_verified() {
  local wt="$1" ref="$2" sha="$3"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$(g -C "$wt" ls-remote origin "$ref" 2>/dev/null | awk '{print $1; exit}')" == "$sha" ]] || return 1
  g -C "$wt" cat-file -e "$sha^{commit}" 2>/dev/null &&
    g -C "$wt" merge-base --is-ancestor "$(g -C "$wt" rev-parse HEAD)" "$sha" 2>/dev/null
}

# salvage_residue WT OBJDIR SHA STATE: NUL list of the paths STATE adds or
# changes against SHA's tree; exit 3 when one is a nested repo (a gitlink).
salvage_residue() {
  local meta p rc=0
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    [[ "$(cut -d' ' -f2 <<<"$meta")" == 160000 ]] && rc=3
    printf '%s\0' "$p"
  done < <(GIT_OBJECT_DIRECTORY="$2/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$(g -C "$1" rev-parse --path-format=absolute --git-common-dir)/objects" \
    g -C "$1" diff-tree -r -z --no-renames --diff-filter=AMT "$3^{tree}" "$4")
  return "$rc"
}

salvage() {
  local wt="$1" id="$2" br="$3" gd od state row ref sha arch="" ts
  sv_why="" sv_sha=""
  gd="$(g -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { sv_why="dirty-retired-kept-no-git-dir"; return; }
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" ]]; then sv_why="dirty-retired-kept-mid-rebase-or-merge"; return; fi
  [[ -n "$br" ]] || { sv_why="dirty-retired-kept-detached"; return; }
  ref="refs/heads/wip/$br"
  od="$(mktemp -d)" || { sv_why="dirty-retired-kept-no-tmp"; return; }
  state="$(salvage_state "$wt" "$od")" || state=""
  if [[ -z "$state" ]]; then rm -rf "$od"; sv_why="dirty-retired-kept-no-state"; return; fi
  row="$(awk -F'\t' -v w="$wt" '$3 == w {r = $0} END {print r}' "$salvage_log" 2>/dev/null)"
  if [[ -n "$row" ]]; then
    IFS=$'\t' read -r _ _ _ _ sha rstate arch <<<"$row"
    if [[ "$rstate" == "$state" ]] && salvage_verified "$wt" "$ref" "$sha" &&
      { [[ -z "$arch" || "$arch" == - ]] || tar -tzf "$arch" >/dev/null 2>&1; }; then
      rm -rf "$od"; sv_sha="$sha"; return
    fi
  fi
  if [[ "$dry" == 1 ]]; then rm -rf "$od"; sv_why="dirty-retired-salvage-planned to $ref"; return; fi

  # A throwaway SPOOL_ROOT: the retired id's lifetime/wip.last is neither
  # read (a stale "unchanged" would skip the push) nor created.
  local sroot="$od/spool"; mkdir -p "$sroot"
  if ! (ID="$id" WIP_WORKTREE="$wt" WIP_REF="$ref" SPOOL_ROOT="$sroot" SPOOL_TEST='' DRY_RUN=0 do_spl_lane_wip_push); then
    rm -rf "$od"; sv_why="dirty-retired-kept-push-failed"; return
  fi
  sha="$(g -C "$wt" ls-remote origin "$ref" 2>/dev/null | awk '{print $1; exit}')"
  salvage_verified "$wt" "$ref" "$sha" || { rm -rf "$od"; sv_why="dirty-retired-kept-push-unverified"; return; }

  local -a res=(); local p kb=0 rc=0
  while IFS= read -r -d '' p; do res+=("$p"); done < <(salvage_residue "$wt" "$od" "$sha" "$state"; echo $? >"$od/rc")
  rc="$(cat "$od/rc")"
  (( rc == 0 )) || { rm -rf "$od"; sv_why="dirty-retired-kept-nested-repo"; return; }
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if (( ${#res[@]} )); then
    kb="$( (cd "$wt" && du -ck -- "${res[@]}" 2>/dev/null) | tail -1 | cut -f1)"
    (( ${kb:-0} <= residue_max_kb )) || { rm -rf "$od"; sv_why="dirty-retired-kept-residue-${kb}KB-over-cap"; return; }
    arch="$salvage_dir/$id.$ts.tgz"
    mkdir -p "$salvage_dir" &&
      printf '%s\0' "${res[@]}" | tar -czf "$arch" -C "$wt" --null --no-recursion -T - &&
      [[ "$(tar -tzf "$arch" | wc -l)" == "${#res[@]}" ]] ||
      { rm -f "$arch"; rm -rf "$od"; sv_why="dirty-retired-kept-archive-failed"; return; }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$id" "$wt" "$ref" "$sha" "$state" "${arch:--}" >>"$salvage_log" ||
    { rm -rf "$od"; sv_why="dirty-retired-kept-log-unwritable"; return; }
  rm -rf "$od"
  say "SALVAGE $id $sha -> origin $ref residue=${#res[@]} archive=${arch:--}"
  sv_why="dirty-retired-salvaged (removed on a later pass)"
}
