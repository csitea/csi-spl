#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Rotate the Docs GitHub App private key on one env (spec 075
# @description repo-edit §9 / T04). Before: generate a NEW private key on the
# @description App's GitHub settings page (the owner's step). Then, per env:
# @description 1. do_put_github_app_key adds it as a new secret version;
# @description 2. the hub roll (do_gcp_hub_restart): the key is injected at
# @description version latest, read when an instance starts, so a fresh revision
# @description picks it up; skipped while cnf docs.repo_edit.inject is not "true"
# @description (the hub does not read the key then);
# @description 3. a reminder to delete the OLD key in GitHub once both envs run
# @description the new one - the old key signs until it is deleted there.
# @description Run ENV=dev, then ENV=prd SHRED=1. DRY_RUN=1 (default) changes nothing.
# @param ENV - required: dev or prd
# @param KEY_FILE - required: the NEW .pem
# @param SHRED (optional) - 0 (default) or 1; 1 only with ENV=prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev KEY_FILE=$HOME/Downloads/<app-slug>.private-key.pem ./run -a do_rotate_github_app_key
# @example ENV=prd KEY_FILE=$HOME/Downloads/<app-slug>.private-key.pem SHRED=1 DRY_RUN=0 ./run -a do_rotate_github_app_key
#------------------------------------------------------------------------------
do_rotate_github_app_key() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 2; }
  local cnf_dir inject app_id
  cnf_dir="$(mktemp -d)"
  if do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf_dir/cnf.yaml"; then
    inject="$(yq -r '.env.docs.repo_edit.inject // ""' "$cnf_dir/cnf.yaml")"
    app_id="$(yq -r '.env.docs.repo_edit.github_app_id // ""' "$cnf_dir/cnf.yaml")"
  fi
  rm -rf "$cnf_dir"
  [[ -n "$app_id" ]] || { do_log "FATAL the $ENV cnf has no env.docs.repo_edit.github_app_id"; return 1; }

  do_log "INFO $ENV: rotate step 1/3 - put the new key"
  ( DRY_RUN="$dry" do_put_github_app_key ) || return $?

  if [[ "$inject" == true ]]; then
    do_log "INFO $ENV: rotate step 2/3 - roll the hub so it reads the new version"
    ( DRY_RUN="$dry" do_gcp_hub_restart ) || return $?
  else
    do_log "INFO $ENV: rotate step 2/3 - no hub roll: cnf docs.repo_edit.inject is '${inject}', the hub does not read the key"
  fi

  do_log "ACTION $ENV: rotate step 3/3 - once dev AND prd hold the new key, delete the OLD private key of GitHub App $app_id on its GitHub settings page (Private keys); until then the old key still signs"
}
