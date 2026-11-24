#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 181 row B8: take ONE private-workspace order to a terraform
# @description plan of its VM (step 062-gcp-workspace-vms), printed. A dry run
# @description unless DRY_RUN=0, and DRY_RUN=0 also needs OWNER_GO, the
# @description owner's go message id for this VM (spec 181 section 7).
# @description   1. order: the tenant's workspace_orders row with its
# @description      price_plans kind private_vm, read with do_spl_db_query
# @description      (read-only, operator scope) from ENV's hub
# @description   2. map entry: <tenant> -> MACHINE_TYPE added to the box's
# @description      runtime VM map ($SPL_VAR_APP_DIR, never git: B5 keeps
# @description      tenant ids out of the cnf); an entry with another type
# @description      is refused, never changed here
# @description   3. tfvars: the rendered <env>/tf/062 tfvars must declare
# @description      workspace_vms a runtime var and carry no value for it
# @description   4. plan: make do-tf-plan (tf-runner) with the whole map as
# @description      TF_VAR_workspace_vms, printed; GATE: an Error, a destroy, a
# @description      replace or an in-place update refuses the run
# @description   5. DRY_RUN=0 only: make do-provision, then the map file is
# @description      written. DRY_RUN unset: nothing is applied or written.
# @description MACHINE_TYPE has no default: the standard size is open (Q-21).
# @param TENANT_ID (required) - the private workspace (tenant id) of the order
# @param ENV (required) - dev or prd: the hub that holds the order and the VM project
# @param MACHINE_TYPE (required) - the VM's machine type, e.g. e2-standard-2
# @param DRY_RUN (optional) - 1 (default): plan and print only. 0: apply
# @param OWNER_GO (optional) - the owner's go message id; needed with DRY_RUN=0
# @param WS_VMS_MAP (optional) - the runtime map file, default
# @param   $SPL_VAR_APP_DIR/062-gcp-workspace-vms/<env>.workspace-vms.json
# @example ENV=dev TENANT_ID=acme MACHINE_TYPE=e2-standard-2 ./run -a do_spl_private_ws_vm_provision
# @example ENV=dev TENANT_ID=acme MACHINE_TYPE=e2-standard-2 DRY_RUN=0 OWNER_GO=<msg-id> ./run -a do_spl_private_ws_vm_provision
#------------------------------------------------------------------------------
do_spl_private_ws_vm_provision() {
  # a local, not a top-level constant: the file stays lazy for ./run (run-eager-files);
  # the _spl_pwv_* helpers read it by bash's dynamic scope
  local SPL_PWV_STEP=062-gcp-workspace-vms
  local tenant="${TENANT_ID:-}" env="${ENV:-}" mt="${MACHINE_TYPE:-}" dry=1 map cur new out rc
  _spl_pwv_inputs "$tenant" "$env" "$mt" || return 1
  if spl_dry_run; then :; else rc=$?; [[ $rc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )); then
    [[ "${OWNER_GO:-}" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$ ]] || {
      do_log "FATAL DRY_RUN=0 needs OWNER_GO, the owner's go message id for this VM (spec 181 section 7); nothing ran"
      return 1; }
  fi
  do_require_bin jq || return 1

  _spl_pwv_order "$env" "$tenant" || return 1
  map="$(_spl_pwv_map_file "$env")" || return 1
  cur="$(_spl_pwv_map_read "$map")" || return 1
  new="$(_spl_pwv_map_add "$cur" "$tenant" "$mt")" || return 1
  do_log "INFO map entry $tenant -> $mt; the plan's TF_VAR_workspace_vms: $new"
  _spl_pwv_tfvars_ok "$env" || return 1

  out="$(TF_VAR_workspace_vms="$new" make --no-print-directory -C "$PROJ_PATH" do-tf-plan ENV="$env" STEP="$SPL_PWV_STEP" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL make do-tf-plan $SPL_PWV_STEP $env failed (rc $rc); nothing applied"; return 1; }
  _spl_pwv_plan_gate "$out" "$tenant"; rc=$?
  (( rc == 0 || rc == 3 )) || return 1
  if (( dry )); then
    do_log "OK DRY_RUN plan printed for $tenant ($env); nothing applied, the map $map unchanged. Apply: DRY_RUN=0 OWNER_GO=<owner msg id>"
    return 0
  fi
  _spl_pwv_apply "$env" "$tenant" "$new" "$rc" "$map" || return 1
  _spl_pwv_map_write "$map" "$new" || return 1
  do_log "OK $tenant ($env) is in the map $map"
}

# _spl_pwv_apply <env> <tenant> <map json> <gate rc> <map file>: make
# do-provision with the same map; a gate "no changes" (3) applies nothing.
_spl_pwv_apply() {
  local out done_re='Apply complete! Resources: [0-9]+ added, [0-9]+ changed, [0-9]+ destroyed'
  (( $4 == 3 )) && { do_log "INFO $SPL_PWV_STEP $1: no changes, apply skipped"; return 0; }
  do_log "INFO applying $SPL_PWV_STEP $1 for $2 on the owner's go $OWNER_GO"
  out="$(TF_VAR_workspace_vms="$3" make --no-print-directory -C "$PROJ_PATH" do-provision ENV="$1" STEP="$SPL_PWV_STEP" 2>&1)"
  grep -qE "$done_re" <<<"$out" || {
    printf '%s\n' "$out" | tail -30
    do_log "FATAL $SPL_PWV_STEP $1: apply failed; the map $5 unchanged"
    return 1; }
  do_log "OK $(grep -oE "$done_re" <<<"$out" | sed -n 1p)"
}

# _spl_pwv_inputs <tenant> <env> <machine type>: the step's own variable rules
# (062 02-variables.tf), so a bad value stops here, before any read.
_spl_pwv_inputs() {
  [[ "$2" == dev || "$2" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '$2'"; return 1; }
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || {
    do_log "FATAL TENANT_ID must match ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ (step $SPL_PWV_STEP), got: '$1'"; return 1; }
  [[ "$3" =~ ^[a-z][a-z0-9]*-[a-z0-9-]+$ ]] || {
    do_log "FATAL MACHINE_TYPE must be a machine type such as e2-standard-2 (no default: spec 181 Q-21 is open), got: '$3'"; return 1; }
}

# _spl_pwv_order <env> <tenant>: exactly one order row of a private_vm plan.
_spl_pwv_order() {
  local out rows
  out="$(ENV="$1" SQL="select 'ORDER ' || o.order_id || ' ' || o.status as r from workspace_orders o join price_plans p on p.tenant_id = o.tenant_id and p.kind = 'private_vm' where o.tenant_id = '$2'" \
    do_spl_db_query 2>&1)" || { printf '%s\n' "$out" | tail -5; do_log "FATAL the order read for $2 in $1 failed; nothing ran"; return 1; }
  rows="$(sed -nE 's/^ ?ORDER (wo_[a-z2-7]{26}) ([a-z_]+)[[:space:]]*$/\1 \2/p' <<<"$out")"
  [[ -n "$rows" && "$rows" != *$'\n'* ]] || {
    do_log "FATAL $2 in $1: no single private_vm order (workspace_orders + price_plans); nothing ran"; return 1; }
  [[ "${rows#* }" == submitted ]] || { do_log "FATAL order ${rows% *} of $2 is '${rows#* }', not submitted; nothing ran"; return 1; }
  do_log "INFO order ${rows% *} of $2 ($1): submitted, plan private_vm"
}

# _spl_pwv_map_file <env> -> the runtime VM map of that env (WS_VMS_MAP wins).
# The three map helpers print a value, so their FATAL goes to stderr.
_spl_pwv_map_file() {
  local d
  [[ -n "${WS_VMS_MAP:-}" ]] && { printf '%s\n' "$WS_VMS_MAP"; return 0; }
  spl_var_app_subdir d "$SPL_PWV_STEP" || { do_log "FATAL no state dir (SPL_VAR_APP_DIR) for the VM map; set WS_VMS_MAP" >&2; return 1; }
  printf '%s/%s.workspace-vms.json\n' "$d" "$1"
}

# _spl_pwv_map_read <file> -> its JSON object of strings; {} when absent.
_spl_pwv_map_read() {
  [[ -e "$1" ]] || { echo '{}'; return 0; }
  jq -ce 'if type == "object" and all(.[]; type == "string") then . else error("not a map") end' "$1" 2>/dev/null ||
    { do_log "FATAL the VM map $1 is not a JSON object of <tenant>: <machine type>" >&2; return 1; }
}

# _spl_pwv_map_add <map json> <tenant> <type>: the map with the entry; an
# entry with another type is refused (a resize is not this action's).
_spl_pwv_map_add() {
  local have
  have="$(jq -r --arg t "$2" '.[$t] // ""' <<<"$1")"
  [[ -z "$have" || "$have" == "$3" ]] || {
    do_log "FATAL $2 already has a VM of type $have in the map, not $3: a resize is not this action's" >&2; return 1; }
  jq -cS --arg t "$2" --arg m "$3" '. + {($t): $m}' <<<"$1"
}

# _spl_pwv_tfvars_ok <env>: the rendered tfvars leave workspace_vms to the
# run time (a -var-file value beats TF_VAR_*: a rendered {} destroys them all).
_spl_pwv_tfvars_ok() {
  local oa f
  [[ "${PROJ_PATH##*/}" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from PROJ_PATH '$PROJ_PATH'"; return 1; }
  oa="${BASH_REMATCH[1]}"
  f="$APP_PATH/$oa-cnf/$oa/$1/tf/$SPL_PWV_STEP.vars.tfvars"
  [[ -f "$f" ]] || { do_log "FATAL no rendered tfvars $f"; return 1; }
  if ! grep -qx '# runtime-vars: workspace_vms' "$f" || grep -qE '^workspace_vms[[:space:]]*=' "$f"; then
    do_log "FATAL $f does not leave workspace_vms to the run time; nothing ran"; return 1
  fi
  do_log "INFO tfvars $f (workspace_vms from the run time)"
}

# _spl_pwv_plan_gate <plan output> <tenant>: rc 0 ok, 3 no changes, 1 refused.
_spl_pwv_plan_gate() {
  local o="$1" sum
  sum="$(grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes' <<<"$o" | sed -n 1p)"
  grep -qE '^(│ )?Error' <<<"$o" && { do_log "FATAL GATE the plan has an Error; nothing applied"; return 1; }
  [[ -n "$sum" ]] || { do_log "FATAL GATE the plan has no summary; nothing applied"; return 1; }
  grep -qE 'will be destroyed|must be replaced|Plan: [0-9]+ to add, [0-9]+ to change, [1-9][0-9]* to destroy' <<<"$o" &&
    { do_log "FATAL GATE the plan destroys or replaces a resource (is the VM map complete?); nothing applied"; return 1; }
  grep -qE 'will be updated in-place|Plan: [0-9]+ to add, [1-9][0-9]* to change' <<<"$o" &&
    { do_log "FATAL GATE the plan updates a resource in place; nothing applied"; return 1; }
  do_log "INFO GATE plan: $sum"
  [[ "$sum" == "No changes" ]] && return 3
  grep -qF "google_compute_instance.workspace[\"$2\"] will be created" <<<"$o" ||
    { do_log "FATAL GATE the plan changes something but does not create $2's VM; nothing applied"; return 1; }
}

# _spl_pwv_map_write <file> <json>: atomically, mode 0600 (tenant ids).
_spl_pwv_map_write() {
  local tmp
  mkdir -p "${1%/*}" || return 1
  tmp="$(mktemp "${1%/*}/.workspace-vms.XXXXXX")" || return 1
  if ! { printf '%s\n' "$2" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }; then
    rm -f "$tmp"; do_log "FATAL cannot write the VM map $1 (the apply DID run: add $2 to it by hand)"; return 1
  fi
}
