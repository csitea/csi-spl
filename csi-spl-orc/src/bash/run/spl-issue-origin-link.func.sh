#!/bin/bash
#------------------------------------------------------------------------------
# @description Link an issue to the discussion it came from in ANOTHER
# @description workspace (SPL-5126; c-001 ruling bf29c39c): POST
# @description /v1/operator/issues/<key>/origin-discussion, as the env's project
# @description service account. The member route refuses such a topic. For now
# @description only the orchestrator runs this; a lane sends it the command.
# @description Nothing printed or logged names the origin workspace or topic.
# @description DRY_RUN=1 (default): check the input, call no cloud, write nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace that owns the issue
# @param ISSUE_KEY - required: the issue, e.g. SPL-123
# @param ORIGIN_TENANT - required: the workspace the topic lives in
# @param DISCUSSION - required: a topic id, its 8-hex short id or a /t/ link
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=<tenant> ISSUE_KEY=SPL-123 ORIGIN_TENANT=<other> DISCUSSION=<topic id> ./run -a do_spl_issue_origin_link
#------------------------------------------------------------------------------
do_spl_issue_origin_link() {
  do_require_bin yq jq curl gcloud || return 1
  local body dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  _spl_issue_origin_body || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if (( dry )); then
    do_log "OK DRY_RUN would link $ISSUE_KEY of $TENANT_ID to its origin topic in another workspace, on $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call POST "/v1/operator/issues/$ISSUE_KEY/origin-discussion" "$body" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { do_log "FATAL $ISSUE_KEY was not linked (http $SPL_HUB_OP_STATUS, $(jq -r '.error // "no error code"' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)). Nothing written."; return 1; }
  do_log "OK $ISSUE_KEY of $TENANT_ID ($ENV) links its origin topic in another workspace, added=$(jq -r '.added' <<<"$SPL_HUB_OP_BODY")"
}

# _spl_issue_origin_body: set the caller's local body from the env vars; every
# refusal is made here, before cnf, gcloud or the hub, and names no value of
# ORIGIN_TENANT or DISCUSSION.
_spl_issue_origin_body() {
  local tenant="${TENANT_ID:-}" key="${ISSUE_KEY:-}" origin="${ORIGIN_TENANT:-}" disc="${DISCUSSION:-}"
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$key" =~ ^[A-Z][A-Z0-9]{0,9}-[0-9]+$ ]] || { do_log "FATAL ISSUE_KEY must be a key such as SPL-123"; return 1; }
  [[ "$origin" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { do_log "FATAL ORIGIN_TENANT must be a workspace slug"; return 1; }
  [[ "$origin" != "$tenant" ]] || { do_log "FATAL ORIGIN_TENANT is the issue's own workspace: use spool issue link"; return 1; }
  [[ -n "$disc" ]] || { do_log "FATAL DISCUSSION is required: a topic id, its short id or a /t/ link"; return 1; }
  body="$(jq -cn --arg t "$tenant" --arg o "$origin" --arg d "$disc" '{tenant: $t, origin_tenant: $o, discussion: $d}')" \
    || { do_log "FATAL could not build the request body"; return 1; }
}
