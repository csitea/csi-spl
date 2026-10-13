#!/bin/bash
#------------------------------------------------------------------------------
# @description Set the "AI agents" switch (SPL-1684, rdb 0189) in a cloud env's
# @description hub DB: the workspace default (no CHANNEL), or one channel's
# @description own switch. Off, the hub does not fan the channel's posts out to
# @description its member agents nor to the fallback responder, and the
# @description unanswered sweep leaves them out; a DM to an agent and an
# @description @agent dispatch still reach it. The workspace default is the
# @description tenants.settings key channel_ai_agents (absent = on, every
# @description channel as before); a channel's own value wins over it, and
# @description AI_AGENTS=default clears it back to the workspace default. The
# @description owner's decision for a workspace: its default off, set once
# @description here; a channel admin switches a channel on in its Properties.
# @description Through the Cloud SQL proxy as the env's project service
# @description account; values travel as psql variables. Exactly one row must
# @description change, or the transaction is rolled back.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param AI_AGENTS - required: on, off or default (default = remove the value)
# @param CHANNEL (optional) - the channel id; unset = the workspace default
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 AI_AGENTS=off DRY_RUN=0 ./run -a do_spl_channel_ai_agents
# @example ENV=dev TENANT_ID=t1 CHANNEL=dispatch AI_AGENTS=on DRY_RUN=0 ./run -a do_spl_channel_ai_agents
#------------------------------------------------------------------------------
do_spl_channel_ai_agents() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" val="${AI_AGENTS:-}" dry=1 where
  spl_require_tenant_slug "$tenant" || return 1
  [[ -z "$ch" || "$ch" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
  [[ "$val" == on || "$val" == off || "$val" == default ]] \
    || { do_log "FATAL AI_AGENTS must be on, off or default, got: '$val'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  where="the workspace default of $tenant"
  [[ -n "$ch" ]] && where="#$ch in $tenant"
  if (( dry )); then
    do_log "OK DRY_RUN would set the AI agents switch $val for $where on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_channel_ai_agents_run "$tenant" "$ch" "$val" "$where"
}

# _spl_channel_ai_agents_sql <channel>: the statement for one channel or for
# the workspace default; every value is a psql variable.
_spl_channel_ai_agents_sql() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SQL
  if [[ -n "$1" ]]; then
    cat <<'SQL'
UPDATE channels SET ai_agents = CASE :'val' WHEN 'default' THEN NULL ELSE :'val' = 'on' END, ai_agents_at = now()
 WHERE tenant_id = :'tenant' AND channel_id = :'ch' AND archived_at IS NULL
RETURNING format('%s | %s | ai_agents=%s', tenant_id, channel_id, coalesce(ai_agents::text, 'default'));
SQL
  else
    cat <<'SQL'
UPDATE tenants SET settings = CASE :'val' WHEN 'default' THEN coalesce(settings, '{}'::jsonb) - 'channel_ai_agents'
       ELSE coalesce(settings, '{}'::jsonb) || jsonb_build_object('channel_ai_agents', :'val' = 'on') END
 WHERE tenant_id = :'tenant'
RETURNING format('%s | channel_ai_agents=%s', tenant_id, coalesce(settings->>'channel_ai_agents', 'default'));
SQL
  fi
  cat <<'SQL'
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
}

_spl_channel_ai_agents_run() {
  local out n
  out="$(_spl_channel_ai_agents_sql "$2" | spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$1" -v ch="$2" -v val="$3")" || { do_log "FATAL AI agents switch of $4 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched $4: rolled back"; return 1; }
  do_log "OK the AI agents switch is now $3 for $4 ($GCP_ACCOUNT): $out"
}
