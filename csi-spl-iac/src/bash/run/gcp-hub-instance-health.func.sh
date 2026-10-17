#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description READ-ONLY: health of every hub Cloud Run instance, per
# @description (revision, instance), from Cloud Logging (SPL-2412, spec 146).
# @description Harvested from the 2026-10-16 prd outage (t1 bd226c16), where an
# @description ad hoc `gcloud logging read` was run three times to tell a stuck
# @description instance (0 WS upgrades, 503s) from a healthy one.
# @description Reads, as the env's project SA (do_gcp_pin_account) in a private
# @description gcloud config, the hub service's request log and its
# @description 'ws hello accepted' lines in [SINCE, UNTIL], then prints one row
# @description per (revision, instance): WS requests, WS upgrades (101), 5xx,
# @description sign-in 503s (/api/v1/auth/*), 'ws hello accepted', first and
# @description last seen (an instance id is shown by its last 8 chars, the
# @description way the incident posts cite it); plus a WARN line for every instance with >= WARN_MIN_WS
# @description WS requests and 0 upgrades. Mutates nothing.
# @param ENV - required: dev or prd
# @param SINCE (optional) - RFC3339 time or a duration like 30m, 2h, 1d (default 30m)
# @param UNTIL (optional) - RFC3339 time, the window end (default: now)
# @param WARN_MIN_WS (optional) - WS requests before 0 upgrades is a WARN (default 5)
# @param HUB_HEALTH_LIMIT (optional) - max log entries read (default 50000)
# @example ENV=prd ./run -a do_gcp_hub_instance_health
# @example ENV=prd SINCE=2026-10-16T19:00:00Z UNTIL=2026-10-16T19:30:00Z ./run -a do_gcp_hub_instance_health
#------------------------------------------------------------------------------
do_gcp_hub_instance_health() {
  local _spl_sdk_saved _spl_sdk_dir
  local warn_min="${WARN_MIN_WS:-5}" limit="${HUB_HEALTH_LIMIT:-50000}" since until=""
  [[ "$warn_min" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL WARN_MIN_WS must be a positive integer, got: '$warn_min'"; return 2; }
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL HUB_HEALTH_LIMIT must be a positive integer, got: '$limit'"; return 2; }
  since="$(_spl_hub_health_time "${SINCE:-30m}")" || { do_log "FATAL SINCE must be RFC3339 or <n>m|h|d, got: '${SINCE:-}'"; return 2; }
  if [[ -n "${UNTIL:-}" ]]; then
    [[ "$UNTIL" == *T* ]] && until="$(_spl_hub_health_time "$UNTIL")" ||
      { do_log "FATAL UNTIL must be an RFC3339 time, got: '$UNTIL'"; return 2; }
  fi
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_require_bin yq jq || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml" svc
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  svc="$(yq -r '.env.hub.service_name // ""' "$cnf")"
  [[ -n "$svc" ]] || { do_log "FATAL the $ENV cnf has no env.hub.service_name"; return 1; }
  do_gcp_pin_account || return 1

  local filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\" AND timestamp>=\"$since\""
  [[ -n "$until" ]] && filter+=" AND timestamp<=\"$until\""
  filter+=" AND (logName=\"projects/$p/logs/run.googleapis.com%2Frequests\" OR jsonPayload.message=\"ws hello accepted\")"
  local fields='json(timestamp,resource.labels.revision_name,labels.instanceId,httpRequest.status,httpRequest.requestUrl,jsonPayload.message)'
  local raw="$_spl_sdk_dir/entries.json"
  do_log "INFO reading $svc in $p, $since .. ${until:-now} (limit $limit) as $GCP_ACCOUNT"
  gcloud logging read "$filter" --project="$p" --account="$GCP_ACCOUNT" --limit="$limit" \
    --format="$fields" >"$raw" 2>"$_spl_sdk_dir/err" ||
    { do_log "FATAL gcloud logging read failed: $(head -c 300 "$_spl_sdk_dir/err")"; return 1; }
  local n
  n="$(jq 'length' "$raw" 2>/dev/null)" && [[ "$n" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL gcloud logging read returned no JSON array"; return 1; }
  ((n < limit)) || do_log "WARN read $n entries = HUB_HEALTH_LIMIT: the window is truncated, counts are low"
  echo "# hub instance health: $svc ($p), $since .. ${until:-now}, $n log entries"
  _spl_hub_health_rows "$raw" "$warn_min"
}

# _spl_hub_health_time <RFC3339 | <n>m|h|d> -> the RFC3339 UTC time it names
_spl_hub_health_time() {
  local v="$1"
  if [[ "$v" =~ ^([1-9][0-9]*)([mhd])$ ]]; then
    local unit=minutes
    [[ "${BASH_REMATCH[2]}" == h ]] && unit=hours
    [[ "${BASH_REMATCH[2]}" == d ]] && unit=days
    date -u -d "-${BASH_REMATCH[1]} $unit" +%Y-%m-%dT%H:%M:%SZ
  elif [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
    date -u -d "$v" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
  else
    return 1
  fi
}

# _spl_hub_health_rows <entries.json> <warn_min> -> the table and WARN lines.
# A WS request is a path ending in /ws; a sign-in is a path under /api/v1/auth/.
# The table shows an instance id's last 8 chars; the WARN line the full id.
_spl_hub_health_rows() {
  jq -r --argjson warn "$2" '
    def path: (.httpRequest.requestUrl // "") | sub("^[a-z]+://[^/]+"; "") | sub("[?#].*$"; "");
    map({rev: (.resource.labels.revision_name // "?"), inst: (.labels.instanceId // "?"),
         ts: .timestamp, st: (.httpRequest.status // 0), p: path, msg: (.jsonPayload.message // "")})
    | group_by([.rev, .inst])
    | map({rev: .[0].rev, inst: .[0].inst,
           ws: map(select(.p | test("/ws$"))) | length,
           up: map(select((.p | test("/ws$")) and .st == 101)) | length,
           e5: map(select(.st >= 500)) | length,
           login503: map(select((.p | startswith("/api/v1/auth/")) and .st == 503)) | length,
           hello: map(select(.msg == "ws hello accepted")) | length,
           first: (map(.ts) | min), last: (map(.ts) | max)})
    | sort_by(.first)
    | (["revision", "instance_8", "ws_req", "ws_101", "5xx", "login_503", "ws_hello", "first_seen", "last_seen"] | @tsv),
      (.[] | [.rev, .inst[-8:], .ws, .up, .e5, .login503, .hello, .first, .last] | map(tostring) | @tsv),
      (.[] | select(.ws >= $warn and .up == 0)
        | "WARN stuck? revision \(.rev) instance \(.inst): \(.ws) WS requests, 0 upgrades (101), \(.e5) 5xx, last seen \(.last)")
  ' "$1"
}
