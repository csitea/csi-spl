#!/bin/bash
#------------------------------------------------------------------------------
# @description Fetch what an API gives about every billing account's invoices
# @description of the last 12 months from the day of the call (spec 123
# @description section 15, SPL-5220). Read only.
# @description
# @description Runs as the dedicated billing SA ONLY (cnf env.cost.gcp.billing_sa,
# @description made by terraform step 002-gcp-billing-sa): its key (BILLING_SA_KEY_FILE,
# @description default ~/.gcp/.<org>/key-<org>-<app>-billing.json) is activated in a throwaway
# @description CLOUDSDK_CONFIG, and every gcloud call carries --account. No
# @description human login, never the owner account, never ~/.config/gcloud.
# @description
# @description For each billing account the SA can read, into the out dir
# @description (BILLING_OUT_DIR, default $HOME/.local/share/<org>-<app>/
# @description billing-invoices, mode 700, never in git) under <day of call>/:
# @description   accounts.tsv            id, name, open
# @description   projects-<id>.tsv       the projects it bills
# @description   amounts.tsv             id, invoice month, currency, cost + credits,
# @description                           from the BigQuery billing export (only the
# @description                           accounts the export carries)
# @description   summary.tsv + README.md every account x month, and the PDF checklist:
# @description                           "have" when do_gcp_billing_invoices_browser
# @description                           saved a document dated in month+1, else "todo"
# @description No Google API returns the invoice PDFs (cloudbilling v1/v1beta,
# @description discovery rev 20261106): they come from the console only, by hand
# @description or with do_gcp_billing_invoices_browser.
# @description Billing account ids are logged masked; the token is never logged.
# @param BILLING_MONTHS (optional) - how many months, default 12
# @param BILLING_TODAY (optional) - the day of the call, YYYY-MM-DD, default today (UTC)
# @param BILLING_SA_KEY_FILE (optional) - the billing SA key, default ~/.gcp/.<org>/key-<org>-<app>-billing.json
# @param BILLING_OUT_DIR (optional) - the out root, default under $HOME
# @example ./run -a do_gcp_billing_invoices_fetch
# @example BILLING_MONTHS=3 ./run -a do_gcp_billing_invoices_fetch
#------------------------------------------------------------------------------
do_gcp_billing_invoices_fetch() {
  local today="${BILLING_TODAY:-$(date -u +%F)}" n="${BILLING_MONTHS:-12}" b months out id
  for b in gcloud curl jq yq; do command -v "${b}" &>/dev/null || { do_log "FATAL ${b} is not installed"; return 1; }; done
  months=$(do_gcp_billing_months "${today}" "${n}") || return 1
  do_resolve_oap ORG
  do_resolve_oap APP
  do_gcp_billing_cnf || return 1
  do_spl_cost_gcp_cnf || return 1
  _gbf_pin || return 1
  out="${BILL_OUT_ROOT}/${today}"
  (umask 077 && mkdir -p "${out}" "${BILL_OUT_ROOT}/pdf") || { do_log "FATAL cannot make the out dir ${out}"; return 1; }
  chmod 700 "${BILL_OUT_ROOT}" "${out}"
  do_log "INFO as=${GCP_ACCOUNT} months=$(head -n 1 <<<"${months}")..$(tail -n 1 <<<"${months}") out=${out}"
  _gbf_accounts "${out}" || return 1
  while IFS=$'\t' read -r id _; do
    _gbf_projects "${id}" "${out}"
  done <"${out}/accounts.tsv"
  _gbf_amounts "${months}" "${out}"
  _gbf_summary "${months}" "${out}"
  do_log "OK wrote ${out}: $(wc -l <"${out}/accounts.tsv") account(s), $(grep -c $'\ttodo$' "${out}/summary.tsv") invoice PDF(s) todo (README.md lists them)"
}

# _gbf_pin - the billing SA from its key, in a throwaway CLOUDSDK_CONFIG
# (do_gcp_pin_account isolates the config when it activates a key). Any other
# identity is refused: ACCOUNT / GCP_ACCOUNT are dropped, never inherited.
_gbf_pin() {
  [[ -f "${BILL_KEY}" ]] || {
    do_log "FATAL no billing SA key ${BILL_KEY} (BILLING_SA_KEY_FILE): terraform step 002-gcp-billing-sa writes it on apply, see do_gcp_billing_sa_create"
    return 1
  }
  unset ACCOUNT GCP_ACCOUNT
  export GCP_SA_KEY_FILE="${BILL_KEY}" PROJ_ID="${BILL_PROJECT}"
  do_gcp_pin_account || return 1
  [[ "${GCP_ACCOUNT}" == "${BILL_EMAIL}" ]] && return 0
  do_log "FATAL the key is not the billing SA ${BILL_EMAIL} but ${GCP_ACCOUNT}: refused, nothing read"
  return 1
}

_gbf_accounts() {
  local out="$1" json
  json=$(gcloud billing accounts list --account="${GCP_ACCOUNT}" --format=json 2>/dev/null) \
    || { do_log "FATAL cannot list the billing accounts as ${GCP_ACCOUNT} (Cloud Billing API on in ${BILL_PROJECT}?)"; return 1; }
  # written only when it holds an account: the browser action reads the newest one
  jq -r '.[] | [(.name | sub("^billingAccounts/"; "")), (.displayName // ""), (.open // false)] | @tsv' <<<"${json}" >"${out}/accounts.tsv.tmp"
  [[ -s "${out}/accounts.tsv.tmp" ]] && { mv "${out}/accounts.tsv.tmp" "${out}/accounts.tsv"; return 0; }
  rm -f "${out}/accounts.tsv.tmp"
  do_log "FATAL ${GCP_ACCOUNT} holds no role on any billing account: the owner grants roles/billing.viewer on each (do_gcp_billing_sa_create prints the commands)"
  return 1
}

_gbf_projects() {
  local id="$1" out="$2"
  if gcloud billing projects list --billing-account="${id}" --account="${GCP_ACCOUNT}" \
      --format='value(projectId,billingEnabled)' >"${out}/projects-${id}.tsv" 2>/dev/null; then
    do_log "OK $(do_gcp_billing_mask "${id}") bills $(wc -l <"${out}/projects-${id}.tsv") project(s)"
  else
    do_log "WARNING cannot list the projects of $(do_gcp_billing_mask "${id}") as ${GCP_ACCOUNT}: REPORT it"
  fi
}

# _gbf_amounts - one BigQuery query over the export (cost + credits per
# account and invoice month), its job in BILL_PROJECT. Unreadable: a WARNING,
# the checklist is still written.
_gbf_amounts() {
  local months="$1" out="$2" GCP_BQ_TOKEN body res rc
  : >"${out}/amounts.tsv"
  GCP_BQ_TOKEN=$(gcloud auth print-access-token --account="${GCP_ACCOUNT}" 2>/dev/null)
  [[ -n "${GCP_BQ_TOKEN}" ]] || { do_log "WARNING no access token for ${GCP_ACCOUNT}: amounts NOT read"; return 0; }
  body=$(umask 077 && mktemp) || return 0
  jq -n --arg t "${COST_SOURCE_PROJECT}.${COST_SOURCE_DATASET}.gcp_billing_export_v1_*" --arg l "${COST_LOCATION}" \
    --arg f "$(head -n 1 <<<"${months}")" --arg u "$(tail -n 1 <<<"${months}")" '{
    useLegacySql: false, location: $l, timeoutMs: 60000, parameterMode: "NAMED",
    query: ("SELECT billing_account_id, invoice.month, currency, ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) "
      + "FROM `" + $t + "` WHERE invoice.month BETWEEN @f AND @u GROUP BY 1, 2, 3 ORDER BY 1, 2"),
    queryParameters: [
      {name: "f", parameterType: {type: "STRING"}, parameterValue: {value: $f}},
      {name: "u", parameterType: {type: "STRING"}, parameterValue: {value: $u}}]}' >"${body}"
  res=$(do_gcp_bq_api POST "projects/${BILL_PROJECT}/queries" "${body}"); rc=$?
  rm -f "${body}"
  if [[ ${rc} -ne 0 ]] || ! jq -e '.jobComplete == true' <<<"${res}" >/dev/null 2>&1; then
    do_log "WARNING amounts NOT read from ${COST_SOURCE_PROJECT}.${COST_SOURCE_DATASET} ($(do_gcp_bq_error "${res}")): the owner grants the billing SA BigQuery Data Viewer there"
    return 0
  fi
  jq -r '.rows[]? | [.f[].v] | @tsv' <<<"${res}" >"${out}/amounts.tsv"
  do_log "OK $(wc -l <"${out}/amounts.tsv") account-month amount(s) from the billing export"
}

# _gbf_summary - every account x month: amount (or -) and the PDF state.
_gbf_summary() {
  local months="$1" out="$2" id name m next cur amt pdf
  # n and today: the caller's locals (do_gcp_billing_invoices_fetch)
  printf 'account\tname\tmonth\tcurrency\tamount\tpdf\n' >"${out}/summary.tsv"
  {
    echo "# Billing invoices, ${n} months to ${today}"
    echo
    echo "PDFs: no API returns them. Download each \"todo\" in the console (Billing > Documents), or run do_gcp_billing_invoices_browser at your desk."
  } >"${out}/README.md"
  while IFS=$'\t' read -r id name _; do
    printf '\n## %s (%s)\n\nhttps://console.cloud.google.com/billing/%s/documents\n\n' "${name}" "${id}" "${id}" >>"${out}/README.md"
    for m in ${months}; do
      next=$(_gbf_next_month "${m}")
      IFS=$'\t' read -r cur amt < <(awk -F'\t' -v a="${id}" -v m="${m}" '$1 == a && $2 == m { print $3 "\t" $4 }' "${out}/amounts.tsv")
      pdf=todo
      compgen -G "${BILL_OUT_ROOT}/pdf/${id}/${next:0:4}-${next:4:2}-*.pdf" >/dev/null && pdf=have
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${m}" "${cur:--}" "${amt:--}" "${pdf}" >>"${out}/summary.tsv"
      printf -- '- [%s] %s-%s %s %s\n' "$([[ ${pdf} == have ]] && echo x || echo ' ')" "${m:0:4}" "${m:4:2}" "${amt:--}" "${cur:-}" >>"${out}/README.md"
    done
  done <"${out}/accounts.tsv"
}

# _gbf_next_month YYYYMM - the month after it, YYYYMM.
_gbf_next_month() {
  local y=$((10#${1:0:4})) m=$((10#${1:4:2}))
  if ((m == 12)); then printf '%04d01' $((y + 1)); else printf '%04d%02d' "${y}" $((m + 1)); fi
}
