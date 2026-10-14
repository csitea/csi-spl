#!/bin/bash
#------------------------------------------------------------------------------
# @description The hub's half of SPL-1808: name the attachments still named by
# @description their own sha256 on the messages of a box whose pin is REVOKED
# @description (the old box-desk), which no box can re-sign any more. Owner
# @description HUM-10, t1 b1af5f5c msg 8d4cf989 (poll a575a57a, option A):
# @description "Rename them on the hub; their old signature no longer matches".
# @description One operator call per workspace,
# @description POST /v1/operator/attachment-names/repair, with the env's
# @description service account id token: the hub sniffs each blob's type,
# @description names it file-<12 hex>.<ext> and keeps the stored sig. A live
# @description box's rows are left to that box (do_spl_attach_name_repair) and
# @description counted in live_box. Prints the hub's JSON per workspace.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_IDS - required: space- or comma-separated workspace slugs
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_IDS='t1 csitea csi-rel' ./run -a do_spl_attach_name_repair_revoked
# @example ENV=prd TENANT_IDS=t1 DRY_RUN=0 ./run -a do_spl_attach_name_repair_revoked
#------------------------------------------------------------------------------
do_spl_attach_name_repair_revoked() {
  do_require_bin yq jq curl gcloud || return 1
  spl_require_cloud_env || return 1
  local tenants t dry=1 body rc=0
  tenants="$(tr ',' ' ' <<<"${TENANT_IDS:-}" | xargs)"
  [[ -n "$tenants" ]] || { do_log "FATAL TENANT_IDS is required (e.g. 't1 csitea')"; return 1; }
  for t in $tenants; do spl_require_tenant_slug "$t" || return 1; done
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  for t in $tenants; do
    body="$(jq -cn --arg tenant "$t" --argjson dry "$( ((dry)) && echo true || echo false)" '{tenant: $tenant, dry_run: $dry}')" || return 1
    spl_hub_operator_call POST /v1/operator/attachment-names/repair "$body" || { rc=1; continue; }
    _spl_anr_revoked_report "$t" "$dry" || rc=1
  done
  (( dry )) && do_log "OK DRY_RUN nothing was renamed. Re-run with DRY_RUN=0 to rename."
  return $rc
}

# _spl_anr_revoked_report <tenant> <dry>: reads SPL_HUB_OP_STATUS / _BODY.
_spl_anr_revoked_report() {
  case "$SPL_HUB_OP_STATUS" in
    200) ;;
    404) do_log "FATAL $1: the hub has no attachment-names route or operator routes are off (404): deploy the hub first. $SPL_HUB_OP_BODY"; return 1 ;;
    401|403) do_log "FATAL $1: the hub refused the operator id token ($SPL_HUB_OP_STATUS) for $GCP_ACCOUNT. $SPL_HUB_OP_BODY"; return 1 ;;
    *) do_log "FATAL $1: attachment names repair failed (http $SPL_HUB_OP_STATUS): $SPL_HUB_OP_BODY"; return 1 ;;
  esac
  jq -c '{tenant, dry_run, found, live_box, messages, renamed, unknown, by_type, samples, failed, more}' <<<"$SPL_HUB_OP_BODY"
  [[ "$(jq -r '.more' <<<"$SPL_HUB_OP_BODY")" == false ]] || do_log "WARN $1: the hub caps a call: re-run for the rest"
  [[ "$(jq -r '.failed | length' <<<"$SPL_HUB_OP_BODY")" == 0 ]] || { do_log "FATAL $1: some messages failed (see failed)"; return 1; }
  do_log "OK $1: $(jq -r '"\(.messages) message(s), \(.renamed) file(s) named, \(.unknown) unknown kept, \(.live_box) left to their live box"' <<<"$SPL_HUB_OP_BODY")$( (( $2 )) && echo ' (dry run)')"
}
