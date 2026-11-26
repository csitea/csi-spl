#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Read-only: does ENV have pending changes for STEP from THIS tree?
# @description `terraform plan -detailed-exitcode -lock=false`, nothing applied,
# @description no plan file kept (it is written in the run dir, which is
# @description removed). It runs in its own run dir
# @description (TF_RUN_DIR_SUFFIX), so it never wipes the dir of an apply of the
# @description same env + step that runs at the same time.
# @description Prints ONE line, `TF_PLAN <env> <step> <verdict> sha=<tree> <summary>`:
# @description   0 clean   - no changes: the env matches this tree
# @description   2 pending - terraform would change a resource
# @description   0 clean   - also when plan exits 2 but `terraform show -json`
# @description               of the plan has no resource change other than
# @description               no-op or a data source read: only outputs move
# @description               (SPL-6528, e.g. Firebase verifying a new tenant
# @description               host); summary `No changes. (outputs only)`
# @description   2 pending - also when that plan file cannot be read
# @description   1 error   - init or plan failed: cannot tell
# @description A clean plan of a clean tree is cached for the order gate
# @description (do_check_dev_leads_prd). Runs in the tf-runner
# @description (make do-tf-plan-pending), never on the host.
# @param ENV (required) - dev or prd
# @param STEP (required) - the terraform step, e.g. 030-cloud-run-hub
# @example ENV=dev STEP=030-cloud-run-hub make do-tf-plan-pending
#------------------------------------------------------------------------------
declare -F env_order_cache_put >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/check-dev-leads-prd.func.sh"
# shellcheck source=../../../lib/bash/funcs/tf-log-mask.func.sh
declare -F do_tf_log_mask >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/tf-log-mask.func.sh"

# tf_plan_resource_changes <run dir> <plan file>: prints how many resources the
# saved plan would change (actions other than no-op, or read for a data source),
# plus moved {} and import {} entries, which change state under a no-op action.
# Fails when the plan cannot be shown or parsed. The JSON may carry sensitive
# values: it goes to jq only, never to a log or the screen.
tf_plan_resource_changes() {
  terraform -chdir="$1" show -json "$2" 2>/dev/null | jq -er '
    if has("format_version") | not then error("not a plan") else
    [.resource_changes[]?
      | select((.change.actions != ["no-op"] and .change.actions != ["read"])
               or .previous_address != null
               or .change.importing != null)] | length end' 2>/dev/null
}

# shellcheck disable=SC2154  # tf_run_path, tf_proj: set by do_tf_init
do_tf_plan_pending() {
  local env="${ENV:?}" step="${STEP:?}" sha log rc summary
  sha="$(env_order_tree_sha)"
  mkdir -p "$PROJ_PATH/dat/log"
  log="$PROJ_PATH/dat/log/tf_plan_pending.${ORG:-}-${APP:-}-${env}.${step}.log"
  # A subshell: do_tf_init exports this env's TF_VAR_* and key, none of which
  # may leak into the caller (the prd gate plans dev from inside a prd run).
  (
    export TF_RUN_DIR_SUFFIX=".plan-pending.$$"
    do_tf_init >"$log" 2>&1 || exit 1
    vars="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
    backend="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"
    prc=1
    if terraform -chdir="$tf_run_path" init -input=false -backend-config="$backend" -upgrade >>"$log" 2>&1; then
      # SPL-5797: step 002 keys resources on the billing account id; the log gets it masked.
      plan_file="$tf_run_path/plan-pending.tfplan"
      terraform -chdir="$tf_run_path" plan -input=false -detailed-exitcode -lock=false -var-file="$vars" \
        -out="$plan_file" 2>&1 |
        do_tf_log_mask >>"$log"
      prc=${PIPESTATUS[0]}
      # SPL-6528: plan exits 2 on an output-only change too; 4 = outputs only.
      [[ $prc -eq 2 && "$(tf_plan_resource_changes "$tf_run_path" "$plan_file")" == 0 ]] && prc=4
    fi
    rm -rf "$tf_run_path"
    exit "$prc"
  )
  rc=$?
  summary="$(grep -m1 -aE '^(Plan: |No changes\.|Error: )' "$log" 2>/dev/null)"
  [[ $rc -eq 4 ]] && { rc=0; summary="No changes. (outputs only)"; }
  case "$rc" in
    0)
      echo "TF_PLAN $env $step clean sha=$sha ${summary:-No changes.}"
      env_order_cache_put "$env" "$step" "$sha"
      return 0 ;;
    2) echo "TF_PLAN $env $step pending sha=$sha ${summary:-terraform would change something}"; return 2 ;;
    *) echo "TF_PLAN $env $step error sha=$sha ${summary:-plan failed} (log: $log)"; return 1 ;;
  esac
}
