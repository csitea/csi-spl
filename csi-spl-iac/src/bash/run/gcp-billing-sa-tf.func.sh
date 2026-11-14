#!/bin/bash
#------------------------------------------------------------------------------
# @description Plan or apply terraform step 002-gcp-billing-sa (spec 123
# @description section 15.2) with the billing account ids it grants
# @description spl-billing roles/billing.viewer + roles/billing.user on
# @description (SPL-5506; owner HUM-10, #laskut f655b326, msg a508c121: "I grant
# @description csi-spl-all Billing Admin once; Terraform does the rest").
# @description The ids are GCP_BILLING_ACCOUNT_IDS when set, else every billing
# @description account the csi-spl-all SA sees (`gcloud billing accounts list`
# @description as that SA from its key, do_gcp_pin_account, never the owner):
# @description the ones the owner gave it Billing Account Administrator on. No
# @description id at all stops it before make. The ids are never printed,
# @description logged or written to a file: they reach terraform only through
# @description the environment of the one make run (TF_VAR_billing_account_ids),
# @description and that run's output is masked. Terraform runs only through
# @description make / tf-runner (csi-spl-orc), ENV=prd (the step is prd only).
# @param TF_VERB (optional) - plan (default) or provision (apply, the owner's go)
# @param GCP_BILLING_ACCOUNT_IDS (optional) - comma separated ids; default: listed as the csi-spl-all SA
# @example ./run -a do_gcp_billing_sa_tf
# @example TF_VERB=provision ./run -a do_gcp_billing_sa_tf
#------------------------------------------------------------------------------
do_gcp_billing_sa_tf() {
  local verb="${TF_VERB:-plan}" target ids id rc mask=XXXXXX-XXXXXX-XXXXXX rx='^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$'
  case "${verb}" in
    plan) target=do-tf-plan ;;
    provision) target=do-provision ;;
    *) do_log "FATAL TF_VERB must be plan or provision, got: ${verb}"; return 1 ;;
  esac
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  do_resolve_oap ORG
  do_resolve_oap APP
  do_gcp_billing_cnf || return 1
  export ENV=prd PROJ_ID="${BILL_PROJECT}"
  unset ACCOUNT GCP_ACCOUNT
  do_gcp_pin_account || return 1

  ids="${GCP_BILLING_ACCOUNT_IDS:-}"
  if [[ -z "${ids}" ]]; then
    ids=$(gcloud billing accounts list --account="${GCP_ACCOUNT}" --format='value(name)' 2>/dev/null | sed 's#^billingAccounts/##' | paste -sd, -)
  fi
  ids="${ids// /}"
  [[ -n "${ids}" ]] || {
    do_log "FATAL no billing account: GCP_BILLING_ACCOUNT_IDS is unset and ${GCP_ACCOUNT} sees none (the owner's one grant, Billing Account Administrator for it on each account, is not made yet?). Nothing ran"
    return 1
  }
  local list=()
  IFS=, read -ra list <<<"${ids}"
  for id in "${list[@]}"; do
    [[ "${id}" =~ ${rx} ]] || { do_log "FATAL a billing account id is not XXXXXX-XXXXXX-XXXXXX (not printed). Nothing ran"; return 1; }
  done
  do_log "INFO ${#list[@]} billing account(s) for ${BILL_EMAIL} as ${GCP_ACCOUNT} (never printed); running make ${target} ENV=prd STEP=002-gcp-billing-sa"

  GCP_BILLING_ACCOUNT_IDS="${ids}" make -C "${APP_PATH}/csi-spl-orc" "${target}" ENV=prd STEP=002-gcp-billing-sa 2>&1 \
    | while IFS= read -r line; do
        for id in "${list[@]}"; do line="${line//${id}/${mask}}"; done
        printf '%s\n' "${line}"
      done
  rc=${PIPESTATUS[0]}
  ids="" list=()
  return "${rc}"
}
