#!/bin/bash
#------------------------------------------------------------------------------
# @description Step 1 of a lane handover (t1 ba8104f6, owner msg b072af77): the
# @description lane's unfinished work, made safe to leave the box. Shared by the
# @description claude, agy and mistral handovers; callable on its own.
# @description   1. the WIP tree: tracked + untracked, not ignored, written in a
# @description      TEMPORARY index on the worktree's HEAD. The lane's index, HEAD
# @description      and files are never touched (the agent need not be alive).
# @description   2. the SCAN, before anything leaves: every file the push would
# @description      add past origin/<trunk> (the WIP and the unpushed commits)
# @description      goes through box-state-pack.sh scan (excluded names, NetVisor
# @description      and bank credential files, key and token material), and a file
# @description      of mode 0600 in the worktree is refused too. Any hit = exit 3,
# @description      one `HIT <path> <reason>` line per file (its NAME, never its
# @description      bytes) and NOTHING pushed.
# @description   3. a commit of that tree on HEAD (unpushed local commits ride
# @description      along), under the repo's own author, no trailer, message
# @description      "wip(<id>): <ts> handover", pushed to refs/heads/wip/handover/<id>
# @description      without force: the pre-push hook skips a push whose refs are
# @description      all refs/heads/wip/* (spec 102 5.4), unfinished work is not
# @description      gated. A ref already there with the same tree is reused; one
# @description      with another tree is refused (exit 4): the caller deletes it.
# @description stdout, last line: `OK HANDOVER-WIP <id> sha=<sha> ref=<ref> files=<n>`
# @description (DRY_RUN: `PLAN HANDOVER-WIP ...`). Exit 0 ok, 1 failed, 3 scan
# @description refused, 4 ref exists with another tree.
# @param ID (required) - the lane id, e.g. c-050
# @param WIP_WORKTREE (optional) - the lane's worktree; default agents/<id>.json .worktree, else the registry rundir
# @param WIP_REMOTE (optional) - default origin
# @param WIP_GIT_NAME, WIP_GIT_EMAIL (optional) - default the repo's user.name / user.email
# @param DRY_RUN (optional) - 1 (default): scan and print the plan, push nothing
# @example ID=c-050 ./run -a do_spl_lane_handover_wip
# @example ID=c-050 DRY_RUN=0 ./run -a do_spl_lane_handover_wip
#------------------------------------------------------------------------------

do_spl_lane_handover_wip() {
  local id="${ID:-}" remote="${WIP_REMOTE:-origin}" dry="${DRY_RUN:-1}"
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { do_log "FATAL ID must be a lane id like c-050, got '$id'"; return 1; }
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local wt
  wt="$(spl_handover_worktree "$id")"
  if [[ -z "$wt" || ! -d "$wt" ]] || ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    do_log "FATAL HANDOVER-WIP $id: no git worktree (WIP_WORKTREE, agents/$id.json or the registry), got '$wt'"; return 1
  fi
  local gd
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)" || return 1
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" ]]; then
    do_log "FATAL HANDOVER-WIP $id: $wt is mid-rebase or mid-merge: finish or abort it first (nothing pushed)"; return 1
  fi

  local head tree idx trunk base ref="refs/heads/wip/handover/$id"
  head="$(git -C "$wt" rev-parse -q --verify HEAD)" || { do_log "FATAL HANDOVER-WIP $id: no HEAD in $wt"; return 1; }
  idx="$(mktemp)" || return 1
  cp "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
  tree="$(cd "$wt" && GIT_INDEX_FILE="$idx" git add -A . && GIT_INDEX_FILE="$idx" git write-tree)"
  rm -f "$idx" "$idx.lock"
  [[ -n "$tree" ]] || { do_log "FATAL HANDOVER-WIP $id: cannot write the wip tree"; return 1; }
  trunk="$(git -C "$wt" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)"
  trunk="${trunk:-$remote/master}"
  base="$(git -C "$wt" merge-base "$head" "$trunk" 2>/dev/null)" || base="$head"

  local list n=0 rc=0
  list="$(mktemp)" || return 1
  git -C "$wt" diff -z --name-only --no-renames --diff-filter=d "$base" "$tree" >"$list" || { rm -f "$list"; return 1; }
  n="$(tr -cd '\0' <"$list" | wc -c)"
  spl_handover_wip_scan "$wt" "$list" || rc=$?
  rm -f "$list"
  if (( rc == 3 )); then
    do_log "FATAL HANDOVER-WIP $id: the scan REFUSED the work (HIT lines above): NOTHING pushed. Move the named files out of $wt, then run again."
    return 3
  fi
  (( rc == 0 )) || { do_log "FATAL HANDOVER-WIP $id: the scan could not run (rc=$rc): nothing pushed"; return 1; }

  local have have_tree=""
  have="$(git -C "$wt" ls-remote "$remote" "$ref" 2>/dev/null | awk '{print $1; exit}')"
  if [[ -n "$have" ]]; then
    git -C "$wt" cat-file -e "$have^{commit}" 2>/dev/null || git -C "$wt" fetch -q "$remote" "$ref" 2>/dev/null
    have_tree="$(git -C "$wt" rev-parse -q --verify "$have^{tree}" 2>/dev/null)"
    if [[ "$have_tree" == "$tree" ]]; then
      echo "OK HANDOVER-WIP $id sha=$have ref=$ref files=$n (already there, same tree)"; return 0
    fi
    do_log "FATAL HANDOVER-WIP $id: $remote $ref exists with another tree (${have:0:12}): delete it first (git push $remote :$ref), never force"
    return 4
  fi
  if [[ "$dry" == 1 ]]; then
    echo "PLAN HANDOVER-WIP $id: scan clean ($n files past ${base:0:12}); would commit tree ${tree:0:12} on HEAD ${head:0:12} and push it to $remote $ref. DRY_RUN=0 pushes."
    return 0
  fi

  local name="${WIP_GIT_NAME:-$(git -C "$wt" config user.name)}" email="${WIP_GIT_EMAIL:-$(git -C "$wt" config user.email)}" ts src
  [[ -n "$name" && -n "$email" && "$email" != *noreply* ]] || { do_log "FATAL HANDOVER-WIP $id: no canonical author (set WIP_GIT_NAME / WIP_GIT_EMAIL)"; return 1; }
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  src="$head"
  if [[ "$tree" != "$(git -C "$wt" rev-parse "$head^{tree}")" ]]; then
    src="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
      git -C "$wt" commit-tree "$tree" -p "$head" -m "wip($id): $ts handover")" || { do_log "FATAL HANDOVER-WIP $id: commit-tree failed"; return 1; }
  fi
  git -C "$wt" push -q "$remote" "$src:$ref" || { do_log "FATAL HANDOVER-WIP $id: push to $remote $ref failed"; return 1; }
  echo "OK HANDOVER-WIP $id sha=$src ref=$ref files=$n"
}

# spl_handover_worktree <id> -> WIP_WORKTREE, else agents/<id>.json .worktree,
# else the registry rundir of <id> (the last row)
spl_handover_worktree() {
  local id="$1" root="${SPOOL_ROOT:-/var/spool-hub}" wt="${WIP_WORKTREE:-}"
  [[ -n "$wt" ]] || wt="$(jq -r '.worktree // ""' "$root/agents/$id.json" 2>/dev/null)"
  [[ -n "$wt" ]] || wt="$(awk -F'\t' -v id="$id" '$1 == id {r = $4} END {print r}' "$root/registry.tsv" 2>/dev/null)"
  printf '%s' "$wt"
}

# spl_handover_wip_scan <worktree> <NUL list of paths> -> 0 clean, 3 a HIT
# line per refused file, 2 the scan could not run. The verdict is
# box-state-pack.sh scan's (one list of patterns for the box backup and this),
# over a tar of the very bytes the push would carry, plus the 0600 rule.
spl_handover_wip_scan() {
  local wt="$1" list="$2" f m rc=0 work pack
  pack="${HANDOVER_PACK_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/box-state-pack.sh}"
  [[ -r "$pack" ]] || { echo "scan: no $pack" >&2; return 2; }
  [[ -s "$list" ]] || return 0
  while IFS= read -r -d '' f; do
    [[ -f "$wt/$f" && ! -L "$wt/$f" ]] || continue
    m="$(stat -c %a "$wt/$f")"
    [[ "${m: -3}" == 600 ]] && { echo "HIT $f 0600"; rc=3; }
  done <"$list"
  work="$(umask 077 && mktemp -d)" || return 2
  if ! (cd "$wt" && tar -cf - --null --no-recursion --ignore-failed-read -T "$list" 2>/dev/null) | zstd -q -o "$work/wip.tar.zst" 2>/dev/null; then
    rm -rf "$work"; echo "scan: cannot pack the wip files" >&2; return 2
  fi
  local out src
  out="$(bash "$pack" scan "$work/wip.tar.zst")"; src=$?
  rm -rf "$work"
  [[ -z "$out" ]] || printf '%s\n' "$out"
  case "$src" in 0) ;; 3) rc=3 ;; *) echo "scan: box-state-pack.sh scan exit $src" >&2; return 2 ;; esac
  return "$rc"
}
