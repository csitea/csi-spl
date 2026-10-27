#!/bin/bash
#------------------------------------------------------------------------------
# @description The daily exchange rates of the costs' second currency
# @description (SPL-2108, rdb 0200 fx_rates): reads the ECB euro reference
# @description rates and the Federal Reserve H.10 noon buying rates from the
# @description URLs in cnf env.fx, turns every rate into units per USD, and
# @description posts the last FX_DAYS days to the ENV hub's operator route
# @description POST /v1/operator/fx/rates (an UPSERT per day, quote and
# @description source: running it twice changes nothing). A currency in cnf
# @description env.fx.ecb_currencies (the European ones) comes from the ECB,
# @description its EUR-based rate divided by the same day's EUR/USD (EUR
# @description itself is 1 / EUR-USD); every other currency comes from the
# @description Fed, whose AUD, EUR, NZD and GBP series are USD per unit and
# @description are inverted. A day a bank did not publish (a weekend, a
# @description holiday, the Fed's weekly lag) has no row: the hub's cost read
# @description takes the last day before it. A bank that fails is reported
# @description and the other one still posts; both failing is FATAL.
# @description DRY_RUN=1 (default): read both banks, print the counts and the
# @description latest day of each, post nothing.
# @description FX_FROM=<YYYY-MM-DD> (SPL-3791) posts a historical range in
# @description place of the last FX_DAYS days: every day from FX_FROM to today,
# @description read from cnf env.fx.ecb_hist_url (the ECB's full file, from
# @description 1999-01-04) and env.fx.fed_range_url (the Fed series with its
# @description {from} and {to} filled as MM/DD/YYYY), posted in the same
# @description chunks and UPSERT. The one-off backfill of a hub; the daily cron
# @description row never sets it.
# @param ENV - required: dev or prd, the hub written
# @param DRY_RUN (optional) - 1 (default) or 0
# @param FX_DAYS (optional) - the days back from today posted, 1..90, default cnf env.fx.days
# @param FX_FROM (optional) - YYYY-MM-DD, 1999-01-04..today: post every day since it (not with FX_DAYS)
# @example ENV=dev ./run -a do_spl_fx_rates_fetch
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_fx_rates_fetch
# @example ENV=prd FX_FROM=2024-07-01 DRY_RUN=0 ./run -a do_spl_fx_rates_fetch
#------------------------------------------------------------------------------
do_spl_fx_rates_fetch() {
  do_require_bin curl jq yq awk || return 1
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" days ecb_url fed_url euro since tmp n_ecb n_fed rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_spl_cloud_cnf || return 1
  euro="$(yq -r '(.env.fx.ecb_currencies // []) | join(" ")' "$SPL_CNF")"
  if [[ -n "${FX_FROM:-}" ]]; then
    spl_fx_range || return 1
  else
    days="${FX_DAYS:-$(yq -r '.env.fx.days // ""' "$SPL_CNF")}"
    ecb_url="$(yq -r '.env.fx.ecb_url // ""' "$SPL_CNF")"
    fed_url="$(yq -r '.env.fx.fed_url // ""' "$SPL_CNF")"
    [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= 90 )) ||
      { do_log "FATAL FX_DAYS / cnf env.fx.days must be 1..90, got: '$days'"; return 1; }
    [[ "$ecb_url" == https://* && "$fed_url" == https://* ]] ||
      { do_log "FATAL cnf env.fx.ecb_url and env.fx.fed_url must be https URLs (no default)"; return 1; }
    since="$(date -u -d "-$days days" +%F)"
  fi
  [[ " $euro " == *" EUR "* ]] || { do_log "FATAL cnf env.fx.ecb_currencies must name EUR"; return 1; }
  tmp="$(umask 077 && mktemp -d)" || return 1
  : >"$tmp/rows"
  if spl_fx_get "$ecb_url" "$tmp/ecb.xml" && spl_fx_ecb_rows "$tmp/ecb.xml" "$euro" "$since" >"$tmp/ecb"; then
    cat "$tmp/ecb" >>"$tmp/rows"
  else
    do_log "WARN the ECB rates were not read from $ecb_url"; : >"$tmp/ecb"
  fi
  if spl_fx_get "$fed_url" "$tmp/fed.csv" && spl_fx_fed_rows "$tmp/fed.csv" "$euro" "$since" >"$tmp/fed"; then
    cat "$tmp/fed" >>"$tmp/rows"
  else
    do_log "WARN the Fed H.10 rates were not read from $fed_url"; : >"$tmp/fed"
  fi
  n_ecb="$(grep -c . "$tmp/ecb")"; n_fed="$(grep -c . "$tmp/fed")"
  do_log "INFO fx ENV=$ENV since=$since ECB rows=$n_ecb latest=$(spl_fx_latest "$tmp/ecb") FED rows=$n_fed latest=$(spl_fx_latest "$tmp/fed") DRY_RUN=$dry"
  if (( n_ecb + n_fed == 0 )); then
    rm -rf "$tmp"; do_log "FATAL neither bank gave a rate since $since: nothing to post"; return 1
  fi
  if [[ "$dry" == 1 ]]; then
    rm -rf "$tmp"; do_log "OK DRY_RUN read $((n_ecb + n_fed)) rate(s), posted nothing. DRY_RUN=0 posts them."; return 0
  fi
  spl_cost_hub_login && spl_fx_post "$tmp/rows" || rc=1
  rm -rf "$tmp"
  (( rc == 0 )) || { do_log "FATAL the rates were not all posted to the $ENV hub"; return 1; }
  (( n_ecb > 0 && n_fed > 0 )) || { do_log "FATAL one bank gave no rate (ECB $n_ecb, FED $n_fed): the other's are in the $ENV hub"; return 1; }
  do_log "OK the $((n_ecb + n_fed)) rate(s) since $since are in the $ENV hub"
}

# spl_fx_range: FX_FROM's checks; sets the caller's since, ecb_url and
# fed_url to the day and the banks' history URLs (the Fed's {from} and {to}
# filled as URL-encoded MM/DD/YYYY, to = today).
spl_fx_range() {
  local today from_q to_q
  today="$(date -u +%F)"
  [[ -z "${FX_DAYS:-}" ]] || { do_log "FATAL FX_FROM and FX_DAYS are mutually exclusive: set one"; return 1; }
  [[ "$FX_FROM" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$(date -u -d "$FX_FROM" +%F 2>/dev/null)" == "$FX_FROM" ]] ||
    { do_log "FATAL FX_FROM must be a day YYYY-MM-DD, got: '$FX_FROM'"; return 1; }
  [[ ! "$FX_FROM" < 1999-01-04 && ! "$FX_FROM" > "$today" ]] ||
    { do_log "FATAL FX_FROM must be 1999-01-04 (the ECB's first day) .. today $today, got: $FX_FROM"; return 1; }
  ecb_url="$(yq -r '.env.fx.ecb_hist_url // ""' "$SPL_CNF")"
  fed_url="$(yq -r '.env.fx.fed_range_url // ""' "$SPL_CNF")"
  [[ "$ecb_url" == https://* && "$fed_url" == https://*'{from}'*'{to}'* ]] ||
    { do_log "FATAL FX_FROM needs cnf env.fx.ecb_hist_url (https) and env.fx.fed_range_url (https, with {from} and {to})"; return 1; }
  from_q="${FX_FROM:5:2}%2F${FX_FROM:8:2}%2F${FX_FROM:0:4}"
  to_q="${today:5:2}%2F${today:8:2}%2F${today:0:4}"
  fed_url="${fed_url//\{from\}/$from_q}"
  fed_url="${fed_url//\{to\}/$to_q}"
  since="$FX_FROM"
}

# spl_fx_get URL OUT: one bounded download; a non-200 or an empty body fails.
spl_fx_get() {
  local code
  code="$(curl -sS --connect-timeout 10 --max-time 60 -o "$2" -w '%{http_code}' "$1" 2>/dev/null)" || return 1
  [[ "$code" == 200 && -s "$2" ]]
}

# spl_fx_ecb_rows XML EURO SINCE: the ECB reference rates (EUR-based, one
# <Cube time="..."> per day) as TSV day, quote, units per USD, ECB, for the
# currencies of EURO on the days >= SINCE that carry a USD rate.
spl_fx_ecb_rows() {
  grep -oE "<Cube (time='[0-9-]+'|time=\"[0-9-]+\"|currency=['\"][A-Z]{3}['\"] rate=['\"][0-9.]+['\"])" "$1" | tr "'" '"' |
    awk -v euro="$2" -v since="$3" -F'"' '
      BEGIN { n = split(euro, e, " "); for (i = 1; i <= n; i++) want[e[i]] = 1 }
      function flush(   c) {
        if (day == "" || day < since || !("USD" in r) || r["USD"] <= 0) return
        for (c in want) {
          if (c == "EUR") printf "%s\tEUR\t%.10g\tECB\n", day, 1 / r["USD"]
          else if (c in r && r[c] > 0) printf "%s\t%s\t%.10g\tECB\n", day, c, r[c] / r["USD"]
        }
      }
      /time=/ { flush(); day = $2; split("", r); next }
      /currency=/ { r[$2] = $4 + 0 }
      END { flush() }' | sort
}

# spl_fx_fed_rows CSV EURO SINCE: the Fed H.10 download (series in columns;
# a "Currency:" and a "Unique Identifier:" header row, then one row per day,
# ND where none) as TSV day, quote, units per USD, FED, for every currency NOT
# in EURO, on the days >= SINCE. A RXI$US_ series is USD per unit: inverted.
spl_fx_fed_rows() {
  awk -v euro="$2" -v since="$3" -F',' '
    BEGIN { n = split(euro, e, " "); for (i = 1; i <= n; i++) skip[e[i]] = 1 }
    { sub(/\r$/, ""); for (i = 1; i <= NF; i++) gsub(/"/, "", $i) }
    $1 == "Currency:" { for (i = 2; i <= NF; i++) cur[i] = $i; next }
    $1 ~ /^Unique Identifier/ { for (i = 2; i <= NF; i++) inv[i] = ($i ~ /RXI\$US_/); next }
    $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $1 >= since {
      for (i = 2; i <= NF; i++) {
        c = cur[i]
        if (c !~ /^[A-Z][A-Z][A-Z]$/ || c == "USD" || (c in skip) || $i !~ /^[0-9]+(\.[0-9]+)?$/ || $i + 0 <= 0) continue
        printf "%s\t%s\t%.10g\tFED\n", $1, c, (inv[i] ? 1 / $i : $i + 0)
      }
    }' "$1" | sort
}

# spl_fx_latest TSV: the latest day of a rows file, "-" when empty.
spl_fx_latest() {
  local d
  d="$(cut -f 1 "$1" | sort | tail -n 1)"
  printf '%s\n' "${d:--}"
}

# spl_fx_post TSV: post the rows in chunks of FX_POST_CHUNK (default 500) to
# the ENV hub as the env's service account (spl_cost_hub_login first).
spl_fx_post() {
  local chunk="${FX_POST_CHUNK:-500}" dir body f
  dir="$(dirname "$1")/chunks"
  mkdir -p "$dir" && split -l "$chunk" "$1" "$dir/c." || return 1
  for f in "$dir"/c.*; do
    body="$(jq -cRn '{rows: [inputs | split("\t") | {day: .[0], quote: .[1], rate: (.[2] | tonumber), source: .[3]}]}' <"$f")" ||
      { do_log "FATAL cannot build the rates body of $f"; return 1; }
    spl_hub_operator_call POST /v1/operator/fx/rates "$body" || return 1
    if [[ "$SPL_HUB_OP_STATUS" != 200 ]]; then
      do_log "FATAL the hub refused the rates (http $SPL_HUB_OP_STATUS): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null | cut -c 1-300)"
      return 1
    fi
    do_log "OK posted $(jq -r '"rows=\(.rows) written=\(.written)"' <<<"$SPL_HUB_OP_BODY")"
  done
}
