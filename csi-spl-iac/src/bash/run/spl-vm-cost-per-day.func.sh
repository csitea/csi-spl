#!/bin/bash
#------------------------------------------------------------------------------
# @description The cost per day of one private workspace's VM: compute, disk and
# @description traffic, from the GCP billing export by the VM's `workspace`
# @description label (spec 181 row B4, gap G5; owner Q-8 A: the VM only).
# @description Read-only on GCP, nothing written anywhere: it runs spec 123's
# @description export read (do_spl_estate_cost_read's file: the cnf, the export
# @description table by prefix, the reader SA identity, the query) with its row
# @description query swapped for one that keeps the `workspace` label and the SKU.
# @description
# @description A line counts only when its `workspace` label is WORKSPACE: a
# @description line labelled for another workspace, or with no such label, is
# @description never counted. A line's part is its service and SKU: egress,
# @description ingress, network or an IP charge = traffic; a persistent disk,
# @description snapshot, image or storage = disk; anything else (cores, RAM,
# @description licences) = compute. Credits are netted. No token line exists
# @description here: spec 181 Q-10, we never resell tokens.
# @description
# @description The window is the trailing env.cost.reread_days days ending DAY
# @description (the export lags and revises recent days). One TSV row per day
# @description and `box` label, in eur_micros (EUR is the one currency read, as
# @description spec 123), state:
# @description   - ok: the export covers the day; partial: a line held back
# @description     (billed in another currency) or the export's newest day;
# @description   - none: the export covers the day and carries no line of this
# @description     workspace (0, box "-");
# @description   - missing: the export is absent or has not reached the day;
# @description     never 0, the amounts are empty.
# @param ENV (required) - dev or prd, the env whose project SA acts as the reader
# @param WORKSPACE (required) - the VM's `workspace` label value (the tenant slug)
# @param DAY (optional) - last UTC day of the window, default yesterday (UTC)
# @param VM_COST_OUT (optional) - write the TSV to this file, default stdout
# @param COST_READER_KEY_FILE (optional) - the reader SA key (spec 123)
# @example ENV=prd WORKSPACE=acme ./run -a do_spl_vm_cost_per_day
# @example ENV=prd WORKSPACE=acme DAY=2026-11-20 VM_COST_OUT=vm-cost.tsv ./run -a do_spl_vm_cost_per_day
#------------------------------------------------------------------------------
do_spl_vm_cost_per_day() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
  local ws="${WORKSPACE:-}"
  [[ "${ws}" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || { do_log "FATAL WORKSPACE must be a GCP label value ([a-z0-9][a-z0-9_-]{0,62}), got: '${ws}'"; return 1; }
  local b
  for b in gcloud curl jq yq awk; do command -v "${b}" &>/dev/null || { do_log "FATAL ${b} is not installed"; return 1; }; done
  local day="${DAY:-$(date -u -d yesterday +%F)}"
  if [[ ! "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$(date -u -d "${day}" +%F 2>/dev/null)" != "${day}" ]]; then
    do_log "FATAL DAY must be a UTC day YYYY-MM-DD, got: ${day}"; return 1
  fi

  do_resolve_oap ORG
  do_resolve_oap APP
  do_spl_cost_gcp_cnf || return 1
  local -a days=()
  local i tmp
  for ((i = COST_REREAD_DAYS - 1; i >= 0; i--)); do days+=("$(date -u -d "${day} -${i} day" +%F)"); done
  tmp=$(umask 077 && mktemp -d) || return 1
  do_log "INFO ENV=${ENV} workspace=${ws} window=${days[0]}..${day} (${COST_REREAD_DAYS} days) export=${COST_SOURCE_PROJECT}.${COST_SOURCE_DATASET} reader=${COST_READER_EMAIL}"

  _spl_vm_cost_read_export "${tmp}" "${days[0]}" "${day}"
  _spl_vm_cost_rows "${tmp}" "${ws}" "${days[@]}" >"${tmp}/out.tsv" || { rm -rf "${tmp}"; do_log "FATAL cannot sum the VM cost rows"; return 1; }
  local d w bx st c dk tr tot why
  while IFS=$'\t' read -r d w bx st c dk tr tot why; do
    [[ "${d}" == day ]] && continue
    do_log "INFO ${d} workspace=${w} box=${bx} ${st} compute=${c} disk=${dk} traffic=${tr} total=${tot} eur_micros${why:+ reason: ${why}}"
  done <"${tmp}/out.tsv"
  local rc=0
  if [[ -n "${VM_COST_OUT:-}" ]]; then cp "${tmp}/out.tsv" "${VM_COST_OUT}" || rc=1
  else cat "${tmp}/out.tsv"; fi
  rm -rf "${tmp}"
  [[ "${rc}" -eq 0 ]] || { do_log "FATAL cannot write ${VM_COST_OUT}"; return 1; }
  do_log "OK the ${ws} VM cost of ${days[0]}..${day} is read; nothing was written to GCP or a DB"
}

# _spl_vm_cost_read_export <dir> <d0> <d1> - spec 123's export read, unchanged,
# in a subshell where its row query is this row's: <dir>/rows.tsv (day project
# workspace box service sku currency amount_micros usd_micros), <dir>/frontier,
# or <dir>/fail. The reader's file is sourced first, so the lazy loader cannot
# re-source it over the swapped query.
_spl_vm_cost_read_export() {
  (
    # shellcheck disable=SC1091 # spec 123's reader, beside this file
    source "$(dirname "${BASH_SOURCE[0]}")/spl-estate-cost-read.func.sh" || exit 1
    _spl_cost_rows_sql() { _spl_vm_cost_rows_sql "$@"; }
    _spl_cost_read_export "$@"
  )
}

# _spl_vm_cost_rows_sql <fq table> - per day, project, workspace label, box
# label, service, SKU and currency, for lines that carry a `workspace` label.
_spl_vm_cost_rows_sql() {
  cat <<EOF
SELECT FORMAT_DATE('%F', DATE(usage_start_time)) AS day, project.id AS project,
  (SELECT l.value FROM UNNEST(labels) l WHERE l.key = 'workspace' LIMIT 1) AS workspace,
  IFNULL((SELECT l.value FROM UNNEST(labels) l WHERE l.key = 'box' LIMIT 1), '') AS box,
  service.description AS service, sku.description AS sku, currency,
  CAST(ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) * 1000000) AS INT64) AS amount_micros,
  CAST(ROUND(SUM((cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) / NULLIF(currency_conversion_rate, 0)) * 1000000) AS INT64) AS usd_micros
FROM $1
WHERE DATE(usage_start_time) BETWEEN @d0 AND @d1 AND project.id LIKE @like
  AND EXISTS (SELECT 1 FROM UNNEST(labels) l WHERE l.key = 'workspace')
GROUP BY day, project, workspace, box, service, sku, currency
ORDER BY day, project, workspace, box, service, sku
EOF
}

# _spl_vm_cost_rows <dir> <workspace> <day>... - the TSV on stdout, header first.
_spl_vm_cost_rows() {
  local dir="$1" ws="$2"; shift 2
  local frontier="" fail=""
  [[ -s "${dir}/frontier" ]] && frontier=$(head -n 1 "${dir}/frontier")
  [[ -s "${dir}/fail" ]] && fail=$(cat "${dir}/fail")
  [[ -f "${dir}/rows.tsv" ]] || : >"${dir}/rows.tsv"
  awk -F'\t' -v ws="${ws}" -v days="$*" -v frontier="${frontier}" -v fail="${fail}" \
    -f <(_spl_vm_cost_rows_awk) "${dir}/rows.tsv"
}

_spl_vm_cost_rows_awk() {
  cat <<'AWK'
function part(svc, sku,   s) {
  s = tolower(svc " " sku)
  if (s ~ /egress|ingress|network|traffic|ip charge|external ip|static ip|load balanc|vpn|interconnect/) return "traffic"
  if (s ~ /pd capacity|pd snapshot|snapshot|hyperdisk|local ssd|disk|image storage|storage/) return "disk"
  return "compute"
}
BEGIN { OFS = "\t"; ndays = split(days, D, " "); for (i = 1; i <= ndays; i++) inwin[D[i]] = 1 }
# the one place a line is counted: its own workspace label, nothing else
fail == "" && ($1 in inwin) && $3 == ws && $8 ~ /^-?[0-9]+$/ {
  day = $1; box = ($4 == "" ? "-" : $4)
  if ($7 != "EUR") { held[day]++; next }
  k = day SUBSEP box
  if (!(k in seen)) { seen[k] = 1; boxes[day] = boxes[day] (boxes[day] == "" ? "" : SUBSEP) box }
  P[k, part($5, $6)] += $8; rows[day]++
}
END {
  print "day", "workspace", "box", "state", "compute_eur_micros", "disk_eur_micros", "traffic_eur_micros", "total_eur_micros", "reason"
  for (i = 1; i <= ndays; i++) {
    d = D[i]; why = ""
    if (fail != "") { print d, ws, "-", "missing", "", "", "", "", fail; continue }
    if (frontier == "" || d > frontier) {
      print d, ws, "-", "missing", "", "", "", "", "the export has not reached " d " (newest export day: " (frontier == "" ? "none" : frontier) ")"; continue
    }
    st = "ok"
    if (held[d] > 0) { st = "partial"; why = held[d] " line(s) held back: billed in a currency with no EUR rate source yet (spec 123 Q-6)" }
    else if (d == frontier) { st = "partial"; why = "the export is still filling " d " (its newest day)" }
    if (rows[d] == 0) { print d, ws, "-", (st == "ok" ? "none" : st), 0, 0, 0, 0, (why == "" ? "no line labelled workspace=" ws : why); continue }
    nb = split(boxes[d], B, SUBSEP)
    for (j = 1; j <= nb; j++) {
      k = d SUBSEP B[j]; c = P[k, "compute"] + 0; dk = P[k, "disk"] + 0; tr = P[k, "traffic"] + 0
      printf "%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s\n", d, ws, B[j], st, c, dk, tr, c + dk + tr, why
    }
  }
}
AWK
}
