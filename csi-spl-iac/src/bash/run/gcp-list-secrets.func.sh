#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description List the Secret Manager secrets of each environment: names and
# @description metadata only, never a value (no `versions access` is run).
# @description Each env is listed AS ITS OWN project SA, from its key
# @description $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json, in a throwaway
# @description private CLOUDSDK_CONFIG that is removed afterwards; the shared
# @description ~/.config/gcloud is never read or written and every call carries
# @description --account and --project. The key is used through
# @description CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE, so nothing is activated.
# @description ENV lists one env; unset, every env in GCP_LIST_ENVS (default
# @description "all dev tst stg prd") whose key exists. An env without a key is
# @description skipped; no key at all fails. FILTER is passed as --filter.
# @example ORG=csi APP=<app> ENV=dev ./run -a do_gcp_list_secrets
# @example ORG=csi APP=<app> FILTER="name~auth" ./run -a do_gcp_list_secrets
#------------------------------------------------------------------------------
do_gcp_list_secrets() {
  do_require_var ORG "${ORG:-}"
  do_require_var APP "${APP:-}"

  local envs env app key account project cfg n_seen=0 rc=0
  envs="${ENV:-${GCP_LIST_ENVS:-all dev tst stg prd}}"
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
      gcloud secrets list --project="${project}" --account="${account}" \
        ${FILTER:+--filter="${FILTER}"} \
        --format='table(name.basename():label=NAME,createTime.date(tz=UTC):label=CREATED,replication.automatic.yesno(yes=automatic,no=user-managed):label=REPLICATION,labels.list():label=LABELS)'
    ) || { do_log "ERROR listing the secrets of ${project} as ${account} failed"; rc=1; }
    n_seen=$((n_seen + 1))
  done

  if [[ "${n_seen}" -eq 0 ]]; then
    do_log "FATAL no SA key for any of: ${envs}"
    return 1
  fi
  do_log "INFO secret listing completed for ${n_seen} env(s)"
  return ${rc}
}
