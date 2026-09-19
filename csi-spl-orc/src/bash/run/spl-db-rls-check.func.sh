#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: does row level security (rdb 0014, 017 FR-SEC-013)
# @description bind the hub in a cloud env? Prints one JSON line: the hub's
# @description Postgres login (the DSN secret's user), its rolsuper /
# @description rolbypassrls, whether 0014 is applied, and per tenant_id table
# @description [relrowsecurity, relforcerowsecurity].
# @description Same path as do_spl_db_message_show: the env's project SA key in
# @description a throwaway CLOUDSDK_CONFIG, the Cloud SQL Auth Proxy on
# @description 127.0.0.1, psql in BEGIN READ ONLY. Reads only the catalog.
# @description Also (017 FR-SEC-014): 0021 fail-closed applied or not, and
# @description "liftable" - every way the login could switch RLS off itself
# @description (owns / can SET ROLE to the owner of a tenant_id table, or to
# @description a superuser / BYPASSRLS role); store.HubRoleCanLiftRLS's query.
# @description Exit 3: the login is superuser or BYPASSRLS (every policy
# @description skipped). Exit 4: EXPECT_RLS=1 and a tenant_id table lacks
# @description ENABLE + FORCE (0014 not applied, or a table added without it).
# @description Exit 5: EXPECT_NOT_LIFTABLE=1 and the login can lift RLS.
# @param ENV - required: dev or prd
# @param EXPECT_RLS (optional) - 1: also require every tenant_id table forced
# @param EXPECT_NOT_LIFTABLE (optional) - 1: also require that the login cannot lift RLS
# @param SPL_SA_KEY (optional) - default $HOME/.gcp/.<org>/key-<project>.json
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev ./run -a do_spl_db_rls_check
# @example ENV=prd EXPECT_RLS=1 ./run -a do_spl_db_rls_check
#------------------------------------------------------------------------------
do_spl_db_rls_check() {
  do_require_bin gcloud psql python3 || return 1
  do_spl_cloud_cnf || return 1
  local key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }
  local cfg rc=0
  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    GCP_ACCOUNT="$(do_gcp_isolated_active_account)" || exit 1
    export GCP_ACCOUNT
    local cloud_dsn dsn out qrc
    cloud_dsn="$(spl_read_dsn)"
    [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; exit 1; }
    spl_sql_proxy_start || exit 1
    dsn="$(spl_proxy_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" ||
      { spl_sql_proxy_stop; do_log "FATAL unexpected DSN shape in $SPL_DSN_SECRET"; exit 1; }
    out="$(spl_psql_ro "$dsn" "$(spl_db_rls_sql)")"
    qrc=$?
    spl_sql_proxy_stop
    [[ $qrc == 0 && -n "$out" ]] || { do_log "FATAL read-only catalog query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; exit 1; }
    printf '%s\n' "$out"
    spl_db_rls_verdict "$out" "${EXPECT_RLS:-0}" "${EXPECT_NOT_LIFTABLE:-0}"
  ) || rc=$?
  rm -rf "$cfg"
  return $rc
}

# spl_db_rls_sql -> one JSON object: the login's role flags, 0014 applied or
# not, and every tenant_id table's [enable, force]. Catalog only, no row data.
spl_db_rls_sql() {
  cat <<'EOF_SQL'
SELECT json_build_object(
  'role', r.rolname, 'superuser', r.rolsuper, 'bypassrls', r.rolbypassrls,
  'migration_0014', EXISTS (SELECT 1 FROM spool_schema_migrations WHERE filename = '0014_tenant_rls.sql'),
  'migration_0021_fail_closed', EXISTS (SELECT 1 FROM spool_schema_migrations WHERE filename = '0021_rls_fail_closed.sql'),
  'liftable', (SELECT COALESCE(json_agg(why ORDER BY why), '[]'::json) FROM (
      SELECT 'can SET ROLE to ' || x.rolname || ' (superuser or BYPASSRLS)' AS why FROM pg_roles x
       WHERE x.rolname <> current_user AND (x.rolsuper OR x.rolbypassrls) AND pg_has_role(current_user, x.oid, 'MEMBER')
      UNION ALL
      SELECT 'owns or can SET ROLE to the owner of ' || c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
       WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND pg_has_role(current_user, c.relowner, 'MEMBER')) l),
  'tables', (SELECT json_object_agg(c.relname, json_build_array(c.relrowsecurity, c.relforcerowsecurity) ORDER BY c.relname)
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
              WHERE n.nspname = current_schema() AND c.relkind = 'r'))
FROM pg_roles r WHERE r.rolname = current_user;
EOF_SQL
}

# spl_db_rls_verdict <json> <expect_rls 0|1> [<expect_not_liftable 0|1>] -> exit 0 / 3 / 4 / 5 with one log line.
spl_db_rls_verdict() {
  local v
  v="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1]); want = sys.argv[2] == "1"; want_nl = sys.argv[3] == "1"
lift = d.get("liftable") or []
tabs = d.get("tables") or {}
forced = sorted(t for t, (on, force) in tabs.items() if on and force)
open_ = sorted(set(tabs) - set(forced))
if d.get("superuser") or d.get("bypassrls"):
    print("3 role %s is superuser/BYPASSRLS: every RLS policy is skipped" % d.get("role"))
elif want and (open_ or not tabs):
    print("4 RLS expected but %d/%d tenant_id tables forced (open: %s)" % (len(forced), len(tabs), ",".join(open_) or "none found"))
elif want_nl and lift:
    print("5 role %s can lift RLS itself (%d path(s), first: %s)" % (d.get("role"), len(lift), lift[0]))
else:
    print("0 role %s is bound by RLS; %d/%d tenant_id tables forced; 0014 applied=%s; 0021 fail-closed applied=%s; liftable=%d%s" % (
        d.get("role"), len(forced), len(tabs), d.get("migration_0014"), d.get("migration_0021_fail_closed"), len(lift),
        (" (first: %s)" % lift[0]) if lift else ""))
' "$1" "$2" "${3:-0}")" || { do_log "FATAL cannot parse the catalog JSON: $1"; return 1; }
  local code="${v%% *}" msg="${v#* }"
  if [[ "$code" == 0 ]]; then do_log "OK $msg"; else do_log "FAIL $msg"; fi
  return "$code"
}
