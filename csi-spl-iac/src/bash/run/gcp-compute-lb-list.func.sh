#!/bin/bash

#------------------------------------------------------------------------------
# @description List GCP Load Balancer resources for an environment
# @example ENV=dev ./run -a do_gcp_compute_lb_list
# @example ENV=dev ./run -a do_gcp_compute_lb_list
#------------------------------------------------------------------------------
do_gcp_compute_lb_list() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${gcp_project:-<unset>}" "${account}" "do_gcp_compute_lb_list"

  local org_app="${ORG_APP:?ORG_APP is required}"
  local org="${org_app%%-*}"
  local app="${org_app##*-}"
  local env="${ENV:?ENV is required (dev/tst/prd)}"
  local prefix="${org}-${app}-${env}-wui"
  local bucket_name="${org}-${app}-${env}-site-static"
  local gcp_project="${org}-${app}-${env}"
  local key_file="$HOME/.gcp/.${org}/key-${org}-${app}-${env}.json"

  log_info "Activating service account for project: ${gcp_project}"
  gcloud auth activate-service-account --key-file="${key_file}" || {
    log_error "Failed to activate service account"
  return 1
  }
  gcloud config set project "${gcp_project}"

  log_info "=== LB Resources for prefix: ${prefix} ==="

  echo ""
  echo "=== Forwarding Rules ==="
  gcloud compute forwarding-rules list --global --filter="name~${prefix}" --account="${account}" --project="${gcp_project}" 2>/dev/null || echo "None found"

  echo ""
  echo "=== Target HTTP Proxies ==="
  gcloud compute target-http-proxies list --filter="name~${prefix}" --account="${account}" --project="${gcp_project}" 2>/dev/null || echo "None found"

  echo ""
  echo "=== Target HTTPS Proxies ==="
  gcloud compute target-https-proxies list --filter="name~${prefix}" --account="${account}" --project="${gcp_project}" 2>/dev/null || echo "None found"

  echo ""
  echo "=== URL Maps ==="
  gcloud compute url-maps list --filter="name~${prefix}" --account="${account}" --project="${gcp_project}" 2>/dev/null || echo "None found"

  echo ""
  echo "=== Backend Buckets ==="
  gcloud compute backend-buckets list --filter="name~${prefix}" --account="${account}" --project="${gcp_project}" 2>/dev/null || echo "None found"

  echo ""
  echo "=== SSL Certificates ==="
  gcloud compute ssl-certificates list --filter="name~${prefix}" --account="${account}" --project="${gcp_project}" 2>/dev/null || echo "None found"

  echo ""
  echo "=== Storage Bucket ==="
  gcloud storage buckets describe "gs://${bucket_name}" --format="value(name)" --account="${account}" 2>/dev/null || echo "Not found: ${bucket_name}"

}
