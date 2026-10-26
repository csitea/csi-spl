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
# @description A round is named by its number (r<N> = 7 or the zero-padded
# @description 01) or by its branch prefix (r01, sdlc, b01): the prefix then
# @description takes the place of r<N> in every pattern, e.g. ROUND=sdlc
# @description matches review/sdlc-*, wip/*sdlc* and [review/]<id>-sdlc-*
# @description (bug round 1 retro; SPL-2525).
# @description Run with DRY_RUN=0 only by the round's retro lane, after the
# @description retro has run C7 over the review branches (round plan R7.4, R8).
# @description PRUNE_ALL_MERGED=1 (no ROUND; SPL-3609, owner msg 34b232f4: "for
# @description all of the merged already github branches - just delete them")
# @description takes EVERY head on the remote instead, with the same cherry
# @description check, and KEEPs and lists by reason: trunk (master, main),
# @description ruleset (ruleset*), protected (GitHub's protected branches),
# @description live-lane (a live lane's branch and its review/ and wip/ names,
# @description lane-map.sh --json --all, every machine) and unlanded. DRY_RUN=0
# @description is refused when the lane map or the protected list cannot be
# @description read whole. Deletes go in atomic pushes of PRUNE_BATCH refs.
# @description PRUNE_UNLANDED=1 is refused in this mode. The box cron row
# @description git-prune-merged (cnf/box-crons/box-crons.manifest) runs it.
# @param ROUND (required, or ROUNDS) - the round(s), e.g. 8, "7,8", 01, r01, sdlc or b01
# @param ROUND a number N means prefix r<N> as written (01 = r01, not r1); a
# @param ROUND prefix is [a-z][a-z0-9]+ (2+ characters), r0 / 00 refused
# @param ROUNDS (optional) - the same list under its plural name, e.g. "7 8";
# @param ROUNDS set ROUND or ROUNDS, not both. Separators: comma and/or space
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PRUNE_REMOTE (optional) - the remote, default origin
# @param PRUNE_GIT_DIR (optional) - the checkout to run git in, default PROJ_PATH
# @param PRUNE_UNLANDED (optional) - 1 lists (and deletes) unlanded tips too; default 0
# @param PRUNE_ALL_MERGED (optional) - 1: every merged head, not a round (no ROUND)
# @param PRUNE_BATCH (optional) - refs per atomic delete push, default 100
# @param PRUNE_LANES_CMD (optional) - prints the lane map JSON, default
# @param   lane-map.sh --json --all
# @param PRUNE_PROTECTED_CMD (optional) - prints the protected branch names,
# @param   default gh api repos/<owner>/<repo>/branches?protected=true
# @example ROUND=7 ./run -a do_git_prune_round_branches
# @example ROUND=7 DRY_RUN=0 ./run -a do_git_prune_round_branches
# @example ROUND="7,8" ./run -a do_git_prune_round_branches
# @example ROUNDS="7 8 9" DRY_RUN=0 ./run -a do_git_prune_round_branches
# @example ROUND="r01,sdlc,b01" ./run -a do_git_prune_round_branches
# @example PRUNE_ALL_MERGED=1 ./run -a do_git_prune_round_branches
# @example PRUNE_ALL_MERGED=1 DRY_RUN=0 ./run -a do_git_prune_round_branches
#------------------------------------------------------------------------------

# prune_round_match <prefix> <branch>: 0 when the branch (no refs/heads/) is
# one of that round's review, wip or lane-prefixed branches. Never master or
# main. In wip/ a prefix ending in a digit is not followed by one (r7 is not
# r70), a prefix ending in a letter not by a letter or digit (sdlc not sdlcx).
prune_round_match() {
  local p="$1" b="$2" tail='[^0-9]'
  case "$b" in master | main) return 1 ;; esac
  [[ "$p" == *[0-9] ]] || tail='[^0-9A-Za-z]'
  [[ "$b" == "review/${p}-"* ]] && return 0
  [[ "$b" =~ ^(review/)?[acgmq]-[0-9]{3}-${p}- ]] && return 0
  [[ "$b" =~ ^wip/(.*[^0-9A-Za-z])?${p}(${tail}.*)?$ ]]
}

# prune_round_parse <spec>: the branch prefixes of "7", "7,8", "7 8", "01",
# "r01,sdlc,b01", one per line, in order, each once: a number N is r<N> as
# written, any other [a-z][a-z0-9]+ is the prefix itself. Non-zero on an empty
# list, a zero round (0, 00, r0) or anything else.
prune_round_parse() {
  local n seen=" " parts=()
  read -ra parts <<<"${1//,/ }"
  ((${#parts[@]})) || return 1
  for n in "${parts[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] && n="r$n"
    [[ "$n" =~ ^[a-z][a-z0-9]+$ && ! "$n" =~ ^r0+$ ]] || return 1
    [[ "$seen" == *" $n "* ]] && continue
    seen+="$n "
    echo "$n"
  done
}

# prune_round_list <git-dir> <remote> <prefix>...: one "<branch>\t<sha>" line
# per head on the remote that matches any of the rounds, each head once.
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

# prune_round_patterns <prefix>...: "review/r7-*, wip/*r7* or [review/]<id>-r7-*"
# per round, joined.
prune_round_patterns() {
  local p out=""
  for p in "$@"; do out+="${out:+, }review/${p}-*, wip/*${p}* or [review/]<id>-${p}-*"; done
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

  if [[ "${PRUNE_ALL_MERGED:-0}" == 1 ]]; then
    [[ -z "$spec" ]] || { do_log "FATAL PRUNE_ALL_MERGED=1 takes no ROUND or ROUNDS, got: '$spec'"; return 1; }
    prune_all_merged "$g" "$r" "$dry"
    return
  fi
  [[ -z "${ROUND:-}" || -z "${ROUNDS:-}" ]] || { do_log "FATAL set ROUND or ROUNDS, not both: ROUND='$ROUND' ROUNDS='$ROUNDS'"; return 1; }
  n="$(prune_round_parse "$spec")" || { do_log "FATAL ROUND must be round numbers or branch prefixes, e.g. ROUND=8, ROUND=\"7,8\" or ROUND=\"r01,sdlc,b01\", got: '$spec'"; return 1; }
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

# --- PRUNE_ALL_MERGED=1: every merged head (SPL-3609) ------------------------

# prune_all_lane_map: the fleet lane map JSON (every machine) on stdout;
# non-zero when it cannot be read whole: the command failed, the output is not
# the map, or the hub did not answer (the other machines' lanes are unknown).
prune_all_lane_map() {
  local cmd="${PRUNE_LANES_CMD:-}" out
  [[ -n "$cmd" ]] || cmd="bash '${PROJ_PATH:-.}/src/bash/features/spawn-agents/scripts/lane-map.sh' --json --all"
  out="$(bash -c "$cmd" 2>/dev/null)" || return 1
  jq -e '.hub == "ok" and (.lanes | type == "array")' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# prune_all_lanes <json>: "<branch>\t<id>@<box>" per name a LIVE lane holds:
# its branch, and review/ and wip/ of the branch and of its slug (the branch
# less its "<id>-" prefix: c-057-x has review/x).
prune_all_lanes() {
  jq -r '.lanes[] | select(.state == "live" and (.branch // "") != "")
    | (.agent_id // "") as $a | .branch as $b | ($b | ltrimstr($a + "-")) as $s
    | ([$b, "review/" + $b, "wip/" + $b, "review/" + $s, "wip/" + $s] | unique[])
      + "\t" + $a + "@" + (.agent_box // "?")' <<<"$1"
}

# prune_all_protected <git-dir> <remote>: the remote repo's protected branch
# names (GitHub), one per line; non-zero when they cannot be read.
prune_all_protected() {
  local url
  if [[ -n "${PRUNE_PROTECTED_CMD:-}" ]]; then bash -c "$PRUNE_PROTECTED_CMD"; return; fi
  url="$(git -C "$1" remote get-url "$2" 2>/dev/null)" || return 1
  [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]] || return 1
  gh api --paginate "repos/${BASH_REMATCH[1]%.git}/branches?protected=true" --jq '.[].name'
}

# prune_all_reason <branch>: why a head is KEPT before the cherry check
# (trunk, ruleset, protected, live-lane <id>@<box>), else nothing. Reads the
# caller's protected and lanes lists.
prune_all_reason() {
  local b="$1" hit
  case "$b" in master | main) echo trunk; return ;; ruleset*) echo ruleset; return ;; esac
  grep -Fxq -- "$b" <<<"$protected" && { echo protected; return; }
  hit="$(awk -F'\t' -v b="$b" '$1 == b { print $2; exit }' <<<"$lanes")"
  [[ -z "$hit" ]] || echo "live-lane $hit"
}

# prune_all_delete <git-dir> <remote> <batch> <branch\tsha>...: delete in
# atomic pushes of <batch> refs, a DELETED line per ref of a pushed batch; a
# failed batch is logged and the others still go. Non-zero when a batch failed
# or a deleted ref is still on the remote.
prune_all_delete() {
  local g="$1" r="$2" n="$3" i bad=0 left still all=() part=() refs=() done=()
  shift 3
  all=("$@")
  for ((i = 0; i < ${#all[@]}; i += n)); do
    part=("${all[@]:i:n}")
    refs=("${part[@]%%$'\t'*}")
    if git -C "$g" push -q --atomic "$r" --delete "${refs[@]/#/refs/heads/}"; then
      printf 'DELETED %s\n' "${part[@]}" | tr '\t' ' '
      done+=("${refs[@]}")
    else
      do_log "FAIL the delete push of batch $((i / n + 1)) (${#part[@]} refs) to $r failed; that batch is kept"
      bad=1
    fi
  done
  ((${#done[@]})) || return 1
  left="$(git -C "$g" ls-remote --heads "$r")" || { do_log "FAIL cannot re-list $r after the delete"; return 1; }
  still="$(sed 's#.*refs/heads/##' <<<"$left" | grep -Fxf <(printf '%s\n' "${done[@]}") | paste -sd' ' -)"
  [[ -z "$still" ]] || { do_log "FAIL deleted branches still on $r: $still"; return 1; }
  return "$bad"
}

# prune_all_merged <git-dir> <remote> <dry>: list every head of the remote as
# REF (merged: no git cherry + line against trunk) or KEEP <reason>, and with
# dry 0 delete the REF heads. The tally line names DELETE n and KEEP n by reason.
prune_all_merged() {
  local g="$1" r="$2" dry="$3" n="${PRUNE_BATCH:-100}" heads trunk lanes protected whole=1
  local b sha ref u why tally="" count=0 kept=0 refs=() del=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL PRUNE_BATCH must be a positive number, got: '$n'"; return 1; }
  [[ "${PRUNE_UNLANDED:-0}" != 1 ]] || { do_log "FATAL PRUNE_UNLANDED=1 is refused with PRUNE_ALL_MERGED=1: merged branches only"; return 1; }
  heads="$(git -C "$g" ls-remote --heads "$r")" || { do_log "FATAL cannot list the heads of remote '$r' from $g"; return 1; }
  if lanes="$(prune_all_lane_map)"; then lanes="$(prune_all_lanes "$lanes")"; else
    lanes="" whole=0; echo "WARN the fleet lane map could not be read whole: live lanes unknown"
  fi
  protected="$(prune_all_protected "$g" "$r")" || { protected="" whole=0; echo "WARN the protected branch list of $r could not be read"; }
  ((whole)) || [[ "$dry" == 1 ]] || { do_log "FATAL DRY_RUN=0 refused: the lane map or the protected list is not whole; nothing deleted"; return 1; }
  trunk="$(prune_round_trunk "$g" "$r")"
  while read -r sha ref; do [[ -n "$ref" ]] && refs+=("$ref"); done <<<"$heads"
  # the tips' objects, for dates and git cherry; no local ref is written
  git -C "$g" fetch -q --no-tags --no-write-fetch-head "$r" "${refs[@]}" 2>/dev/null || true
  trunk="${trunk%%$'\t'*}"
  while read -r sha ref; do
    b="${ref#refs/heads/}"
    [[ -n "$b" ]] || continue
    why="$(prune_all_reason "$b")"
    if [[ -z "$why" ]]; then u="$(prune_round_unlanded "$g" "$trunk" "$sha")"; [[ "$u" == 0 ]] || why="unlanded $u"; fi
    if [[ -n "$why" ]]; then
      printf 'KEEP %s %s\n' "$b" "$why"
      tally+="${why%% *}"$'\n' kept=$((kept + 1))
      continue
    fi
    printf 'REF %s %s %s\n' "$b" "$sha" "$(prune_round_date "$g" "$sha")"
    del+=("$b"$'\t'"$sha") count=$((count + 1))
  done <<<"$heads"
  why="$(sort <<<"$tally" | uniq -c | awk 'NF == 2 { printf "%s%s %s", s, $2, $1; s = ", " }')"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN all merged on $r: DELETE $count, KEEP $kept (${why:-none}), nothing deleted (DRY_RUN=0 deletes the REF lines)"
    return 0
  fi
  ((count)) || { do_log "OK all merged on $r: nothing to delete, KEEP $kept (${why:-none})"; return 0; }
  prune_all_delete "$g" "$r" "$n" "${del[@]}" || { do_log "FAIL all merged on $r: not every listed branch was deleted (the lines above)"; return 1; }
  do_log "OK all merged on $r: deleted $count branch(es) in batches of $n, KEEP $kept (${why:-none})"
}
