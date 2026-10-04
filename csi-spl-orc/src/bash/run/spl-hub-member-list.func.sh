#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: list a cloud tenant's members and its invites from
# @description the hub Postgres, as one JSON line each — "does prd already have
# @description <someone>?" without ad hoc psql. A member line carries the
# @description human id, email, display name, role, when and by whom admitted,
# @description disabled_at, and the sign-in providers with the last login; an
# @description invite line carries the email, role, created / expires /
# @description accepted and the mail count.
# @description Same path as do_spl_db_message_show: the env's project service
# @description account in a throwaway CLOUDSDK_CONFIG, the DSN from Secret
# @description Manager into a local, the Cloud SQL Auth Proxy on 127.0.0.1,
# @description psql in BEGIN READ ONLY with default_transaction_read_only=on.
# @description Prints no secret. Exit 2 when nothing matches.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (e.g. t1)
# @param MATCH (optional) - keep only rows whose email or display name
# @param   contains this text (case-insensitive; letters, digits, . _ @ + -)
# @param SPL_SA_KEY (optional) - default $HOME/.gcp/.<org>/key-<project>.json
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_hub_member_list
# @example ENV=prd TENANT_ID=t1 MATCH=example.com ./run -a do_spl_hub_member_list
#------------------------------------------------------------------------------
do_spl_hub_member_list() {
  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  if [[ "$provider" == none ]]; then
    do_require_bin psql python3 || return 1
  else
    do_require_bin gcloud psql python3 || return 1
  fi
  do_spl_cloud_cnf || return 1
  local sql
  sql="$(spl_hub_member_list_sql)" || return 1
  if [[ "$provider" == none ]]; then
    local dsn none_rc=0
    spl_db_runtime_local || return 1
    _spl_hub_member_list_query || none_rc=$?
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
    _spl_hub_member_list_query
    exit $?
  ) || rc=$?
  rm -rf "$cfg"
  return $rc
}

# _spl_hub_member_list_query -> the read, once $dsn is the local login.
# Exit 2 when nothing matches. Stops the proxy.
_spl_hub_member_list_query() {
  local out qrc
  out="$(spl_psql_ro "$dsn" "$sql")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  [[ -n "$out" ]] || { do_log "FAIL no member or invite in $SPL_PROJECT/$SPL_DB_NAME for tenant $TENANT_ID${MATCH:+ matching '$MATCH'}"; return 2; }
  printf '%s\n' "$out"
  do_log "OK $(grep -c '"type" : "member"' <<<"$out") member(s), $(grep -c '"type" : "invite"' <<<"$out") invite(s) in $SPL_PROJECT/$SPL_DB_NAME for $TENANT_ID${MATCH:+ matching '$MATCH'} (read-only, as ${GCP_ACCOUNT:-})"
}

# spl_hub_member_list_sql -> the member + invite query for TENANT_ID [MATCH].
# Both values are checked against a strict pattern first, so the literals it
# interpolates cannot carry SQL.
spl_hub_member_list_sql() {
  local t="${TENANT_ID:-}" m="${MATCH:-}" mf_h='' mf_i=''
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$t'"; return 1; }
  if [[ -n "$m" ]]; then
    [[ "$m" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] || { do_log "FATAL MATCH must be 1..64 of letters, digits, . _ @ + -, got: '$m'"; return 1; }
    m="${m,,}"
    mf_h=" AND (lower(coalesce(h.email, '')) LIKE '%$m%' OR lower(coalesce(h.display_name, '')) LIKE '%$m%')"
    mf_i=" AND i.email LIKE '%$m%'"
  fi
  cat <<EOF_SQL
SELECT json_build_object('type', 'member', 'tenant_id', tm.tenant_id, 'human_id', h.human_id,
  'email', h.email, 'display_name', h.display_name, 'role', tm.role, 'admitted_by', tm.admitted_by,
  'member_since', tm.created_at, 'disabled_at', h.disabled_at,
  'identities', COALESCE((SELECT json_agg(json_build_object('provider', hi.provider, 'last_login_at', hi.last_login_at)
                                  ORDER BY hi.provider)
                          FROM human_identities hi WHERE hi.human_id = h.human_id), '[]'::json))
FROM tenant_memberships tm JOIN humans h ON h.human_id = tm.human_id
WHERE tm.tenant_id = '$t'$mf_h
ORDER BY tm.created_at;
SELECT json_build_object('type', 'invite', 'tenant_id', i.tenant_id, 'email', i.email, 'role', i.role,
  'invited_by', i.invited_by, 'created_at', i.created_at, 'expires_at', i.expires_at,
  'accepted_at', i.accepted_at, 'accepted_by', i.accepted_by, 'mail_count', i.mail_count)
FROM tenant_invites i
WHERE i.tenant_id = '$t'$mf_i
ORDER BY i.created_at;
EOF_SQL
}
