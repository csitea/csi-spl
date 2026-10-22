#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description List the Cloud Monitoring alert incidents of the last SINCE
# @description (default 24h; 90m, 24h, 2d) per alert policy (the alert type):
# @description count, first open, last violating minute and the resource, then
# @description one line per incident with its peak value. Cloud Monitoring has
# @description no public incidents API (v3 .../incidents answers 404) and logs
# @description nothing per incident, so each enabled policy is REPLAYED: its
# @description threshold conditions are read from the Monitoring v3 timeSeries
# @description endpoint with the condition's own filter and aggregation, and
# @description src/bash/scripts/alert-incidents.py finds where each held for
# @description its duration. Each env runs AS ITS OWN project SA, from its key
# @description $HOME/.gcp/.<org>/key-<project>.json (do_gcp_env_sa_key_file), used through
# @description CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE in a throwaway private
# @description CLOUDSDK_CONFIG (removed afterwards); --account and --project on
# @description every gcloud call, the access token only in a 0600 curl -K file.
# @description ENV lists one env; unset, every env in GCP_LIST_ENVS (default
# @description "dev prd") whose key exists. ALERT_UNTIL (UTC, default now) ends
# @description the window. Read-only: no create, update or delete.
# @example ORG=csi APP=spl ENV=prd SINCE=24h ./run -a do_gcp_list_alert_incidents
# @example ORG=csi APP=spl ./run -a do_gcp_list_alert_incidents
#------------------------------------------------------------------------------
do_gcp_list_alert_incidents() {
  do_require_var ORG "${ORG:-}"
  do_require_var APP "${APP:-}"

  local envs env key account project since until n_seen=0 rc=0
  envs="${ENV:-${GCP_LIST_ENVS:-dev prd}}"
  read -r since until < <(gcp_alert_window "${SINCE:-24h}" "${ALERT_UNTIL:-}") \
    || { do_log "FATAL SINCE='${SINCE:-}' is not <n>m, <n>h or <n>d, or ALERT_UNTIL is not a UTC time"; return 1; }

  for env in ${envs}; do
    key=$(do_gcp_env_sa_key_file "${env}" "" "${envs}") || {
      [[ $? -eq 2 ]] && return 1
      do_log "INFO no SA key for ${env} (the project key, do_gcp_sa_key_file), skipped"
      continue
    }
    account=$(do_gcp_sa_key_email "${key}")
    project=$(jq -r '.project_id // ""' "${key}" 2>/dev/null)
    if [[ -z "${account}" || -z "${project}" ]]; then
      do_log "ERROR the SA key ${key} has no client_email or project_id"
      rc=1
      continue
    fi
    do_gcp_log_identity "${project}" "${account}" "${FUNCNAME[0]}"
    echo "== ${env} (${project})"
    gcp_alert_incidents_env "${key}" "${project}" "${account}" "${since}" "${until}" \
      || { do_log "ERROR listing the alert incidents of ${project} as ${account} failed"; rc=1; }
    n_seen=$((n_seen + 1))
  done

  if [[ "${n_seen}" -eq 0 ]]; then
    do_log "FATAL no SA key for any of: ${envs}"
    return 1
  fi
  do_log "INFO alert incident listing completed for ${n_seen} env(s), ${since} .. ${until}"
  return ${rc}
}

# gcp_alert_window <since> [<until>] -> "<start> <end>", UTC, seconds precision
gcp_alert_window() {
  local n unit end
  [[ "$1" =~ ^([0-9]+)([mhd])$ ]] || return 1
  n="${BASH_REMATCH[1]}"
  unit=$(case "${BASH_REMATCH[2]}" in m) echo minutes ;; h) echo hours ;; d) echo days ;; esac)
  end=$(date -u -d "${2:-now}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  echo "$(date -u -d "${end} - ${n} ${unit}" +%Y-%m-%dT%H:%M:%SZ) ${end}"
}

# gcp_alert_incidents_env <key> <project> <account> <since> <until>: the policies,
# one timeSeries read per threshold condition (every page), then the report.
gcp_alert_incidents_env() {
  local key="$1" project="$2" account="$3" since="$4" until="$5" cfg
  cfg="$(umask 077 && mktemp -d)" || return 1
  # the subshell's EXIT trap removes the config, the token file and the pages
  # on every exit, an interrupt too
  (
    trap 'rm -rf "${cfg}"' EXIT
    umask 077
    export CLOUDSDK_CONFIG="${cfg}/gcloud" CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${key}"
    local py="${PROJ_PATH:-$(dirname "${BASH_SOURCE[0]}")/../../..}/src/bash/scripts/alert-incidents.py"
    local tok n page next url="https://monitoring.googleapis.com/v3/projects/${project}/timeSeries"
    mkdir -p "${cfg}/q" || exit 1
    gcloud alpha monitoring policies list --project="${project}" --account="${account}" \
      --format=json >"${cfg}/policies.json" || exit 1
    tok=$(gcloud auth print-access-token --account="${account}" 2>/dev/null)
    [[ -n "${tok}" ]] || { echo "no access token for ${account}" >&2; exit 1; }
    printf 'header = "Authorization: Bearer %s"\n' "${tok}" >"${cfg}/auth.curl"
    for n in $(python3 "${py}" plan "${cfg}/policies.json" "${cfg}/q"); do
      page=0 next=""
      while :; do
        curl -s --connect-timeout 10 --max-time 60 -G "${url}" -K "${cfg}/auth.curl" -K "${cfg}/q/q${n}.curl" \
          --data-urlencode "interval.startTime=${since}" --data-urlencode "interval.endTime=${until}" \
          --data-urlencode "pageSize=100000" ${next:+--data-urlencode "pageToken=${next}"} \
          >"${cfg}/q/q${n}.p${page}.json" || exit 1
        next=$(jq -r '.nextPageToken // ""' "${cfg}/q/q${n}.p${page}.json" 2>/dev/null)
        [[ -n "${next}" && "${page}" -lt 50 ]] || break
        page=$((page + 1))
      done
    done
    python3 "${py}" report "${cfg}/policies.json" "${cfg}/q" "${since}" "${until}"
  )
}
