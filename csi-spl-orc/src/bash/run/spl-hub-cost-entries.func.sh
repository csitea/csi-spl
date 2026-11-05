#!/bin/bash
#------------------------------------------------------------------------------
# @description The operator's hand-entered Cloud infra and HR costs (SPL-4824,
# @description rdb 0245 cost_entries, spec 143 expenses-cost-entries.md),
# @description THROUGH THE HUB as the env's project service account
# @description (do_gcp_pin_account; never the owner account), like
# @description do_spl_hub_fleet_paid. The estate's month cost read counts them
# @description (source cost_entry). COST_CMD:
# @description   list    (default) GET /v1/operator/cost-entries
# @description   index   the same GET, figure-free (SPL-4891): one line per
# @description           row with its id, period and type only, then one
# @description           line per period: <period> rows=<n>; with
# @description           COST_EXPECT_FILE also sum=OK|MISMATCH (the period's
# @description           raw amounts summed, no FX, OK when within half a
# @description           cent of the file's sum), sum=UNCHECKED for a period
# @description           the file lacks, sum=BADROW for a period holding an
# @description           amount that is not a number; the sums are over the
# @description           rows COST_TYPE leaves, and COST_MONTH drops the
# @description           file's other periods; never an amount, currency,
# @description           note or label, also not on a malformed hub answer
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
# @param COST_CMD (optional) - list | index | create | delete
# @param COST_TYPE (optional) - list and index filter, or create: cloud | hr
# @param COST_MONTH (optional) - list and index filter: YYYY-MM
# @param COST_EXPECT_FILE (optional) - index: a file kept outside git (or
#   /dev/stdin), one `period<TAB>net sum` per line, no header; its sums are
#   compared, never printed, also not on a bad line (its number only), and
#   never on a command line (they reach jq on stdin and in the environment)
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
# @example ENV=dev COST_CMD=index COST_TYPE=cloud COST_EXPECT_FILE=/dev/stdin ./run -a do_spl_hub_cost_entries
# @example ENV=dev COST_CMD=create COST_TYPE=cloud COST_LABEL=fixture COST_AMOUNT=1 COST_GROSS=1.24 COST_CURRENCY=EUR COST_PERIOD=2020-01 ./run -a do_spl_hub_cost_entries
# @example ENV=dev COST_CMD=delete COST_ID=<uuid> DRY_RUN=0 ./run -a do_spl_hub_cost_entries
#------------------------------------------------------------------------------
do_spl_hub_cost_entries() {
  do_require_bin jq curl gcloud || return 1
  local cmd="${COST_CMD:-list}" method path body="" shown="" dry=0
  case "$cmd" in
    list) method=GET path="$(_spl_hub_cost_entries_list_path)" || return 1 ;;
    index)
      method=GET path="$(_spl_hub_cost_entries_list_path)" || return 1
      SPL_COST_EXPECT="$(_spl_hub_cost_entries_expect)" || return 1; export SPL_COST_EXPECT ;;
    create)
      method=POST path=/v1/operator/cost-entries; body="$(_spl_hub_cost_entries_body)" || return 1
      shown="period=$COST_PERIOD type=$COST_TYPE label=$COST_LABEL" ;;
    delete) _spl_hub_cost_entries_id || return 1; method=DELETE path="/v1/operator/cost-entries/$COST_ID" ;;
    *) do_log "FATAL COST_CMD must be list, index, create or delete, got: '$cmd'"; return 1 ;;
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

# _spl_hub_cost_entries_expect -> COST_EXPECT_FILE (a file or a pipe) as a
# JSON object {period: sum}, {} without it, only COST_MONTH's period with
# it, else FATAL with the line number only: the file holds figures, so no
# line of it is ever printed, and no sum rides a command line (ps)
_spl_hub_cost_entries_expect() {
  local f="${COST_EXPECT_FILE:-}" line n=0 kept=""
  local rx=$'^([0-9]{4}-(0[1-9]|1[0-2]))\t((0|[1-9][0-9]*)(\\.[0-9]{1,4})?)$'
  [[ -z "$f" ]] && { echo '{}'; return 0; }
  [[ (-f "$f" || -p "$f") && -r "$f" ]] || { do_log "FATAL COST_EXPECT_FILE is not a readable file or pipe" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1)); line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ $rx ]] || { do_log "FATAL COST_EXPECT_FILE line $n must be period<TAB>sum (the value is not printed)" >&2; return 1; }
    [[ -n "${COST_MONTH:-}" && "${BASH_REMATCH[1]}" != "$COST_MONTH" ]] && continue
    kept+="$line"$'\n'
  done <"$f"
  printf '%s' "$kept" | jq -Rnc '[inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries' 2>/dev/null ||
    { do_log "FATAL COST_EXPECT_FILE could not be read (the values are not printed)" >&2; return 1; }
}

# _spl_hub_cost_entries_index <body> -> the figure-free index of a list
# answer: per row id period type (each shape-checked, else "?"), then per
# period its row count and, with the exported SPL_COST_EXPECT, OK (within
# half a cent) | MISMATCH | UNCHECKED | BADROW; a malformed answer is FATAL
# with nothing of it printed (jq's error would quote it)
_spl_hub_cost_entries_index() {
  jq -r '
    def ok(re): if type == "string" and test(re) then . else "?" end;
    ($ENV.SPL_COST_EXPECT // "{}" | fromjson) as $exp
    | [(.entries // [])[] | {id: (.id | ok("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")),
      period: (.period | ok("^[0-9]{4}-(0[1-9]|1[0-2])$")), type: (.type | ok("^(cloud|hr)$")),
      amount: (.amount | if type == "number" then . else (tonumber? // null) end)}] as $e
    | ($e | group_by(.period) | map({key: .[0].period,
        value: {n: length, bad: any(.[]; .amount == null), s: (map(.amount // 0) | add)}}) | from_entries) as $g
    | ($e[] | "  \(.id) \(.period) \(.type)"),
      (([$g | keys[]] + [$exp | keys[]] | unique[]) as $p
       | "\($p) rows=\($g[$p].n // 0)" + (if $exp == {} then "" elif $exp[$p] == null then " sum=UNCHECKED"
           elif $g[$p].bad then " sum=BADROW" elif ((($g[$p].s // 0) - $exp[$p]) | fabs) < 0.005 then " sum=OK"
           else " sum=MISMATCH" end))' <<<"$1" 2>/dev/null ||
    { do_log "FATAL the hub's answer is not a list of cost entries (it is not printed)"; return 1; }
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
    200:index)
      do_log "OK $ENV cost entries (index, figure-free): $(jq -r '.entries | if type == "array" then length else "?" end' <<<"$b" 2>/dev/null)"
      _spl_hub_cost_entries_index "$b" ;;
    201:create) do_log "OK $ENV cost entry created: $(jq -r '"\(.id) \(.period) \(.type) \(.label)"' <<<"$b" 2>/dev/null)" ;;
    204:delete) do_log "OK $ENV cost entry $COST_ID deleted" ;;
    400:*) do_log "FATAL the hub refused it (400)$err"; return 1 ;;
    401:*|403:*) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS)$err: is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS?"; return 1 ;;
    404:*) do_log "FATAL the hub answered 404$err: no such entry, or a hub without this door yet"; return 1 ;;
    *) do_log "FATAL the hub answered $SPL_HUB_OP_STATUS$err"; return 1 ;;
  esac
}
