#!/bin/bash
#------------------------------------------------------------------------------
# @description Register a software project of a workspace and one of its
# @description repos on the hub (spec 143 releases-projects.md section 4.5,
# @description row B-6): PUT /v1/operator/workspaces/<id>/projects/<project>,
# @description then PUT /v1/operator/workspaces/<id>/repos with the project.
# @description Only the operator registers (section 9, answer 2): the calls
# @description carry the env's project service account id token. Nothing is
# @description read from the cnf or written to git: a customer's workspace,
# @description repo and host stay out of this public repo. Every input is
# @description required, with no default. A workspace's first project becomes
# @description its default, its first repo its primary. Dry run unless
# @description DRY_RUN=0. Re-running it updates the rows (idempotent).
# @param ENV (required) - dev or prd
# @param WORKSPACE_ID (required) - the workspace (tenant) id
# @param WORKSPACE_PROJECT (required) - the project slug, 1..48 of a-z 0-9 -
# @param WORKSPACE_REPO_SLUG (required) - the repo, lowercase <owner>/<name>
# @param WORKSPACE_REPO_WEB_URL (required) - the repo's https web URL
# @param WORKSPACE_PROJECT_NAME (optional) - the project's shown name, default the slug
# @param WORKSPACE_REPO_TRUNK (optional) - its trunk branch, default main
# @param WORKSPACE_REPO_AUTH_MODE (optional) - github_app (default), pat_kms, public or ingest_only
# @param WORKSPACE_REPO_PRIMARY (optional) - 1: make it the workspace's primary repo; default 0
# @param WORKSPACE_REPO_PUBLIC (optional) - 1: its release notes are public (notes_public); default 0
# @param DRY_RUN (optional) - 1 (default): print the two requests, call nothing; 0: send them
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev WORKSPACE_ID=<WORKSPACE> WORKSPACE_PROJECT=web-shop WORKSPACE_REPO_SLUG=<org>/web-shop WORKSPACE_REPO_WEB_URL=https://example.com/<org>/web-shop ./run -a do_workspace_repo_register
#------------------------------------------------------------------------------
do_workspace_repo_register() {
  do_require_bin jq || return 1
  spl_require_cloud_env || return 1
  wrr_inputs || return 1
  local name="${WORKSPACE_PROJECT_NAME:-$WORKSPACE_PROJECT}" base="/v1/operator/workspaces/$WORKSPACE_ID"
  local pbody rbody
  pbody="$(jq -cn --arg n "$name" '{name: $n, is_default: false}')" || return 1
  rbody="$(jq -cn --arg s "$WORKSPACE_REPO_SLUG" --arg p "$WORKSPACE_PROJECT" --arg u "$WORKSPACE_REPO_WEB_URL" \
    --arg b "${WORKSPACE_REPO_TRUNK:-main}" --arg a "${WORKSPACE_REPO_AUTH_MODE:-github_app}" \
    --argjson pr "$([[ "${WORKSPACE_REPO_PRIMARY:-0}" == 1 ]] && echo true || echo false)" \
    --argjson pu "$([[ "${WORKSPACE_REPO_PUBLIC:-0}" == 1 ]] && echo true || echo false)" \
    '{repo_slug: $s, project_slug: $p, repo_web_url: $u, trunk_branch: $b, auth_mode: $a, is_primary: $pr, notes_public: $pu}')" || return 1
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    printf 'PUT %s/projects/%s %s\nPUT %s/repos %s\n' "$base" "$WORKSPACE_PROJECT" "$pbody" "$base" "$rbody"
    do_log "INFO DRY_RUN: nothing sent (DRY_RUN=0 sends both)" >&2
    return 0
  fi
  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  wrr_put "$base/projects/$WORKSPACE_PROJECT" "$pbody" || return 1
  wrr_put "$base/repos" "$rbody" || return 1
  printf '%s\n' "$SPL_HUB_OP_BODY"
  do_log "OK $WORKSPACE_REPO_SLUG registered under $WORKSPACE_ID/$WORKSPACE_PROJECT on $SPL_HUB_URL"
}

# wrr_inputs -> rc 1 + FATAL on a missing or malformed input; no default
# for any of the four (releases-projects.md section 5, "No default URLs").
wrr_inputs() {
  local v
  for v in WORKSPACE_ID WORKSPACE_PROJECT WORKSPACE_REPO_SLUG WORKSPACE_REPO_WEB_URL; do
    [[ -n "${!v:-}" ]] || { do_log "FATAL $v must be set (no default)"; return 1; }
  done
  [[ "$WORKSPACE_ID" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { do_log "FATAL WORKSPACE_ID is not a workspace id: '$WORKSPACE_ID'"; return 1; }
  [[ "$WORKSPACE_PROJECT" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || { do_log "FATAL WORKSPACE_PROJECT must be 1..48 of a-z 0-9 -: '$WORKSPACE_PROJECT'"; return 1; }
  [[ "$WORKSPACE_REPO_SLUG" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || { do_log "FATAL WORKSPACE_REPO_SLUG must be a lowercase owner/name: '$WORKSPACE_REPO_SLUG'"; return 1; }
  [[ "$WORKSPACE_REPO_WEB_URL" =~ ^https://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || { do_log "FATAL WORKSPACE_REPO_WEB_URL must be an https URL: '$WORKSPACE_REPO_WEB_URL'"; return 1; }
}

# wrr_put <path> <json> -> rc 0 on HTTP 200, else FATAL naming the hub's error.
wrr_put() {
  spl_hub_operator_call PUT "$1" "$2" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] && return 0
  do_log "FATAL PUT $1 answered HTTP $SPL_HUB_OP_STATUS: $(jq -r '(.error // "") + " " + (.message // "")' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  return 1
}
