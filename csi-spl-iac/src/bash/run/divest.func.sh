#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Divest.
#------------------------------------------------------------------------------
do_divest() {

  export ACTION="divest"
  do_tf_init

  bucket=${STATE_BUCKET:-}
  do_log "INFO using the following state bucket: $bucket"
  do_log "INFO bucket_name: ${bucket}"

  # divest
  do_tf_destroy "${STEP}"

  # As agreed in 2207291920 :::
  # Remote buckets will be provisioned and remain in the account until further notice.
  # This allows us to keep a single version of tfstate through the code, and enjoy
  # all the functionalities s3 state storing provides, without breaking states or
  # being locked by AWS console/cli caching.
  do_log "INFO 2207291920 ::: remote buckets need to be manually removed"
  echo do_tf_destroy_local_step_bucket "${STEP}-remote-bucket"
  rv=$?
  test $rv == "0"
}
