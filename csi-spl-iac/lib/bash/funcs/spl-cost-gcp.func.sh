#!/bin/bash
#------------------------------------------------------------------------------
# @description The pieces do_gcp_billing_export_setup and do_spl_estate_cost_read
# @description share (spec 123 section 4.2, build lane 2): the cnf env.cost
# @description values and one BigQuery REST call.
# @description
# @description BigQuery goes over REST with an access token minted by
# @description `gcloud auth print-access-token --account=...`, not through the
# @description bq CLI: bq has no --account, so it would act as whatever the
# @description gcloud config holds active, and the owner rule (2026-09-19) is
# @description --account on every call. The token reaches curl on stdin
# @description (`-K -`), never argv, and is never logged.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# @description Read cnf env.cost (all.env.yaml, deep-merged with <ENV>.env.yaml
# @description when ENV names one) into COST_REREAD_DAYS, COST_EXPORT_PROJECT,
# @description COST_DATASET, COST_LOCATION, COST_READER_SA, COST_READER_EMAIL and
# @description COST_PROJECT_LIKE. Any empty value is a refusal.
# @param $1 (optional) the cnf dir, default $APP_PATH/<org>-<app>-cnf/<org>-<app>
# @example do_spl_cost_gcp_cnf || return 1
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # the COST_* globals are read by the two cost actions
do_spl_cost_gcp_cnf() {
  local cnf="${1:-${APP_PATH:-}/${ORG:-}-${APP:-}-cnf/${ORG:-}-${APP:-}}"
  local files=() vals=() i
  [[ -f "${cnf}/all.env.yaml" ]] || { do_log "FATAL no ${cnf}/all.env.yaml"; return 1; }
  files=("${cnf}/all.env.yaml")
  [[ -n "${ENV:-}" && -f "${cnf}/${ENV}.env.yaml" ]] && files+=("${cnf}/${ENV}.env.yaml")
  mapfile -t vals < <(yq eval-all '. as $i ireduce ({}; . * $i)' "${files[@]}" |
    yq -r '[.env.cost.reread_days, .env.cost.gcp.export_project, .env.cost.gcp.export_dataset,
            .env.cost.gcp.export_location, .env.cost.gcp.reader_sa, .env.cost.gcp.project_like] | .[] | (. // "")')
  [[ ${#vals[@]} -eq 6 ]] || { do_log "FATAL cannot read env.cost from ${files[*]}"; return 1; }
  for i in 0 1 2 3 4 5; do
    [[ -n "${vals[i]}" && "${vals[i]}" != null ]] || { do_log "FATAL env.cost value $((i + 1)) of 6 is empty in ${files[*]}"; return 1; }
  done
  [[ "${vals[0]}" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL env.cost.reread_days must be 1..99, got: ${vals[0]}"; return 1; }
  [[ "${vals[1]}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { do_log "FATAL env.cost.gcp.export_project is no project id: ${vals[1]}"; return 1; }
  [[ "${vals[2]}" =~ ^[A-Za-z0-9_]{1,1024}$ ]] || { do_log "FATAL env.cost.gcp.export_dataset is no dataset id: ${vals[2]}"; return 1; }
  [[ "${vals[3]}" =~ ^[A-Za-z0-9-]{2,40}$ ]] || { do_log "FATAL env.cost.gcp.export_location is no location: ${vals[3]}"; return 1; }
  [[ "${vals[4]}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { do_log "FATAL env.cost.gcp.reader_sa is no SA id: ${vals[4]}"; return 1; }
  [[ "${vals[5]}" =~ ^[a-z0-9-]+%$ ]] || { do_log "FATAL env.cost.gcp.project_like must be <prefix>%, got: ${vals[5]}"; return 1; }
  COST_REREAD_DAYS="${vals[0]}"
  COST_EXPORT_PROJECT="${vals[1]}"
  COST_DATASET="${vals[2]}"
  COST_LOCATION="${vals[3]}"
  COST_READER_SA="${vals[4]}"
  COST_READER_EMAIL="${vals[4]}@${vals[1]}.iam.gserviceaccount.com"
  COST_PROJECT_LIKE="${vals[5]}"
}

#------------------------------------------------------------------------------
# @description One BigQuery REST call (v2 API) with the token in GCP_BQ_TOKEN
# @description (a shell variable of the caller, never exported, never argv).
# @description Prints the response body. Returns 0 on 2xx, 3 on 401/403, 4 on
# @description 404 and 1 on anything else (no answer included).
# @param $1 METHOD (GET, POST, PATCH)
# @param $2 the path under .../bigquery/v2/, e.g. projects/p/datasets/d
# @param $3 (optional) a JSON body file
# @example body=$(do_gcp_bq_api GET "projects/${p}/datasets/${d}"); rc=$?
#------------------------------------------------------------------------------
do_gcp_bq_api() {
  local method="${1:?method}" path="${2:?path}" body="${3:-}" out code
  local -a data=()
  [[ -n "${body}" ]] && data=(-H 'Content-Type: application/json' --data-binary "@${body}")
  out=$(printf 'header = "Authorization: Bearer %s"\n' "${GCP_BQ_TOKEN:?GCP_BQ_TOKEN unset}" |
    curl -sS -K - -X "${method}" "${data[@]}" --max-time 120 -w '\n%{http_code}' \
      "${GCP_BQ_API:-https://bigquery.googleapis.com/bigquery/v2}/${path}" 2>&1) || { printf '%s' "${out}"; return 1; }
  code="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  case "${code}" in
    2??) return 0 ;;
    401 | 403) return 3 ;;
    404) return 4 ;;
    *) return 1 ;;
  esac
}

#------------------------------------------------------------------------------
# @description The first line of a BigQuery error body (.error.message), or the
# @description body's first 200 chars when it is no JSON error.
# @param $1 the response body
#------------------------------------------------------------------------------
do_gcp_bq_error() {
  local m
  m=$(jq -r '.error.message // empty | split("\n")[0]' <<<"${1:-}" 2>/dev/null)
  [[ -n "${m}" ]] || m=$(head -c 200 <<<"${1:-}" | tr '\n' ' ')
  printf '%s' "${m}"
}
