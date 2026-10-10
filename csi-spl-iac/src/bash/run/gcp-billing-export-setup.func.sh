#!/bin/bash
#------------------------------------------------------------------------------
# @description Prepare the GCP billing export to BigQuery and its reader
# @description (spec 123 section 4.2, build lane 2; spec 122 section 9 reuses it).
# @description A DRY RUN unless DRY_RUN=0, and DRY_RUN=0 is the OWNER's (spec 123
# @description Q-3, by 2026-10-25): the dry run reads, and prints every call it
# @description would make; it mutates nothing. Idempotent: what exists is kept.
# @description
# @description In cnf env.cost.gcp.export_project (csi-spl-all), as that
# @description project's SA from its key (do_gcp_pin_account), never the owner:
# @description   1. enable bigquery, bigquerydatatransfer and iamcredentials;
# @description   2. the export dataset (env.cost.gcp.export_dataset, multi-region
# @description      export_location so the export backfills);
# @description   3. the dedicated reader SA (env.cost.gcp.reader_sa, Q-2 = A);
# @description   4. roles/bigquery.dataViewer for it on THAT dataset only, and
# @description      roles/bigquery.jobUser on the project: a query is a job, and
# @description      jobUser lets it run one without reading any table;
# @description   5. roles/iam.serviceAccountTokenCreator on the reader SA for the
# @description      dev and prd project SAs: do_spl_estate_cost_read acts AS the
# @description      reader (impersonation) when no reader key is on disk, so no
# @description      new key is minted (a key needs the org policy lift of gcp-002).
# @description   6. The billing export itself: the Cloud Billing API cannot turn it
# @description      on, only the console can. The action checks for the
# @description      gcp_billing_export_v1_* table and, while it is absent, prints
# @description      the console step for the owner (billing account admin).
# @description GCP_BILLING_ACCOUNT_ID is never committed and is logged masked.
# @description Unset, it is read as the pinned SA from the billing link of the
# @description export project; an unreadable link stops the run before any step.
# @param GCP_BILLING_ACCOUNT_ID (optional) - the billing account (XXXXXX-XXXXXX-XXXXXX);
# @param   unset: the account that bills env.cost.gcp.export_project
# @param DRY_RUN (optional) - 1 (default): read and report. 0: mutate (the owner's).
# @example ./run -a do_gcp_billing_export_setup
# @example GCP_BILLING_ACCOUNT_ID=<id> ./run -a do_gcp_billing_export_setup
# @example GCP_BILLING_ACCOUNT_ID=<id> DRY_RUN=0 ./run -a do_gcp_billing_export_setup
#------------------------------------------------------------------------------
do_gcp_billing_export_setup() {
  local bill="${GCP_BILLING_ACCOUNT_ID:-}"
  [[ -z "${bill}" || "${bill}" =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ ]] || { do_log "FATAL GCP_BILLING_ACCOUNT_ID is no billing account id (XXXXXX-XXXXXX-XXXXXX)"; return 1; }
  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  local b
  for b in gcloud curl jq yq; do command -v "${b}" &>/dev/null || { do_log "FATAL ${b} is not installed"; return 1; }; done

  do_resolve_oap ORG
  do_resolve_oap APP
  do_spl_cost_gcp_cnf || return 1
  export PROJ_ID="${COST_EXPORT_PROJECT}"
  do_gcp_pin_account || return 1
  do_gcp_require_live_account "${GCP_ACCOUNT}" || { do_log "FATAL ${GCP_ACCOUNT} cannot mint a token"; return 1; }
  [[ "${GCP_ACCOUNT}" == *.gserviceaccount.com ]] || { do_log "FATAL ${GCP_ACCOUNT} is no service account: the owner account is the gcp-000..004 bootstrap's only"; return 1; }
  local resolved=""
  [[ -n "${bill}" ]] || { bill=$(_bes_billing_resolve) || return 1; resolved=1; }

  _BES_DRY="${dry_run}" _BES_FAILED=""
  _BES_TMP=$(umask 077 && mktemp -d) || return 1
  do_log "INFO project=${COST_EXPORT_PROJECT} dataset=${COST_DATASET} (${COST_LOCATION}) reader=${COST_READER_EMAIL} as=${GCP_ACCOUNT} billing=XXXXXX-XXXXXX-${bill: -6} DRY_RUN=${dry_run}"

  local GCP_BQ_TOKEN
  GCP_BQ_TOKEN=$(gcloud auth print-access-token --account="${GCP_ACCOUNT}" 2>/dev/null)
  [[ -n "${GCP_BQ_TOKEN}" ]] || { rm -rf "${_BES_TMP}"; do_log "FATAL no access token for ${GCP_ACCOUNT}"; return 1; }

  if [[ -n "${resolved}" ]]; then
    do_log "OK ${COST_EXPORT_PROJECT} is billed by XXXXXX-XXXXXX-${bill: -6} (GCP_BILLING_ACCOUNT_ID unset: read from its billing link)"
  else
    _bes_billing_link "${bill}"
  fi
  _bes_apis && _bes_dataset && _bes_reader_sa && _bes_dataset_viewer && _bes_job_user && _bes_token_creators \
    || _BES_FAILED="${_BES_FAILED:-finish the setup: a step stopped without a reason}"
  _bes_export_table
  rm -rf "${_BES_TMP}"

  [[ -z "${_BES_FAILED}" ]] || { do_log "FATAL Failed to ${_BES_FAILED}"; return 1; }
  if [[ "${dry_run}" == 1 ]]; then
    do_log "OK DRY_RUN complete: nothing was changed. The owner runs it with DRY_RUN=0 (spec 123 Q-3)."
  else
    do_log "OK the export dataset and its reader ${COST_READER_EMAIL} are ready"
  fi
}

# _bes_run <what> <cmd> [args...] - the one mutation gate: DRY_RUN=1 logs <what>
# and runs nothing; DRY_RUN=0 runs <cmd> and records a failure in _BES_FAILED.
_bes_run() {
  local what="$1"; shift
  if [[ "${_BES_DRY}" == 1 ]]; then do_log "INFO DRY_RUN would run: ${what}"; return 0; fi
  do_log "INFO run: ${what}"
  "$@" >/dev/null 2>"${_BES_TMP}/err" && return 0
  _BES_FAILED="${what} ($(tail -n 2 "${_BES_TMP}/err" | tr '\n' ' '))"
  return 1
}

# _bes_billing_resolve - read only: print the id of the account that bills the
# export project, read as the pinned SA. Unreadable or malformed -> FATAL, rc 1:
# the id is never guessed, and never read as another identity.
_bes_billing_resolve() {
  local got
  got=$(gcloud billing projects describe "${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" --format='value(billingAccountName)' 2>/dev/null)
  got="${got#billingAccounts/}"
  [[ "${got}" =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ ]] && { printf '%s' "${got}"; return 0; }
  do_log "FATAL GCP_BILLING_ACCOUNT_ID is unset and the billing link of ${COST_EXPORT_PROJECT} cannot be read as ${GCP_ACCOUNT} (permission billing.resourceAssociations.list? REPORT it): set GCP_BILLING_ACCOUNT_ID. Nothing was changed" >&2
  return 1
}

# _bes_billing_link <bill> - read only: is the export project billed by that
# account? A mismatch or an unreadable link is a WARNING (the SA may lack
# billing.resourceAssociations.list), never a stop.
_bes_billing_link() {
  local got
  got=$(gcloud billing projects describe "${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" --format='value(billingAccountName)' 2>/dev/null)
  if [[ -z "${got}" ]]; then
    do_log "WARNING cannot read the billing link of ${COST_EXPORT_PROJECT} as ${GCP_ACCOUNT} (permission?): REPORT it, check it in the console"
  elif [[ "${got}" != "billingAccounts/$1" ]]; then
    do_log "WARNING ${COST_EXPORT_PROJECT} is billed by XXXXXX-XXXXXX-${got: -6}, not by GCP_BILLING_ACCOUNT_ID: the export must be on the account that pays for ${COST_PROJECT_LIKE}"
  else
    do_log "OK ${COST_EXPORT_PROJECT} is billed by GCP_BILLING_ACCOUNT_ID"
  fi
}

_bes_apis() {
  local on api missing=()
  on=$(gcloud services list --enabled --project="${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" --format='value(config.name)' 2>"${_BES_TMP}/err") \
    || { _BES_FAILED="list the enabled APIs of ${COST_EXPORT_PROJECT} ($(tail -n 1 "${_BES_TMP}/err"))"; return 1; }
  for api in bigquery.googleapis.com bigquerydatatransfer.googleapis.com iamcredentials.googleapis.com; do
    grep -qx "${api}" <<<"${on}" || missing+=("${api}")
  done
  (( ${#missing[@]} )) || { do_log "OK the APIs are on"; return 0; }
  _bes_run "gcloud services enable ${missing[*]} --project=${COST_EXPORT_PROJECT} --account=${GCP_ACCOUNT}" \
    gcloud services enable "${missing[@]}" --project="${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}"
}

# _bes_dataset - three-way, as gcp-001: exists / reported absent / cannot tell.
_bes_dataset() {
  local out rc path="projects/${COST_EXPORT_PROJECT}/datasets/${COST_DATASET}"
  out=$(do_gcp_bq_api GET "${path}"); rc=$?
  case "${rc}" in
    0) printf '%s' "${out}" >"${_BES_TMP}/dataset.json"; do_log "OK dataset ${COST_EXPORT_PROJECT}.${COST_DATASET} exists"; return 0 ;;
    4) ;;
    *) _BES_FAILED="tell whether ${COST_EXPORT_PROJECT}.${COST_DATASET} exists ($(do_gcp_bq_error "${out}"))"; return 1 ;;
  esac
  jq -n --arg p "${COST_EXPORT_PROJECT}" --arg d "${COST_DATASET}" --arg l "${COST_LOCATION}" \
    '{datasetReference: {projectId: $p, datasetId: $d}, location: $l,
      description: "GCP billing export (spec 123); read by the cost reader SA only"}' >"${_BES_TMP}/ds-new.json"
  _bes_run "BigQuery datasets.insert ${COST_EXPORT_PROJECT}.${COST_DATASET} location=${COST_LOCATION}" \
    do_gcp_bq_api POST "projects/${COST_EXPORT_PROJECT}/datasets" "${_BES_TMP}/ds-new.json" || return 1
  [[ "${_BES_DRY}" == 1 ]] && return 0
  # the access patch below REPLACES the list: it is built only on a read that worked
  do_gcp_bq_api GET "${path}" >"${_BES_TMP}/dataset.json" \
    || { rm -f "${_BES_TMP}/dataset.json"; _BES_FAILED="read back ${COST_EXPORT_PROJECT}.${COST_DATASET} after creating it"; return 1; }
}

_bes_reader_sa() {
  local out rc
  out=$(gcloud iam service-accounts describe "${COST_READER_EMAIL}" --project="${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" --format='value(email)' 2>&1); rc=$?
  if [[ ${rc} -eq 0 ]]; then do_log "OK reader SA ${COST_READER_EMAIL} exists"; _BES_SA=1; return 0; fi
  grep -qiE 'not[ _]found|does not exist|unknown service account|404' <<<"${out}" || { _BES_FAILED="tell whether ${COST_READER_EMAIL} exists (${out})"; return 1; }
  _BES_SA=0
  _bes_run "gcloud iam service-accounts create ${COST_READER_SA} --project=${COST_EXPORT_PROJECT} --account=${GCP_ACCOUNT}" \
    gcloud iam service-accounts create "${COST_READER_SA}" --display-name="${COST_READER_SA}" \
      --description="Reads the billing export dataset ${COST_DATASET} only (spec 123 Q-2)." \
      --project="${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}"
}

# _bes_dataset_viewer - dataViewer on the export dataset ONLY (a dataset access
# entry), never a project-level data role.
_bes_dataset_viewer() {
  if [[ -s "${_BES_TMP}/dataset.json" ]] && jq -e --arg m "${COST_READER_EMAIL}" \
      '[.access[]? | select(.userByEmail == $m and (.role == "roles/bigquery.dataViewer" or .role == "READER"))] | length > 0' \
      "${_BES_TMP}/dataset.json" >/dev/null; then
    do_log "OK ${COST_READER_EMAIL} reads ${COST_DATASET}"; return 0
  fi
  if [[ "${_BES_DRY}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: BigQuery datasets.patch ${COST_EXPORT_PROJECT}.${COST_DATASET} access += {role: roles/bigquery.dataViewer, userByEmail: ${COST_READER_EMAIL}}"
    return 0
  fi
  [[ -s "${_BES_TMP}/dataset.json" ]] || { _BES_FAILED="read the access list of ${COST_DATASET} before patching it"; return 1; }
  jq --arg m "${COST_READER_EMAIL}" '{access: ((.access // []) + [{role: "roles/bigquery.dataViewer", userByEmail: $m}]), etag: .etag}' \
    "${_BES_TMP}/dataset.json" >"${_BES_TMP}/ds-access.json"
  _bes_run "BigQuery datasets.patch ${COST_EXPORT_PROJECT}.${COST_DATASET} access += dataViewer ${COST_READER_EMAIL}" \
    do_gcp_bq_api PATCH "projects/${COST_EXPORT_PROJECT}/datasets/${COST_DATASET}" "${_BES_TMP}/ds-access.json"
}

_bes_job_user() {
  local member="serviceAccount:${COST_READER_EMAIL}" role="roles/bigquery.jobUser"
  if gcloud projects get-iam-policy "${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" --format=json 2>/dev/null |
      jq -e --arg r "${role}" --arg m "${member}" '[.bindings[]? | select(.role == $r and (.members | index($m)))] | length > 0' >/dev/null; then
    do_log "OK ${COST_READER_EMAIL} may run query jobs in ${COST_EXPORT_PROJECT}"; return 0
  fi
  _bes_run "gcloud projects add-iam-policy-binding ${COST_EXPORT_PROJECT} --member=${member} --role=${role} --condition=None --account=${GCP_ACCOUNT}" \
    gcloud projects add-iam-policy-binding "${COST_EXPORT_PROJECT}" --member="${member}" --role="${role}" --condition=None --account="${GCP_ACCOUNT}"
}

# _bes_token_creators - the dev and prd project SAs (the gcp-002 names) may act
# as the reader. Read only when the SA already exists; a new one has no policy.
_bes_token_creators() {
  local env sa policy='{}' role="roles/iam.serviceAccountTokenCreator"
  [[ "${_BES_SA:-0}" == 1 ]] && policy=$(gcloud iam service-accounts get-iam-policy "${COST_READER_EMAIL}" \
    --project="${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" --format=json 2>/dev/null)
  [[ -n "${policy}" ]] || policy='{}'
  for env in dev prd; do
    sa="${ORG}-${APP}-${env}@${ORG}-${APP}-${env}.iam.gserviceaccount.com"
    if jq -e --arg r "${role}" --arg m "serviceAccount:${sa}" '[.bindings[]? | select(.role == $r and (.members | index($m)))] | length > 0' \
        <<<"${policy}" >/dev/null 2>&1; then
      do_log "OK ${sa} may act as ${COST_READER_EMAIL}"; continue
    fi
    _bes_run "gcloud iam service-accounts add-iam-policy-binding ${COST_READER_EMAIL} --member=serviceAccount:${sa} --role=${role} --project=${COST_EXPORT_PROJECT} --account=${GCP_ACCOUNT}" \
      gcloud iam service-accounts add-iam-policy-binding "${COST_READER_EMAIL}" --member="serviceAccount:${sa}" \
        --role="${role}" --project="${COST_EXPORT_PROJECT}" --account="${GCP_ACCOUNT}" || return 1
  done
}

# _bes_export_table - read only. The export is on when the dataset holds a
# gcp_billing_export_v1_<account> table; until then, the console step.
_bes_export_table() {
  local out rc
  out=$(do_gcp_bq_api GET "projects/${COST_EXPORT_PROJECT}/datasets/${COST_DATASET}/tables?maxResults=1000"); rc=$?
  if [[ ${rc} -eq 0 ]] && jq -e '[.tables[]?.tableReference.tableId | select(startswith("gcp_billing_export_v1_"))] | length > 0' <<<"${out}" >/dev/null; then
    do_log "OK the billing export is on: $(jq -r '[.tables[]?.tableReference.tableId | select(startswith("gcp_billing_export_v1_"))][0]' <<<"${out}" | sed -E 's/[0-9A-F]{6}_[0-9A-F]{6}_/XXXXXX_XXXXXX_/')"
    return 0
  fi
  do_log "INFO the billing export is NOT on yet. The API cannot turn it on; the owner (billing account admin) does, once, in the console:"
  do_log "INFO   https://console.cloud.google.com/billing/<GCP_BILLING_ACCOUNT_ID>/export -> BigQuery export -> Standard usage cost -> EDIT SETTINGS"
  do_log "INFO   project ${COST_EXPORT_PROJECT}, dataset ${COST_DATASET} -> SAVE. The table gcp_billing_export_v1_<account> appears within hours."
}
