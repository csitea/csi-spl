#!/bin/bash
#------------------------------------------------------------------------------
# @description The pieces the three billing-account actions share (spec 123
# @description section 15, SPL-5220): do_gcp_billing_sa_create,
# @description do_gcp_billing_invoices_fetch and do_gcp_billing_invoices_browser.
# @description
# @description Sets, from cnf env.cost.gcp (all.env.yaml):
# @description   BILL_PROJECT  export_project, the billing SA's home (csi-spl-all)
# @description   BILL_SA       billing_sa, its id (spl-billing)
# @description   BILL_EMAIL    <billing_sa>@<export_project>.iam.gserviceaccount.com
# @description and, from env with $HOME defaults (no literal user or host):
# @description   BILL_KEY      BILLING_SA_KEY_FILE, default the per-env key
# @description                 pattern $HOME/.gcp/.<org>/key-<org>-<app>-billing.json
# @description                 (minted out of band by the owner, never terraform,
# @description                 never git)
# @description   BILL_OUT_ROOT BILLING_OUT_DIR, default
# @description                 $HOME/.local/share/<org>-<app>/billing-invoices
# @description Needs ORG and APP (do_resolve_oap). Never logs a key or a token.
# @param $1 (optional) the cnf dir, default $APP_PATH/<org>-<app>-cnf/<org>-<app>
# @example do_gcp_billing_cnf || return 1
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # the BILL_* globals are read by the three actions
do_gcp_billing_cnf() {
  local cnf="${1:-${APP_PATH:-}/${ORG:-}-${APP:-}-cnf/${ORG:-}-${APP:-}}" vals=()
  [[ -n "${ORG:-}" && -n "${APP:-}" ]] || { do_log "FATAL ORG and APP must be set (do_resolve_oap)"; return 1; }
  [[ -f "${cnf}/all.env.yaml" ]] || { do_log "FATAL no ${cnf}/all.env.yaml"; return 1; }
  mapfile -t vals < <(yq -r '[.env.cost.gcp.export_project, .env.cost.gcp.billing_sa] | .[] | (. // "")' "${cnf}/all.env.yaml")
  [[ "${vals[0]:-}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { do_log "FATAL env.cost.gcp.export_project is no project id: ${vals[0]:-}"; return 1; }
  [[ "${vals[1]:-}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { do_log "FATAL env.cost.gcp.billing_sa is no SA id: ${vals[1]:-}"; return 1; }
  BILL_PROJECT="${vals[0]}"
  BILL_SA="${vals[1]}"
  BILL_EMAIL="${BILL_SA}@${BILL_PROJECT}.iam.gserviceaccount.com"
  BILL_KEY="${BILLING_SA_KEY_FILE:-${HOME:?HOME unset}/.gcp/.${ORG}/key-${ORG}-${APP}-billing.json}"
  BILL_OUT_ROOT="${BILLING_OUT_DIR:-${HOME:?HOME unset}/.local/share/${ORG}-${APP}/billing-invoices}"
}

#------------------------------------------------------------------------------
# @description Print the invoice months (YYYYMM, oldest first) of the last
# @description <n> months from the day of the call: the <n> whole months before
# @description the current one. An invoice for month M is issued on the 1st of
# @description M+1, so for 2026-11-10 and n=12 it prints 202511..202610: every
# @description invoice issued between 2025-11-10 and 2026-11-10.
# @param $1 the day of the call, YYYY-MM-DD
# @param $2 n, 1..36
# @example do_gcp_billing_months 2026-11-10 12
#------------------------------------------------------------------------------
do_gcp_billing_months() {
  local today="${1:?today}" n="${2:?n}" y m i
  [[ "${n}" =~ ^[1-9][0-9]?$ ]] && ((n <= 36)) || { do_log "FATAL the month count must be 1..36, got: ${n}" >&2; return 1; }
  [[ "${today}" =~ ^([0-9]{4})-([0-9]{2})-[0-9]{2}$ ]] || { do_log "FATAL the day must be YYYY-MM-DD, got: ${today}" >&2; return 1; }
  y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  ((m >= 1 && m <= 12)) || { do_log "FATAL the day must be YYYY-MM-DD, got: ${today}" >&2; return 1; }
  # the first month: n months before the current one
  i=$((y * 12 + m - 1 - n)) y=$((i / 12)) m=$((i % 12 + 1))
  for ((i = 0; i < n; i++)); do
    printf '%04d%02d\n' "${y}" "${m}"
    if ((m == 12)); then m=1 y=$((y + 1)); else m=$((m + 1)); fi
  done
}

#------------------------------------------------------------------------------
# @description Print a billing account id masked to its last block
# @description (XXXXXX-XXXXXX-<last 6>): ids go into the log masked only.
# @param $1 the id
#------------------------------------------------------------------------------
do_gcp_billing_mask() {
  printf 'XXXXXX-XXXXXX-%s' "${1: -6}"
}
