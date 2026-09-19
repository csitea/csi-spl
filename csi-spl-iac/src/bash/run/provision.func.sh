#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Provision.
#------------------------------------------------------------------------------

# 066-T005 / FR-004: host-side container resolver check before terraform.
# Inside the tf-runner this is a no-op (the make wrapper already ran it).
_provision_check_container_dns() {
  if [[ "${SKIP_CONTAINER_DNS_CHECK:-}" == "1" ]]; then
    return 0
  fi
  if declare -f do_check_container_dns >/dev/null 2>&1; then
    do_check_container_dns
    return $?
  fi
  local _src="" _dir _cand _helpers
  if [[ -n "${ORC_PROJ_PATH:-}" && -f "${ORC_PROJ_PATH}/src/bash/run/check-container-dns.func.sh" ]]; then
    _src="${ORC_PROJ_PATH}/src/bash/run/check-container-dns.func.sh"
  else
    _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
    for _cand in "${_dir}"/*-orc/src/bash/run/check-container-dns.func.sh; do
      if [[ -f "$_cand" ]]; then
        _src="$_cand"
        break
      fi
    done
  fi
  if [[ -z "$_src" ]]; then
    do_log "WARN do_check_container_dns not found — skipping container DNS check"
    return 0
  fi
  _helpers="$(dirname "$_src")/flush-dns.func.sh"
  [[ -f "$_helpers" ]] && source "$_helpers"
  # shellcheck disable=SC1090
  source "$_src"
  do_check_container_dns
}

do_provision() {

  _provision_check_container_dns || return $?

  do_tf_init

  # the state bucket name OR it's naming convention should be fetched from the conf
  # and not built dynamically in the different runtmes ...
  bucket=${STATE_BUCKET:-}
  export TF_VAR_STEP=${STEP:?}

  do_log "INFO running checking the bucket"
  do_log "INFO bucket_name: ${bucket}"

  if [[ "${ACTION}" == "divest" ]]; then
    # divest
    do_tf_destroy "${STEP}"

    # As agreed in 2207291920 :::
    # Remote buckets will be provisioned and remain in the account until further notice.
    # This allows us to keep a single version of tfstate through the code, and enjoy
    # all the functionalities s3 state storing provides, without breaking states or
    # being locked by AWS console/cli caching.
    do_log "INFO 2207291920 ::: remote buckets need to be manually removed"
    echo do_tf_destroy_local_step_bucket "${STEP}-remote-bucket"
  else
    do_tf_apply "${STEP}"
  fi

  rv=$?
  test $rv == "0"
}
