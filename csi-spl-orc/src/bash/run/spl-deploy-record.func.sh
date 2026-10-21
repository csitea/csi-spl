#!/bin/bash
#------------------------------------------------------------------------------
# @description The deploy record's CI report (spec 143 section 2.3.2, task
# @description T026, SPL-2788): POST one deploy of the hub or the WUI to THIS
# @description env's hub, /v1/operator/deploys, which writes an rdb 0202
# @description estate_deploys row (source ci). Owner HUM-10 poll 3 = C (msg
# @description a8bfcdd0): the deploy step reports each deploy, plus the hub's
# @description 2-minute check fills in one this step missed. The workflows
# @description (20 hub, 30 WUI) run it after the deploy with
# @description continue-on-error, so a failed report never fails the deploy;
# @description the action itself still exits 1 on a refusal, so the run shows
# @description it. Idempotent per workflow run: a re-run step returns the
# @description first row. Authenticated as the env's project service account
# @description (operator id token, spl_hub_operator_call), never the owner
# @description account; the key comes from the repo secret
# @description GCP_KEY_CSI_SPL_<ENV> through google-github-actions/auth.
# @param ENV - required: dev or prd
# @param DEPLOY_COMPONENT - required: hub or wui
# @param DEPLOY_VERSION - required: the minted version, 3.2.5 or v3.2.5 (-c<N> past the wrap)
# @param DEPLOY_SHA (optional) - the deployed commit, default $GITHUB_SHA, else HEAD
# @param DEPLOY_STATUS (optional) - success (default) or failed
# @param DEPLOY_RUN_ID (optional) - the workflow run id, default $GITHUB_RUN_ID
# @param DRY_RUN (optional) - 1 (default): print the request body, call nothing; 0: POST it
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev DEPLOY_COMPONENT=hub DEPLOY_VERSION=3.2.5 ./run -a do_spl_deploy_record
# @example ENV=prd DEPLOY_COMPONENT=wui DEPLOY_VERSION=3.2.5 DEPLOY_STATUS=failed DRY_RUN=0 ./run -a do_spl_deploy_record
#------------------------------------------------------------------------------
do_spl_deploy_record() {
  do_require_bin git jq || return 1
  spl_require_cloud_env || return 1
  local component="${DEPLOY_COMPONENT:-}" version="${DEPLOY_VERSION:-}" status="${DEPLOY_STATUS:-success}"
  local run_id="${DEPLOY_RUN_ID:-${GITHUB_RUN_ID:-}}" sha="${DEPLOY_SHA:-${GITHUB_SHA:-}}" dry="${DRY_RUN:-1}"
  [[ "$component" == hub || "$component" == wui ]] || { do_log "FATAL DEPLOY_COMPONENT must be hub or wui, got: '$component'"; return 1; }
  [[ "$version" =~ ^v?[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$ ]] ||
    { do_log "FATAL DEPLOY_VERSION must look like 3.2.5 or v1.0.1-c2, got: '$version'"; return 1; }
  [[ "$status" == success || "$status" == failed ]] || { do_log "FATAL DEPLOY_STATUS must be success or failed, got: '$status'"; return 1; }
  [[ "$run_id" =~ ^[A-Za-z0-9._-]{0,64}$ ]] || { do_log "FATAL DEPLOY_RUN_ID must be up to 64 of [A-Za-z0-9._-], got: '$run_id'"; return 1; }
  [[ -n "$sha" ]] || sha="$(git -C "${APP_PATH:-.}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { do_log "FATAL DEPLOY_SHA must be a full 40-character sha, got: '$sha'"; return 1; }

  local body
  body="$(jq -cn --arg env "$ENV" --arg c "$component" --arg v "$version" --arg sha "$sha" --arg st "$status" --arg run "$run_id" \
    '{env: $env, component: $c, version: $v, commit_sha: $sha, status: $st} + (if $run != "" then {workflow_run_id: $run} else {} end)')" || return 1
  if [[ "$dry" != 0 ]]; then
    printf '%s\n' "$body"
    do_log "INFO DRY_RUN: the $ENV $component deploy of ${sha:0:8} not reported (DRY_RUN=0 posts it)" >&2
    return 0
  fi

  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call POST /v1/operator/deploys "$body" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
    { do_log "FATAL POST /v1/operator/deploys answered HTTP $SPL_HUB_OP_STATUS: $(jq -r '.message // .error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"; return 1; }
  jq -c '{env: .deploy.env, component: .deploy.component, version: .deploy.version, sha: .deploy.commit_sha,
    status: .deploy.status, deploy_id: .deploy.deploy_id, stored: .stored}' <<<"$SPL_HUB_OP_BODY"
  do_log "OK the $ENV $component deploy of ${sha:0:8} recorded on $SPL_HUB_URL ($(jq -r 'if .stored then "new row" else "already recorded by this run" end' <<<"$SPL_HUB_OP_BODY"))"
}
