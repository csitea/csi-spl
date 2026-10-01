#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove unused DEV test workspaces (owner, t1 bea3a4e6,
# @description 2026-10-01: "if they just create clutter, remove them"). DEV
# @description only, an explicit list, never a mapped tenant (env.dns.
# @description mapped_tenants) and never one with a message or a ready host.
# @description BEFORE any delete every row of every table with a tenant_id
# @description column for those tenants goes to a 0600 JSON-lines backup
# @description (one {"table","rows"} object per table). Then ONE transaction:
# @description DELETE FROM tenants (ON DELETE CASCADE takes channels, seats,
# @description roles, counters; the release trigger marks the host removing),
# @description and a host row that never had an address (not mapped, status
# @description pending / failed / removing) is closed as removed, so the host
# @description reconcile (workflow 40) never runs terraform for an address
# @description that never existed. payment_checkouts has no FK: the audit
# @description rows stay. A list entry with no tenant row only closes its host
# @description row. Dry run unless DRY_RUN=0 (the backup is written either way).
# @param ENV - required: dev (prd is refused)
# @param PURGE_TENANTS - required: space-separated tenant ids
# @param PURGE_BACKUP (optional) - backup file, default <state dir>/backups/tenant-test-purge.<utc>.jsonl
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev PURGE_TENANTS="m2card3 m2card4" DRY_RUN=0 ./run -a do_spl_tenant_test_purge
#------------------------------------------------------------------------------
do_spl_tenant_test_purge() {
  do_require_bin yq jq psql || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL removing test workspaces is DEV only (ENV=${ENV:-})"; return 1; }
  local dry=1 t
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local -a list=()
  read -r -a list <<<"${PURGE_TENANTS:-}"
  (( ${#list[@]} )) || { do_log "FATAL PURGE_TENANTS is empty (no default)"; return 1; }
  for t in "${list[@]}"; do
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL invalid tenant id '$t'"; return 1; }
  done
  do_spl_cloud_cnf || return 1
  local mapped
  mapped=" $(yq -r '.env.dns.mapped_tenants // [] | .[]' "$SPL_CNF" | tr '\n' ' ') "
  for t in "${list[@]}"; do
    [[ "$mapped" != *" $t "* ]] || { do_log "FATAL $t is a mapped tenant (env.dns.mapped_tenants): never purged"; return 1; }
  done
  local bk="${PURGE_BACKUP:-$SPL_STATE_DIR/backups/tenant-test-purge.$(date -u +%Y%m%dT%H%M%SZ).jsonl}"
  mkdir -p "$(dirname "$bk")" && chmod 700 "$(dirname "$bk")" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_test_purge_run "$dry" "$bk" "${list[@]}"
}

# spl_tenant_test_purge_arr <id...> -> ARRAY['a','b']::text[] (ids are slug-checked)
spl_tenant_test_purge_arr() {
  local IFS=,
  local -a q=("${@/#/\'}"); q=("${q[@]/%/\'}")
  printf "ARRAY[%s]::text[]" "${q[*]}"
}

_spl_tenant_test_purge_psql() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -P pager=off "$@"
}

_spl_tenant_test_purge_run() {
  local dry="$1" bk="$2"; shift 2
  local arr t ex msgs mem host bad=0
  arr="$(spl_tenant_test_purge_arr "$@")"
  local guard
  guard="$(_spl_tenant_test_purge_psql <<SQL
SET app.rls_scope = 'operator';
SELECT 'row', l.t, (x.tenant_id IS NOT NULL),
       (SELECT count(*) FROM messages m WHERE m.tenant_id = l.t),
       (SELECT count(*) FROM tenant_memberships s WHERE s.tenant_id = l.t),
       coalesce(h.status, '-')
  FROM unnest($arr) AS l(t)
  LEFT JOIN tenants x ON x.tenant_id = l.t
  LEFT JOIN tenant_hosts h ON h.tenant_id = l.t;
SQL
)" || { do_log "FATAL cannot read the tenants"; return 1; }
  while read -r _ t ex msgs mem host; do
    do_log "INFO $t exists=$ex messages=$msgs members=$mem host=$host"
    (( msgs == 0 )) || { do_log "FATAL $t has $msgs message(s): not an unused test workspace"; bad=1; }
    [[ "$host" != ready ]] || { do_log "FATAL $t has a ready host: deprovision it first"; bad=1; }
  done < <(grep '^row ' <<<"$guard")
  (( bad == 0 )) || return 1

  local tables q="" tb
  tables="$(_spl_tenant_test_purge_psql -c "SELECT table_name FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'tenant_id' ORDER BY table_name")" || return 1
  q="SET app.rls_scope = 'operator';"$'\n'
  for tb in $tables; do
    [[ "$tb" =~ ^[a-z_0-9]+$ ]] || continue
    q+="SELECT json_build_object('table', '$tb', 'rows', coalesce(json_agg(x), '[]'::json)) FROM $tb x WHERE x.tenant_id = ANY($arr);"$'\n'
  done
  (umask 077 && _spl_tenant_test_purge_psql <<<"$q" >"$bk") || { do_log "FATAL backup failed: nothing deleted"; return 1; }
  jq -e -s 'length > 0' "$bk" >/dev/null || { do_log "FATAL backup $bk is empty or not JSON: nothing deleted"; return 1; }
  do_log "INFO backup: $bk ($(jq -s '[.[].rows | length] | add' "$bk") rows over $(wc -l <"$bk") tables, mode $(stat -c %a "$bk"))"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN=1: nothing deleted (DRY_RUN=0 removes: $*)"
    return 0
  fi

  _spl_tenant_test_purge_psql <<SQL || { do_log "FATAL the purge transaction failed: nothing deleted"; return 1; }
BEGIN;
SET LOCAL app.rls_scope = 'operator';
DELETE FROM tenants WHERE tenant_id = ANY($arr);
UPDATE tenant_hosts SET status = 'removed', detail = 'test workspace purged before any address existed', updated_at = now()
 WHERE tenant_id = ANY($arr) AND status IN ('pending', 'failed', 'removing');
COMMIT;
SQL
  local after
  after="$(_spl_tenant_test_purge_psql <<SQL
SET app.rls_scope = 'operator';
SELECT 'after', (SELECT count(*) FROM tenants WHERE tenant_id = ANY($arr)),
       (SELECT count(*) FROM tenant_hosts WHERE tenant_id = ANY($arr) AND status <> 'removed');
SQL
)" || return 1
  read -r _ t host < <(grep '^after ' <<<"$after")
  [[ "$t" == 0 && "$host" == 0 ]] || { do_log "FATAL after the purge: $t tenant(s) and $host open host row(s) remain"; return 1; }
  do_log "OK removed $# dev test workspace(s): $* (host rows closed as removed; backup $bk)"
}
