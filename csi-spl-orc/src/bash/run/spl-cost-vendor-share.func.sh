#!/bin/bash
#------------------------------------------------------------------------------
# @description Gives one workspace a share of ONE vendor's paid AI items over
# @description the months FROM..TO (both included) THROUGH THE HUB, as the
# @description env's project service account (do_gcp_pin_account; never the
# @description owner account), never by SQL (SPL-6301, spec 143
# @description costs-allocation.md 7.7; owner HUM-10, topic f3203933 msg
# @description cfbd1832). It PUTs the tokens_vendor split
# @description <vendor>:<from>:<to> (PUT /v1/operator/cost-splits):
# @description COST_SHARE_WORKSPACE at COST_SHARE_BP, the rest over the stored
# @description tokens split pro rata (largest remainder), or COST_SHARE_REST.
# @description Every other vendor and month keeps the tokens split. It logs
# @description the vendor's paid items per month (counts only, never an
# @description amount or a plan). Dry run unless DRY_RUN=0: the reads run, no PUT.
# @param ENV (required) - dev or prd
# @param COST_SHARE_VENDOR (required) - claude, mistral, grok, agy or qwen
# @param COST_SHARE_FROM (required) - the first month, YYYY-MM
# @param COST_SHARE_TO (required) - the last month, YYYY-MM
# @param COST_SHARE_WORKSPACE (required) - the workspace id that gets the share
# @param COST_SHARE_BP (required) - its share in basis points, 1..10000
# @param COST_SHARE_REST (optional) - "<ws>=<bp>,..." for the other 10000 - bp; default the tokens split pro rata
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd COST_SHARE_VENDOR=claude COST_SHARE_FROM=2026-01 COST_SHARE_TO=2026-06 COST_SHARE_WORKSPACE=ws1 COST_SHARE_BP=4000 ./run -a do_spl_cost_vendor_share
#------------------------------------------------------------------------------
do_spl_cost_vendor_share() {
  do_require_bin jq curl gcloud || return 1
  local v="${COST_SHARE_VENDOR}" from="${COST_SHARE_FROM}" to="${COST_SHARE_TO}" ws="${COST_SHARE_WORKSPACE}" bp="${COST_SHARE_BP}" dry=1
  _spl_cost_vshare_args "$v" "$from" "$to" "$ws" "$bp" || return 1
  if spl_dry_run; then dry=1; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local tmp; tmp="$(mktemp -d)" || return 1
  _spl_cost_vshare_run "$tmp" "$v:$from:$to" "$ws" "$bp" "$dry"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# _spl_cost_vshare_args VENDOR FROM TO WS BP -> each is well formed, else FATAL
_spl_cost_vshare_args() {
  [[ "$1" =~ ^(claude|mistral|grok|agy|qwen)$ ]] || { do_log "FATAL COST_SHARE_VENDOR must be claude, mistral, grok, agy or qwen"; return 1; }
  local m
  for m in "$2" "$3"; do
    [[ "$m" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || { do_log "FATAL COST_SHARE_FROM and COST_SHARE_TO must be months YYYY-MM"; return 1; }
  done
  [[ ! "$2" > "$3" ]] || { do_log "FATAL COST_SHARE_FROM is after COST_SHARE_TO"; return 1; }
  [[ "$4" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { do_log "FATAL COST_SHARE_WORKSPACE must be a workspace id"; return 1; }
  [[ "$5" =~ ^[1-9][0-9]{0,4}$ && $5 -le 10000 ]] || { do_log "FATAL COST_SHARE_BP must be 1..10000 basis points"; return 1; }
  [[ -z "${COST_SHARE_REST:-}" ]] || _spl_cost_vshare_full "$4" "$5" "$COST_SHARE_REST" >/dev/null || return 1
}

# _spl_cost_vshare_full WS BP REST -> "<ws>=<bp>,..." of WS at BP plus REST
# (merged when REST names WS); FATAL unless the whole sums to 10000
_spl_cost_vshare_full() {
  local pair whole="" b="$2"
  while IFS= read -r pair; do
    [[ "$pair" =~ ^([A-Za-z0-9._-]{1,64})=([1-9][0-9]{0,4})$ ]] \
      || { do_log "FATAL COST_SHARE_REST is <ws>=<bp>,... with bp 1..10000" >&2; return 1; }
    if [[ "${BASH_REMATCH[1]}" == "$1" ]]; then b=$((b + BASH_REMATCH[2])); else whole+=",$pair"; fi
  done < <(tr ',' '\n' <<<"$3")
  whole="$1=$b$whole"
  _spl_cost_split_shares "$whole" >/dev/null || return 1
  echo "$whole"
}

# _spl_cost_vshare_rest SPLITS_JSON WS BP -> "<ws>=<bp>,..." of the whole
# split: WS at BP, the other 10000 - BP over the tokens split pro rata
# (floor, then the largest remainders, ties by workspace id); FATAL without
# a stored tokens split
_spl_cost_vshare_rest() {
  local rest=$((10000 - $3)) out
  jq -e 'any(.splits[]; .split_kind == "tokens")' "$1" >/dev/null \
    || { do_log "FATAL no tokens split is stored: set it first (COST_SPLIT_TOKENS of do_spl_cost_split_apply)" >&2; return 1; }
  out="$(jq -r --argjson r "$rest" '
    [first(.splits[] | select(.split_kind == "tokens")) | .shares[]] | sort_by(.workspace_id)
    | map(. + {q: ((.share_bp * $r) / 10000 | floor), f: ((.share_bp * $r) % 10000)}) as $s
    | ($r - ([$s[].q] | add)) as $left
    | [$s | to_entries | sort_by([-.value.f, .value.workspace_id]) | .[] | .value]
    | [to_entries[] | .value + {q: (.value.q + (if .key < $left then 1 else 0 end))}]
    | map(select(.q > 0)) | sort_by(.workspace_id) | map("\(.workspace_id)=\(.q)") | join(",")' "$1")" || return 1
  if [[ -z "$out" ]]; then echo "$2=$3"; else _spl_cost_vshare_full "$2" "$3" "$out"; fi
}

# _spl_cost_vshare_months PAID_JSON VENDOR FROM TO -> logs the vendor's paid
# items per month (counts only); FATAL when the range holds none
_spl_cost_vshare_months() {
  local m="$3" n total=0 next
  while [[ ! "$m" > "$4" ]]; do
    next="$(date -u -d "$m-01 +1 month" +%Y-%m)"
    n="$(jq --arg v "$2" --arg a "$m-01" --arg b "$next-01" \
      '[.items[] | select(.vendor == $v and .period_start < $b and .period_end > $a)] | length' "$1")" || return 1
    do_log "PLAN vendor=$2 month=$m paid items=$n" >&2
    total=$((total + n))
    m="$next"
  done
  (( total > 0 )) || { do_log "FATAL vendor $2 has no paid item in $3..$4" >&2; return 1; }
}

# _spl_cost_vshare_run TMP SUBJECT WS BP DRY: read, plan, apply
_spl_cost_vshare_run() {
  local tmp="$1" subject="$2" ws="$3" bp="$4" dry="$5" v from to whole line
  IFS=: read -r v from to <<<"$subject"
  _spl_cost_split_get /v1/operator/cost-splits "$tmp/splits.json" || return 1
  _spl_cost_split_get /v1/operator/fleet-tokens/paid "$tmp/paid.json" || return 1
  _spl_cost_vshare_months "$tmp/paid.json" "$v" "$from" "$to" || return 1
  if [[ -n "${COST_SHARE_REST:-}" ]]; then whole="$(_spl_cost_vshare_full "$ws" "$bp" "$COST_SHARE_REST")" || return 1
  else whole="$(_spl_cost_vshare_rest "$tmp/splits.json" "$ws" "$bp")" || return 1; fi
  local w; for w in $(tr ',' '\n' <<<"$whole" | cut -d= -f1); do _spl_cost_split_live "$tmp/splits.json" "$w" || return 1; done
  _spl_cost_vshare_overlap "$tmp/splits.json" "$subject" || return 1
  line="$(_spl_cost_split_body tokens_vendor "$subject" "$whole" "$tmp/splits.json" "tokens_vendor $v $from..$to")" || return 1
  if (( dry )); then
    do_log "OK DRY_RUN $ENV: $(grep -c . <<<"$line") PUT(s) planned to $SPL_HUB_URL, none sent. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -n "$line" ]] || { do_log "OK $ENV: nothing to send"; return 0; }
  printf '%s\n' "$line" >"$tmp/puts"
  _spl_cost_split_send "$tmp/puts"
}

# _spl_cost_vshare_overlap SPLITS_JSON SUBJECT -> FATAL when a stored
# tokens_vendor split of the same vendor (another subject) meets the months
_spl_cost_vshare_overlap() {
  local v from to o
  IFS=: read -r v from to <<<"$2"
  o="$(jq -r --arg v "$v" --arg a "$from" --arg b "$to" --arg s "$2" '
    [.splits[] | select(.split_kind == "tokens_vendor" and .subject != $s) | .subject | split(":")
     | select(.[0] == $v and .[1] <= $b and $a <= .[2]) | join(":")] | first // ""' "$1")" || return 1
  [[ -z "$o" ]] || { do_log "FATAL the months meet the stored tokens_vendor split $o: remove it first" >&2; return 1; }
}
