#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The STALE-TREE part of do_check_pre_push (refactor round 6,
# @description row 05; extended by SPL-2253): a push from a stale tree silently
# @description set 26 paths of other lanes back to old content (8bb97690e,
# @description r5-02), and a stale copy of m-260 (aea648fbe on 97a636405) would
# @description have deleted 718 lines of 6 files, 3 of them deletions, that
# @description the old check did not count. Per outgoing commit
# @description (PRE_PUSH_BASE..HEAD), a path COUNTS when the commit:
# @description   - sets it back to a blob it held before one of its last 40
# @description     commits, and not the parent's (refactor-round-5-retro.md
# @description     section 7); or
# @description   - deletes it, and another commit (not outgoing, not citing the
# @description     commit's own SPL-n key) added or changed it within the last
# @description     40 commits before it.
# @description 3 or more counted paths -> REFUSED. A counted path whose current
# @description content came from ANOTHER LANE's commit (not outgoing, not the
# @description own SPL-n key) committed in the 24 h before the commit refuses
# @description ALONE, no 3-path threshold. Each path is named with the commit
# @description it would undo. A subject starting `Revert` or containing
# @description `restore` (case-insensitive) is exempt; a body line
# @description `Undoes: <sha>` drops the paths that undo that one commit (a
# @description deliberate redo or removal of another lane's work names it; a
# @description stale copy does not). A renamed path (git's -M) or an added one
# @description is not counted: it undoes nothing.
# @param PRE_PUSH_BASE (optional) - the push base, default origin/master
# @param STALE_TREE_RANGE (optional) - do_check_pre_push_stale_tree only: the
# @param        commits to check, default <PRE_PUSH_BASE>..HEAD
# @param STALE_TREE_TREE (optional) - do_check_pre_push_stale_tree only: the
# @param        checkout, default $APP_PATH
# @example ./run -a do_check_pre_push_stale_tree
# @example STALE_TREE_RANGE=9fefb364d..8bb97690e ./run -a do_check_pre_push_stale_tree
#------------------------------------------------------------------------------

# How far back each path's history is read, the count that refuses, and the
# window in which another lane's content refuses alone.
_PPS_DEPTH=40
_PPS_LIMIT=3
_PPS_RECENT_S=86400

# Reads one stream: "R<TAB>kind<TAB>path<TAB>new<TAB>old" rows (kind M or D),
# "O<TAB>sha" outgoing commits, "F<TAB>sha" the last 40 commits before the
# commit, then the path-limited `git log --raw` (headers "@sha<TAB>ct<TAB>subj").
# Prints "<at1|count><TAB>kind<TAB>path<TAB>sha<TAB>subject" per counted path,
# sha being the commit it would undo (the one whose content is current).
# shellcheck disable=SC2016
_PPS_AWK='
  function other(s, subj) { return !(s in own) && !(key != "" && subj ~ ("(^|[^A-Z])" key "([^0-9]|$)")) }
  function hit(cls, p) { print cls "\t" kind[p] "\t" p "\t" psha[p] "\t" psub[p]; done[p] = 1; if (--left == 0) exit }
  $1 == "R" { kind[$3] = $2; nw[$3] = $4; par[$3] = $5; left++; next }
  $1 == "O" { own[$2] = 1; next }
  $1 == "F" { f40[$2] = 1; next }
  /^@/ { sha = substr($1, 2); ct = $2; subj = $3; oth = other(sha, subj); next }
  /^:/ {
    p = $2; if (!(p in kind) || (p in done)) next
    if (!(p in psha)) {
      if (kind[p] == "D" && (sha in own)) next
      psha[p] = sha; psub[p] = subj; recent[p] = oth && ct >= cut
      if (kind[p] == "D") {
        if (recent[p]) hit("at1", p); else if (oth && (sha in f40)) hit("count", p)
        else { done[p] = 1; if (--left == 0) exit }
        next
      }
    }
    split($1, m, " ")
    if (m[3] == nw[p] && m[3] != par[p]) { hit(recent[p] ? "at1" : "count", p); next }
    if (++seen[p] >= depth) { done[p] = 1; if (--left == 0) exit }
  }
'

# The counted paths of commit <sha> (rows as _PPS_AWK prints them). Three git
# calls per commit: diff-tree (renames detected) for the modified and deleted
# paths, rev-list for the last 40 commits, then ONE path-limited log over all paths, read until
# every path is decided (the retro's per-path loop took 4.7 s on the 33 paths
# of 8bb97690e).
_pps_commit() {  # <tree> <sha> <ct> <subject> <outgoing shas, one per line>
  local tree="$1" c="$2" ct="$3" subj="$4" own="$5" meta p o n st key=""
  local -a paths=() lines=()
  git -C "$tree" rev-parse -q --verify "$c^{commit}^" >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r meta p; do
    read -r _ _ o n st <<<"$meta"
    case "$st" in M* | T*) st=M ;; D*) st=D ;; *) continue ;; esac
    paths+=("$p"); lines+=("R"$'\t'"$st"$'\t'"$p"$'\t'"$n"$'\t'"$o")
  done < <(git -C "$tree" -c core.quotePath=false diff-tree -r -M --no-abbrev --no-commit-id "$c^" "$c")
  [[ "${#paths[@]}" -gt 0 ]] || return 0
  [[ "$subj" =~ (SPL-[0-9]+) ]] && key="${BASH_REMATCH[1]}"
  awk -F'\t' -v depth="$_PPS_DEPTH" -v cut="$((ct - _PPS_RECENT_S))" -v key="$key" "$_PPS_AWK" <(
    printf '%s\n' "${lines[@]}"
    sed '/^$/d; s/^/O\t/' <<<"$own"
    git -C "$tree" rev-list -n "$_PPS_DEPTH" "$c^" 2>/dev/null | sed 's/^/F\t/'
    git -C "$tree" -c core.quotePath=false --literal-pathspecs log --no-renames --raw --no-abbrev \
      --format='tformat:@%H%x09%ct%x09%s' "$c^" -- "${paths[@]}" 2>/dev/null
  )
}

# Is <subject> a named restore, exempt from the count?
_pps_exempt() {  # <subject>
  local s="${1,,}"
  [[ "$s" == revert* || "$s" == *restore* ]]
}

# The rows of <rows> whose undone commit the body names on an "Undoes: <sha>"
# line (7+ hex chars, a prefix of the full sha) are a deliberate undo: dropped.
_pps_named() {  # <body> <rows>
  local body="$1" rows="$2" s named=""
  while read -r s; do [[ "$s" =~ ^[0-9a-f]{7,40}$ ]] && named+="$s "; done \
    < <(sed -n 's/^Undoes:[[:space:]]*\([0-9a-fA-F]*\).*/\1/p' <<<"$body" | tr 'A-F' 'a-f')
  [[ -n "$named" ]] || { printf '%s\n' "$rows"; return 0; }
  awk -F'\t' -v named="$named" '
    BEGIN { n = split(named, w, " ") }
    { for (i = 1; i <= n; i++) if (index($4, w[i]) == 1) next; print }
  ' <<<"$rows"
}

# One commit's verdict from its counted rows: rc 1 when refused, the lines
# naming each path and the commit it would undo.
_pps_verdict() {  # <sha> <subject> <rows>
  local c="$1" subj="$2" rows="$3" n a d
  n="$(grep -c . <<<"$rows")"; a="$(grep -c '^at1' <<<"$rows")"; d="$(cut -f2 <<<"$rows" | grep -c '^D')"
  [[ "$n" -ge "$_PPS_LIMIT" || "$a" -gt 0 ]] || return 0
  if _pps_exempt "$subj"; then
    echo "stale-tree: PASS ${c:0:9} undoes $n paths ($d deleted, $a of another lane's last 24 h), and its subject names a restore: $subj"
    return 0
  fi
  echo "stale-tree: REFUSED ${c:0:9} undoes $n paths ($d deleted, $a of another lane's last 24 h; the limit is $_PPS_LIMIT, or 1 of another lane's last 24 h): $subj"
  awk -F'\t' '{ printf "  stale-tree: %s %s -- undoes %.9s %s%s\n", ($2 == "D" ? "deletes" : "sets back"), $3, $4, $5, ($1 == "at1" ? " (another lane, last 24 h)" : "") }' <<<"$rows"
  return 1
}

# Check every non-merge commit of <range> (a merge's diff against its first
# parent is the other side's work, not a change of its own); rc 1 when one is
# refused.
_pps_check_range() {  # <tree> <range>
  local tree="$1" range="$2" own c ct subj rows rc=0 checked=0
  own="$(git -C "$tree" rev-list "$range" 2>/dev/null)"
  while IFS=$'\t' read -r c ct subj; do
    [[ -n "$c" ]] || continue
    checked=$((checked + 1))
    rows="$(_pps_commit "$tree" "$c" "$ct" "$subj" "$own")"
    [[ -n "$rows" ]] || continue
    rows="$(_pps_named "$(git -C "$tree" log -1 --format=%B "$c")" "$rows")"
    [[ -n "$rows" ]] || continue
    _pps_verdict "$c" "$subj" "$rows" || rc=1
  done < <(git -C "$tree" log --reverse --no-merges --format='%H%x09%ct%x09%s' "$range" 2>/dev/null)
  if [[ "$rc" -ne 0 ]]; then
    echo "stale-tree: a stale tree overwrites or deletes other lanes' landed work. Fetch, rebase onto origin/master and re-apply only your change."
    echo "stale-tree: an intended restore says so: a subject starting 'Revert' or containing 'restore'; an intended undo of one commit names it in the body: 'Undoes: <sha>'."
  else
    echo "stale-tree: PASS $checked outgoing commit(s), none undoes $_PPS_LIMIT or more paths or another lane's last 24 h"
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
