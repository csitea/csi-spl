#!/bin/bash
#------------------------------------------------------------------------------
# @description List, and with DRY_RUN=0 delete, one or more refactor rounds'
# @description review and wip branches on the remote: review/r<N>-*, wip/*r<N>*
# @description and the lane-prefixed <id>-r<N>-* and review/<id>-r<N>-*
# @description (<id> = [acgmq]-NNN) for each round N (refactor-round-8-plan.md
# @description row 10; several rounds in one run: round 9 plan row 08; lane
# @description prefix and unlanded tips: round 10 plan row 09). One REF line per
# @description branch: the branch, its tip sha and its tip's commit date.
# @description A tip with commits not cherry-equal to the remote's master
# @description (git cherry + lines, a squash-landed branch included) prints
# @description KEEP <branch> <n> unlanded and is never deleted, unless
# @description PRUNE_UNLANDED=1; a tip that cannot be checked prints KEEP with ?.
# @description DRY_RUN=1 (the default) deletes nothing. DRY_RUN=0 deletes only
# @description the REF branches, in one atomic push, and prints a DELETED
# @description line each. master / main, and any ref outside the patterns,
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
# @param PRUNE_UNLANDED (optional) - 1 lists (and deletes) unlanded tips too; default 0
# @example ROUND=7 ./run -a do_git_prune_round_branches
# @example ROUND=7 DRY_RUN=0 ./run -a do_git_prune_round_branches
# @example ROUND="7,8" ./run -a do_git_prune_round_branches
# @example ROUNDS="7 8 9" DRY_RUN=0 ./run -a do_git_prune_round_branches
#------------------------------------------------------------------------------

# prune_round_match <round> <branch>: 0 when the branch (no refs/heads/) is one
# of that round's review, wip or lane-prefixed branches. Never master or main.
prune_round_match() {
  local n="$1" b="$2"
  case "$b" in master | main) return 1 ;; esac
  [[ "$b" == "review/r${n}-"* ]] && return 0
  [[ "$b" =~ ^(review/)?[acgmq]-[0-9]{3}-r${n}- ]] && return 0
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

# prune_round_patterns <round>...: "review/r7-*, wip/*r7* or [review/]<id>-r7-*"
# per round, joined.
prune_round_patterns() {
  local n out=""
  for n in "$@"; do out+="${out:+, }review/r${n}-*, wip/*r${n}* or [review/]<id>-r${n}-*"; done
  echo "$out"
}

# prune_round_trunk <git-dir> <remote>: "<sha>\t<branch>" of the remote's
# master, else its main; empty when it has neither.
prune_round_trunk() {
  git -C "$1" ls-remote "$2" refs/heads/master refs/heads/main 2>/dev/null \
    | awk '{ b = $2; sub("refs/heads/", "", b); t[b] = $1 } END { if ("master" in t) b = "master"; else if ("main" in t) b = "main"; else exit; print t[b] "\t" b }'
}

# prune_round_unlanded <git-dir> <trunk-sha> <tip-sha>: the count of the tip's
# commits not cherry-equal to trunk (git cherry + lines), or ? when it cannot
# be checked (no trunk on the remote, or an object is not here).
prune_round_unlanded() {
  local out
  [[ -n "$2" ]] || { echo '?'; return 0; }
  out="$(git -C "$1" cherry "$2" "$3" 2>/dev/null)" || { echo '?'; return 0; }
  grep -c '^+' <<<"$out"
}

# prune_round_date <git-dir> <sha>: the tip's commit date, or ? when the
# object is not here (the fetch in do_git_prune_round_branches failed).
prune_round_date() {
  git -C "$1" log -1 --format=%cI "$2" 2>/dev/null || echo '?'
}

do_git_prune_round_branches() {
  local spec="${ROUNDS:-${ROUND:-}}" dry="${DRY_RUN:-1}" r="${PRUNE_REMOTE:-origin}" g="${PRUNE_GIT_DIR:-${PROJ_PATH:-.}}"
  local list b sha left n trunk u count=0 kept=0 refs=() rounds=() del=() still=""

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
  trunk="$(prune_round_trunk "$g" "$r")"
  # the tips' and trunk's objects, for dates and git cherry; no local ref is written
  git -C "$g" fetch -q --no-tags --no-write-fetch-head "$r" "${refs[@]}" ${trunk:+"refs/heads/${trunk#*$'\t'}"} 2>/dev/null || true
  trunk="${trunk%%$'\t'*}"

  refs=()
  while IFS=$'\t' read -r b sha; do
    u="$(prune_round_unlanded "$g" "$trunk" "$sha")"
    if [[ "$u" != 0 && "${PRUNE_UNLANDED:-0}" != 1 ]]; then
      printf 'KEEP %s %s unlanded\n' "$b" "$u"
      kept=$((kept + 1))
      continue
    fi
    printf 'REF %s %s %s\n' "$b" "$sha" "$(prune_round_date "$g" "$sha")"
    refs+=("refs/heads/$b")
    del+=("$b"$'\t'"$sha")
    count=$((count + 1))
  done <<<"$list"

  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN round $n: $count branch(es) listed, $kept kept unlanded on $r, nothing deleted (DRY_RUN=0 deletes the listed)"
    return 0
  fi
  ((count)) || { do_log "OK round $n: nothing to delete on $r, $kept kept unlanded"; return 0; }

  git -C "$g" push -q --atomic "$r" --delete "${refs[@]}" || { do_log "FATAL the delete push to $r failed; nothing deleted"; return 1; }
  printf 'DELETED %s\n' "${del[@]}" | tr '\t' ' '
  left="$(prune_round_list "$g" "$r" "${rounds[@]}")" || { do_log "FAIL cannot re-list $r after the delete"; return 1; }
  still="$(cut -f1 <<<"$left" | grep -Fxf <(printf '%s\n' "${del[@]%%$'\t'*}") | paste -sd' ' -)"
  [[ -z "$still" ]] || { do_log "FAIL round $n branches still on $r after the delete: $still"; return 1; }
  do_log "OK round $n: deleted $count branch(es) on $r, $kept kept unlanded"
}
