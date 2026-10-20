#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"

#------------------------------------------------------------------------------
# @description List GCP Load Balancer resources for an environment. Read-only:
# @description lists the <org>-<app>-<env>-wui-* parts and the site bucket as the
# @description env's project SA, in a private gcloud config. A missing ORG_APP or
# @description ENV is refused before any gcloud call.
# @example ORG_APP=csi-spl ENV=dev ./run -a do_gcp_compute_lb_list
#------------------------------------------------------------------------------
do_gcp_compute_lb_list() {
  local org_app="${ORG_APP:?ORG_APP is required}"
  local env="${ENV:?ENV is required (dev/tst/prd)}"
  local org="${org_app%%-*}"
  local app="${org_app##*-}"
  local prefix="${org}-${app}-${env}-wui"
  local bucket_name="${org}-${app}-${env}-site-static"
  local gcp_project="${org}-${app}-${env}"
  local key_file="$HOME/.gcp/.${org}/key-${org}-${app}-${env}.json"

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
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
  do_gcp_log_identity "${gcp_project}" "${account}" "do_gcp_compute_lb_list"

  do_log "INFO Activating service account for project: ${gcp_project}"
  gcloud auth activate-service-account --key-file="${key_file}" || {
    do_log "ERROR Failed to activate service account"
    return 1
  }
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
  gcloud config set project "${gcp_project}"

  do_log "INFO === LB Resources for prefix: ${prefix} ==="

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
