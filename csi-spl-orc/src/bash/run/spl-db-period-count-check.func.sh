#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: prove the month-quota counter of one tenant (rdb
# @description 0023 message_period_counts, specs/027 T040) equals the row count
# @description it replaced: SUM(messages) of the counters of the current UTC
# @description period against COUNT(*) of messages received since that period
# @description start. Prints one JSON line {tenant_id, period_start, counter,
# @description rows, equal}. Exit 0 when equal, 3 when they differ, 1 on error.
# @description Same identity and transport as do_spl_db_message_show: the env's
# @description project service account in a throwaway CLOUDSDK_CONFIG, the DSN
# @description from Secret Manager, the Cloud SQL Auth Proxy on 127.0.0.1, psql
# @description in BEGIN READ ONLY with the operator row-level-security scope.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (e.g. t1)
# @param SPL_SA_KEY (optional) - default $HOME/.gcp/.<org>/key-<project>.json
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_db_period_count_check
#------------------------------------------------------------------------------
do_spl_db_period_count_check() {
  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  if [[ "$provider" == none ]]; then
    do_require_bin psql python3 || return 1
  else
    do_require_bin gcloud psql python3 || return 1
  fi
  do_spl_cloud_cnf || return 1
  local t="${TENANT_ID:-}"
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$t'"; return 1; }
  if [[ "$provider" == none ]]; then
    local dsn none_rc=0
    spl_db_runtime_local || return 1
    _spl_db_period_count_query || none_rc=$?
    unset dsn
    return "$none_rc"
  fi
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
    spl_db_runtime_local || exit 1
    _spl_db_period_count_query
    exit $?
  ) || rc=$?
  rm -rf "$cfg"
  return $rc
}

# _spl_db_period_count_query -> the read, once $dsn is the local login.
# Exit 3 when the counter and the row count differ. Stops the proxy.
_spl_db_period_count_query() {
  local out qrc
  out="$(spl_psql_ro "$dsn" "$(spl_db_period_count_sql "$t")")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  printf '%s\n' "$out"
  spl_db_period_count_equal "$out" || {
    do_log "FAIL message_period_counts differs from COUNT(*) for $t in $SPL_PROJECT/$SPL_DB_NAME"
    return 3
  }
  do_log "OK message_period_counts equals COUNT(*) for $t in $SPL_PROJECT/$SPL_DB_NAME (read-only, as ${GCP_ACCOUNT:-})"
}

# spl_db_period_count_sql <tenant slug> -> one json object: the counter SUM and
# the row COUNT since the current UTC period start. The caller has checked the
# slug against a strict pattern, so the literal it interpolates carries no SQL.
spl_db_period_count_sql() {
  cat <<EOF_SQL
WITH p AS (SELECT date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS start),
c AS (SELECT COALESCE(SUM(messages), 0) AS n FROM message_period_counts, p
       WHERE tenant_id = '$1' AND period_start >= p.start),
r AS (SELECT COUNT(*) AS n FROM messages, p WHERE tenant_id = '$1' AND received_at >= p.start)
SELECT json_build_object('tenant_id', '$1', 'period_start', p.start, 'counter', c.n, 'rows', r.n, 'equal', c.n = r.n)
FROM p, c, r;
EOF_SQL
}

# spl_db_period_count_equal <json line> -> 0 when its "equal" is true.
spl_db_period_count_equal() {
  python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("equal") is True else 1)' "$1" 2>/dev/null
}
