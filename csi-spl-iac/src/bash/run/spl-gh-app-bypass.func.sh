#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description After the owner installed the Docs GitHub App (spec 075 §9.1
# @description steps 4-5, T00): find its installation on the repo's account
# @description (waiting up to GH_APP_WAIT seconds), print the App id and the
# @description installation id (cnf env.docs.repo_edit), then make the App a
# @description bypass actor (type Integration, mode always) of every ruleset
# @description that applies to the default branch, and read each one back.
# @description No ruleset on the branch: nothing to bypass (§9.1 step 5), the
# @description read-back says so. A classic branch protection is reported and
# @description refused (not handled here). DRY_RUN=1 (default): change nothing.
# @param GH_APP_SLUG - required: the App's slug (do_spl_gh_app_manifest prints it)
# @param GH_APP_REPO (optional) - <owner>/<repo>, default: the origin remote
# @param GH_APP_WAIT (optional) - seconds to wait for the install (default 0)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example GH_APP_SLUG=<app-slug> ./run -a do_spl_gh_app_bypass
# @example GH_APP_SLUG=<app-slug> GH_APP_WAIT=1800 DRY_RUN=0 ./run -a do_spl_gh_app_bypass
#------------------------------------------------------------------------------
do_spl_gh_app_bypass() {
  local dry="${DRY_RUN:-1}" slug="${GH_APP_SLUG:-}" wait_s="${GH_APP_WAIT:-0}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || { do_log "FATAL GH_APP_SLUG must be the App's slug"; return 2; }
  [[ "$wait_s" =~ ^[0-9]+$ ]] || { do_log "FATAL GH_APP_WAIT must be seconds"; return 2; }
  do_require_bin gh jq || return 1
  local repo; repo="$(_sga_repo)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { do_log "FATAL no GitHub repo: set GH_APP_REPO=<owner>/<repo>"; return 1; }
  local inst app_id inst_id end=$((SECONDS + wait_s))
  while :; do
    inst="$(gh api "orgs/${repo%%/*}/installations" --paginate \
      --jq ".installations[] | select(.app_slug == \"$slug\") | \"\(.app_id) \(.id)\"" 2>/dev/null | sed -n 1p)"
    [[ -n "$inst" || $SECONDS -ge $end ]] && break
    sleep 20
  done
  read -r app_id inst_id <<<"$inst"
  [[ "${app_id:-}" =~ ^[0-9]+$ && "${inst_id:-}" =~ ^[0-9]+$ ]] ||
    { do_log "ERROR $slug is not installed on ${repo%%/*} yet: $(_sga_install_url "$repo" "$slug")"; return 3; }
  do_log "OK $slug installed: github_app_id=$app_id installation_id=$inst_id"

  local br rules rc=0 src_type src id
  br="$(gh api "repos/$repo" --jq .default_branch)" || { do_log "FATAL cannot read $repo"; return 1; }
  rules="$(gh api "repos/$repo/rules/branches/$br")" || { do_log "FATAL cannot read the rules of $repo $br"; return 1; }
  if [[ "$(jq length <<<"$rules")" == 0 ]]; then
    if [[ "$(gh api "repos/$repo/branches/$br" --jq .protected)" == true ]]; then
      do_log "ERROR $repo $br has a classic branch protection, no ruleset: add $slug by hand (spec 075 §9.1 step 5)"; return 1
    fi
    do_log "OK read-back: $repo $br has no ruleset and no branch protection (rules/branches/$br -> []): nothing to bypass"
    return 0
  fi
  while IFS=$'\t' read -r src_type src id; do
    _sgb_one "$src_type" "$src" "$id" "$app_id" "$dry" || rc=1
  done < <(jq -r 'map("\(.ruleset_source_type)\t\(.ruleset_source)\t\(.ruleset_id)") | unique[]' <<<"$rules")
  return $rc
}

# <source type> <source> <ruleset id> <app id> <dry> - one ruleset: add the App
# as a bypass actor unless it is one, then read the bypass list back
_sgb_one() {
  local ep rs has
  case "$1" in
    Repository) ep="repos/$2/rulesets/$3" ;;
    Organization) ep="orgs/$2/rulesets/$3" ;;
    *) do_log "ERROR ruleset $3: unknown source type '$1'"; return 1 ;;
  esac
  rs="$(gh api "$ep")" || { do_log "ERROR cannot read $ep"; return 1; }
  has="$(jq --argjson a "$4" '[.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $a)] | length' <<<"$rs")"
  if [[ "$has" != 0 ]]; then
    do_log "OK $ep ($(jq -r .name <<<"$rs")): App $4 already bypasses"
  elif [[ "$5" == 1 ]]; then
    do_log "OK DRY_RUN would add App $4 (Integration, always) to the bypass list of $ep. Re-run with DRY_RUN=0."
    return 0
  else
    jq --argjson a "$4" '{bypass_actors: ((.bypass_actors // []) + [{actor_id: $a, actor_type: "Integration", bypass_mode: "always"}])}' <<<"$rs" |
      gh api -X PUT "$ep" --input - >/dev/null || { do_log "ERROR could not update $ep"; return 1; }
    rs="$(gh api "$ep")" || { do_log "ERROR cannot read $ep back"; return 1; }
  fi
  do_log "OK read-back $ep bypass_actors: $(jq -c '[.bypass_actors[]? | "\(.actor_type):\(.actor_id):\(.bypass_mode)"]' <<<"$rs")"
  jq -e --argjson a "$4" 'any(.bypass_actors[]?; .actor_type == "Integration" and .actor_id == $a)' <<<"$rs" >/dev/null ||
    { do_log "ERROR App $4 is not in the bypass list of $ep"; return 1; }
}
