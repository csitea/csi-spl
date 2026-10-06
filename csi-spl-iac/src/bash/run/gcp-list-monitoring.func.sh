#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description List the Cloud Monitoring alerting of each environment: the
# @description uptime checks, the alert policies and the notification channels
# @description (names, types and state only; a channel's labels, which hold its
# @description address, are never printed). The 070-gcp-monitoring before/after
# @description measure (availability plan row R03). Each env is listed AS ITS
# @description OWN project SA, from its key
# @description $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json, in a throwaway
# @description private CLOUDSDK_CONFIG that is removed afterwards; the shared
# @description ~/.config/gcloud is never read or written and every call carries
# @description --account and --project. The key is used through
# @description CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE, so nothing is activated.
# @description ENV lists one env; unset, every env in GCP_LIST_ENVS (default
# @description "dev prd") whose key exists. An env without a key is skipped;
# @description no key at all fails. Read-only: no create, update or delete.
# @example ORG=csi APP=spl ENV=dev ./run -a do_gcp_list_monitoring
# @example ORG=csi APP=spl ./run -a do_gcp_list_monitoring
#------------------------------------------------------------------------------
do_gcp_list_monitoring() {
  do_require_var ORG "${ORG:-}"
  do_require_var APP "${APP:-}"

  local envs env app key account project cfg n_seen=0 rc=0
  envs="${ENV:-${GCP_LIST_ENVS:-dev prd}}"
  app="${APP#${ORG}-}"

  for env in ${envs}; do
    key="${HOME}/.gcp/.${ORG}/key-${ORG}-${app}-${env}.json"
    if [[ ! -f "${key}" ]]; then
      do_log "INFO no SA key for ${env} (${key}), skipped"
      continue
    fi
    account=$(do_gcp_sa_key_email "${key}")
    project=$(jq -r '.project_id // ""' "${key}" 2>/dev/null)
    if [[ -z "${account}" || -z "${project}" ]]; then
      do_log "ERROR the SA key ${key} has no client_email or project_id"
      rc=1
      continue
    fi

    do_gcp_log_identity "${project}" "${account}" "${FUNCNAME[0]}"
    cfg="$(umask 077 && mktemp -d)" || return 1
    # the subshell's EXIT trap removes the config on every exit, an interrupt
    # too (a RETURN trap does not run when bash dies of SIGINT)
    (
      trap 'rm -rf "${cfg}"' EXIT
      export CLOUDSDK_CONFIG="${cfg}" CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${key}"
      set -o pipefail
      echo "== ${env} uptime checks"
      gcloud monitoring uptime list-configs --project="${project}" --account="${account}" \
        --format='table(displayName:label=NAME,monitoredResource.labels.host:label=HOST,httpCheck.path:label=PATH,period:label=PERIOD,selectedRegions.list():label=REGIONS)' || exit 1
      echo "== ${env} alert policies"
      gcloud alpha monitoring policies list --project="${project}" --account="${account}" \
        --format='table(displayName:label=NAME,enabled:label=ENABLED,notificationChannels.len():label=CHANNELS)' || exit 1
      echo "== ${env} notification channels"
      gcloud beta monitoring channels list --project="${project}" --account="${account}" \
        --format='table(displayName:label=NAME,type:label=TYPE,enabled:label=ENABLED,verificationStatus:label=VERIFICATION)' || exit 1
    ) || { do_log "ERROR listing the monitoring of ${project} as ${account} failed"; rc=1; }
    n_seen=$((n_seen + 1))
  done

  if [[ "${n_seen}" -eq 0 ]]; then
    do_log "FATAL no SA key for any of: ${envs}"
    return 1
  fi
  do_log "INFO monitoring listing completed for ${n_seen} env(s)"
  return ${rc}
}
