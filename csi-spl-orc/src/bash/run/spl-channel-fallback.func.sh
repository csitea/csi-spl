#!/bin/bash
#------------------------------------------------------------------------------
# @description Switch the fallback responder off (or back on) for ONE channel
# @description (rdb 0068, SPL-997, specs/038 FR-039) in a cloud env's hub DB.
# @description A channel with no_fallback = true keeps the pre-SPL-997
# @description behaviour: a human post there that no member agent can hear
# @description reaches no agent. Meant for proof and test channels that have no
# @description agent on purpose (#live-proof); people's channels keep the
# @description default. Through the Cloud SQL proxy as the env's project
# @description service account; values travel as psql variables. Exactly one
# @description row must change, or the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param CHANNEL - required: the channel id (e.g. live-proof)
# @param NO_FALLBACK - required: 1 (switch the fallback off) or 0 (back on)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 CHANNEL=live-proof NO_FALLBACK=1 DRY_RUN=0 ./run -a do_spl_channel_fallback
#------------------------------------------------------------------------------
do_spl_channel_fallback() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" off="${NO_FALLBACK:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$ch" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
  [[ "$off" == 0 || "$off" == 1 ]] || { do_log "FATAL NO_FALLBACK must be 1 (off) or 0 (on), got: '$off'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local word=on; (( off )) && word=off
  if (( dry )); then
    do_log "OK DRY_RUN would switch the fallback responder $word for #$ch in $tenant on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_channel_fallback_run "$tenant" "$ch" "$off" "$word"
}

_spl_channel_fallback_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v ch="$2" -v off="$3" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE channels SET no_fallback = (:'off' = '1')
 WHERE tenant_id = :'tenant' AND channel_id = :'ch'
RETURNING format('%s | %s | no_fallback=%s', tenant_id, channel_id, no_fallback);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL no_fallback update of #$2 in $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched #$2 in $1: rolled back"; return 1; }
  do_log "OK the fallback responder is now $4 for #$2 in $1 ($GCP_ACCOUNT): $out"
}
