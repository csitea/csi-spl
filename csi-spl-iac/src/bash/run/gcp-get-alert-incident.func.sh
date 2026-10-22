#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Show ONE Cloud Monitoring alert incident: its policy (enabled,
# @description channels, each condition with filter, comparison, threshold,
# @description duration and aggregation), its resource and peak, and its
# @description timeline (every aligned point of that series around it, each
# @description marked VIOLATES or ok). The gcp_alert_incident MCP tool runs it
# @description (SPL-2887). An incident has no id (Cloud Monitoring has no
# @description public incidents API), so it is named as
# @description do_gcp_list_alert_incidents prints it: POLICY (display name) and
# @description OPENED (YYYY-MM-DDTHH:MMZ, the minute it opened). The policy is
# @description replayed exactly as that action does (alert-incidents.py, reused
# @description by src/bash/scripts/alert-incident.py) over OPENED minus 2 h ..
# @description OPENED plus 24 h, capped at now (ALERT_UNTIL overrides the end).
# @description As the env's OWN project SA, from its key
# @description $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json, through
# @description CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE in a throwaway private
# @description CLOUDSDK_CONFIG; --account and --project on every gcloud call,
# @description the access token only in a 0600 curl -K file. Read-only.
# @description Exit 1 bad input, no key or a read error; 3 no enabled policy of
# @description that name; 4 no incident of it opened at OPENED (the ones that
# @description did are listed).
# @example ORG=csi APP=spl ENV=prd POLICY='csi-spl-prd hub 5xx rate' OPENED=2026-10-22T09:31Z ./run -a do_gcp_get_alert_incident
#------------------------------------------------------------------------------
do_gcp_get_alert_incident() {
  do_require_var ORG "${ORG:-}"
  do_require_var APP "${APP:-}"
  local env="${ENV:-}" policy="${POLICY:-}" opened="${OPENED:-}" app key account project since until now
  [[ "${env}" =~ ^[a-z]{2,8}$ ]] || { do_log "FATAL ENV must name one env (dev or prd), got: '${env}'"; return 1; }
  [[ -n "${policy}" && "${policy}" != *$'\n'* ]] || { do_log "FATAL POLICY must name one alert policy display name"; return 1; }
  [[ "${opened}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] && date -u -d "${opened}" >/dev/null 2>&1 \
    || { do_log "FATAL OPENED must be YYYY-MM-DDTHH:MMZ (UTC), got: '${opened}'"; return 1; }
  app="${APP#${ORG}-}"
  key="${HOME}/.gcp/.${ORG}/key-${ORG}-${app}-${env}.json"
  [[ -f "${key}" ]] || { do_log "FATAL no SA key for ${env} (${key})"; return 1; }
  account=$(do_gcp_sa_key_email "${key}")
  project=$(jq -r '.project_id // ""' "${key}" 2>/dev/null)
  [[ -n "${account}" && -n "${project}" ]] || { do_log "FATAL the SA key ${key} has no client_email or project_id"; return 1; }

  since=$(date -u -d "${opened} - 2 hours" +%Y-%m-%dT%H:%M:%SZ)
  if [[ -n "${ALERT_UNTIL:-}" ]]; then
    until=$(date -u -d "${ALERT_UNTIL}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || { do_log "FATAL ALERT_UNTIL is not a UTC time"; return 1; }
  else
    until=$(date -u -d "${opened} + 24 hours" +%Y-%m-%dT%H:%M:%SZ) now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [[ "${until}" < "${now}" ]] || until="${now}"
  fi
  do_gcp_log_identity "${project}" "${account}" "${FUNCNAME[0]}"
  echo "== ${env} (${project})"
  gcp_alert_incident_env "${key}" "${project}" "${account}" "${policy}" "${opened}" "${since}" "${until}"
}

# gcp_alert_incident_env <key> <project> <account> <policy> <opened> <since> <until>:
# the one policy, one timeSeries read per threshold condition (every page),
# then the detail. Returns the detail's exit code.
gcp_alert_incident_env() {
  local key="$1" project="$2" account="$3" policy="$4" opened="$5" since="$6" until="$7" cfg
  cfg="$(umask 077 && mktemp -d)" || return 1
  # the subshell's EXIT trap removes the config, the token file and the pages
  # on every exit, an interrupt too
  (
    trap 'rm -rf "${cfg}"' EXIT
    umask 077
    export CLOUDSDK_CONFIG="${cfg}/gcloud" CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${key}"
    local dir="${PROJ_PATH:-$(dirname "${BASH_SOURCE[0]}")/../../..}/src/bash/scripts"
    local tok n page next url="https://monitoring.googleapis.com/v3/projects/${project}/timeSeries"
    mkdir -p "${cfg}/q" || exit 1
    gcloud alpha monitoring policies list --project="${project}" --account="${account}" \
      --format=json >"${cfg}/policies.json" || exit 1
    python3 "${dir}/alert-incident.py" select "${cfg}/policies.json" "${policy}" >"${cfg}/policy.json" || exit 3
    tok=$(gcloud auth print-access-token --account="${account}" 2>/dev/null)
    [[ -n "${tok}" ]] || { echo "no access token for ${account}" >&2; exit 1; }
    printf 'header = "Authorization: Bearer %s"\n' "${tok}" >"${cfg}/auth.curl"
    for n in $(python3 "${dir}/alert-incidents.py" plan "${cfg}/policy.json" "${cfg}/q"); do
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
    python3 "${dir}/alert-incident.py" detail "${cfg}/policy.json" "${cfg}/q" "${opened}" "${since}" "${until}"
  )
}
