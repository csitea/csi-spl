#!/bin/bash
#------------------------------------------------------------------------------
# @description Undo a channel delete (SPL-72, rdb 0052, channels-v1 §5.4).
# @description DELETE /v1/channels/{channel} is a soft delete: it stamps
# @description channels.deleted_at / deleted_by and removes nothing. This
# @description clears the stamp, so the channel's members, agents and the
# @description messages still in retention come back as they were. A channel
# @description that is not deleted is a no-op that says so. Values travel as
# @description psql variables, in the tenant's RLS scope.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param CHANNEL - required: the channel id (slug)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 CHANNEL=release-notes DRY_RUN=0 ./run -a do_spl_channel_restore
#------------------------------------------------------------------------------
do_spl_channel_restore() {
  do_require_bin yq psql || return 1
  local tenant="${TENANT_ID:-}" channel="${CHANNEL:-}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel slug, got: '$channel'"; return 1; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  if (( dry )); then
    do_log "OK DRY_RUN would restore #$channel in $tenant on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_channel_restore_run "$tenant" "$channel"
}

_spl_channel_restore_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v channel="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE channels SET deleted_at = NULL, deleted_by = NULL
WHERE tenant_id = :'tenant' AND channel_id = :'channel' AND deleted_at IS NOT NULL
RETURNING format('%s | %s | %s', tenant_id, channel_id, created_by);
COMMIT;
SQL
)" || { do_log "FATAL restore of #$2 in $1 failed: $out"; return 1; }
  if grep -q ' | ' <<<"$out"; then
    do_log "OK $1 #$2 restored ($GCP_ACCOUNT); members see it on their next load"
  else
    do_log "OK $1 #$2 is not a deleted channel: nothing to restore ($GCP_ACCOUNT)"
  fi
}
