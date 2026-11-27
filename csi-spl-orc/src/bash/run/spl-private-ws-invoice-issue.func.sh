#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 181 row B14 (gap G15; Q-9 B, Q-16 B, Q-19 A, Q-20 A): the
# @description month-end invoice issuer. For a closed UTC month and every
# @description private workspace (price plan private_vm) or one WORKSPACE:
# @description   1. list: GET /v1/operator/invoices/private-workspaces (the env
# @description      SA, operatorAuth): each workspace and its human members
# @description   2. cost: the VM's month cost from B4 (csi-spl-iac
# @description      do_spl_vm_cost_per_day), read in its trailing windows back
# @description      from the month's last day; the sum of total_eur_micros. A
# @description      day that is missing or partial, or not read at all,
# @description      refuses the WHOLE run before any write (never 0)
# @description   3. print each quote: workspace, humans, vm_cost_micros
# @description   4. DRY_RUN=0 only: POST /v1/operator/invoices/issue per
# @description      workspace; the hub counts the members again and writes the
# @description      invoice (B12's IssueInvoice), 201 new, 200 a replay that
# @description      returns the invoice already there (nothing new written).
# @description No DB password or Cloud SQL proxy on the box; read-only on GCP.
# @param ENV (required) - dev or prd: the hub and the env SA
# @param MONTH (required) - the closed UTC month to invoice, YYYY-MM (an open or future month is refused)
# @param WORKSPACE (optional) - one private workspace (tenant id), default every one
# @param DRY_RUN (optional) - 1 (default): print the quotes, write nothing. 0: issue the invoices
# @example ENV=prd MONTH=2026-11 ./run -a do_spl_private_ws_invoice_issue
# @example ENV=prd MONTH=2026-11 WORKSPACE=acme DRY_RUN=0 ./run -a do_spl_private_ws_invoice_issue
#------------------------------------------------------------------------------
do_spl_private_ws_invoice_issue() {
  local env="${ENV:-}" month="${MONTH:-}" ws="${WORKSPACE:-}" dry=1 rc tmp w h cost
  spl_require_cloud_env "$env" || return 1
  _spl_pwi_month_closed "$month" || return 1
  [[ -z "$ws" || "$ws" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || { do_log "FATAL WORKSPACE must be a workspace id, got: '$ws'"; return 1; }
  if spl_dry_run; then :; else rc=$?; [[ $rc -eq 1 ]] || return 1; dry=0; fi
  do_require_bin jq || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1

  tmp=$(umask 077 && mktemp -d) || return 1
  _spl_pwi_list "$ws" >"$tmp/list.tsv" || { rm -rf "$tmp"; return 1; }
  [[ -s "$tmp/list.tsv" ]] || { rm -rf "$tmp"; do_log "OK no private workspace${ws:+ named $ws} on $env: nothing to invoice for $month"; return 0; }
  : >"$tmp/quotes.tsv"
  while IFS=$'\t' read -r w h; do
    cost="$(_spl_pwi_month_cost "$env" "$w" "$month" "$tmp")" || {
      rm -rf "$tmp"; do_log "FATAL $w: no complete VM cost for $month; NOTHING issued for any workspace"; return 1; }
    printf '%s\t%s\t%s\n' "$w" "$h" "$cost" >>"$tmp/quotes.tsv"
    do_log "INFO quote $w $month: humans=$h vm_cost_micros=$cost (the hub prices it with the workspace's plan)"
  done <"$tmp/list.tsv"
  if (( dry )); then
    do_log "OK DRY_RUN $env $month: $(wc -l <"$tmp/quotes.tsv") quote(s) above, nothing issued. Issue: DRY_RUN=0"
    rm -rf "$tmp"
    return 0
  fi
  _spl_pwi_issue_all "$month" "$tmp/quotes.tsv"; rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# _spl_pwi_month_closed <YYYY-MM>: a real month that ended before today (UTC).
_spl_pwi_month_closed() {
  [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || { do_log "FATAL MONTH must be YYYY-MM, got: '$1'"; return 1; }
  local now; now="$(date -u +%Y-%m)"
  [[ "$1" < "$now" ]] || { do_log "FATAL MONTH $1 is not closed (this UTC month is $now): an invoice is issued after its month ends; nothing issued"; return 1; }
}

# _spl_pwi_list [workspace]: the hub's private workspaces, "<id>\t<humans>" per line.
_spl_pwi_list() {
  local q=""
  [[ -n "$1" ]] && q="?workspace=$1"
  spl_hub_operator_call GET "/v1/operator/invoices/private-workspaces$q" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || {
    do_log "FATAL the hub did not list the private workspaces (http $SPL_HUB_OP_STATUS: $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)); nothing issued" >&2
    return 1; }
  jq -r '.workspaces[] | "\(.workspace)\t\(.humans)"' <<<"$SPL_HUB_OP_BODY" || { do_log "FATAL the hub's list is not {workspaces: [...]}" >&2; return 1; }
}

# _spl_pwi_b4 <env> <workspace> <day> <out tsv>: B4's TSV of its window
# ending <day> (csi-spl-iac do_spl_vm_cost_per_day; read-only on GCP).
_spl_pwi_b4() {
  ( cd "${APP_PATH:-$PROJ_PATH/..}/csi-spl-iac" && ENV="$1" WORKSPACE="$2" DAY="$3" VM_COST_OUT="$4" ./run -a do_spl_vm_cost_per_day ) >&2
}

# _spl_pwi_month_cost <env> <workspace> <YYYY-MM> <tmp dir>: prints the sum
# of total_eur_micros over every day of the month. B4's windows are read
# back from the month's last day until one reaches its first. Refused (1):
# a day missing or partial, a day of the month not read, a window that
# reads no new day, an amount that is not a whole number.
_spl_pwi_month_cost() {
  local env="$1" w="$2" first="$3-01" last day out="$4/b4-$2.tsv" chunk="$4/chunk.tsv" earliest
  last="$(date -u -d "$first +1 month -1 day" +%F)" || return 1
  day="$last"
  : >"$out"
  while [[ ! "$day" < "$first" ]]; do
    rm -f "$chunk"
    _spl_pwi_b4 "$env" "$w" "$day" "$chunk" || { do_log "FATAL B4 failed for $w, window ending $day" >&2; return 1; }
    earliest="$(awk -F'\t' 'NR > 1 && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ { print $1 }' "$chunk" 2>/dev/null | sort | sed -n 1p)"
    [[ -n "$earliest" && ! "$earliest" > "$day" ]] || { do_log "FATAL B4 read no day for $w in the window ending $day" >&2; return 1; }
    awk -F'\t' -v a="$first" -v b="$day" 'NR > 1 && $1 >= a && $1 <= b' "$chunk" >>"$out"
    day="$(date -u -d "$earliest -1 day" +%F)"
  done
  _spl_pwi_sum "$out" "$w" "$first" "$last"
}

# _spl_pwi_sum <rows> <workspace> <first day> <last day>: every day present,
# none missing or partial; prints the total.
_spl_pwi_sum() {
  local why days="" d="$3"
  while [[ ! "$d" > "$4" ]]; do days+="$d "; d="$(date -u -d "$d +1 day" +%F)" || return 1; done
  why="$(awk -F'\t' -v days="$days" '
    { seen[$1] = 1
      if ($4 != "ok" && $4 != "none") { printf "%s is %s (%s)\n", $1, $4, $9; next }
      if ($8 !~ /^-?[0-9]+$/) printf "%s has no whole total_eur_micros: [%s]\n", $1, $8 }
    END { n = split(days, D, " "); for (i = 1; i <= n; i++) if (!(D[i] in seen)) printf "%s was not read\n", D[i] }' "$1")"
  [[ -z "$why" ]] || { do_log "FATAL $2 $3..$4 is not complete: $(paste -sd ';' <<<"$why")" >&2; return 1; }
  awk -F'\t' '{ s += $8 } END { printf "%.0f\n", s }' "$1"
}

# _spl_pwi_issue_all <YYYY-MM> <quotes tsv>: one POST per workspace; 201
# issued, 200 replayed (the invoice already there); anything else stops.
_spl_pwi_issue_all() {
  local month="$1" w h cost body n=0 r=0
  while IFS=$'\t' read -r w h cost; do
    body="$(jq -cn --arg w "$w" --arg m "$month" --argjson c "$cost" '{workspace: $w, month: $m, vm_cost_micros: $c}')" || return 1
    spl_hub_operator_call POST /v1/operator/invoices/issue "$body" || return 1
    case "$SPL_HUB_OP_STATUS" in
      201) n=$((n + 1)); do_log "OK issued $w $month: $(jq -c '.invoice | {humans, vm_cost_micros, total_micros, issued_on, due_on}' <<<"$SPL_HUB_OP_BODY")" ;;
      200) r=$((r + 1)); do_log "OK $w $month was already issued, unchanged: $(jq -c '.invoice | {humans, vm_cost_micros, total_micros, issued_on, due_on}' <<<"$SPL_HUB_OP_BODY")" ;;
      *) do_log "FATAL the hub did not issue $w $month (http $SPL_HUB_OP_STATUS: $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)); $n issued before it, the rest not tried (a re-run is safe: replays issue nothing new)"
         return 1 ;;
    esac
  done <"$2"
  do_log "OK $month: $n invoice(s) issued, $r already there"
}
