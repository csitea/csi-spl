#!/bin/bash
#------------------------------------------------------------------------------
# @description Add the ONE version of this env's vendor-key fingerprint pepper
# @description (spec 127 section 4.2, lane I1) to the EMPTY Secret Manager slot
# @description step 057 creates (cnf vendor_keys.pepper_secret). The value is 32
# @description random bytes from /dev/urandom, piped straight into gcloud on
# @description stdin: never argv, a file, a log, git or terraform state. It is
# @description verified by its LENGTH only, never shown. Runs as the env's
# @description project SA in a private gcloud config.
# @description Refuses when the slot is missing (apply 057 first) and does
# @description nothing when an enabled version exists: a new pepper changes every
# @description stored fingerprint, so rotation is a separate, later action.
# @description DRY_RUN=1 (default): read and report, change nothing.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_vendor_key_pepper_put
#------------------------------------------------------------------------------
do_spl_vendor_key_pepper_put() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin yq gcloud || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml" sec
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  sec="$(yq -r '.env.vendor_keys.pepper_secret // ""' "$cnf")"
  [[ "$sec" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL the $ENV cnf has no valid env.vendor_keys.pepper_secret: '$sec'"; return 1; }
  do_gcp_pin_account || return 1
  local have
  gcloud secrets describe "$sec" --project="$p" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { do_log "FATAL no secret $p/$sec: apply step 057 first (it creates the empty slot)"; return 1; }
  have="$(gcloud secrets versions list "$sec" --project="$p" --account="$GCP_ACCOUNT" --filter=state:ENABLED --format='value(name)' 2>/dev/null)" ||
    { do_log "FATAL cannot list the versions of $p/$sec as $GCP_ACCOUNT"; return 1; }
  if [[ -n "$have" ]]; then
    do_log "OK $p/$sec already holds an enabled pepper version: nothing to add"
    return 0
  fi
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would add a 32-byte random pepper to $p/$sec. Re-run with DRY_RUN=0."
    return 0
  fi
  head -c 32 /dev/urandom | gcloud secrets versions add "$sec" --project="$p" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1 ||
    { do_log "FATAL could not add a version to $p/$sec as $GCP_ACCOUNT"; return 1; }
  if [[ "$(gcloud secrets versions access latest --secret="$sec" --project="$p" --account="$GCP_ACCOUNT" 2>/dev/null | wc -c)" -eq 32 ]]; then
    do_log "OK $p/$sec: pepper version added, verified by length (value not shown)"
  else
    do_log "ERROR $p/$sec: the latest version is not 32 bytes"; return 1
  fi
}
