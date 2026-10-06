#!/bin/bash
#------------------------------------------------------------------------------
# @description The daily purge of the calendar trash (spec 097 4.8, T004,
# @description FR-008): a DELETE of the hub is soft (deleted_at set, the
# @description event restorable with POST .../restore); this action removes
# @description for good the events deleted more than cnf
# @description env.calendar.trash_retention_days (default 30, Q6) ago, in
# @description every workspace, and nothing else. A series' exceptions and
# @description guests go with it (ON DELETE CASCADE, rdb 0139). The SQL runs
# @description in OPERATOR RLS scope. Run daily by workflow 46. Prints one
# @description JSON line: env, dry_run, retention_days, the rows past it
# @description ("older").
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default): count in a READ ONLY transaction, delete nothing
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (do_gcp_account)
# @example ENV=dev ./run -a do_spl_calendar_purge_trash
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_calendar_purge_trash
#------------------------------------------------------------------------------
do_spl_calendar_purge_trash() {
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" days out rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  days="$(spl_calendar_trash_days "$SPL_CNF")" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  out="$(mktemp)" || return 1
  CAL_DRY="$dry" CAL_TRASH_DAYS="$days" spl_via_proxy _spl_calendar_purge_trash_run "$out" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the calendar trash purge in $ENV failed, nothing was committed: $(tr '\n' ' ' <"$out")"
    rm -f "$out"; return 1
  fi
  printf '{"env":"%s","dry_run":%s,"retention_days":%s,"older":%s}\n' "$ENV" \
    "$([[ "$dry" == 1 ]] && echo true || echo false)" "$days" "$(tail -n 1 "$out")"
  rm -f "$out"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN counted the calendar events in $ENV deleted more than $days days ago, removed nothing"
    return 0
  fi
  do_log "OK purged the calendar events in $ENV deleted more than $days days ago"
}

# spl_calendar_trash_days <cnf> -> cnf env.calendar.trash_retention_days
# (absent = 30) on stdout; anything but a whole number of days >= 1 is refused.
spl_calendar_trash_days() {
  local d
  d="$(yq -r '.env.calendar.trash_retention_days // 30' "$1")"
  [[ "$d" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL cnf env.calendar.trash_retention_days is not a whole number of days >= 1: '$d'"; return 1; }
  echo "$d"
}

# _spl_calendar_purge_trash_run <out> - the purge (CAL_DRY=0) or its count
# (CAL_DRY=1), one transaction through $SPL_PROXY_DSN; the last line of
# <out> is the count of events deleted before the retention.
_spl_calendar_purge_trash_run() {
  local begin='BEGIN;' where body
  where='deleted_at IS NOT NULL AND deleted_at < now() - make_interval(days => :days)'
  if [[ "$CAL_DRY" == 1 ]]; then
    begin='BEGIN READ ONLY;'
    body="SELECT count(*) FROM calendar_events WHERE $where;"
  else
    body="WITH d AS (DELETE FROM calendar_events WHERE $where RETURNING 1) SELECT count(*) FROM d;"
  fi
  printf '%s\nSET LOCAL app.rls_scope = '"'"'operator'"'"';\n%s\nCOMMIT;\n' "$begin" "$body" |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v days="$CAL_TRASH_DAYS" >"$1" 2>&1
}
