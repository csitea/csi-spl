#!/bin/bash
#------------------------------------------------------------------------------
# @description Revoke an unaccepted invite for a cloud tenant: DELETE the
# @description tenant_invites row through the Cloud SQL proxy, as the env's
# @description project service account (do_gcp_pin_account: its key, never
# @description the owner account). An already-accepted invite is refused
# @description (the human is already a member; do not delete the invite).
# @description Values travel as psql variables (:'var', quoted by psql),
# @description never spliced into the SQL. Exactly one unaccepted row must
# @description be deleted, or the transaction is rolled back. The DSN is
# @description never logged. DRY_RUN=1 (default): print the revoke, call no
# @description cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param INVITE_EMAIL - required: the invitee's email
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev TENANT_ID=t1 INVITE_EMAIL=<email> DRY_RUN=0 ./run -a do_spl_hub_invite_revoke
#------------------------------------------------------------------------------
do_spl_hub_invite_revoke() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" email="${INVITE_EMAIL:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL INVITE_EMAIL is not an email: '$email'"; return 1; }
  email="${email,,}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would revoke the unaccepted invite for $email on $tenant on $SPL_SQL_CONN, as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_hub_invite_revoke_run "$tenant" "$email"
}

_spl_hub_invite_revoke_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v email="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT COUNT(*) FILTER (WHERE accepted_at IS NOT NULL)::int AS accepted
  FROM tenant_invites
 WHERE tenant_id = :'tenant' AND email = :'email' \gset
\if :accepted
ROLLBACK;
\echo already-accepted
\quit 1
\endif
DELETE FROM tenant_invites
 WHERE tenant_id = :'tenant' AND email = :'email' AND accepted_at IS NULL
RETURNING format('%s | %s | %s | %s', tenant_id, email, role, invited_by);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || {
    if grep -q 'already-accepted' <<<"$out"; then
      do_log "FATAL invite for $2 in $1 is already accepted: refusing"
    else
      do_log "FATAL invite revoke of $2 in $1 failed: $out"
    fi
    return 1
  }
  n="$(grep -c ' | ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched unaccepted invite $2 in $1: rolled back"; return 1; }
  do_log "OK revoked invite $2 in $1 ($GCP_ACCOUNT): $out"
}
