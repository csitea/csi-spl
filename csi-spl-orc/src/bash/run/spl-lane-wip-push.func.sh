#!/bin/bash
#------------------------------------------------------------------------------
# @description Push a lane's unfinished work to its wip ref (spec 102 section 5.4):
# @description refs/heads/wip/<lane branch>, never any other ref. The dirty tree
# @description (tracked + untracked, not ignored) is committed on top of HEAD in a
# @description TEMPORARY index, so the lane's own index, HEAD and working tree are
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
# @param DRY_RUN (optional) - 1 prints the plan and writes nothing; default 0 (the watchdog's job)
# @example ID=c-050 ./run -a do_spl_lane_wip_push
# @example ID=c-050 DRY_RUN=1 ./run -a do_spl_lane_wip_push
#------------------------------------------------------------------------------

do_spl_lane_wip_push() {
  local id="${ID:-}" root="${SPOOL_ROOT:-/var/spool-hub}" remote="${WIP_REMOTE:-origin}"
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

  local gd mid="" branch
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

  local ref="${WIP_REF:-refs/heads/wip/$branch}"
  spl_lane_wip_ref_ok "$ref" || { do_log "FATAL WIP $id: refused ref '$ref': only refs/heads/wip/<branch> is ever pushed"; return 1; }

  local life="$root/$id/lifetime" ts src key diff="" patch=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -n "$mid" ]]; then
    src="$(git -C "$wt" rev-parse -q --verify ORIG_HEAD)" || { do_log "FATAL WIP $id: mid-$mid without ORIG_HEAD"; return 1; }
    diff="$(git -C "$wt" diff --binary HEAD 2>/dev/null)"
    key="$mid $src $(printf '%s' "$diff" | git hash-object --stdin)"
  else
    local idx tree head
    head="$(git -C "$wt" rev-parse -q --verify HEAD)" || { do_log "FATAL WIP $id: no HEAD in $wt"; return 1; }
    idx="$(mktemp)" || return 1
    cp "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
    tree="$(cd "$wt" && GIT_INDEX_FILE="$idx" git add -A . && GIT_INDEX_FILE="$idx" git write-tree)"
    rm -f "$idx" "$idx.lock"
    [[ -n "$tree" ]] || { do_log "FATAL WIP $id: cannot write the wip tree"; return 1; }
    key="tree $head $tree"
    src="$head"
    [[ "$tree" == "$(git -C "$wt" rev-parse "$head^{tree}")" ]] || src=""
  fi
  if [[ -f "$life/wip.last" && "$(cat "$life/wip.last")" == "$key" ]]; then
    do_log "SKIP WIP $id: unchanged since the last push ($ref)"; return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    do_log "PLAN WIP $id: push ${src:-<a wip commit on HEAD>} -> $remote $ref${mid:+ (mid-$mid: ORIG_HEAD, the dirty diff as a patch file)}"
    return 0
  fi

  if [[ -z "$src" ]]; then
    local name="${WIP_GIT_NAME:-$(git -C "$wt" config user.name)}" email="${WIP_GIT_EMAIL:-$(git -C "$wt" config user.email)}"
    [[ -n "$name" ]] || name="$(git -C "$wt" log -1 --no-mailmap --format=%an)"
    [[ -n "$email" ]] || email="$(git -C "$wt" log -1 --no-mailmap --format=%ae)"
    [[ -n "$name" && -n "$email" && "$email" != *noreply* ]] || { do_log "FATAL WIP $id: no canonical author (set WIP_GIT_NAME / WIP_GIT_EMAIL)"; return 1; }
    src="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
      git -C "$wt" commit-tree "$tree" -p "$head" -m "wip($id): $ts handoff")" || { do_log "FATAL WIP $id: commit-tree failed"; return 1; }
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
  printf '%s\n' "$key" >"$life/wip.last"
  do_log "OK WIP $id: pushed ${src:0:12} -> $remote $ref${patch:+ patch=$patch}"
}

# spl_lane_wip_ref_ok REF: the push wrapper's assertion: refs/heads/wip/<name>
# only, no "..", no refspec syntax.
spl_lane_wip_ref_ok() {
  [[ "$1" =~ ^refs/heads/wip/[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]
}
