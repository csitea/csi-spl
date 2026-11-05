#!/bin/bash
#------------------------------------------------------------------------------
# @description The operator's hand-entered Cloud infra and HR costs (SPL-4824,
# @description rdb 0245 cost_entries, spec 143 expenses-cost-entries.md),
# @description THROUGH THE HUB as the env's project service account
# @description (do_gcp_pin_account; never the owner account), like
# @description do_spl_hub_fleet_paid. The estate's month cost read counts them
# @description (source cost_entry). COST_CMD:
# @description   list    (default) GET /v1/operator/cost-entries
# @description   create  POST an entry (DRY_RUN=1 default prints what it would)
# @description   delete  DELETE entry COST_ID (DRY_RUN=1 default prints it)
# @description create, delete and their DRY_RUN lines are figure-free
# @description (SPL-4877, the SPL-4843 ruling): only the id, period, type and
# @description label, never the amount, currency or note, also not on a
# @description refusal (its HTTP code and the hub's error code only) or a bad
# @description input (its name and rule, never the value given). ./run
# @description tees every line into ~/var/log/<proj>/run.sh.<ts>.{out,err}.log.
# @description A dry create prints: OK DRY_RUN would POST
# @description /v1/operator/cost-entries period=<p> type=<t> label=<l> to <hub> ...
# @param ENV - required: dev or prd
# @param COST_CMD (optional) - list | create | delete
# @param COST_TYPE (optional) - list filter, or create: cloud | hr
# @param COST_MONTH (optional) - list filter: YYYY-MM
# @param COST_LABEL COST_AMOUNT COST_CURRENCY COST_PERIOD - create: the label
#   (1..100 chars), the amount NET of VAT above 0 (owner poll 68d7f768
#   answer 4 NET, msg 4eb41f4c), the ISO 4217 code, the month YYYY-MM
# @param COST_GROSS (optional) - create: the invoice's gross (with VAT), not
#   below the net; the table keeps one amount, so it rides the note as
#   "gross <amount> <currency>"
# @param COST_NOTE (optional) - create: at most 2000 characters with the gross
# @param COST_ID - delete: the entry's uuid
# @param DRY_RUN (optional) - 1 (default) or 0, create and delete only
# @example ENV=dev COST_TYPE=cloud COST_MONTH=2026-01 ./run -a do_spl_hub_cost_entries
# @example ENV=dev COST_CMD=create COST_TYPE=cloud COST_LABEL=fixture COST_AMOUNT=1 COST_GROSS=1.24 COST_CURRENCY=EUR COST_PERIOD=2020-01 ./run -a do_spl_hub_cost_entries
# @example ENV=dev COST_CMD=delete COST_ID=<uuid> DRY_RUN=0 ./run -a do_spl_hub_cost_entries
#------------------------------------------------------------------------------
do_spl_hub_cost_entries() {
  do_require_bin jq curl gcloud || return 1
  local cmd="${COST_CMD:-list}" method path body="" shown="" dry=0
  case "$cmd" in
    list) method=GET path="$(_spl_hub_cost_entries_list_path)" || return 1 ;;
    create)
      method=POST path=/v1/operator/cost-entries; body="$(_spl_hub_cost_entries_body)" || return 1
      shown="period=$COST_PERIOD type=$COST_TYPE label=$COST_LABEL" ;;
    delete) _spl_hub_cost_entries_id || return 1; method=DELETE path="/v1/operator/cost-entries/$COST_ID" ;;
    *) do_log "FATAL COST_CMD must be list, create or delete, got: '$cmd'"; return 1 ;;
  esac
  if [[ "$method" != GET ]]; then
    if spl_dry_run; then dry=1; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if (( dry )); then
    do_log "OK DRY_RUN would $method $path${shown:+ $shown} to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call "$method" "$path" "$body" || return 1
  _spl_hub_cost_entries_report "$cmd"
}

# _spl_hub_cost_entries_field <NAME> -> the env var NAME is a valid entry
# field value (rdb 0245's CHECKs, store.CheckCostEntry), else FATAL
_spl_hub_cost_entries_field() {
  local v="${!1-}"
  case "$1" in
    COST_TYPE) [[ "$v" =~ ^(cloud|hr)$ ]] || { do_log "FATAL COST_TYPE must be cloud or hr (the value is not printed)" >&2; return 1; } ;;
    COST_LABEL) [[ -n "${v// /}" && ${#v} -le 100 ]] || { do_log "FATAL COST_LABEL must be 1..100 characters" >&2; return 1; } ;;
    COST_AMOUNT|COST_GROSS) [[ "$v" =~ ^[0-9]+(\.[0-9]{1,4})?$ && ! "$v" =~ ^0+(\.0+)?$ ]] || { do_log "FATAL $1 must be a number above 0 with at most 4 decimals (the value is not printed)" >&2; return 1; } ;;
    COST_CURRENCY) [[ "$v" =~ ^[A-Z]{3}$ ]] || { do_log "FATAL COST_CURRENCY must be an ISO 4217 code such as EUR (the value is not printed)" >&2; return 1; } ;;
    COST_PERIOD|COST_MONTH) [[ "$v" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || { do_log "FATAL $1 must be a month YYYY-MM (the value is not printed)" >&2; return 1; } ;;
    COST_NOTE) [[ ${#v} -le 2000 ]] || { do_log "FATAL COST_NOTE must be at most 2000 characters" >&2; return 1; } ;;
  esac
}

# _spl_hub_cost_entries_list_path -> the list path with COST_TYPE / COST_MONTH
_spl_hub_cost_entries_list_path() {
  local q="" f
  for f in COST_TYPE COST_MONTH; do
    [[ -z "${!f:-}" ]] && continue
    _spl_hub_cost_entries_field "$f" || return 1
    q="$q&$([[ $f == COST_TYPE ]] && echo type || echo month)=${!f}"
  done
  echo "/v1/operator/cost-entries${q:+?${q#&}}"
}

# _spl_hub_cost_entries_id -> COST_ID is an entry's uuid, else FATAL
_spl_hub_cost_entries_id() {
  [[ "${COST_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && return 0
  do_log "FATAL COST_ID must be a cost entry's uuid (the value is not printed)"; return 1
}

# _spl_hub_cost_entries_note -> COST_NOTE with COST_GROSS kept in it (the
# amount is the net), else FATAL: a gross below the net, a note too long
_spl_hub_cost_entries_note() {
  local note="${COST_NOTE:-}"
  if [[ -n "${COST_GROSS:-}" ]]; then
    _spl_hub_cost_entries_field COST_GROSS || return 1
    jq -en --argjson g "$COST_GROSS" --argjson n "$COST_AMOUNT" '$g >= $n' >/dev/null ||
      { do_log "FATAL COST_GROSS is below the net COST_AMOUNT (the values are not printed)" >&2; return 1; }
    note="gross $COST_GROSS $COST_CURRENCY${note:+; $note}"
  fi
  [[ ${#note} -le 2000 ]] || { do_log "FATAL COST_NOTE with the gross must be at most 2000 characters" >&2; return 1; }
  echo "$note"
}

# _spl_hub_cost_entries_body -> the create body from the env, checked first;
# the amount as a number (+ 0: jq 1.7 would keep 64.80's literal)
_spl_hub_cost_entries_body() {
  local f note
  for f in COST_TYPE COST_LABEL COST_AMOUNT COST_CURRENCY COST_PERIOD; do
    _spl_hub_cost_entries_field "$f" || return 1
  done
  note="$(_spl_hub_cost_entries_note)" || return 1
  jq -cn --arg t "$COST_TYPE" --arg l "$COST_LABEL" --argjson a "$COST_AMOUNT" --arg c "$COST_CURRENCY" \
    --arg p "$COST_PERIOD" --arg n "$note" \
    '{type: $t, label: $l, amount: ($a + 0), currency: $c, period: $p, note: $n}'
}

# _spl_hub_cost_entries_report <cmd> -> the hub's answer as OK lines, or the
# refusal. A create prints id period type label only; a refusal its HTTP code
# and the hub's [a-z_] error code, never the body or its detail (SPL-4877).
_spl_hub_cost_entries_report() {
  local b="$SPL_HUB_OP_BODY" err
  err="$(jq -r '.error // empty' <<<"$b" 2>/dev/null | grep -xE '[a-z_]{1,40}')"
  err="${err:+ ($err)}"
  case "$SPL_HUB_OP_STATUS:$1" in
    200:list)
      do_log "OK $ENV cost entries: $(jq -r '.entries | length' <<<"$b")"
      jq -r '.entries[] | "  \(.id) \(.period) \(.type) \(.amount) \(.currency) \(.label)"' <<<"$b" ;;
    201:create) do_log "OK $ENV cost entry created: $(jq -r '"\(.id) \(.period) \(.type) \(.label)"' <<<"$b" 2>/dev/null)" ;;
    204:delete) do_log "OK $ENV cost entry $COST_ID deleted" ;;
    400:*) do_log "FATAL the hub refused it (400)$err"; return 1 ;;
    401:*|403:*) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS)$err: is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS?"; return 1 ;;
    404:*) do_log "FATAL the hub answered 404$err: no such entry, or a hub without this door yet"; return 1 ;;
    *) do_log "FATAL the hub answered $SPL_HUB_OP_STATUS$err"; return 1 ;;
  esac
}
