#!/bin/bash
#------------------------------------------------------------------------------
# @description terraform init + validate + plan for ONE step of ONE env. Never
# @description applies: there is deliberately no apply action (see doc 6.2).
# @description The step is copied to the git-ignored run dir
# @description bin/<org>/<app>/<env>/<step>, and planned with the tfvars tpl-gen
# @description rendered into csi-spl-cnf/csi-spl/<env>/tf/.
# @description
# @description TF_BACKEND=gcs (default) uses the state bucket from the rendered
# @description backend-config. TF_BACKEND=local plans against an empty local
# @description state instead: use it while the state bucket does not exist yet.
# @description 000-gcp-remote-bucket always has local state.
# @description
# @description TF_OFFLINE_PLAN=1 gives the provider a dummy access token, so a
# @description plan of resources that do not exist yet runs with no credential
# @description at all. Only meaningful with TF_BACKEND=local (nothing to refresh).
# @param ENV - required: dev or prd
# @param STEP - required: e.g. 020-gcp-relay-bucket
# @param TF_BACKEND (optional) - gcs (default) or local
# @param TF_OFFLINE_PLAN (optional) - 1: dummy token, no GCP call; requires TF_BACKEND=local
# @param TF_BIN (optional) - terraform binary; default: tfswitch-installed version from the env yaml
# @example ENV=dev STEP=020-gcp-relay-bucket TF_BACKEND=local TF_OFFLINE_PLAN=1 ./run -a do_tf_plan
#------------------------------------------------------------------------------
do_tf_plan() {
  do_resolve_oap ORG
  do_resolve_oap APP
  do_require_var ENV "${ENV:-}"
  do_require_var STEP "${STEP:-}"
  [[ "$ENV" == dev || "$ENV" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: $ENV"; return 1; }

  local src="$PROJ_PATH/src/terraform/$STEP"
  local cnf_dir="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf"
  local cnf_yaml="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV.env.yaml"
  local vars="$cnf_dir/$STEP.vars.tfvars"
  local backend_cfg="$cnf_dir/$STEP.backend-config.tfvars"
  local run_dir="$PROJ_PATH/bin/$ORG/$APP/$ENV/$STEP"
  local backend="${TF_BACKEND:-gcs}"
  [[ "$STEP" == 000-* ]] && backend=local

  [[ -d "$src" ]]  || { do_log "FATAL no such step: $src"; return 1; }
  [[ -f "$vars" ]] || { do_log "FATAL not rendered: $vars (run ENV=$ENV ./run -a do_tpl_gen)"; return 1; }
  [[ "$backend" == gcs || "$backend" == local ]] || { do_log "FATAL TF_BACKEND must be gcs or local, got: $backend"; return 1; }
  if [[ "${TF_OFFLINE_PLAN:-0}" == 1 && "$backend" != local ]]; then
    do_log "FATAL TF_OFFLINE_PLAN=1 needs TF_BACKEND=local"; return 1
  fi

  local tf="${TF_BIN:-}"
  if [[ -z "$tf" ]]; then
    local ver
    ver=$(yq -r '.env.versions.terraform_version' "$cnf_yaml")
    tf="$HOME/.local/share/$ORG-$APP/bin/terraform-$ver"
    if [[ ! -x "$tf" ]]; then
      mkdir -p "$(dirname "$tf")"
      tfswitch -b "$tf" "$ver" >/dev/null 2>&1 || { do_log "FATAL tfswitch could not install terraform $ver"; return 1; }
    fi
  fi
  do_log "INFO terraform: $("$tf" version | head -1) ($tf) backend=$backend offline=${TF_OFFLINE_PLAN:-0}"

  # The run dir is wiped and re-copied. Refuse while a local-state operation
  # (an apply from this same dir) holds its lock.
  if [[ -f "$run_dir/.terraform.tfstate.lock.info" ]]; then
    do_log "FATAL $run_dir holds a terraform lock (an apply in flight?); refusing to wipe it"; return 1
  fi
  rm -rf "$run_dir" && mkdir -p "$run_dir" && cp -r "$src/." "$run_dir/" || return 1

  local init_args=(-input=false)
  if [[ "$backend" == local && "$STEP" != 000-* ]]; then
    printf '%s\n' '# written by do_tf_plan: TF_BACKEND=local' 'terraform {' '  backend "local" {}' '}' \
      >"$run_dir/backend_override.tf"
  elif [[ "$backend" == gcs ]]; then
    [[ -f "$backend_cfg" ]] || { do_log "FATAL not rendered: $backend_cfg"; return 1; }
    init_args+=(-backend-config="$backend_cfg")
  fi

  (
    set -e
    # One cache per org/app/env/step: terraform's plugin cache is not safe for
    # concurrent inits, and two operators planning different steps must not race.
    export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache/$ORG/$APP/$ENV/$STEP"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
    if [[ "${TF_OFFLINE_PLAN:-0}" == 1 ]]; then
      export GOOGLE_OAUTH_ACCESS_TOKEN="offline-plan-not-a-real-token"
      unset GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CREDENTIALS
    fi
    "$tf" -chdir="$run_dir" init "${init_args[@]}" -no-color >/dev/null
    "$tf" -chdir="$run_dir" validate -no-color
    "$tf" -chdir="$run_dir" plan -input=false -lock=false -no-color \
      -var-file="$vars" -out="$run_dir/$ORG-$APP-$ENV.tfplan"
  ) || { do_log "FATAL terraform plan failed for $ENV/$STEP"; return 1; }

  do_log "OK planned $ENV/$STEP -> $run_dir/$ORG-$APP-$ENV.tfplan (not applied)"
}
