#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_live_proof: the proof a "**Live**" post to a human must carry
# (SPL-2122; how-to-post.md rule 16). Owner HUM-10, t1 topic 28559e83, msgs
# 395a375b and 6c3fd53d: a dispatcher posted **Live**
# "every card is the same height" from a lane report that never measured the
# image cards, then had to take it back. Rules 14 and 15 said so in prose
# only; do_spl_desk_reply and do_spl_desk_post now refuse such a post (FATAL,
# nothing sent) unless the body carries:
#   1. at least one commit sha of this checkout, and every one it names is on
#      origin/master (`git merge-base --is-ancestor <sha> origin/master`,
#      after a git-fetch-fresh.sh fetch);
#   2. per sha: when it changed a hub or wui build input, dev AND prd serve it
#      (_spl_served_components / _spl_served_env of do_check_lane_served,
#      i.e. do_check_deploy_lag), judged only on the components whose input
#      it changed (SPL-3746: a blog-only sha is not held by a pending hub
#      roll; a mixed one needs both); when it changed none, the body says
#      `no deploy`;
#   3. a `checked:` line naming the measured cases and a `not checked:` line
#      (it may say `none`).
# A hex word that is no commit of this checkout (a msg id, a topic prefix) is
# not a sha; an all-digit word that is one is (SPL-2706: "704617890" was
# refused while the full sha passed). Any other opening (**Planned, not built
# yet**, **In progress**, **Landed, not live yet**, a poll form, plain text)
# is not checked.
# SPL-2420: LIVE_REPO=<name> proves shas of a customer repo the cnf knows
# (env.box.landed_repos, see spl_landed_repo) instead: its clone on this box
# (else one FATAL naming this box and the cnf's), fetched, every sha an
# ancestor of origin/<its trunk>; rule 2 is skipped (no hub or wui build of
# csi-spl serves another repo). Never gh compare (its "behind" = trunk lacks it).
# Reads only: one fetch, local git, the deploy-lag probes. Nothing is mutated.
# Env: LIVE_REPO (default none: this checkout),
#      LANE_WT (default APP_PATH), LANE_FETCH_SCRIPT (default git-fetch-fresh.sh),
#      LANE_REMOTE / LANE_BRANCH (default origin / master),
#      LANE_ENVS (default "dev prd"), the same knobs as do_check_lane_served.
#------------------------------------------------------------------------------

# spl_desk_live_opens <body>: 0 when the body's first words are **Live**
# (leading blank lines and @-mentions skipped: a reply in a topic is tagged).
spl_desk_live_opens() {
  local first
  first="$(sed -n -E '/[^[:space:]]/{p;q}' <<<"$1")"
  first="$(sed -E 's/^[[:space:]]*(@[A-Za-z0-9_-]+[[:space:],:]*)*//' <<<"$first")"
  grep -qiE '^\*\*live(\*\*|[[:space:]]*[:.!,(])' <<<"$first"
}

# spl_desk_live_proof <body>: 0 when the body does not open with **Live**, or
# carries its proof; else one FATAL per missing piece and 1.
spl_desk_live_proof() {
  local body="$1"
  spl_desk_live_opens "$body" || return 0
  local wt="${LANE_WT:-$APP_PATH}" remote="${LANE_REMOTE:-origin}" branch="${LANE_BRANCH:-master}"
  local fetch="${LANE_FETCH_SCRIPT:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/git-fetch-fresh.sh}"
  local -a miss=()
  local lead='^[[:space:]>*_-]*'
  grep -qiE "${lead}checked[*_]*[[:space:]]*:[*_[:space:]]*[^*_[:space:]]" <<<"$body" ||
    miss+=("a 'checked:' line listing the cases you measured")
  grep -qiE "${lead}not[[:space:]]+checked[*_]*[[:space:]]*:[*_[:space:]]*[^*_[:space:]]" <<<"$body" ||
    miss+=("a 'not checked:' line (it may say 'none')")

  if [[ -n "${LIVE_REPO:-}" ]]; then
    spl_desk_live_repo_proof "$body" "${miss[@]}"
    return
  fi

  local -a shas=()
  local tok full seen=" " fetched=1
  bash "$fetch" -C "$wt" --remote "$remote" --branch "$branch" >/dev/null 2>&1 || fetched=0
  while read -r tok; do
    [[ -n "$tok" ]] || continue
    full="$(git -C "$wt" rev-parse --verify -q "$tok^{commit}" 2>/dev/null)" || continue
    [[ "$seen" == *" $full "* ]] && continue
    seen+="$full "; shas+=("$full")
  done < <(sed -E 's/[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}//g' <<<"$body" | grep -oE '\b[0-9a-f]{7,40}\b')

  if (( ${#shas[@]} == 0 )); then
    miss+=("a commit sha on $remote/$branch (none of the body's hex words is a commit of $wt; a customer repo's sha: LIVE_REPO=<cnf name>)")
  elif (( ! fetched )); then
    miss+=("a fetch of $remote/$branch to prove the sha(s) landed (the fetch failed)")
  else
    local s e v comps parent
    for s in "${shas[@]}"; do
      if ! git -C "$wt" merge-base --is-ancestor "$s" "$remote/$branch" 2>/dev/null; then
        miss+=("sha ${s:0:9} on $remote/$branch (it is not: say **Landed, not live yet** only once it is, rule 14)")
        continue
      fi
      parent="$(git -C "$wt" rev-parse --verify -q "$s^" 2>/dev/null)" || parent="$s"
      comps="$(_spl_served_components "$wt" "$parent" "$s" 2>/dev/null)"
      if [[ -z "$comps" ]]; then
        grep -qiE '\bno[[:space:]-]+deploy\b' <<<"$body" ||
          miss+=("the words 'no deploy' for sha ${s:0:9}: it changed no hub or wui build input, so no build serves it")
        continue
      fi
      for e in ${LANE_ENVS:-dev prd}; do
        v="$(_spl_served_env "$e" "$wt" "$s" "$comps" 2>/dev/null)"
        [[ "$v" == served ]] || miss+=("sha ${s:0:9} served on $e (do_check_deploy_lag says: ${v:-unknown}) judged on: $comps")
      done
    done
  fi

  spl_desk_live_verdict "${miss[@]}"
}

# spl_desk_live_verdict [MISSING...]: 0 with none, else the FATAL list and 1.
spl_desk_live_verdict() {
  (( $# == 0 )) && return 0
  do_log "FATAL a **Live** post must carry its proof; nothing was sent. Missing:"
  local m
  for m in "$@"; do do_log "FATAL   - $m"; done
  do_log "FATAL the rule: csi-spl-doc/doc/help/how-to-post.md rule 16 (Live = on master AND served on dev and prd, rule 14). Not proven yet? Open with **Landed, not live yet** or **In progress** instead."
  return 1
}

# spl_desk_live_repo_proof BODY [MISSING...]: the LIVE_REPO proof (SPL-2420),
# through the shared spl_landed_repo / spl_landed_repo_trunk of
# spl-lane-issue.func.sh. A clone that is not on this box ends it at once:
# no sha can be checked here.
spl_desk_live_repo_proof() {
  local body="$1" name="$LIVE_REPO" err row clone trunk tok full seen=" " n=0
  shift
  local -a miss=("$@")
  err="$(mktemp)" || return 1
  row="$(spl_landed_repo "$name" 2>"$err")" || { cat "$err" >&2; rm -f "$err"; return 1; }
  clone="${row%%$'\t'*}"
  trunk="$(spl_landed_repo_trunk "$name" "$clone" "${row#*$'\t'}" 2>"$err")" ||
    { miss+=("$(sed -E -n '1s/^.*FATAL //p' "$err")"); rm -f "$err"; spl_desk_live_verdict "${miss[@]}"; return; }
  rm -f "$err"
  while read -r tok; do
    [[ -n "$tok" ]] || continue
    full="$(spl_landed_repo_git "$clone" rev-parse --verify -q "$tok^{commit}" 2>/dev/null)" || continue
    [[ "$seen" == *" $full "* ]] && continue
    seen+="$full "; n=$((n + 1))
    spl_landed_repo_git "$clone" merge-base --is-ancestor "$full" "refs/remotes/origin/$trunk" 2>/dev/null ||
      miss+=("$name sha ${full:0:9} on origin/$trunk (it is not: say **Landed, not live yet** only once it is, rule 14)")
  done < <(sed -E 's/[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}//g' <<<"$body" | grep -oE '\b[0-9a-f]{7,40}\b')
  (( n )) || miss+=("a commit sha of $name on origin/$trunk (none of the body's hex words is a commit of $clone)")
  spl_desk_live_verdict "${miss[@]}"
}
