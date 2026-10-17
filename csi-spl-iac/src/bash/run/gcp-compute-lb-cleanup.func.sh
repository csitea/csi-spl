#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"

#------------------------------------------------------------------------------
# @description Cleanup GCP Load Balancer resources that may be orphaned. Deletes
# @description the load balancer parts in dependency order: 1. forwarding rules
# @description 2. target proxies 3. URL maps 4. backend bucket 5. SSL certificate
# @description 6. storage bucket (only with DELETE_BUCKET=true). Parts are named
# @description <org>-<app>-<env>-wui-*. Destructive, so a DRY RUN unless DRY_RUN=0:
# @description DRY_RUN=1 (default) prints the gcloud calls it would make (account,
# @description project, resource) and makes none. A missing ORG_APP or ENV is
# @description refused before any gcloud call.
# @param DRY_RUN (optional) - 1 (default): print the calls, run none. 0: delete.
# @param DELETE_BUCKET (optional) - true also deletes gs://<org>-<app>-<env>-site-static
# @example ORG_APP=csi-spl ENV=dev ./run -a do_gcp_compute_lb_cleanup
# @example ORG_APP=csi-spl ENV=dev DRY_RUN=0 ./run -a do_gcp_compute_lb_cleanup
#------------------------------------------------------------------------------
do_gcp_compute_lb_cleanup() {
  local org_app="${ORG_APP:?ORG_APP is required}"
  local env="${ENV:?ENV is required (dev/tst/prd)}"
  local org="${org_app%%-*}"
  local app="${org_app##*-}"
  local prefix="${org}-${app}-${env}-wui"
  local bucket_name="${org}-${app}-${env}-site-static"
  local gcp_project="${org}-${app}-${env}"
  local key_file="$HOME/.gcp/.${org}/key-${org}-${app}-${env}.json"
  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { log_error "DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  local part kind name scope account parts
  mapfile -t parts < <(_gcp_lb_cleanup_parts)

  if [[ "${dry_run}" == 1 ]]; then
    _gcp_lb_cleanup_dry_run "${prefix}" "${gcp_project}" "${bucket_name}" "${key_file}"
    return
  fi

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
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${gcp_project}" "${account}" "do_gcp_compute_lb_cleanup"

  log_info "Activating service account for project: ${gcp_project}"
  gcloud auth activate-service-account --key-file="${key_file}" || {
    log_error "Failed to activate service account"
  return 1
  }
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
  gcloud config set project "${gcp_project}"

  log_info "=== Cleaning up LB resources for prefix: ${prefix} ==="

  # 1-5. forwarding rules, target proxies, URL maps, backend bucket, SSL certificate
  for part in "${parts[@]}"; do
    read -r kind name scope <<<"${part}"
    # shellcheck disable=SC2086 # scope is empty or one flag
    gcloud compute "${kind}" delete "${prefix}-${name}" ${scope} --quiet --account="${account}" --project="${gcp_project}" 2>/dev/null && \
      log_info "Deleted ${prefix}-${name}" || log_warn "Not found: ${prefix}-${name}"
  done

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

#------------------------------------------------------------------------------
# @description The LB parts do_gcp_compute_lb_cleanup deletes, one per line as
# @description "<resource kind> <name suffix> [scope flag]", in dependency order.
#------------------------------------------------------------------------------
_gcp_lb_cleanup_parts() {
  printf '%s\n' \
    "forwarding-rules http-forwarding --global" \
    "forwarding-rules https-forwarding --global" \
    "target-http-proxies http-proxy" \
    "target-https-proxies https-proxy" \
    "url-maps http-redirect --global" \
    "url-maps https-url-map --global" \
    "backend-buckets backend" \
    "ssl-certificates ssl-cert"
}

#------------------------------------------------------------------------------
# @description The DRY_RUN=1 half of do_gcp_compute_lb_cleanup: print the gcloud
# @description calls the real run would make and make none. The account comes
# @description from ACCOUNT / GCP_ACCOUNT or the key's client_email, as the real
# @description run resolves it, without a gcloud call.
# @param $1 prefix $2 project $3 bucket name $4 SA key file
#------------------------------------------------------------------------------
_gcp_lb_cleanup_dry_run() {
  local prefix="$1" gcp_project="$2" bucket_name="$3" key_file="$4" account part kind name scope
  account="${ACCOUNT:-${GCP_ACCOUNT:-}}"
  [[ -n "${account}" ]] || account=$(do_gcp_sa_key_email "${key_file}") \
    || { log_error "no gcloud account: set ACCOUNT or provide the key ${key_file}"; return 1; }
  log_info "DRY_RUN would run: gcloud auth activate-service-account --key-file=${key_file}"
  while read -r kind name scope; do
    log_info "DRY_RUN would run: gcloud compute ${kind} delete ${prefix}-${name}${scope:+ ${scope}} --quiet --account=${account} --project=${gcp_project}"
  done < <(_gcp_lb_cleanup_parts)
  if [[ "${DELETE_BUCKET:-false}" == "true" ]]; then
    log_info "DRY_RUN would run: gcloud storage rm -r gs://${bucket_name} --account=${account}"
  fi
  log_info "DRY_RUN for ${prefix} complete: nothing was deleted. Re-run with DRY_RUN=0 to delete."
}
