#!/bin/bash
#------------------------------------------------------------------------------
# @description The retention purge of the demo post audit (spec 077 FR-011,
# @description T025; rdb 0131 demo_post_audit): deletes the audit rows of the
# @description demo workspace (cnf env.demo.workspace) older than cnf
# @description env.demo.audit_retention_days (default 90) and nothing else.
# @description The table is append-only: its trigger refuses every UPDATE and
# @description every DELETE unless the transaction set app.demo_audit_purge,
# @description which this action alone does. The nightly wipe
# @description (do_spl_demo_wipe) never touches the table.
# @description The SQL runs in TENANT RLS scope (app.tenant_id = the demo id).
# @description An audit is kept whether the demo is on or off, so the purge
# @description runs either way. Prints one JSON line: workspace, env,
# @description dry_run, retention_days, the rows older than it ("older").
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default): count in a READ ONLY transaction, delete nothing
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (do_gcp_account)
# @example ENV=dev ./run -a do_spl_demo_audit_purge
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_demo_audit_purge
#------------------------------------------------------------------------------
do_spl_demo_audit_purge() {
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" ws days out rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  ws="$(spl_demo_wipe_workspace "$SPL_CNF")" || return 1
  days="$(spl_demo_audit_retention_days "$SPL_CNF")" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  out="$(mktemp)" || return 1
  DEMO_WS="$ws" DEMO_DRY="$dry" DEMO_AUDIT_DAYS="$days" spl_via_proxy _spl_demo_audit_purge_run "$out" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the demo audit purge of $ws in $ENV failed, nothing was committed: $(tr '\n' ' ' <"$out")"
    rm -f "$out"; return 1
  fi
  printf '{"workspace":"%s","env":"%s","dry_run":%s,"retention_days":%s,"older":%s}\n' "$ws" "$ENV" \
    "$([[ "$dry" == 1 ]] && echo true || echo false)" "$days" "$(tail -n 1 "$out")"
  rm -f "$out"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN counted the demo audit rows of $ws in $ENV older than $days days, deleted nothing"
    return 0
  fi
  do_log "OK purged the demo audit rows of $ws in $ENV older than $days days"
}

# spl_demo_audit_retention_days <cnf> -> cnf env.demo.audit_retention_days
# (absent = 90) on stdout; anything but a whole number of days >= 1 is refused.
spl_demo_audit_retention_days() {
  local d
  d="$(yq -r '.env.demo.audit_retention_days // 90' "$1")"
  [[ "$d" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL cnf env.demo.audit_retention_days is not a whole number of days >= 1: '$d'"; return 1; }
  echo "$d"
}

# _spl_demo_audit_purge_run <out> - the purge (DEMO_DRY=0) or its count
# (DEMO_DRY=1), one transaction through $SPL_PROXY_DSN; the last line of
# <out> is the count of rows older than the retention.
_spl_demo_audit_purge_run() {
  local begin='BEGIN;' body
  if [[ "$DEMO_DRY" == 1 ]]; then
    begin='BEGIN READ ONLY;'
    body="SELECT count(*) FROM demo_post_audit WHERE tenant_id = :'ws' AND at < now() - make_interval(days => :days);"
  else
    body="SET LOCAL app.demo_audit_purge = 'on';
WITH d AS (DELETE FROM demo_post_audit WHERE tenant_id = :'ws' AND at < now() - make_interval(days => :days) RETURNING 1)
SELECT count(*) FROM d;"
  fi
  printf '%s\nSET LOCAL app.tenant_id = :'"'"'ws'"'"';\n%s\nCOMMIT;\n' "$begin" "$body" |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v ws="$DEMO_WS" -v days="$DEMO_AUDIT_DAYS" >"$1" 2>&1
}
