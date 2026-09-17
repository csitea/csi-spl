#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove a gcloud credential can actually mint an access token, BEFORE
# @description anything is decided or mutated on its behalf (finding F-23.3).
# @description
# @description WHY THIS IS A POSITIVE ASSERTION AND NOT AN EXIT-CODE TEST.
# @description A gcloud exit code does not distinguish "this identity is fine and
# @description there is nothing there" from "this identity was refused": a DENIED
# @description `gcloud compute instances list` returns **exit 0 and an empty set**
# @description (measured by CLE-16; `storage` and `secrets` return 1, `compute`
# @description returns 0). Any pre-flight built on `if gcloud ...; then` inherits
# @description that ambiguity. So this one asserts a POSITIVE artifact instead —
# @description a non-empty access token on stdout — and treats exit-0-with-empty-
# @description output as failure. An empty answer can no longer read as consent.
# @description
# @description It is also the exact call the reauth wall refuses: `rapt_required`
# @description is returned by the token endpoint itself (F-23), so a credential
# @description blocked by the org's reauth policy fails here rather than four
# @description lines later inside an idempotency check that would misread the
# @description failure as "the resource does not exist".
# @description
# @description The token is never logged; only its length is, which is enough to
# @description tell a real token from an empty string in a transcript.
# @param $1 (optional) - the account to prove. Defaults to ${GCP_ACCOUNT}.
# @example do_gcp_require_live_account "${GCP_ACCOUNT}" || quit_on "credential is dead"
#------------------------------------------------------------------------------
do_gcp_require_live_account() {
  local account="${1:-${GCP_ACCOUNT:-}}"

  if [[ -z "${account}" ]]; then
    do_log "ERROR do_gcp_require_live_account: no account given and GCP_ACCOUNT is empty"
    return 2
  fi

  local err_file token rc msg
  err_file=$(mktemp)
  token=$(gcloud auth print-access-token --account="${account}" 2>"${err_file}")
  rc=$?
  msg=$(tail -n 3 "${err_file}" | tr '\n' ' ')
  rm -f "${err_file}"

  if [[ "${rc}" -eq 0 && -n "${token}" ]]; then
    do_log "INFO GCP credential for ${account} is live (minted a ${#token}-char access token)"
    return 0
  fi

  do_log "ERROR GCP credential for ${account} cannot mint an access token (rc=${rc}, ${#token} chars): ${msg}"
  return 1
}
