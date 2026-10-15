#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Read-only: does ENV have pending changes for STEP from THIS tree?
# @description `terraform plan -detailed-exitcode -lock=false`, nothing applied,
# @description no plan file kept. It runs in its own run dir
# @description (TF_RUN_DIR_SUFFIX), so it never wipes the dir of an apply of the
# @description same env + step that runs at the same time.
# @description Prints ONE line, `TF_PLAN <env> <step> <verdict> sha=<tree> <summary>`:
# @description   0 clean   - no changes: the env matches this tree
# @description   2 pending - terraform would change something
# @description   1 error   - init or plan failed: cannot tell
# @description A clean plan of a clean tree is cached for the order gate
# @description (do_check_dev_leads_prd). Runs in the tf-runner
# @description (make do-tf-plan-pending), never on the host.
# @param ENV - required: dev or prd
# @param STEP - required: the terraform step, e.g. 030-cloud-run-hub
# @example ENV=dev STEP=030-cloud-run-hub make do-tf-plan-pending
#------------------------------------------------------------------------------
declare -F env_order_cache_put >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/check-dev-leads-prd.func.sh"

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
      terraform -chdir="$tf_run_path" plan -input=false -detailed-exitcode -lock=false -var-file="$vars" >>"$log" 2>&1
      prc=$?
    fi
    rm -rf "$tf_run_path"
    exit "$prc"
  )
  rc=$?
  summary="$(grep -m1 -aE '^(Plan: |No changes\.|Error: )' "$log" 2>/dev/null)"
  case "$rc" in
    0)
      echo "TF_PLAN $env $step clean sha=$sha ${summary:-No changes.}"
      env_order_cache_put "$env" "$step" "$sha"
      return 0 ;;
    2) echo "TF_PLAN $env $step pending sha=$sha ${summary:-terraform would change something}"; return 2 ;;
    *) echo "TF_PLAN $env $step error sha=$sha ${summary:-plan failed} (log: $log)"; return 1 ;;
  esac
}
