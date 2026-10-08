#!/bin/bash
#------------------------------------------------------------------------------
# @description Read or set ONE box's own fleet-load band and runner CPU cap
# @description (rdb 0134 / 0152, t1 338e5258) THROUGH THE HUB: GET, then PATCH
# @description /v1/operator/fleet-load {boxes}, as the env's project service
# @description account (do_gcp_pin_account; never the owner account). The hub
# @description replaces the whole boxes map, so the PATCH sends every other
# @description box back as the GET gave it, and a BAND change keeps the box's
# @description own runner_cpu_pct, as the WUI's band save does
# @description (csi-spl-wui fleetBoxBandPatch). A cap needs a band: the hub
# @description stores it inside the box's {low, high}. Neither BAND nor
# @description RUNNER_CPU_PCT: read only. DRY_RUN=1 (default) reads, prints
# @description the PATCH body, writes nothing.
# @param ENV - required: dev or prd
# @param BOX - required: the box id ([a-z0-9-], up to 32)
# @param BAND (optional) - <low>..<high>, % of cores (low 1..99, high 2..100, low < high), or 'default' to drop the box's entry, cap and all (the fleet band and cap apply)
# @param RUNNER_CPU_PCT (optional) - 1..100, or 'default' to drop the box's own cap (the fleet's applies)
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered it, a HUM-* id
# @param ORDERED_VIA (optional) - the agent or channel that carried the order, at most 64 chars
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev BOX=box-a ./run -a do_spl_hub_box_band
# @example ENV=dev BOX=box-a RUNNER_CPU_PCT=60 ORDERED_BY=HUM-10 ORDERED_VIA=c-540 DRY_RUN=0 ./run -a do_spl_hub_box_band
#------------------------------------------------------------------------------
do_spl_hub_box_band() {
  do_require_bin jq curl gcloud || return 1
  local box="${BOX:-}" band="${BAND:-}" cpu="${RUNNER_CPU_PCT:-}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" dry=1 write=0
  _spl_hub_box_band_check "$box" "$band" "$cpu" "$ordby" "$ordvia" || return 1
  [[ -n "$band" || -n "$cpu" ]] && write=1
  if (( write )); then
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
    (( dry )) || [[ -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0"; return 1; }
  fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call GET /v1/operator/fleet-load || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { _spl_hub_box_band_report "$box"; return 1; }
  (( write )) || { _spl_hub_box_band_report "$box"; return; }
  local body
  body="$(_spl_hub_box_band_body "$box" "$band" "$cpu" "$ordby" "$ordvia" <<<"$SPL_HUB_OP_BODY")" \
    || { do_log "FATAL box $box has no band of its own: a runner CPU cap lives inside {low, high}; give BAND=<low>..<high> too. Nothing changed."; return 1; }
  if (( dry )); then
    do_log "OK DRY_RUN would PATCH the hub $SPL_HUB_URL as the $SPL_PROJECT service account with: $body. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_hub_operator_call PATCH /v1/operator/fleet-load "$body" || return 1
  _spl_hub_box_band_report "$box"
}

# _spl_hub_box_band_check <box> <band> <cpu> <ordered_by> <ordered_via> -> 1 + FATAL on bad input
_spl_hub_box_band_check() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX must be a box id ([a-z0-9-], up to 32), got: '$1'"; return 1; }
  if [[ "$2" == default ]]; then
    [[ -z "$3" ]] || { do_log "FATAL BAND=default drops the box's cap too: leave RUNNER_CPU_PCT unset"; return 1; }
  elif [[ -n "$2" ]]; then
    [[ "$2" =~ ^([1-9][0-9]?)\.\.([1-9][0-9]?|100)$ ]] && (( BASH_REMATCH[1] < BASH_REMATCH[2] )) \
      || { do_log "FATAL BAND must be <low>..<high> (low 1..99, high 2..100, low < high), got: '$2'"; return 1; }
  fi
  [[ -z "$3" || "$3" == default || ( "$3" =~ ^[1-9][0-9]*$ && "$3" -le 100 ) ]] \
    || { do_log "FATAL RUNNER_CPU_PCT must be 1..100 or 'default', got: '$3'"; return 1; }
  [[ -z "$4" || "$4" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$4'"; return 1; }
  [[ ${#5} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
}

# _spl_hub_box_band_body <box> <band> <cpu> <ordered_by> <ordered_via> < GET body
# -> the PATCH body: every box as read, this box's band and/or cap changed;
# 1 when the box has no band and BAND is not given
_spl_hub_box_band_body() {
  jq -c --arg box "$1" --arg band "$2" --arg cpu "$3" --arg by "$4" --arg via "$5" '
    def by_via: {ordered_by: $by} + (if $via != "" then {ordered_via: $via} else {} end);
    (.boxes // {}) as $m
    | if $band == "default" then {boxes: ($m | del(.[$box]))} + by_via else .
    | ($m[$box] // null) as $old
    | (if $band != "" then ($band | split("..") | {low: (.[0] | tonumber), high: (.[1] | tonumber)})
       elif $old != null then {low: $old.low, high: $old.high} else null end) as $b
    | if $b == null then error("no band") else . end
    | ($b + (if $cpu == "default" then {}
             elif $cpu != "" then {runner_cpu_pct: ($cpu | tonumber)}
             elif ($old.runner_cpu_pct // null) != null then {runner_cpu_pct: $old.runner_cpu_pct}
             else {} end)) as $new
    | {boxes: ($m + {($box): $new})} + by_via end' 2>/dev/null
}

# _spl_hub_box_band_report <box> -> the box's band and cap as one OK line, or the refusal
_spl_hub_box_band_report() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200)
      do_log "OK $ENV box $1: $(jq -r --arg box "$1" '(.boxes // {})[$box] as $b | (.runner_cpu_pct // 80) as $f
        | if $b == null then "no band of its own (the fleet band \(.low)..\(.high)), runner CPU cap \($f)% (the fleet'"'"'s)"
          else "band \($b.low)..\($b.high), runner CPU cap \($b.runner_cpu_pct // $f)% (\(if $b.runner_cpu_pct then "its own" else "the fleet'"'"'s" end))" end' <<<"$SPL_HUB_OP_BODY")"
      return 0 ;;
    400) do_log "FATAL the hub refused the setting (400): $detail. Nothing changed."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    *) do_log "FATAL box $1 band was not read or changed (http $SPL_HUB_OP_STATUS): $detail"; return 1 ;;
  esac
}
