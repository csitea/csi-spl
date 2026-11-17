#!/bin/bash
#------------------------------------------------------------------------------
# @description Import the GCP month totals of the Google Cloud invoice PDFs
# @description into the hub's cost entries (SPL-5802, spec 123 section 15.6;
# @description owner HUM-10, #laskut f655b326, msg 92f3fb10, answer 2 A: the
# @description owner downloads the PDFs, this imports their month totals).
# @description 1. Reads every *.pdf under COST_INVOICE_DIR (sub dirs too, as
# @description    do_gcp_billing_invoices_browser saves pdf/<account id>/) with
# @description    pdftotext, parses each with src/bash/scripts/
# @description    invoice-pdf-month-totals.py: month, billing account (its
# @description    last 4 only, in every output), net (before VAT), currency.
# @description    Writes them to COST_INVOICE_TSV (mode 600, refused inside a
# @description    git work tree: it holds amounts).
# @description 2. COST_INVOICE_CMD=import (default) then reads, as the env's
# @description    project service account (never the owner account), the hub's
# @description    cloud cost entries (GET /v1/operator/cost-entries?type=cloud,
# @description    only period + label are used) and the gcp days of cost_lines
# @description    (a read only transaction, operator RLS scope, counts only),
# @description    and prints one table row per invoice: month, account last 4,
# @description    net, currency, action. Never double counts, the action is:
# @description      create                   no Google Cloud figure for the month yet
# @description      conflict:cost_entry      a cloud entry whose label names Google
# @description                               Cloud or GCP is in that month
# @description      conflict:cost_lines=n/N  the billing export holds n of the
# @description                               month's N days (all or some): skipped
# @description      skip:unparsed:<fields>   a field the PDF did not give
# @description      skip:not-above-0         a net of 0 or less (credits)
# @description      skip:duplicate           a second invoice of that month+account
# @description    and the plan's sha256 (over the table).
# @description 3. DRY_RUN=1 (default) runs each create row through
# @description    do_spl_hub_cost_entries COST_CMD=create DRY_RUN=1 (its checks,
# @description    nothing posted). DRY_RUN=0 needs COST_INVOICE_PLAN_SHA equal to
# @description    the plan shown, so only the table the owner OKed is written,
# @description    then creates each create row through the same path.
# @description The table is the one place amounts are printed; a billing
# @description account id is never printed, a PDF only by its base name.
# @param COST_INVOICE_DIR (required) - the dir holding the invoice PDFs (no default)
# @param ENV (optional) - dev or prd, the hub read and written; needed with COST_INVOICE_CMD=import
# @param COST_INVOICE_CMD (optional) - import (default) or totals (parse and write the TSV only, no cloud call)
# @param COST_INVOICE_TSV (optional) - the month-totals TSV, default <COST_INVOICE_DIR>/month-totals.tsv
# @param COST_INVOICE_PLAN_SHA (optional) - the plan's sha256 from the dry run; needed with DRY_RUN=0
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example COST_INVOICE_DIR=<dir> COST_INVOICE_CMD=totals ./run -a do_spl_hub_cost_invoice_import
# @example ENV=prd COST_INVOICE_DIR=<dir> ./run -a do_spl_hub_cost_invoice_import
# @example ENV=prd COST_INVOICE_DIR=<dir> COST_INVOICE_PLAN_SHA=<sha> DRY_RUN=0 ./run -a do_spl_hub_cost_invoice_import
#------------------------------------------------------------------------------
do_spl_hub_cost_invoice_import() {
  do_require_bin pdftotext python3 jq || return 1
  local cmd="${COST_INVOICE_CMD:-import}" tsv dry=1 n plan sha
  case "$cmd" in import|totals) ;; *) do_log "FATAL COST_INVOICE_CMD must be import or totals, got: '$cmd'"; return 1 ;; esac
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  tsv="$(_scii_tsv_path)" || return 1
  _scii_totals "$COST_INVOICE_DIR" "$tsv" || return 1
  n="$(wc -l <"$tsv")"
  do_log "OK $n invoice PDF(s) read into $(_scii_mask "$tsv") ($(grep -c $'\tok$' "$tsv") parsed in full)"
  [[ "$cmd" == totals ]] && return 0
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd for COST_INVOICE_CMD=import"; return 1; }
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local held days
  held="$(_scii_hub_gcp_periods)" || return 1
  days="$(_scii_gcp_days)" || return 1
  plan="$(_scii_plan "$tsv" "$held" "$days")" || return 1
  sha="$(printf '%s\n' "$plan" | sha256sum | cut -d' ' -f1)"
  _scii_print "$plan" "$sha"
  if (( dry )); then
    _scii_create "$plan" 1 || return 1
    do_log "OK DRY_RUN nothing written. To write the create rows, on the owner's OK of this table: DRY_RUN=0 COST_INVOICE_PLAN_SHA=$sha"
    return 0
  fi
  [[ "${COST_INVOICE_PLAN_SHA:-}" == "$sha" ]] ||
    { do_log "FATAL DRY_RUN=0 needs COST_INVOICE_PLAN_SHA=<the sha of the table the owner OKed>; this plan is $sha: nothing written"; return 1; }
  _scii_create "$plan" 0
}

# _scii_mask <text> -> <text> with each billing account id cut to its last 4
# (a dir named pdf/<account id>/ is how the browser action saves them)
_scii_mask() {
  sed -E 's/[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{2}([0-9A-F]{4})/...\1/g' <<<"$1"
}

# _scii_tsv_path -> COST_INVOICE_TSV (default in the PDF dir); refused inside
# a git work tree, since the file holds amounts
_scii_tsv_path() {
  local dir="${COST_INVOICE_DIR:-}" tsv
  [[ -n "$dir" ]] || { do_log "FATAL COST_INVOICE_DIR must be set (no default)" >&2; return 1; }
  [[ -d "$dir" && -r "$dir" ]] || { do_log "FATAL COST_INVOICE_DIR is not a readable dir: $(_scii_mask "$dir")" >&2; return 1; }
  tsv="${COST_INVOICE_TSV:-$dir/month-totals.tsv}"
  [[ -d "$(dirname "$tsv")" ]] || { do_log "FATAL the dir of COST_INVOICE_TSV does not exist: $(_scii_mask "$tsv")" >&2; return 1; }
  if git -C "$(dirname "$tsv")" rev-parse --is-inside-work-tree &>/dev/null; then
    do_log "FATAL COST_INVOICE_TSV is inside a git work tree (it holds amounts): $(_scii_mask "$tsv")" >&2; return 1
  fi
  echo "$tsv"
}

# _scii_totals <dir> <tsv> -> one parser row per PDF, sorted by month, into
# <tsv> (mode 600); FATAL when the dir holds no PDF or one cannot be read
_scii_totals() {
  local dir="$1" tsv="$2" pdf txt rows="" py="$PROJ_PATH/src/bash/scripts/invoice-pdf-month-totals.py"
  txt="$(mktemp)" || return 1
  while IFS= read -r -d '' pdf; do
    pdftotext -layout -q "$pdf" "$txt" 2>/dev/null ||
      { rm -f "$txt"; do_log "FATAL pdftotext could not read $(basename "$pdf")"; return 1; }
    rows+="$(python3 -I "$py" "$txt" "$pdf")"$'\n' || { rm -f "$txt"; return 1; }
  done < <(find "$dir" -type f -iname '*.pdf' -print0 | sort -z)
  rm -f "$txt"
  [[ -n "$rows" ]] || { do_log "FATAL no *.pdf under COST_INVOICE_DIR $(_scii_mask "$dir")"; return 1; }
  (umask 077 && printf '%s' "$rows" | sort -t $'\t' -k2,2 -k3,3 -k1,1 >"$tsv") || { do_log "FATAL cannot write $(_scii_mask "$tsv")"; return 1; }
  chmod 600 "$tsv"
}

# _scii_hub_gcp_periods -> the periods that hold a cloud entry labelled
# Google Cloud or GCP (the label _scii_create writes, so a re-run finds
# its own rows), one per line; reads only period and label of the
# hub's answer, prints no figure, also not on a refusal
_scii_hub_gcp_periods() {
  spl_hub_operator_call GET '/v1/operator/cost-entries?type=cloud' || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { do_log "FATAL the hub answered $SPL_HUB_OP_STATUS to the cloud cost entries read" >&2; return 1; }
  local p
  p="$(jq -r '.entries | if type == "array" then . else error end | .[]
    | select((.label // "") | test("google|gcp"; "i")) | .period | select(test("^[0-9]{4}-[0-9]{2}$"))' \
    <<<"$SPL_HUB_OP_BODY" 2>/dev/null)" ||
    { do_log "FATAL the hub's answer is not a list of cost entries (it is not printed)" >&2; return 1; }
  [[ -z "$p" ]] || sort -u <<<"$p"
}

# _scii_gcp_days -> "<YYYY-MM><TAB><days>" per month that cost_lines holds
# gcp days of (the billing export), counts only, through the proxy
_scii_gcp_days() {
  do_require_bin yq psql || return 1
  spl_via_proxy _scii_gcp_days_query
}

_scii_gcp_days_query() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -P pager=off -c 'BEGIN TRANSACTION READ ONLY' \
      -c "SET LOCAL app.rls_scope = 'operator'" \
      -c "SELECT to_char(day, 'YYYY-MM'), count(DISTINCT day) FROM cost_lines WHERE source = 'gcp' AND superseded_by IS NULL GROUP BY 1 ORDER BY 1" \
      -c 'ROLLBACK' | grep -E $'^[0-9]{4}-[0-9]{2}\t[0-9]+$'
  local rc=("${PIPESTATUS[@]}")
  (( rc[0] == 0 )) || { do_log "FATAL the cost_lines gcp days read failed (psql exit ${rc[0]})" >&2; return 1; }
  return 0
}

# _scii_plan <tsv> <held periods> <gcp days> -> "month acct net cur action"
# per invoice, tab separated, in the TSV's order (see the header for actions)
_scii_plan() {
  local tsv="$1" held="$2" days="$3" file month acct net cur status action seen=" " have dim
  while IFS=$'\t' read -r file month acct net cur status; do
    [[ -n "$file" ]] || continue
    if [[ "$status" != ok ]]; then action="skip:$status"
    elif ! jq -en --argjson v "$net" '$v > 0' >/dev/null 2>&1; then action=skip:not-above-0
    elif [[ "$seen" == *" $month/$acct "* ]]; then action=skip:duplicate
    elif grep -qxF "$month" <<<"$held"; then action=conflict:cost_entry
    else
      have="$(awk -F'\t' -v m="$month" '$1 == m { print $2 }' <<<"$days")"
      dim="$(date -u -d "$month-01 +1 month -1 day" +%d)" || return 1
      if [[ -n "$have" && "$have" -gt 0 ]]; then action="conflict:cost_lines=$have/$((10#$dim))"; else action=create; fi
    fi
    [[ "$status" == ok ]] && seen+="$month/$acct "
    printf '%s\t%s\t%s\t%s\t%s\n' "$month" "$acct" "$net" "$cur" "$action"
  done <"$tsv"
}

# _scii_print <plan> <sha> -> the DRY_RUN table, the one output with amounts
_scii_print() {
  do_log "OK plan for $ENV, $(grep -c $'\tcreate$' <<<"$1") create row(s), sha256 $2:"
  { printf 'month\taccount\tnet\tcurrency\taction\n'; printf '%s\n' "$1"; } |
    awk -F'\t' '{ printf "  %-8s %-8s %10s %-9s %s\n", $1, $2, $3, $4, $5 }'
}

# _scii_create <plan> <dry 0|1> -> each create row through
# do_spl_hub_cost_entries COST_CMD=create; stops at the first failure
_scii_create() {
  local month acct net cur action n=0
  while IFS=$'\t' read -r month acct net cur action; do
    [[ "$action" == create ]] || continue
    COST_CMD=create COST_TYPE=cloud COST_LABEL="Google Cloud (billing account ending $acct)" COST_AMOUNT="$net" \
      COST_CURRENCY="$cur" COST_PERIOD="$month" COST_NOTE="invoice PDF import, SPL-5802" COST_GROSS="" \
      DRY_RUN="$2" do_spl_hub_cost_entries ||
      { do_log "FATAL the create of $month (account ending $acct) failed after $n created: the rest is not written"; return 1; }
    n=$((n + 1))
  done <<<"$1"
  do_log "OK $n create row(s) $( (( $2 )) && echo checked, none posted || echo created)"
}
