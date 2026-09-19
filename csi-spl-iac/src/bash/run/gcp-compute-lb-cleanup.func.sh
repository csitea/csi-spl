#!/bin/bash

#------------------------------------------------------------------------------
# @description Cleanup GCP Load Balancer resources that may be orphaned This action deletes load balancer components in the correct dependency order: 1. Forwarding rules 2. Target proxies 3. URL maps 4. Backend buckets 5. SSL certificates 6. Storage bucket (optional) Resources are named with pattern: ${ORG}-${APP}-${ENV}-wui-*
# @example ENV=dev ./run -a do_gcp_compute_lb_cleanup
# @example ENV=dev ./run -a do_gcp_compute_lb_cleanup
#------------------------------------------------------------------------------
do_gcp_compute_lb_cleanup() {
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
  do_gcp_log_identity "${gcp_project:-<unset>}" "${account}" "do_gcp_compute_lb_cleanup"

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
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
  gcloud config set project "${gcp_project}"

  log_info "=== Cleaning up LB resources for prefix: ${prefix} ==="

  # 1. Delete forwarding rules
  log_info "Deleting forwarding rules..."
  gcloud compute forwarding-rules delete "${prefix}-http-forwarding" --global --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-http-forwarding" || log_warn "Not found: ${prefix}-http-forwarding"
  gcloud compute forwarding-rules delete "${prefix}-https-forwarding" --global --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-https-forwarding" || log_warn "Not found: ${prefix}-https-forwarding"

  # 2. Delete target proxies
  log_info "Deleting target proxies..."
  gcloud compute target-http-proxies delete "${prefix}-http-proxy" --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-http-proxy" || log_warn "Not found: ${prefix}-http-proxy"
  gcloud compute target-https-proxies delete "${prefix}-https-proxy" --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-https-proxy" || log_warn "Not found: ${prefix}-https-proxy"

  # 3. Delete URL maps
  log_info "Deleting URL maps..."
  gcloud compute url-maps delete "${prefix}-http-redirect" --global --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-http-redirect" || log_warn "Not found: ${prefix}-http-redirect"
  gcloud compute url-maps delete "${prefix}-https-url-map" --global --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-https-url-map" || log_warn "Not found: ${prefix}-https-url-map"

  # 4. Delete backend bucket
  log_info "Deleting backend bucket..."
  gcloud compute backend-buckets delete "${prefix}-backend" --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-backend" || log_warn "Not found: ${prefix}-backend"

  # 5. Delete SSL certificate
  log_info "Deleting SSL certificate..."
  gcloud compute ssl-certificates delete "${prefix}-ssl-cert" --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
    log_info "Deleted ${prefix}-ssl-cert" || log_warn "Not found: ${prefix}-ssl-cert"

  # 6. Delete storage bucket (optional - prompt or use flag)
  if [[ "${DELETE_BUCKET:-false}" == "true" ]]; then
    log_info "Deleting storage bucket: ${bucket_name}..."
    gcloud storage rm -r "gs://${bucket_name}" --account="${account}" 2>/dev/null && \
      log_info "Deleted gs://${bucket_name}" || log_warn "Not found or failed: gs://${bucket_name}"
  else
    log_info "Skipping storage bucket deletion. Set DELETE_BUCKET=true to delete."
  fi

  log_info "=== LB cleanup complete ==="
}
