#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Create or update ONE repo ruleset that stops a force push and a
# @description deletion of master (owner go 2026-10-10: "each one trying to do
# @description that MUST rebase with the work of the others"). Rules
# @description non_fast_forward + deletion ONLY: no pull request, no status
# @description check, so lanes keep pushing straight to master. NO bypass actor
# @description (bypass_actors: []): the fleet pushes as a repo admin, so an
# @description admin bypass would not stop it. Targets refs/heads/master plus
# @description the throwaway proof refs refs/heads/ruleset-proof/** (the live
# @description control runs there, never on master). Found by name;
# @description do_spl_gh_app_bypass skips it by that name.
# @description DRY_RUN=1 (default): prints the JSON and its diff to what is
# @description live, writes nothing. DRY_RUN=0: POST (none yet) or PUT (it
# @description differs), then reads it back, checks it and prints its id.
# @param GH_RULESET_REPO (optional) - <owner>/<repo>, default: the origin remote (no literal default)
# @param GH_MASTER_RULESET_NAME (optional) - the ruleset's name, default master-no-force
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_gh_master_ruleset
# @example DRY_RUN=0 ./run -a do_spl_gh_master_ruleset
#------------------------------------------------------------------------------
do_spl_gh_master_ruleset() {
  local dry="${DRY_RUN:-1}" name="${GH_MASTER_RULESET_NAME:-master-no-force}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL GH_MASTER_RULESET_NAME must be [A-Za-z0-9._-]+"; return 2; }
  do_require_bin gh jq || return 1
  local repo; repo="$(_sgmr_repo)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { do_log "FATAL no GitHub repo: set GH_RULESET_REPO=<owner>/<repo>"; return 1; }
  local want id live=""
  want="$(_sgmr_body "$name")"
  id="$(_sgmr_id "$repo" "$name")" || { do_log "FATAL cannot list the rulesets of $repo"; return 1; }
  if [[ -n "$id" ]]; then
    live="$(gh api "repos/$repo/rulesets/$id")" || { do_log "FATAL cannot read repos/$repo/rulesets/$id"; return 1; }
  fi
  do_log "INFO wanted ruleset $name on $repo:"
  jq -S . <<<"$want"
  if [[ -n "$live" ]] && diff <(_sgmr_shape <<<"$live") <(_sgmr_shape <<<"$want") >/dev/null; then
    do_log "OK ruleset $name (id $id) on $repo already holds: no change"
    _sgmr_check "$repo" "$id"; return
  fi
  local verb=create was="none live yet"
  [[ -z "$id" ]] || { verb=update; was="ruleset $id"; }
  do_log "INFO diff live -> wanted ($was):"
  diff <(if [[ -n "$live" ]]; then _sgmr_shape <<<"$live"; fi) <(_sgmr_shape <<<"$want")
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would $verb ruleset $name on $repo. Re-run with DRY_RUN=0."; return 0
  fi
  if [[ -n "$id" ]]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null <<<"$want" || { do_log "ERROR cannot update ruleset $id"; return 1; }
  else
    gh api -X POST "repos/$repo/rulesets" --input - >/dev/null <<<"$want" || { do_log "ERROR cannot create ruleset $name"; return 1; }
    id="$(_sgmr_id "$repo" "$name")"
  fi
  [[ "$id" =~ ^[0-9]+$ ]] || { do_log "ERROR ruleset $name not found after the write"; return 1; }
  _sgmr_check "$repo" "$id"
}

_sgmr_repo() {
  if [[ -n "${GH_RULESET_REPO:-}" ]]; then printf '%s\n' "$GH_RULESET_REPO"; return 0; fi
  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# <repo> <name> - the id of the repo ruleset of that name, empty when none
_sgmr_id() {
  local all; all="$(gh api "repos/$1/rulesets" --paginate)" || return 1
  jq -rs --arg n "$2" '[add // [] | .[] | select(.name == $n) | .id][0] // empty' <<<"$all"
}

# <name> - the ruleset body
_sgmr_body() {
  jq -n --arg name "$1" '{
    name: $name, target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["refs/heads/master", "refs/heads/ruleset-proof/**"], exclude: []}},
    rules: [{type: "deletion"}, {type: "non_fast_forward"}],
    bypass_actors: []}'
}

# ruleset JSON on stdin - the fields this action owns, sorted
_sgmr_shape() {
  jq -S '{name, target, enforcement,
    include: ((.conditions.ref_name.include // []) | sort), exclude: ((.conditions.ref_name.exclude // []) | sort),
    rules: ([.rules[]?.type] | sort), bypass_actors: (.bypass_actors // [])}'
}

# <repo> <id> - read the ruleset back, check it holds, print its id
_sgmr_check() {
  local rs; rs="$(gh api "repos/$1/rulesets/$2")" || { do_log "ERROR cannot read repos/$1/rulesets/$2 back"; return 1; }
  jq -e '.enforcement == "active" and ([.rules[]?.type] | sort) == ["deletion", "non_fast_forward"]
    and (.bypass_actors // []) == [] and ((.conditions.ref_name.include // []) | index("refs/heads/master") != null)' <<<"$rs" >/dev/null ||
    { do_log "ERROR read-back of ruleset $2 does not hold: $(_sgmr_shape <<<"$rs" | jq -c .)"; return 1; }
  do_log "OK read-back ruleset_id=$2 $(_sgmr_shape <<<"$rs" | jq -c .)"
}
