#!/bin/bash
#------------------------------------------------------------------------------
# @description The operator's paid AI vendor items and the effective price per
# @description token (SPL-2342, rdb 0205), THROUGH THE HUB as the env's project
# @description service account (do_gcp_pin_account, a Google id token for the
# @description hub URL; never the owner account), like do_spl_hub_agent_kinds.
# @description The owner enters real items in the web UI; this action is for
# @description reads and for test fixtures. PAID_CMD:
# @description   list       (default) GET /v1/operator/fleet-tokens/paid
# @description   effective  GET /v1/operator/fleet-tokens/effective?from=&to=
# @description   create     POST an item (DRY_RUN=1 default prints the body)
# @description   update     PATCH item PAID_ID with only the fields given
# @description              (SPL-3890; DRY_RUN=1 default prints the body)
# @description   delete     DELETE item PAID_ID (DRY_RUN=1 default prints it)
# @param ENV - required: dev or prd
# @param PAID_CMD (optional) - list | effective | create | update | delete
# @param FROM, TO (optional) - effective: UTC days YYYY-MM-DD, TO excluded
# @param VENDOR KIND PLAN_LABEL AMOUNT CURRENCY PERIOD_START PERIOD_END - create
# @param QUANTITY (optional, default 1), NOTE (optional) - create
# @param PAID_ID - update, delete: the item's uuid
# @param VENDOR KIND PLAN_LABEL QUANTITY AMOUNT CURRENCY PERIOD_START PERIOD_END
#   NOTE (optional) - update: only the ones set ride the body; at least one
# @param DRY_RUN (optional) - 1 (default) or 0, create and delete only
# @param PAID_FX (optional) - effective: 1 adds, per vendor, the read's non-USD
#   items and how many took the rate of their own period (a rate day on or
#   before the item's period start), the first one after it, or none
#   (SPL-3791; counts only, a second GET of the item list)
# @example ENV=dev ./run -a do_spl_hub_fleet_paid
# @example ENV=dev PAID_CMD=effective FROM=2026-09-01 TO=2026-10-01 ./run -a do_spl_hub_fleet_paid
# @example ENV=prd PAID_CMD=effective PAID_FX=1 FROM=2024-07-01 TO=2025-07-01 ./run -a do_spl_hub_fleet_paid
# @example ENV=prd PAID_CMD=update PAID_ID=<uuid> PERIOD_END=2027-10-01 ./run -a do_spl_hub_fleet_paid
# @example ENV=dev PAID_CMD=create VENDOR=agy KIND=topup PLAN_LABEL=fixture AMOUNT=1 CURRENCY=USD PERIOD_START=2020-01-01 PERIOD_END=2020-01-02 DRY_RUN=0 ./run -a do_spl_hub_fleet_paid
#------------------------------------------------------------------------------
do_spl_hub_fleet_paid() {
  do_require_bin jq curl gcloud || return 1
  local cmd="${PAID_CMD:-list}" method path body="" dry=0
  case "$cmd" in
    list) method=GET path=/v1/operator/fleet-tokens/paid ;;
    effective) method=GET path="$(_spl_hub_fleet_paid_effective_path)" || return 1 ;;
    create) method=POST path=/v1/operator/fleet-tokens/paid; body="$(_spl_hub_fleet_paid_body)" || return 1 ;;
    update)
      _spl_hub_fleet_paid_id || return 1
      method=PATCH path="/v1/operator/fleet-tokens/paid/$PAID_ID"; body="$(_spl_hub_fleet_paid_patch)" || return 1 ;;
    delete) _spl_hub_fleet_paid_id || return 1; method=DELETE path="/v1/operator/fleet-tokens/paid/$PAID_ID" ;;
    *) do_log "FATAL PAID_CMD must be list, effective, create, update or delete, got: '$cmd'"; return 1 ;;
  esac
  if [[ "$method" != GET ]]; then
    if spl_dry_run; then dry=1; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if (( dry )); then
    do_log "OK DRY_RUN would $method $path${body:+ $body} to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call "$method" "$path" "$body" || return 1
  _spl_hub_fleet_paid_report "$cmd" || return 1
  [[ "$cmd" == effective && "${PAID_FX:-0}" == 1 ]] || return 0
  _spl_hub_fleet_paid_fx_counts
}

# _spl_hub_fleet_paid_fx_counts -> per vendor of the effective read just made,
# its non-USD items and which rate each took: own_period (the rate day is on
# or before the period start), first_after (the hub fell back to the first
# day after it) or no_rate. Counts only: no amount or rate is printed.
_spl_hub_fleet_paid_fx_counts() {
  local eff="$SPL_HUB_OP_BODY"
  spl_hub_operator_call GET /v1/operator/fleet-tokens/paid "" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { do_log "FATAL the item list answered $SPL_HUB_OP_STATUS"; return 1; }
  jq -r --argjson l "$SPL_HUB_OP_BODY" '
    ($l.items | map({key: .id, value: .}) | from_entries) as $m
    | .vendors[] | .vendor as $v
    | [(.items // [])[] | . as $s | $m[$s.id] | select(. != null and .currency != "USD")
       | if $s.fx_rate_day == null then "none" elif $s.fx_rate_day <= .period_start[0:10] then "own" else "after" end]
    | "  \($v) fx non_usd=\(length) own_period=\(map(select(. == "own")) | length) first_after=\(map(select(. == "after")) | length) no_rate=\(map(select(. == "none")) | length)"' <<<"$eff"
}

# _spl_hub_fleet_paid_effective_path -> the effective read's path with FROM / TO
_spl_hub_fleet_paid_effective_path() {
  local q="" d
  for d in FROM TO; do
    [[ -z "${!d:-}" ]] && continue
    [[ "${!d}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { do_log "FATAL $d must be a UTC day YYYY-MM-DD, got: '${!d}'" >&2; return 1; }
    q="$q&${d,,}=${!d}"
  done
  echo "/v1/operator/fleet-tokens/effective${q:+?${q#&}}"
}

# _spl_hub_fleet_paid_id -> PAID_ID is a paid item's uuid, else FATAL
_spl_hub_fleet_paid_id() {
  [[ "${PAID_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && return 0
  do_log "FATAL PAID_ID must be a paid item's uuid, got: '${PAID_ID:-}'"; return 1
}

# _spl_hub_fleet_paid_field <NAME> -> the env var NAME is a valid item field
# value, else FATAL: create checks every field, update only the ones set
_spl_hub_fleet_paid_field() {
  local v="${!1-}" re_day='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  case "$1" in
    VENDOR) [[ "$v" =~ ^(claude|mistral|grok|agy|qwen)$ ]] || { do_log "FATAL VENDOR must be claude, mistral, grok, agy or qwen, got: '$v'" >&2; return 1; } ;;
    KIND) [[ "$v" =~ ^(subscription|topup)$ ]] || { do_log "FATAL KIND must be subscription or topup, got: '$v'" >&2; return 1; } ;;
    PLAN_LABEL) [[ -n "$v" && ${#v} -le 100 ]] || { do_log "FATAL PLAN_LABEL must be 1..100 characters" >&2; return 1; } ;;
    QUANTITY) [[ "$v" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL QUANTITY must be 1..1000, got: '$v'" >&2; return 1; } ;;
    AMOUNT) [[ "$v" =~ ^[0-9]+(\.[0-9]{1,4})?$ && ! "$v" =~ ^0+(\.0+)?$ ]] || { do_log "FATAL AMOUNT must be a number above 0, got: '$v'" >&2; return 1; } ;;
    CURRENCY) [[ "$v" =~ ^[A-Z]{3}$ ]] || { do_log "FATAL CURRENCY must be an ISO 4217 code such as USD, got: '$v'" >&2; return 1; } ;;
    PERIOD_START|PERIOD_END) [[ "$v" =~ $re_day ]] || { do_log "FATAL $1 must be a UTC day YYYY-MM-DD, got: '$v'" >&2; return 1; } ;;
    NOTE) [[ ${#v} -le 2000 ]] || { do_log "FATAL NOTE must be at most 2000 characters" >&2; return 1; } ;;
  esac
}

# _spl_hub_fleet_paid_patch -> the update body: only the fields set in the
# env, each checked; the hub keeps the rest and checks the whole item
_spl_hub_fleet_paid_patch() {
  local f body='{}'
  for f in VENDOR KIND PLAN_LABEL QUANTITY AMOUNT CURRENCY PERIOD_START PERIOD_END NOTE; do
    [[ -n "${!f+set}" ]] || continue
    _spl_hub_fleet_paid_field "$f" || return 1
    case "$f" in
      QUANTITY|AMOUNT) body="$(jq -c --arg k "${f,,}" --argjson v "${!f}" '. + {($k): $v}' <<<"$body")" ;;
      *) body="$(jq -c --arg k "${f,,}" --arg v "${!f}" '. + {($k): $v}' <<<"$body")" ;;
    esac
  done
  [[ "$body" != '{}' ]] || { do_log "FATAL update needs at least one field: VENDOR KIND PLAN_LABEL QUANTITY AMOUNT CURRENCY PERIOD_START PERIOD_END NOTE" >&2; return 1; }
  [[ -z "${PERIOD_START:-}" || -z "${PERIOD_END:-}" || "$PERIOD_END" > "$PERIOD_START" ]] ||
    { do_log "FATAL PERIOD_END must be after PERIOD_START" >&2; return 1; }
  echo "$body"
}

# _spl_hub_fleet_paid_body -> the create body from the env, checked first
_spl_hub_fleet_paid_body() {
  local f
  QUANTITY="${QUANTITY:-1}"
  for f in VENDOR KIND PLAN_LABEL QUANTITY AMOUNT CURRENCY PERIOD_START PERIOD_END; do
    _spl_hub_fleet_paid_field "$f" || return 1
  done
  [[ "$PERIOD_END" > "$PERIOD_START" ]] ||
    { do_log "FATAL PERIOD_START and PERIOD_END must be UTC days YYYY-MM-DD, the end after the start" >&2; return 1; }
  jq -cn --arg v "$VENDOR" --arg k "$KIND" --arg p "$PLAN_LABEL" --argjson q "${QUANTITY:-1}" --argjson a "$AMOUNT" \
    --arg c "$CURRENCY" --arg s "$PERIOD_START" --arg e "$PERIOD_END" --arg n "${NOTE:-}" \
    '{vendor: $v, kind: $k, plan_label: $p, quantity: $q, amount: $a, currency: $c, period_start: $s, period_end: $e, note: $n}'
}

# _spl_hub_fleet_paid_report <cmd> -> the hub's answer as OK lines, or the refusal
_spl_hub_fleet_paid_report() {
  local b="$SPL_HUB_OP_BODY" detail
  detail="$(jq -r '.detail // .error // .' <<<"$b" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS:$1" in
    200:list)
      do_log "OK $ENV paid items: $(jq -r '.items | length' <<<"$b")"
      jq -r '.items[] | "  \(.id) \(.vendor) \(.kind) \(.plan_label) \(.quantity) x \(.amount) \(.currency) [\(.period_start), \(.period_end)) by \(.created_by)"' <<<"$b" ;;
    200:effective)
      do_log "OK $ENV effective price [$(jq -r '.from' <<<"$b"), $(jq -r '.to' <<<"$b")), $(jq -r '.days' <<<"$b") days"
      jq -r '.vendors[] | "  \(.vendor) \(.status) tokens=\(.tokens) cache_read=\(.cache_read) paid_usd=\(.paid_usd) per_day=\(.paid_per_day_usd) effective_usd_per_mtok=\(.effective_usd_per_mtok) list_usd_per_mtok=\(.list_usd_per_mtok)"' <<<"$b" ;;
    201:create) do_log "OK $ENV paid item created: $(jq -r '.id' <<<"$b") ($(jq -r '"\(.vendor) \(.kind) \(.plan_label)"' <<<"$b"))" ;;
    200:update) do_log "OK $ENV paid item $PAID_ID updated: $(jq -r '"\(.vendor) \(.kind) \(.plan_label) \(.quantity) x \(.amount) \(.currency) [\(.period_start), \(.period_end))"' <<<"$b")" ;;
    204:delete) do_log "OK $ENV paid item $PAID_ID deleted" ;;
    400:*) do_log "FATAL the hub refused it (400): $detail"; return 1 ;;
    401:*|403:*) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? $detail"; return 1 ;;
    404:*) do_log "FATAL the hub answered 404 ($detail): no such item, or a hub without this door yet"; return 1 ;;
    *) do_log "FATAL the hub answered $SPL_HUB_OP_STATUS: $detail"; return 1 ;;
  esac
}
