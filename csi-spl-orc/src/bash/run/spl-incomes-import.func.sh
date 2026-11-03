#!/bin/bash
#------------------------------------------------------------------------------
# @description Imports a workspace's income invoices into the ENV hub for
# @description Reporting -> Incomes (SPL-4697, rdb 0256, spec 143 incomes.md):
# @description reads INCOMES_FILE, a TSV kept OUTSIDE git (one header line
# @description naming invoice_no payer period issue_date due_date hours
# @description unit_price net vat_pct vat total currency), checks every row
# @description with the table's rules (incomes-tsv-to-json.py) and sends the
# @description batch to PUT /v1/operator/incomes as the env's project service
# @description account: an upsert by invoice number, all rows or none, so a
# @description second run changes nothing. A wrong row is fixed at the source
# @description and imported again. Never prints a figure: the log names the
# @description row count, the period span and the hub's counts only. The batch
# @description never rides argv: curl reads it from the 0700 temp dir
# @description (--data @file), so ps and /proc/<pid>/cmdline show no row.
# @description DRY_RUN=1 (default): check and summarise, send nothing.
# @param ENV - required: dev or prd, the hub written
# @param INCOMES_TENANT - required: the workspace id the rows belong to
# @param INCOMES_FILE - required: the TSV path
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev INCOMES_TENANT=<tenant> INCOMES_FILE=<tsv> ./run -a do_spl_incomes_import
#------------------------------------------------------------------------------
do_spl_incomes_import() {
  do_require_bin jq python3 || return 1
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" tenant="${INCOMES_TENANT:-}" file="${INCOMES_FILE:-}" tmp rc=0
  local py="$PROJ_PATH/src/bash/scripts/incomes-tsv-to-json.py"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$tenant" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]] || { do_log "FATAL INCOMES_TENANT must be a workspace id, got: '$tenant'"; return 1; }
  [[ -f "$file" && -r "$file" ]] || { do_log "FATAL INCOMES_FILE must be a readable TSV, got: '$file'"; return 1; }
  tmp="$(umask 077 && mktemp -d)" || return 1
  if ! python3 -I "$py" "$tenant" "$file" >"$tmp/body.json" 2>"$tmp/summary"; then
    do_log "FATAL $(tail -1 "$tmp/summary")"
    rm -rf "$tmp"
    return 1
  fi
  do_log "INFO $tenant: $(tail -1 "$tmp/summary")"
  if [[ "$dry" == 1 ]]; then
    do_log "OK dry run: nothing sent; DRY_RUN=0 imports it into the $ENV hub"
    rm -rf "$tmp"
    return 0
  fi
  if spl_cost_hub_login && spl_hub_operator_call PUT /v1/operator/incomes "@$tmp/body.json"; then
    if [[ "$SPL_HUB_OP_STATUS" == 200 ]]; then
      do_log "OK the $ENV hub took them: $(jq -r '"\(.inserted) new, \(.updated) replaced"' <<<"$SPL_HUB_OP_BODY")"
    else
      do_log "FATAL the $ENV hub refused the import (http $SPL_HUB_OP_STATUS): $(jq -r '[.error, .detail, (.index | tostring?)] | map(select(. != null)) | join(" ")' <<<"$SPL_HUB_OP_BODY" 2>/dev/null | cut -c 1-300)"
      rc=1
    fi
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}
