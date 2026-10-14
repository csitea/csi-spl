#!/bin/bash
#------------------------------------------------------------------------------
# @description A throwaway gcloud config for the calling function, so the
# @description shared ~/.config/gcloud is never written (owner rule
# @description 2026-09-19). spl_gcp_temp_sdk_config saves the caller's
# @description CLOUDSDK_CONFIG into the caller's local _spl_sdk_saved, makes a
# @description private dir in the caller's local _spl_sdk_dir and exports it;
# @description spl_gcp_temp_sdk_config_restore removes that dir and restores
# @description CLOUDSDK_CONFIG, or unsets it when the caller had none.
# @description
# @description The RETURN trap stays in the caller (round 9 plan, D7): a trap set
# @description in here would fire when THIS function returns and drop the dir
# @description before the caller used it. Refactor round 9 row 10: 26 files
# @description carried the 4-line block copied.
# @example local _spl_sdk_saved _spl_sdk_dir
# @example spl_gcp_temp_sdk_config || return 1
# @example trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
#------------------------------------------------------------------------------
spl_gcp_temp_sdk_config() {
  _spl_sdk_saved="${CLOUDSDK_CONFIG-}"
  _spl_sdk_dir="$(mktemp -d)" || return 1
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
}

spl_gcp_temp_sdk_config_restore() {
  [[ -n "${_spl_sdk_dir:-}" ]] && rm -rf "$_spl_sdk_dir"
  if [[ -n "${_spl_sdk_saved:-}" ]]; then
    export CLOUDSDK_CONFIG="$_spl_sdk_saved"
  else
    unset CLOUDSDK_CONFIG
  fi
}
