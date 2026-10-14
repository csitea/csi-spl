#!/bin/bash
#------------------------------------------------------------------------------
# @description List, and with DRY_RUN=0 delete, one or more refactor rounds'
# @description review and wip branches on the remote: review/r<N>-* and wip/*r<N>*
# @description for each round N (refactor-round-8-plan.md row 10; several rounds
# @description in one run: round 9 plan row 08). One REF line per branch: the
# @description branch, its tip sha and its tip's commit date.
# @description DRY_RUN=1 (the default) deletes nothing. DRY_RUN=0 deletes only
# @description the listed branches, in one atomic push, and prints a DELETED
# @description line each. master / main, and any ref outside the two patterns,
# @description are never deleted. In wip/*r<ROUND>* the r<ROUND> stands alone:
# @description wip/x-r17-y and wip/x-r70-y are not round 7's.
# @description Run with DRY_RUN=0 only by the round's retro lane, after the
# @description retro has run C7 over the review branches (round plan R7.4, R8).
# @param ROUND (required, or ROUNDS) - the round number(s), e.g. 8, or "7,8"
# @param ROUNDS (optional) - the same list under its plural name, e.g. "7 8";
# @param ROUNDS set ROUND or ROUNDS, not both. Separators: comma and/or space
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PRUNE_REMOTE (optional) - the remote, default origin
# @param PRUNE_GIT_DIR (optional) - the checkout to run git in, default PROJ_PATH
# @example ROUND=7 ./run -a do_git_prune_round_branches
# @example ROUND=7 DRY_RUN=0 ./run -a do_git_prune_round_branches
# @example ROUND="7,8" ./run -a do_git_prune_round_branches
# @example ROUNDS="7 8 9" DRY_RUN=0 ./run -a do_git_prune_round_branches
#------------------------------------------------------------------------------

# prune_round_match <round> <branch>: 0 when the branch (no refs/heads/) is one
# of that round's review or wip branches. Never master or main.
prune_round_match() {
  local n="$1" b="$2"
  case "$b" in master | main) return 1 ;; esac
  [[ "$b" == "review/r${n}-"* ]] && return 0
  [[ "$b" =~ ^wip/(.*[^0-9A-Za-z])?r${n}([^0-9].*)?$ ]]
}

# prune_round_parse <spec>: the round numbers of "7", "7,8" or "7 8", one per
# line, in order, each once. Non-zero on an empty list or a non-number.
prune_round_parse() {
  local n seen=" " parts=()
  read -ra parts <<<"${1//,/ }"
  ((${#parts[@]})) || return 1
  for n in "${parts[@]}"; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$seen" == *" $n "* ]] && continue
    seen+="$n "
    echo "$n"
  done
}

# prune_round_list <git-dir> <remote> <round>...: one "<branch>\t<sha>" line per
# head on the remote that matches any of the rounds, each head once.
prune_round_list() {
  local g="$1" r="$2" heads sha ref b n
  shift 2
  heads="$(git -C "$g" ls-remote --heads "$r")" || return 1
  while read -r sha ref; do
    [[ -n "$ref" ]] || continue
    b="${ref#refs/heads/}"
    for n in "$@"; do
      prune_round_match "$n" "$b" && { printf '%s\t%s\n' "$b" "$sha"; break; }
    done
  done <<<"$heads"
  return 0
}

# prune_round_patterns <round>...: "review/r7-* or wip/*r7*" per round, joined.
prune_round_patterns() {
  local n out=""
  for n in "$@"; do out+="${out:+, }review/r${n}-* or wip/*r${n}*"; done
  echo "$out"
}

# prune_round_date <git-dir> <sha>: the tip's commit date, or ? when the
# object is not here (the fetch in do_git_prune_round_branches failed).
prune_round_date() {
  git -C "$1" log -1 --format=%cI "$2" 2>/dev/null || echo '?'
}

do_git_prune_round_branches() {
  local spec="${ROUNDS:-${ROUND:-}}" dry="${DRY_RUN:-1}" r="${PRUNE_REMOTE:-origin}" g="${PRUNE_GIT_DIR:-${PROJ_PATH:-.}}"
  local list b sha left n count=0 refs=() rounds=()

  [[ -z "${ROUND:-}" || -z "${ROUNDS:-}" ]] || { do_log "FATAL set ROUND or ROUNDS, not both: ROUND='$ROUND' ROUNDS='$ROUNDS'"; return 1; }
  n="$(prune_round_parse "$spec")" || { do_log "FATAL ROUND must be round numbers, e.g. ROUND=8 or ROUND=\"7,8\", got: '$spec'"; return 1; }
  mapfile -t rounds <<<"$n"
  n="${rounds[*]}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }

  list="$(prune_round_list "$g" "$r" "${rounds[@]}")" || { do_log "FATAL cannot list the heads of remote '$r' from $g"; return 1; }
  if [[ -z "$list" ]]; then
    do_log "OK round $n: no $(prune_round_patterns "${rounds[@]}") branch on $r"
    return 0
  fi
  while IFS=$'\t' read -r b sha; do refs+=("refs/heads/$b"); done <<<"$list"
  # the tips' objects, for their dates; no local ref is written
  git -C "$g" fetch -q --no-tags --no-write-fetch-head "$r" "${refs[@]}" 2>/dev/null || true

  while IFS=$'\t' read -r b sha; do
    printf 'REF %s %s %s\n' "$b" "$sha" "$(prune_round_date "$g" "$sha")"
    count=$((count + 1))
  done <<<"$list"

  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN round $n: $count branch(es) listed on $r, nothing deleted (DRY_RUN=0 deletes them)"
    return 0
  fi

  git -C "$g" push -q --atomic "$r" --delete "${refs[@]}" || { do_log "FATAL the delete push to $r failed; nothing deleted"; return 1; }
  while IFS=$'\t' read -r b sha; do printf 'DELETED %s %s\n' "$b" "$sha"; done <<<"$list"
  left="$(prune_round_list "$g" "$r" "${rounds[@]}")" || left="?"
  [[ -z "$left" ]] || { do_log "FAIL round $n branches still on $r after the delete: $(cut -f1 <<<"$left" | paste -sd' ' -)"; return 1; }
  do_log "OK round $n: deleted $count branch(es) on $r"
}
