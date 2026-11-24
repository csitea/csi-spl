#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 181 row B9: cancel ONE private workspace (section 4.5,
# @description owner Q-12 C: the VM is deleted at once, the hub data stays 30
# @description days). A dry run unless DRY_RUN=0, and DRY_RUN=0 also needs
# @description OWNER_GO, the owner's go message id for this VM delete (spec
# @description 181 section 7).
# @description   1. order: the tenant's private_vm order (B8's read, read-only)
# @description   2. map: the tenant's entry leaves the box's runtime VM map
# @description      (B8's file, $SPL_VAR_APP_DIR, never git); no entry = no VM
# @description      to delete, only the hub cancel runs
# @description   3. plan: make do-tf-plan (tf-runner) of 062 with the map
# @description      without the tenant, printed; GATE: an Error, a create, a
# @description      replace, an in-place update, or a destroy of anything not
# @description      keyed by this tenant refuses the run
# @description   4. DRY_RUN=0 only: the hub cancel (POST /v1/operator/
# @description      workspaces/<t>/cancel, the env SA: leases end, pins and
# @description      join tokens revoked; the hub purges its data 30 days on),
# @description      then make do-provision (the VM deleted), then the map.
# @param TENANT_ID (required) - the private workspace (tenant id) to cancel
# @param ENV (required) - dev or prd: the hub of the workspace and the VM project
# @param DRY_RUN (optional) - 1 (default): plan and print only. 0: cancel and delete
# @param OWNER_GO (optional) - the owner's go message id; needed with DRY_RUN=0
# @param WS_VMS_MAP (optional) - the runtime map file, default
# @param   $SPL_VAR_APP_DIR/062-gcp-workspace-vms/<env>.workspace-vms.json
# @example ENV=dev TENANT_ID=acme ./run -a do_spl_private_ws_cancel
# @example ENV=dev TENANT_ID=acme DRY_RUN=0 OWNER_GO=<msg-id> ./run -a do_spl_private_ws_cancel
#------------------------------------------------------------------------------
do_spl_private_ws_cancel() {
  # B8's helpers (spl-private-ws-vm-provision.func.sh) read it by dynamic scope
  local SPL_PWV_STEP=062-gcp-workspace-vms
  local tenant="${TENANT_ID:-}" env="${ENV:-}" dry=1 map cur new had out rc
  _spl_pwc_inputs "$tenant" "$env" || return 1
  if spl_dry_run; then :; else rc=$?; [[ $rc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )); then
    [[ "${OWNER_GO:-}" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$ ]] || {
      do_log "FATAL DRY_RUN=0 needs OWNER_GO, the owner's go message id for this VM delete (spec 181 section 7); nothing ran"
      return 1; }
  fi
  do_require_bin jq || return 1

  _spl_pwv_order "$env" "$tenant" || return 1
  map="$(_spl_pwv_map_file "$env")" || return 1
  cur="$(_spl_pwv_map_read "$map")" || return 1
  had="$(jq -r --arg t "$tenant" '.[$t] // ""' <<<"$cur")"
  new="$(jq -cS --arg t "$tenant" 'del(.[$t])' <<<"$cur")" || return 1
  rc=3
  if [[ -n "$had" ]]; then
    do_log "INFO map entry $tenant -> $had leaves; the plan's TF_VAR_workspace_vms: $new"
    _spl_pwv_tfvars_ok "$env" || return 1
    out="$(TF_VAR_workspace_vms="$new" make --no-print-directory -C "$PROJ_PATH" do-tf-plan ENV="$env" STEP="$SPL_PWV_STEP" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    (( rc == 0 )) || { do_log "FATAL make do-tf-plan $SPL_PWV_STEP $env failed (rc $rc); nothing cancelled or deleted"; return 1; }
    _spl_pwc_plan_gate "$out" "$tenant"; rc=$?
    (( rc == 0 || rc == 3 )) || return 1
  else
    do_log "INFO $tenant has no VM in the map $map: the hub cancel only, no VM to delete"
  fi
  if (( dry )); then
    do_log "OK DRY_RUN $tenant ($env): nothing cancelled, nothing deleted, the map $map unchanged. Cancel: DRY_RUN=0 OWNER_GO=<owner msg id>"
    return 0
  fi
  _spl_pwc_hub_cancel "$tenant" || return 1
  [[ -n "$had" ]] || return 0
  _spl_pwc_apply "$env" "$tenant" "$new" "$rc" "$map" || return 1
  _spl_pwv_map_write "$map" "$new" || return 1
  do_log "OK $tenant ($env): cancelled, its VM deleted, out of the map $map; the hub purges its data after 30 days"
}

# _spl_pwc_inputs <tenant> <env>: step 062's tenant rule, dev or prd.
_spl_pwc_inputs() {
  [[ "$2" == dev || "$2" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '$2'"; return 1; }
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || {
    do_log "FATAL TENANT_ID must match ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ (step $SPL_PWV_STEP), got: '$1'"; return 1; }
}

# _spl_pwc_plan_gate <plan output> <tenant>: rc 0 ok, 3 no changes, 1
# refused. Only destroys, and only of resources keyed by this tenant
# (the VM, its SA, its SA's role bindings "<tenant>/<role>").
_spl_pwc_plan_gate() {
  local o="$1" t="$2" sum bad
  sum="$(grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes' <<<"$o" | sed -n 1p)"
  grep -qE '^(│ )?Error' <<<"$o" && { do_log "FATAL GATE the plan has an Error; nothing cancelled or deleted"; return 1; }
  [[ -n "$sum" ]] || { do_log "FATAL GATE the plan has no summary; nothing cancelled or deleted"; return 1; }
  grep -qE 'will be created|must be replaced|will be updated in-place|Plan: [1-9][0-9]* to add|to add, [1-9][0-9]* to change' <<<"$o" &&
    { do_log "FATAL GATE the plan creates, replaces or updates a resource; a cancel only destroys; nothing cancelled or deleted"; return 1; }
  bad="$(grep -E 'will be destroyed' <<<"$o" | grep -vF "[\"$t\"] will be destroyed" | grep -vF "[\"$t/" | sed -n 1p)"
  [[ -z "$bad" ]] || { do_log "FATAL GATE the plan destroys something not $t's:$bad; nothing cancelled or deleted"; return 1; }
  do_log "INFO GATE plan: $sum"
  [[ "$sum" == "No changes" ]] && return 3
  grep -qF "google_compute_instance.workspace[\"$t\"] will be destroyed" <<<"$o" ||
    { do_log "FATAL GATE the plan does not destroy $t's VM; nothing cancelled or deleted"; return 1; }
}

# _spl_pwc_hub_cancel <tenant>: the hub's operator cancel, as the env SA.
# 201 cancelled, 200 already cancelled; anything else stops before the VM.
_spl_pwc_hub_cancel() {
  local body
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  body="$(jq -cn --arg t "$1" '{workspace_id: $t}')" || return 1
  spl_hub_operator_call POST "/v1/operator/workspaces/$1/cancel" "$body" || return 1
  case "$SPL_HUB_OP_STATUS" in
    200|201)
      do_log "OK hub cancel of $1 ($SPL_HUB_OP_STATUS): revoked_boxes=$(jq -c '.revoked_boxes' <<<"$SPL_HUB_OP_BODY") purge_after=$(jq -r '.purge_after' <<<"$SPL_HUB_OP_BODY")" ;;
    *)
      do_log "FATAL the hub did not cancel $1 (http $SPL_HUB_OP_STATUS: $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)); the VM is NOT deleted"
      return 1 ;;
  esac
}

# _spl_pwc_apply <env> <tenant> <map json> <gate rc> <map file>: make
# do-provision with the map without the tenant, on the owner's go.
_spl_pwc_apply() {
  local out done_re='Apply complete! Resources: 0 added, 0 changed, [1-9][0-9]* destroyed'
  (( $4 == 3 )) && { do_log "INFO $SPL_PWV_STEP $1: no changes, the VM is already gone"; return 0; }
  do_log "INFO deleting $2's VM ($SPL_PWV_STEP $1) on the owner's go $OWNER_GO"
  out="$(TF_VAR_workspace_vms="$3" make --no-print-directory -C "$PROJ_PATH" do-provision ENV="$1" STEP="$SPL_PWV_STEP" 2>&1)"
  grep -qE "$done_re" <<<"$out" || {
    printf '%s\n' "$out" | tail -30
    do_log "FATAL $SPL_PWV_STEP $1: the VM delete failed; the hub cancel stands, the map $5 unchanged"
    return 1; }
  do_log "OK $(grep -oE "$done_re" <<<"$out" | sed -n 1p)"
}
