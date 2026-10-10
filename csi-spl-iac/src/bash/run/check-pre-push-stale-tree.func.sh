#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The STALE-TREE part of do_check_pre_push (refactor round 6,
# @description row 05): a push from a stale tree silently set 26 paths of other
# @description lanes back to old content (8bb97690e, r5-02) and CI never saw it,
# @description its run was cancelled. Per outgoing commit (PRE_PUSH_BASE..HEAD),
# @description a path counts when the commit sets it back to a blob it held
# @description before one of its last 40 commits, and not the parent's (the
# @description detector of refactor-round-5-retro.md section 7). 3 or more such
# @description paths -> REFUSED, naming them, unless the subject starts with
# @description `Revert` or contains `restore` (case-insensitive).
# @description Only paths modified in place count: an added, deleted or renamed
# @description path has no "before" and no "after" blob to compare.
# @param PRE_PUSH_BASE (optional) - the push base, default origin/master
# @param STALE_TREE_RANGE (optional) - do_check_pre_push_stale_tree only: the
# @param        commits to check, default <PRE_PUSH_BASE>..HEAD
# @param STALE_TREE_TREE (optional) - do_check_pre_push_stale_tree only: the
# @param        checkout, default $APP_PATH
# @example ./run -a do_check_pre_push_stale_tree
# @example STALE_TREE_RANGE=9fefb364d..8bb97690e ./run -a do_check_pre_push_stale_tree
#------------------------------------------------------------------------------

# How far back each path's history is read, and the count that refuses.
_PPS_DEPTH=40
_PPS_LIMIT=3

# The paths commit <sha> sets back to an older blob, one per line. Two git
# calls per commit: diff-tree for the modified paths, then ONE path-limited
# log over all of them, read until every path has its 40 commits or a hit
# (the retro's per-path loop took 4.7 s on the 33 paths of 8bb97690e).
_pps_commit() {  # <tree> <sha>
  local tree="$1" c="$2" meta p o n st
  local -a paths=() rows=()
  git -C "$tree" rev-parse -q --verify "$c^{commit}^" >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r meta p; do
    read -r _ _ o n st <<<"$meta"
    [[ "$st" == M* || "$st" == T* ]] || continue
    paths+=("$p"); rows+=("$p"$'\t'"$n"$'\t'"$o")
  done < <(git -C "$tree" -c core.quotePath=false diff-tree -r --no-renames --no-abbrev --no-commit-id "$c^" "$c")
  [[ "${#paths[@]}" -gt 0 ]] || return 0
  awk -v depth="$_PPS_DEPTH" -F'\t' '
    NR == FNR { nw[$1] = $2; par[$1] = $3; left++; next }
    /^:/ {
      p = $2; if (!(p in nw) || (p in done)) next
      split($1, m, " "); src = m[3]
      if (src == nw[p] && src != par[p]) { print p; done[p] = 1; if (--left == 0) exit; next }
      if (++seen[p] >= depth) { done[p] = 1; if (--left == 0) exit }
    }
  ' <(printf '%s\n' "${rows[@]}") \
    <(git -C "$tree" -c core.quotePath=false --literal-pathspecs log --no-renames --raw --no-abbrev \
        --format=tformat:@ "$c^" -- "${paths[@]}" 2>/dev/null)
}

# Is <subject> a named restore, exempt from the count?
_pps_exempt() {  # <subject>
  local s="${1,,}"
  [[ "$s" == revert* || "$s" == *restore* ]]
}

# Check every non-merge commit of <range> (a merge's diff against its first
# parent is the other side's work, not a change of its own); rc 1 when one sets
# back 3 or more paths.
_pps_check_range() {  # <tree> <range>
  local tree="$1" range="$2" c subj hits n rc=0 checked=0
  while read -r c; do
    [[ -n "$c" ]] || continue
    checked=$((checked + 1))
    hits="$(_pps_commit "$tree" "$c")"
    n=0; [[ -n "$hits" ]] && n="$(wc -l <<<"$hits")"
    [[ "$n" -ge "$_PPS_LIMIT" ]] || continue
    subj="$(git -C "$tree" log -1 --format=%s "$c")"
    if _pps_exempt "$subj"; then
      echo "stale-tree: PASS ${c:0:9} sets $n paths back, and its subject names a restore: $subj"
      continue
    fi
    echo "stale-tree: REFUSED ${c:0:9} sets $n paths back to a blob they held before one of their last $_PPS_DEPTH commits: $subj"
    sed 's/^/  stale-tree: /' <<<"$hits"
    rc=1
  done < <(git -C "$tree" rev-list --reverse --no-merges "$range" 2>/dev/null)
  if [[ "$rc" -ne 0 ]]; then
    echo "stale-tree: a stale tree overwrites other lanes' landed work. Fetch, rebase onto origin/master and re-apply only your change."
    echo "stale-tree: an intended restore says so: a subject starting 'Revert' or containing 'restore'."
  else
    echo "stale-tree: PASS $checked outgoing commit(s), none sets $_PPS_LIMIT or more paths back"
  fi
  return "$rc"
}

# The part: the commits this push carries, PRE_PUSH_BASE..HEAD. An unknown
# base has no outgoing range to read, so it passes and says so (the gate
# itself already WARNs and widens to FULL for it).
_pp_part_stale_tree() {  # <tree>
  local tree="$1" base="${PRE_PUSH_BASE:-origin/master}"
  if ! git -C "$tree" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    echo "stale-tree: WARN unknown base '$base' -- no outgoing commits to check"
    return 0
  fi
  _pps_check_range "$tree" "$base..HEAD"
}

do_check_pre_push_stale_tree() {
  local tree="${STALE_TREE_TREE:-$APP_PATH}" range="${STALE_TREE_RANGE:-${PRE_PUSH_BASE:-origin/master}..HEAD}"
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 \
    || { do_log "FATAL stale-tree: $tree is not a git checkout"; return 2; }
  if _pps_check_range "$tree" "$range"; then
    do_log "INFO stale-tree: PASS $range"
    return 0
  fi
  do_log "FATAL stale-tree: REFUSED $range"
  return 1
}
