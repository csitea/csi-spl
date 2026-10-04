#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: show where a message landed in a cloud env's hub
# @description Postgres: its `messages` row and its `deliveries` rows, as one
# @description JSON line per message. The proof that a send went through the
# @description hub into the database, without ad hoc psql.
# @description Runs as the env's project service account in a throwaway
# @description CLOUDSDK_CONFIG (never the owner account, never the shared
# @description ~/.config/gcloud): the DSN comes from Secret Manager into a
# @description local, the Cloud SQL Auth Proxy listens on 127.0.0.1, psql gets
# @description the login through PG* env vars (never argv) and runs with
# @description default_transaction_read_only=on inside BEGIN READ ONLY.
# @description Prints no secret and no message body: body_len and the first
# @description 16 hex of sha256(body) let a caller match a body it sent.
# @description Select by MSG_ID, or TASK_ID, or the LAST n (default 5) rows of
# @description the tenant. Exit 2 when nothing matches.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (e.g. t1)
# @param MSG_ID (optional) - one message uuid
# @param TASK_ID (optional) - every message of one task/topic uuid
# @param LAST (optional) - the newest n messages of the tenant (1..50, default 5)
# @param SPL_SA_KEY (optional) - default $HOME/.gcp/.<org>/key-<project>.json
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev TENANT_ID=t1 MSG_ID=<uuid> ./run -a do_spl_db_message_show
# @example ENV=prd TENANT_ID=t1 LAST=3 ./run -a do_spl_db_message_show
#------------------------------------------------------------------------------
do_spl_db_message_show() {
  do_require_bin gcloud psql python3 || return 1
  do_spl_cloud_cnf || return 1
  local where
  where="$(spl_db_message_filter)" || return 1
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
    out="$(spl_psql_ro "$dsn" "$(spl_db_message_sql "$where")")"
    qrc=$?
    spl_sql_proxy_stop
    [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; exit 1; }
    [[ -n "$out" ]] || { do_log "FAIL no message in $SPL_PROJECT/$SPL_DB_NAME for tenant $TENANT_ID ($where)"; exit 2; }
    printf '%s\n' "$out"
    do_log "OK $(wc -l <<<"$out") message row(s) in $SPL_PROJECT/$SPL_DB_NAME for $TENANT_ID (read-only, as $GCP_ACCOUNT)"
  ) || rc=$?
  rm -rf "$cfg"
  return $rc
}

# spl_db_message_filter -> the SQL WHERE for TENANT_ID + MSG_ID | TASK_ID | LAST.
# Every value is checked against a strict pattern first, so the literals it
# interpolates cannot carry SQL.
spl_db_message_filter() {
  local t="${TENANT_ID:-}" u='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$t'"; return 1; }
  if [[ -n "${MSG_ID:-}" ]]; then
    [[ "$MSG_ID" =~ $u ]] || { do_log "FATAL MSG_ID must be a lowercase uuid, got: '$MSG_ID'"; return 1; }
    printf "m.tenant_id = '%s' AND m.msg_id = '%s'" "$t" "$MSG_ID"
  elif [[ -n "${TASK_ID:-}" ]]; then
    [[ "$TASK_ID" =~ $u ]] || { do_log "FATAL TASK_ID must be a lowercase uuid, got: '$TASK_ID'"; return 1; }
    printf "m.tenant_id = '%s' AND m.task_id = '%s'" "$t" "$TASK_ID"
  else
    local n="${LAST:-5}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 50 )) || { do_log "FATAL LAST must be 1..50, got: '$n'"; return 1; }
    printf "m.tenant_id = '%s' ORDER BY m.received_at DESC LIMIT %d" "$t" "$n"
  fi
}

# spl_db_message_sql <where> -> one json object per message, deliveries nested.
# No body and no env/sig bytes leave the database.
spl_db_message_sql() {
  cat <<EOF_SQL
SELECT json_build_object(
  'tenant_id', r.tenant_id, 'msg_id', r.msg_id, 'task_id', r.task_id, 'channel', r.channel,
  'kind', r.kind, 'from_box', r.from_box, 'from_id', r.from_id, 'to_box', r.to_box, 'to_id', r.to_id,
  'ts', r.ts, 'created_at', r.received_at, 'expires_at', r.expires_at,
  'body_len', r.body_len, 'body_sha256_16', r.body_sha,
  'deliveries', COALESCE((SELECT json_agg(json_build_object('to_box', d.to_box, 'state', d.state,
                           'received_at', d.received_at, 'sent_at', d.sent_at) ORDER BY d.to_box)
                          FROM deliveries d WHERE d.tenant_id = r.tenant_id AND d.msg_id = r.msg_id), '[]'::json))
FROM (SELECT m.tenant_id, m.msg_id, m.task_id, m.channel, m.kind, m.from_box, m.from_id, m.to_box, m.to_id,
             m.ts, m.received_at, m.expires_at, length(m.body) AS body_len,
             left(encode(sha256(convert_to(m.body, 'UTF8')), 'hex'), 16) AS body_sha
        FROM messages m WHERE $1) r
ORDER BY r.received_at;
EOF_SQL
}

# spl_psql_ro <proxy dsn> <sql> -> psql in a read-only transaction; the login
# travels in PG* env vars only, never argv. The transaction takes the
# operator row-level-security scope (rdb 0014, 017 FR-SEC-013): this is a
# cross-tenant operator read, and without the scope every tenant table shows
# zero rows to the hub login.
spl_psql_ro() {
  local parts
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$1")" || return 1
  local -a f
  mapfile -t f <<<"$parts"
  printf 'BEGIN READ ONLY;\nSET LOCAL app.rls_scope = '\''operator'\'';\n%s\nROLLBACK;\n' "$2" |
    PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}" \
    PGSSLMODE=disable PGCONNECT_TIMEOUT=15 PGOPTIONS='-c default_transaction_read_only=on' \
    psql -X -q -At -v ON_ERROR_STOP=1 2>&1
}
