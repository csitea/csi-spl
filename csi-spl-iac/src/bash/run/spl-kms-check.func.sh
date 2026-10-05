#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove the marketing KMS key (step 055, spec 090 T002) works
# @description for the hub: encrypt a fixed test string AS the hub's runtime
# @description SA (cnf hub.runtime_sa_account_id), decrypt the ciphertext AS
# @description that SA, and compare. Prints exactly one line on stdout: OK when
# @description the round trip returns the string, FAIL otherwise (no key, no
# @description grant, no impersonation, or a mismatch). Diagnostics go to
# @description stderr; no secret is involved (the test string is fixed).
# @description Runs as the env's project SA (do_gcp_pin_account) in a private
# @description gcloud config, impersonating the runtime SA: 055 grants the
# @description project SA serviceAccountTokenCreator on that SA only.
# @description Read-only: nothing in GCP changes.
# @param ENV - required: dev or prd
# @example ENV=dev ./run -a do_spl_kms_check
#------------------------------------------------------------------------------
do_spl_kms_check() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  local p region ring key rt
  if ! spl_kms_check_target >&2; then
    echo FAIL
    return 1
  fi
  local plain="spool-kms-check ${ENV}" back
  back="$(printf '%s' "$plain" | spl_kms_call encrypt --plaintext-file=- --ciphertext-file=- |
    spl_kms_call decrypt --ciphertext-file=- --plaintext-file=-)"
  if [[ "$back" == "$plain" ]]; then
    echo OK
    return 0
  fi
  do_log "ERROR the round trip on $ring/$key as $rt did not return the test string" >&2
  echo FAIL
  return 1
}

# spl_kms_check_target - sets p, region, ring, key and rt (the caller's
# locals) from the merged cnf of $ENV, and pins GCP_ACCOUNT to the project SA.
spl_kms_check_target() {
  do_require_bin yq gcloud || return 1
  do_gcp_spl_proj_id || return 1
  p="$PROJ_ID"
  local cnf="$CLOUDSDK_CONFIG/cnf.yaml" rt_id
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  region="$(yq -r '.env.gcp.gcp_region // ""' "$cnf")"
  ring="$(yq -r '.env.marketing.kms_key.key_ring // ""' "$cnf")"
  key="$(yq -r '.env.marketing.kms_key.crypto_key // ""' "$cnf")"
  rt_id="$(yq -r '.env.hub.runtime_sa_account_id // ""' "$cnf")"
  [[ -n "$region" && -n "$ring" && -n "$key" && -n "$rt_id" ]] ||
    { do_log "FATAL the $ENV cnf lacks env.gcp.gcp_region, env.marketing.kms_key.{key_ring,crypto_key} or env.hub.runtime_sa_account_id"; return 1; }
  rt="$rt_id@$p.iam.gserviceaccount.com"
  do_gcp_pin_account || return 1
}

# spl_kms_call <encrypt|decrypt> <file args...> - one gcloud kms call on the
# marketing key, as the runtime SA; gcloud's own messages are dropped.
spl_kms_call() {
  local verb="$1"
  shift
  gcloud kms "$verb" --project="$p" --location="$region" --keyring="$ring" --key="$key" \
    --account="$GCP_ACCOUNT" --impersonate-service-account="$rt" "$@" 2>/dev/null
}
