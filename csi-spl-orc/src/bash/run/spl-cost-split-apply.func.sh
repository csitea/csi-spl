#!/bin/bash
#------------------------------------------------------------------------------
# @description Allocates the estate's costs to workspaces THROUGH THE HUB as
# @description the env's project service account (do_gcp_pin_account; never
# @description the owner account), never by SQL (SPL-5768, spec 143
# @description costs-allocation.md sections 4 and 7; owner HUM-10, csitea
# @description f655b326 msgs 8384d4b9, 28b33f17, 666ce94d, 0142ae24, 3440bf12):
# @description   cloud   every Cloud item of the months FROM..TO gets one
# @description           workspace at 10000 bp (PUT /v1/operator/cost-allocations):
# @description           a cost line whose project starts with
# @description           COST_SPLIT_CLOUD_PREFIX goes to COST_SPLIT_OPERATOR,
# @description           every other line and every cloud cost entry to
# @description           COST_SPLIT_OTHER
# @description   route   COST_SPLIT_ROUTE='<prefix>:<ws>' (SPL-6301, 7.8): every
# @description           Cloud cost line item of FROM..TO whose project starts
# @description           with <prefix> goes to <ws> at 10000 bp; it wins over
# @description           the cloud rules, and with COST_SPLIT_CLOUD_PREFIX
# @description           unset only the routed items are planned
# @description           a plain cloud run keeps a cost line already wholly at
# @description           a third workspace (routed earlier), never moves it
# @description           back to COST_SPLIT_OTHER (SPL-6323, 7.8)
# @description   tokens  COST_SPLIT_TOKENS, the split of every paid AI item
# @description           (PUT /v1/operator/cost-splits)
# @description   persons COST_SPLIT_PERSONS, one split per hr person code
# @description It prints counts only (items per rule, hr rows and months per
# @description person code, the PUTs sent and refused), never an amount,
# @description label or name. Dry run unless DRY_RUN=0: the reads run, no PUT.
# @param ENV (required) - dev or prd
# @param COST_SPLIT_OPERATOR (optional) - the operator workspace id; default t1
# @param COST_SPLIT_OTHER (optional) - the workspace of every other cloud item; default csitea
# @param COST_SPLIT_CLOUD_PREFIX (optional) - the operator's cost line projects; default csi-spl- (none with COST_SPLIT_ROUTE); "" = no cloud step
# @param COST_SPLIT_ROUTE (optional) - "<prefix>:<ws>", the cost line projects routed to one workspace; "" = no route
# @param COST_SPLIT_FROM (optional) - the first month read, YYYY-MM; default 2024-07
# @param COST_SPLIT_TO (optional) - the last month read, YYYY-MM; default this month (UTC)
# @param COST_SPLIT_TOKENS (optional) - "<ws>=<bp>,<ws>=<bp>", summing to 10000; "" = no tokens step
# @param COST_SPLIT_PERSONS (optional) - "<code>:<ws>=<bp>,<ws>=<bp>;<code>:..."; "" = no person step
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd COST_SPLIT_TOKENS=t1=7000,csitea=3000 ./run -a do_spl_cost_split_apply
# @example ENV=prd COST_SPLIT_ROUTE=cust-a-:ws-a COST_SPLIT_FROM=2026-01 ./run -a do_spl_cost_split_apply
# @example ENV=prd COST_SPLIT_PERSONS='E-01:t1=7000,csitea=3000' DRY_RUN=0 ./run -a do_spl_cost_split_apply
#------------------------------------------------------------------------------
do_spl_cost_split_apply() {
  do_require_bin jq curl gcloud || return 1
  local op="${COST_SPLIT_OPERATOR:-t1}" other="${COST_SPLIT_OTHER:-csitea}" dry=1
  local prefix="${COST_SPLIT_CLOUD_PREFIX-csi-spl-}" from="${COST_SPLIT_FROM:-2024-07}" to="${COST_SPLIT_TO:-$(date -u +%Y-%m)}"
  # SPL-6301: a route alone plans the routed items only
  [[ -n "${COST_SPLIT_ROUTE:-}" && -z "${COST_SPLIT_CLOUD_PREFIX+set}" ]] && prefix=""
  _spl_cost_split_args "$op" "$other" "$from" "$to" || return 1
  if spl_dry_run; then dry=1; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local tmp; tmp="$(mktemp -d)" || return 1
  _spl_cost_split_run "$tmp" "$op" "$other" "$prefix" "$from" "$to" "$dry"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# _spl_cost_split_run TMP OP OTHER PREFIX FROM TO DRY: read, plan, apply
_spl_cost_split_run() {
  local tmp="$1" op="$2" other="$3" prefix="$4" from="$5" to="$6" dry="$7"
  _spl_cost_split_get /v1/operator/cost-splits "$tmp/splits.json" || return 1
  local ws; for ws in "$op" "$other"; do _spl_cost_split_live "$tmp/splits.json" "$ws" || return 1; done
  local route="${COST_SPLIT_ROUTE:-}"
  [[ -z "$route" ]] || _spl_cost_split_live "$tmp/splits.json" "${route#*:}" || return 1
  : >"$tmp/puts"
  if [[ -n "$prefix" || -n "$route" ]]; then
    _spl_cost_split_items "$tmp" "$from" "$to" || return 1
    _spl_cost_split_cloud_plan "$tmp/items.json" "$op" "$other" "$prefix" "$route" >>"$tmp/puts" || return 1
  fi
  if [[ -n "${COST_SPLIT_TOKENS:-}" ]]; then
    _spl_cost_split_body tokens "" "$COST_SPLIT_TOKENS" "$tmp/splits.json" >>"$tmp/puts" || return 1
  fi
  if [[ -n "${COST_SPLIT_PERSONS:-}" ]]; then
    _spl_cost_split_persons "$tmp" >>"$tmp/puts" || return 1
  fi
  local n; n="$(grep -c . "$tmp/puts")"
  if (( dry )); then
    do_log "OK DRY_RUN $ENV: $n PUT(s) planned to $SPL_HUB_URL, none sent. Re-run with DRY_RUN=0."
    return 0
  fi
  _spl_cost_split_send "$tmp/puts"
}

# _spl_cost_split_args OP OTHER FROM TO -> each is well formed, else FATAL
# (the value of a split is never printed: it holds no figure, but stays
# out of the log like the rest)
_spl_cost_split_args() {
  local ws m
  for ws in "$1" "$2"; do
    [[ "$ws" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { do_log "FATAL COST_SPLIT_OPERATOR and COST_SPLIT_OTHER must be workspace ids"; return 1; }
  done
  [[ "$1" != "$2" ]] || { do_log "FATAL COST_SPLIT_OPERATOR and COST_SPLIT_OTHER must differ"; return 1; }
  for m in "$3" "$4"; do
    [[ "$m" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || { do_log "FATAL COST_SPLIT_FROM and COST_SPLIT_TO must be months YYYY-MM"; return 1; }
  done
  [[ ! "$3" > "$4" ]] || { do_log "FATAL COST_SPLIT_FROM is after COST_SPLIT_TO"; return 1; }
  [[ -z "${COST_SPLIT_ROUTE:-}" || "${COST_SPLIT_ROUTE}" =~ ^[a-z0-9][a-z0-9-]{0,59}:[A-Za-z0-9._-]{1,64}$ ]] \
    || { do_log "FATAL COST_SPLIT_ROUTE is <prefix>:<ws>, the prefix [a-z0-9-] (a GCP project id start)"; return 1; }
  [[ -z "${COST_SPLIT_TOKENS:-}" ]] || _spl_cost_split_shares "${COST_SPLIT_TOKENS}" >/dev/null || return 1
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$p" =~ ^[A-Z]{1,3}-[0-9]{2,4}:(.+)$ ]] || { do_log "FATAL COST_SPLIT_PERSONS: each entry is <code>:<ws>=<bp>,..."; return 1; }
    _spl_cost_split_shares "${BASH_REMATCH[1]}" >/dev/null || return 1
  done < <(tr ';' '\n' <<<"${COST_SPLIT_PERSONS:-}")
}

# _spl_cost_split_shares "<ws>=<bp>,..." -> the shares JSON array; FATAL
# unless every pair is well formed and the sum is 10000
_spl_cost_split_shares() {
  local pair sum=0 out="[]"
  while IFS= read -r pair; do
    [[ "$pair" =~ ^([A-Za-z0-9._-]{1,64})=([1-9][0-9]{0,4})$ && ${BASH_REMATCH[2]} -le 10000 ]] \
      || { do_log "FATAL a split is <ws>=<bp>,... with bp 1..10000" >&2; return 1; }
    sum=$((sum + BASH_REMATCH[2]))
    out="$(jq -c --arg w "${BASH_REMATCH[1]}" --argjson b "${BASH_REMATCH[2]}" '. + [{workspace_id: $w, share_bp: $b}]' <<<"$out")"
  done < <(tr ',' '\n' <<<"$1")
  (( sum == 10000 )) || { do_log "FATAL a split's shares sum to $sum basis points, not 10000" >&2; return 1; }
  echo "$out"
}

# _spl_cost_split_get PATH FILE -> the GET's 200 body in FILE, else FATAL
# with the HTTP code and the hub's error code only
_spl_cost_split_get() {
  spl_hub_operator_call GET "$1" || return 1
  if [[ "$SPL_HUB_OP_STATUS" != 200 ]]; then
    do_log "FATAL GET ${1%%\?*} answered $SPL_HUB_OP_STATUS $(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
    return 1
  fi
  printf '%s' "$SPL_HUB_OP_BODY" >"$2"
}

# _spl_cost_split_live SPLITS_JSON WS -> WS is a live workspace, else FATAL
_spl_cost_split_live() {
  jq -e --arg w "$2" 'any(.workspaces[]; .id == $w)' "$1" >/dev/null && return 0
  do_log "FATAL workspace $2 is not a live workspace of this hub"; return 1
}

# _spl_cost_split_items TMP FROM TO -> TMP/items.json, the Cloud items of
# every month FROM..TO, each key once with its split in force
_spl_cost_split_items() {
  local tmp="$1" m="$2" months=0
  echo '[]' >"$tmp/items.json"
  while [[ ! "$m" > "$3" ]]; do
    _spl_cost_split_get "/v1/operator/cost-allocations?month=$m" "$tmp/month.json" || return 1
    jq -s '(.[0] + [.[1].items[] | select(.label == "cloud") | {source, project_or_vendor, kind, shares}])
      | unique_by([.source, .project_or_vendor, .kind])' "$tmp/items.json" "$tmp/month.json" >"$tmp/items.next" \
      && mv "$tmp/items.next" "$tmp/items.json" || return 1
    months=$((months + 1))
    m="$(date -u -d "$m-01 +1 month" +%Y-%m)"
  done
  do_log "OK read $months month(s): $(jq length "$tmp/items.json") Cloud item(s)"
}

# _spl_cost_split_cloud_plan ITEMS OP OTHER PREFIX [ROUTE] -> one PUT line
# per item whose split is not already its rule's; logs the counts per rule.
# ROUTE "<prefix>:<ws>" (SPL-6301) wins over the rules for a cost line; with
# PREFIX "" only the routed items are planned; a route that matches no item
# is FATAL. A cost line wholly at a workspace that is neither OP nor OTHER
# was routed: line-kept, never planned (SPL-6323).
_spl_cost_split_cloud_plan() {
  local route="${5:-}" rp="" rw=""
  [[ -n "$route" ]] && rp="${route%%:*}" rw="${route#*:}"
  jq -r --arg op "$2" --arg other "$3" --arg pre "$4" --arg rp "$rp" --arg rw "$rw" '
    def rule: if .source == "cost_entry" then "cloud-entry"
      elif ($rp != "" and (.project_or_vendor | startswith($rp))) then "line-route"
      elif ((.shares | length) == 1 and .shares[0].share_bp == 10000
        and .shares[0].workspace_id != $op and .shares[0].workspace_id != $other) then "line-kept"
      elif (.project_or_vendor | startswith($pre)) then "line-prefix" else "line-other" end;
    def ws: if rule == "line-route" then $rw elif rule == "line-prefix" then $op else $other end;
    .[] | . as $i | ($i | rule) as $r | select($pre != "" or $r == "line-route") | ($i | ws) as $w
    | if $r == "line-kept" then "SKIP\t\($r)"
      elif ($i.shares == [{workspace_id: $w, share_bp: 10000}]) then "SKIP\t\($r)"
      else "PUT\t\($r)\t" + ({source, project_or_vendor, kind, shares: [{workspace_id: $w, share_bp: 10000}]} | tojson) end
  ' "$1" >"$1.plan" || return 1
  local r rules=(line-prefix line-other cloud-entry line-kept)
  [[ -n "$4" ]] || rules=()
  [[ -z "$rp" ]] || rules=(line-route "${rules[@]}")
  for r in "${rules[@]}"; do
    [[ $r == line-kept ]] && { do_log "PLAN cloud rule=line-kept: already routed=$(grep -c "^SKIP	line-kept$" "$1.plan")" >&2; continue; }
    do_log "PLAN cloud rule=$r -> $(_spl_cost_split_rule_ws "$r" "$2" "$3" "$rw"): items=$(grep -c "^PUT	$r	" "$1.plan") already=$(grep -c "^SKIP	$r$" "$1.plan")" >&2
  done
  if [[ -n "$rp" ]] && ! grep -qE "^(PUT|SKIP)	line-route" "$1.plan"; then
    do_log "FATAL COST_SPLIT_ROUTE prefix $rp matches no Cloud cost line item of the months read" >&2; return 1
  fi
  awk -F'\t' '$1 == "PUT" { print "/v1/operator/cost-allocations\t" $3 }' "$1.plan"
}

# _spl_cost_split_rule_ws RULE OP OTHER ROUTE_WS -> the workspace of RULE
_spl_cost_split_rule_ws() {
  case "$1" in line-route) echo "$4" ;; line-prefix) echo "$2" ;; *) echo "$3" ;; esac
}

# _spl_cost_split_body KIND SUBJECT SHARES SPLITS_JSON [LABEL] -> the PUT line
# of the split, none when it is already in force; logs the plan
_spl_cost_split_body() {
  local shares body label="${5:-$1}"
  shares="$(_spl_cost_split_shares "$3")" || return 1
  body="$(jq -cn --arg k "$1" --arg s "$2" --argjson sh "$shares" '{split_kind: $k, subject: $s, shares: $sh}')"
  if jq -e --arg k "$1" --arg s "$2" --argjson sh "$shares" \
    'any(.splits[]; .split_kind == $k and .subject == $s and (.shares | sort_by(.workspace_id)) == ($sh | sort_by(.workspace_id)))' "$4" >/dev/null; then
    do_log "PLAN split $label: already in force" >&2
    return 0
  fi
  do_log "PLAN split $label: shares=$(jq length <<<"$shares")" >&2
  printf '/v1/operator/cost-splits\t%s\n' "$body"
}

# _spl_cost_split_persons TMP -> the PUT line of each person's split; logs
# the person's hr rows and months (counts only), FATAL on an unknown code
_spl_cost_split_persons() {
  local tmp="$1" p code id
  _spl_cost_split_get "/v1/operator/cost-entries?type=hr" "$tmp/hr.json" || return 1
  do_log "OK hr rows: $(jq '.entries | length' "$tmp/hr.json"), with no person: $(jq '[.entries[] | select((.person_id // "") == "")] | length' "$tmp/hr.json")" >&2
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    code="${p%%:*}"
    id="$(jq -r --arg c "$code" 'first(.people[] | select(.code == $c) | .id) // ""' "$tmp/splits.json")"
    [[ -n "$id" ]] || { do_log "FATAL no hr person with code $code" >&2; return 1; }
    do_log "PLAN person $code: hr rows=$(jq --arg i "$id" '[.entries[] | select(.person_id == $i)] | length' "$tmp/hr.json") months=$(jq --arg i "$id" '[.entries[] | select(.person_id == $i) | .period] | unique | length' "$tmp/hr.json")" >&2
    _spl_cost_split_body person "$id" "${p#*:}" "$tmp/splits.json" "person $code" || return 1
  done < <(tr ';' '\n' <<<"$COST_SPLIT_PERSONS")
}

# _spl_cost_split_send PUTS -> each PUT line sent; counts the 200s and the
# refusals (the HTTP code and the hub's error code only); non-zero on any
_spl_cost_split_send() {
  local path body ok=0 bad=0
  while IFS=$'\t' read -r path body; do
    [[ -z "$path" ]] && continue
    spl_hub_operator_call PUT "$path" "$body" || return 1
    if [[ "$SPL_HUB_OP_STATUS" == 200 ]]; then ok=$((ok + 1)); else
      bad=$((bad + 1))
      do_log "ERROR PUT $path answered $SPL_HUB_OP_STATUS $(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
    fi
  done <"$1"
  do_log "$( ((bad)) && echo ERROR || echo OK) $ENV: PUT sent=$((ok + bad)) ok=$ok refused=$bad"
  (( bad == 0 ))
}
