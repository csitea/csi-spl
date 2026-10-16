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
#      (_spl_served_needs_deploy / _spl_served_env of do_check_lane_served,
#      i.e. do_check_deploy_lag); when it changed none, the body says
#      `no deploy`;
#   3. a `checked:` line naming the measured cases and a `not checked:` line
#      (it may say `none`).
# A hex word that is no commit of this checkout (a msg id, a topic prefix) is
# not a sha. Any other opening (**Planned, not built yet**, **In progress**,
# **Landed, not live yet**, a poll form, plain text) is not checked.
# Reads only: one fetch, local git, the deploy-lag probes. Nothing is mutated.
# Env: LANE_WT (default APP_PATH), LANE_FETCH_SCRIPT (default git-fetch-fresh.sh),
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

  local -a shas=()
  local tok full seen=" " fetched=1
  bash "$fetch" -C "$wt" --remote "$remote" --branch "$branch" >/dev/null 2>&1 || fetched=0
  while read -r tok; do
    [[ -n "$tok" && "$tok" =~ [0-9] && "$tok" =~ [a-f] ]] || continue
    full="$(git -C "$wt" rev-parse --verify -q "$tok^{commit}" 2>/dev/null)" || continue
    [[ "$seen" == *" $full "* ]] && continue
    seen+="$full "; shas+=("$full")
  done < <(sed -E 's/[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}//g' <<<"$body" | grep -oE '\b[0-9a-f]{7,40}\b')

  if (( ${#shas[@]} == 0 )); then
    miss+=("a commit sha on $remote/$branch (none of the body's hex words is a commit of $wt)")
  elif (( ! fetched )); then
    miss+=("a fetch of $remote/$branch to prove the sha(s) landed (the fetch failed)")
  else
    local s e v needs parent
    for s in "${shas[@]}"; do
      if ! git -C "$wt" merge-base --is-ancestor "$s" "$remote/$branch" 2>/dev/null; then
        miss+=("sha ${s:0:9} on $remote/$branch (it is not: say **Landed, not live yet** only once it is, rule 14)")
        continue
      fi
      parent="$(git -C "$wt" rev-parse --verify -q "$s^" 2>/dev/null)" || parent="$s"
      needs="$(_spl_served_needs_deploy "$wt" "$parent" "$s" 2>/dev/null)"
      if [[ "$needs" == no ]]; then
        grep -qiE '\bno[[:space:]-]+deploy\b' <<<"$body" ||
          miss+=("the words 'no deploy' for sha ${s:0:9}: it changed no hub or wui build input, so no build serves it")
        continue
      fi
      for e in ${LANE_ENVS:-dev prd}; do
        v="$(_spl_served_env "$e" "$wt" "$s" 2>/dev/null)"
        [[ "$v" == served ]] || miss+=("sha ${s:0:9} served on $e (do_check_deploy_lag says: ${v:-unknown})")
      done
    done
  fi

  (( ${#miss[@]} == 0 )) && return 0
  do_log "FATAL a **Live** post must carry its proof; nothing was sent. Missing:"
  local m
  for m in "${miss[@]}"; do do_log "FATAL   - $m"; done
  do_log "FATAL the rule: csi-spl-doc/doc/help/how-to-post.md rule 16 (Live = on master AND served on dev and prd, rule 14). Not proven yet? Open with **Landed, not live yet** or **In progress** instead."
  return 1
}
