#!/bin/bash
#------------------------------------------------------------------------------
# @description Import one Outlook export (spec 180 FR-1, made by
# @description csi-spl-orc/src/powershell/outlook-calendar-export.ps1) into a
# @description member's private calendar in one workspace, THROUGH THE HUB:
# @description PUT /v1/operator/calendar/import/outlook (spec 180 FR-2, FR-9;
# @description calendar_operator_import.go), as the env's project service
# @description account (do_gcp_pin_account; never the owner account). The file
# @description is checked here first as the hub checks it (format, from <= to,
# @description at most 2000 events, RFC 3339 times, a source_id), so a bad
# @description file (e.g. a 06.30.00 time) calls nothing. The hub upserts by
# @description key and deletes the owner's imported rows in the window that
# @description are not in the file. Logs the four counts; never a title.
# @description DRY_RUN=1 (default): print the counts it would send, call nothing.
# @param ENV (required) - dev or prd
# @param TENANT_ID (required) - the workspace slug
# @param EVENT_OWNER (required) - the member whose calendar it is, a HUM-* id
# @param IMPORT_FILE (required) - the export file (spool-hub-outlook-export/1 JSON)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=csitea EVENT_OWNER=HUM-10 IMPORT_FILE=/path/export.json ./run -a do_spl_calendar_import_outlook
# @example ENV=prd TENANT_ID=csitea EVENT_OWNER=HUM-10 IMPORT_FILE=/path/export.json DRY_RUN=0 ./run -a do_spl_calendar_import_outlook
#------------------------------------------------------------------------------
do_spl_calendar_import_outlook() {
  do_require_bin jq curl gcloud || return 1
  local dry=1 n
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "${TENANT_ID:-}" || return 1
  [[ "${EVENT_OWNER:-}" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL EVENT_OWNER must be a HUM-* id, got: '${EVENT_OWNER:-}'"; return 1; }
  n="$(_spl_outlook_import_check "${IMPORT_FILE:-}")" || { printf '%s\n' "$n"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  local path="/v1/operator/calendar/import/outlook?tenant=$TENANT_ID&owner=$EVENT_OWNER"
  if (( dry )); then
    do_log "OK DRY_RUN would PUT $path to $SPL_HUB_URL in $ENV as the $SPL_PROJECT service account: $n; wrote nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local body rc
  body="$(umask 077; mktemp)" || { do_log "FATAL could not make a temp file"; return 1; }
  jq -c . "$IMPORT_FILE" >"$body" || { rm -f "$body"; do_log "FATAL could not compact $IMPORT_FILE"; return 1; }
  spl_hub_operator_call PUT "$path" "@$body"
  rc=$?
  rm -f "$body"
  (( rc == 0 )) || return 1
  _spl_outlook_import_answer "$n"
}

# _spl_outlook_import_answer <summary>: log the hub's answer to the PUT; the
# four counts on 200, the hub's reason otherwise (it names an event by index).
_spl_outlook_import_answer() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    200) ;;
    404) do_log "FATAL the hub answered 404: the Outlook import is off (SPOOL_HUB_CALENDAR_OUTLOOK_IMPORT_ENABLED) or not deployed. Nothing written."; return 1 ;;
    401|403) do_log "FATAL the hub refused the import ($SPL_HUB_OP_STATUS): $detail. Nothing written."; return 1 ;;
    *) do_log "FATAL the import was refused (http $SPL_HUB_OP_STATUS): $detail. Nothing written."; return 1 ;;
  esac
  local counts
  counts="$(jq -r '"created=\(.created) updated=\(.updated) unchanged=\(.unchanged) deleted=\(.deleted)"' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)" \
    || { do_log "FATAL the hub answered 200 without the counts"; return 1; }
  echo "$counts"
  do_log "OK imported $1 into $TENANT_ID ($ENV) for $EVENT_OWNER: $counts"
}

# _spl_outlook_import_check <file>: check an export as the hub does (spec 180
# FR-3) and print "<n> events, <from> .. <to>". A refusal prints FATAL with
# the first bad event's index and why (never its title) and returns 1.
_spl_outlook_import_check() {
  local f="$1" why
  [[ -n "$f" && -f "$f" && -r "$f" ]] || { echo "FATAL IMPORT_FILE is not a readable file: '$f'"; return 1; }
  why="$(jq -r '
    def rfc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    def day: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
    def bad(e): if (e.source_id // "" | tostring | gsub("\\s"; "")) == "" then "source_id is empty"
      elif e.all_day == true then (if (e.day | day) and (e.end_day | day) and e.day <= e.end_day then empty
        else "an all-day event has day <= end_day, each YYYY-MM-DD" end)
      elif (e.starts_at | rfc | not) then "starts_at is not an RFC 3339 time"
      elif (e.ends_at | rfc | not) then "ends_at is not an RFC 3339 time"
      elif (e.ends_at | fromdateiso8601? // 0) <= (e.starts_at | fromdateiso8601? // 0) and (e.starts_at | endswith("Z")) and (e.ends_at | endswith("Z"))
        then "ends_at must be after starts_at" else empty end;
    if .format != "spool-hub-outlook-export/1" then "format must be spool-hub-outlook-export/1"
    elif (.from | rfc | not) or (.to | rfc | not) or .from > .to then "from and to must be RFC 3339 times, from <= to"
    elif (.events | type) != "array" then "events must be a list"
    elif (.events | length) > 2000 then "an import holds at most 2000 events"
    else first(.events | to_entries[] | (bad(.value) as $w | "event \(.key): \($w)")) // "" end' "$f" 2>/dev/null)" \
    || { echo "FATAL IMPORT_FILE is not JSON: $f"; return 1; }
  [[ -z "$why" ]] || { echo "FATAL IMPORT_FILE refused, nothing sent: $why"; return 1; }
  jq -r '"\(.events | length) events, \(.from) .. \(.to)"' "$f"
}
