#!/bin/bash
#------------------------------------------------------------------------------
# @description Set one tenant's fallback responder list (rdb 0067, SPL-997,
# @description specs/038 FR-032/FR-036) in a cloud env's hub DB: an ordered
# @description list of agent ids. A human post that no agent it was meant for
# @description can hear goes to the FIRST agent of this list that is online;
# @description with none online (or no list) the hub picks the longest-online
# @description agent of the tenant. AGENTS=none clears the list. Through the
# @description Cloud SQL proxy as the env's project service account. The list
# @description travels as a psql variable (:'var'), never spliced into the
# @description SQL. Exactly one row must change, or the transaction is
# @description rolled back. An agent id need not be seated today: the hub
# @description skips an id that is not online.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param AGENTS - required: space-separated agent ids, first = first choice
# @param   (at most 20, no repeats), or none
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 AGENTS="CLE-001" DRY_RUN=0 ./run -a do_spl_tenant_responders
#------------------------------------------------------------------------------
do_spl_tenant_responders() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" dry=1 a list=() seen=" "
  spl_require_tenant_slug "$tenant" || return 1
  [[ -n "${AGENTS:-}" ]] || { do_log "FATAL AGENTS must name agent ids (e.g. \"CLE-001 GRK-3\") or be none"; return 1; }
  if [[ "$AGENTS" != none ]]; then
    read -r -a list <<<"$AGENTS"
    for a in "${list[@]}"; do
      [[ "$a" =~ ^[A-Z]{2,4}-[0-9]{1,12}$ && "$a" != HUM-* ]] || { do_log "FATAL AGENTS entry is not an agent id: '$a'"; return 1; }
      [[ "$seen" != *" $a "* ]] || { do_log "FATAL AGENTS names $a twice"; return 1; }
      seen+="$a "
    done
    (( ${#list[@]} >= 1 && ${#list[@]} <= 20 )) || { do_log "FATAL AGENTS holds ${#list[@]} ids; 1..20 allowed"; return 1; }
  fi
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set the fallback responders of $tenant to ${list[*]:-none} on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_responders_run "$tenant" "${list[*]:-}"
}

_spl_tenant_responders_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v agents="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
UPDATE tenants SET responders = COALESCE(string_to_array(NULLIF(:'agents', ''), ' '), '{}')
 WHERE tenant_id = :'tenant'
RETURNING format('%s | %s', tenant_id, coalesce(NULLIF(array_to_string(responders, ' '), ''), 'none'));
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL responders update of $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched tenant $1: rolled back"; return 1; }
  do_log "OK $1 fallback responders are now ${2:-none} ($GCP_ACCOUNT): $out"
}
