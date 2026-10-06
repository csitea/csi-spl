#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Put the Docs GitHub App private key (spec 075 §9) into this env's
# @description Secret Manager secret GH_APP_SECRET (default
# @description spool-hub-github-app-key), as the env's project SA in a private
# @description gcloud config. The slot is terraform's (T01, step 030); while T01
# @description is not applied it is created here, empty, with the labels and the
# @description user-managed replication 030 uses, so T01 imports it. A version
# @description is added from KEY_FILE (gcloud reads the file: the value is never
# @description argv, stdout or a log) only when the latest differs (sha256), then
# @description verified by sha256. do_spl_gh_app_manifest calls it per env.
# @description DRY_RUN=1 (default): read and compare, change nothing.
# @param ENV - required: dev or prd
# @param KEY_FILE - required: the App's .pem
# @param GH_APP_SECRET (optional) - default spool-hub-github-app-key
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev KEY_FILE=$HOME/.github/.csi/<app-slug>.pem DRY_RUN=0 ./run -a do_spl_gh_app_key_put
#------------------------------------------------------------------------------
do_spl_gh_app_key_put() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}" sec="${GH_APP_SECRET:-spool-hub-github-app-key}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$sec" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL not a secret id: '$sec'"; return 2; }
  [[ -n "${KEY_FILE:-}" && -s "$KEY_FILE" ]] || { do_log "FATAL KEY_FILE must name a non-empty key file"; return 2; }
  do_require_bin yq || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml" region
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  region="$(yq -r '.env.gcp.gcp_region // ""' "$cnf")"
  [[ -n "$region" ]] || { do_log "FATAL the $ENV cnf has no env.gcp.gcp_region"; return 1; }
  do_gcp_pin_account || return 1
  local sa="$GCP_ACCOUNT" want have
  want="$(sha256sum <"$KEY_FILE" | cut -d' ' -f1)"
  if ! gcloud secrets describe "$sec" --project="$p" --account="$sa" >/dev/null 2>&1; then
    if [[ "$dry" == 1 ]]; then
      do_log "OK DRY_RUN would create the empty slot $p/$sec ($region) and add the key. Re-run with DRY_RUN=0."
      return 0
    fi
    gcloud secrets create "$sec" --project="$p" --account="$sa" --replication-policy=user-managed \
      --locations="$region" --labels="org=$ORG,app=$APP,env=$ENV,role=hub-github-app" >/dev/null ||
      { do_log "FATAL could not create $p/$sec as $sa"; return 1; }
    do_log "OK created the empty slot $p/$sec ($region); T01 imports it into step 030"
  fi
  have="$(gcloud secrets versions access latest --secret="$sec" --project="$p" --account="$sa" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "$have" == "$want" ]]; then
    do_log "OK $p/$sec already holds this key (sha256): nothing to add"
  elif [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would add a version to $p/$sec. Re-run with DRY_RUN=0."
  elif ! gcloud secrets versions add "$sec" --project="$p" --account="$sa" --data-file="$KEY_FILE" >/dev/null 2>&1; then
    do_log "FATAL could not add a version to $p/$sec as $sa"; return 1
  elif [[ "$(gcloud secrets versions access latest --secret="$sec" --project="$p" --account="$sa" 2>/dev/null | sha256sum | cut -d' ' -f1)" == "$want" ]]; then
    do_log "OK $p/$sec: new version verified by sha256 (value not shown)"
  else
    do_log "ERROR $p/$sec latest version does not match the key file (sha256)"; return 1
  fi
}
