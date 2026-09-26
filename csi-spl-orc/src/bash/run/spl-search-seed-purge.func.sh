#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete a search seed made by do_spl_search_seed (specs/022 §9,
# @description CLE-34992): the tenant row, whose ON DELETE CASCADE takes its
# @description messages, channels and counters. Only a tenant id starting with
# @description "seed-" is accepted, and only on DEV, so this can never delete a
# @description real tenant. Dry run unless DRY_RUN=0: prints the row count.
# @param ENV - required: dev (prd is refused)
# @param SEED_TENANT (optional) - default seed-search; must match ^seed-[a-z0-9-]{1,26}$
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_search_seed_purge
#------------------------------------------------------------------------------
do_spl_search_seed_purge() {
  do_require_bin yq psql || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL the search seed is DEV only (ENV=${ENV:-})"; return 1; }
  local t="${SEED_TENANT:-seed-search}" dry=1
  [[ "$t" =~ ^seed-[a-z0-9-]{1,26}$ ]] || { do_log "FATAL SEED_TENANT must match ^seed-[a-z0-9-]{1,26}\$, got: $t"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_search_seed_purge_run "$t" "$dry"
}

# spl_search_seed_purge_sql <tenant> <dry>: counts, then (dry=0) deletes.
spl_search_seed_purge_sql() {
  echo "SET statement_timeout = 0;"
  echo "SELECT set_config('app.rls_scope', 'operator', false);"
  echo "SELECT count(*) AS messages_before FROM messages WHERE tenant_id = '$1';"
  [[ "$2" == 0 ]] && echo "DELETE FROM tenants WHERE tenant_id = '$1' AND tenant_id LIKE 'seed-%';" &&
    echo "SELECT count(*) AS messages_after FROM messages WHERE tenant_id = '$1';"
  return 0
}

_spl_search_seed_purge_run() {
  spl_search_seed_purge_sql "$1" "$2" | spl_pg_env "$SPL_PROXY_DSN" psql -X -q -v ON_ERROR_STOP=1 -P pager=off -f - || return 1
  [[ "$2" == 1 ]] && do_log "INFO DRY_RUN=1: nothing deleted (DRY_RUN=0 deletes $1)"
  return 0
}
