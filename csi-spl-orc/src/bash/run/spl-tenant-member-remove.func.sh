#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove one member from a cloud tenant (workspace): DELETE its
# @description tenant_memberships row through the Cloud SQL proxy, as the env's
# @description project service account. The shell twin of the hub's
# @description DELETE /v1/members/{human_id} (store removeMemberTx): in ONE
# @description transaction it locks the tenant row, refuses the workspace's
# @description last enabled owner (ErrLastOwner) and its last enabled member
# @description holding members.invite (ErrLastAdmin), deletes exactly one row,
# @description and writes the member_activity row the hub writes (kind
# @description 'removed', actor 'operator') so the person's Activity log shows
# @description it; any refusal rolls everything back. Sessions: the hub keeps
# @description no per-tenant session row; every request re-reads the
# @description membership (the hub's door cache holds it at most 5 s), so the
# @description deleted row IS the revocation, exactly as on the hub path.
# @description EMAIL is resolved through human_identities to exactly one human,
# @description or the run refuses. Values travel as psql variables (:'var'),
# @description never spliced into the SQL; app.tenant_id is set for the
# @description transaction (rdb 0014). This is the OPERATOR path: outside the
# @description hub's RBAC checks (no self-removal rule, no demo ban).
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param HUMAN_ID - a human id, e.g. HUM-4. Set this or EMAIL, not both.
# @param EMAIL - the human's email, resolved through human_identities to
# @param   exactly one human_id, or the run refuses. Lower-cased.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=0 ./run -a do_spl_tenant_member_remove
# @example ENV=dev TENANT_ID=t1 EMAIL=person@example.com ./run -a do_spl_tenant_member_remove
#------------------------------------------------------------------------------
do_spl_tenant_member_remove() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" human="${HUMAN_ID:-}" email="${EMAIL:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  if [[ -n "$human" && -n "$email" ]] || [[ -z "$human" && -z "$email" ]]; then
    do_log "FATAL set exactly one of HUMAN_ID or EMAIL"
    return 1
  fi
  if [[ -n "$human" ]]; then
    [[ "$human" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  else
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL EMAIL is not an email: '$email'"; return 1; }
    email="${email,,}"
  fi
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would remove ${human:-$email} from $tenant (refusing the last owner or last admin) and record member_activity 'removed' by operator on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_member_remove_run "$tenant" "$human" "$email"
}

# _spl_tenant_member_remove_run <tenant> <human> <email>: run the transaction
# against SPL_PROXY_DSN and turn its marker lines into one verdict. A refusal
# is judged by its marker, not by psql's exit code (\quit carries none).
_spl_tenant_member_remove_run() {
  local out rc=0 who="${2:-$3}" mark
  out="$(_spl_tenant_member_remove_sql |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v tenant="$1" -v human="$2" -v email="$3" 2>&1)" || rc=$?
  if mark="$(spl_psql_mark "$out" refuse-human)"; then
    do_log "FATAL email $3 matches $mark human(s) in human_identities; want exactly one"
  elif mark="$(spl_psql_mark "$out" refuse-not-member)"; then
    do_log "FATAL $mark is not a member of $1: nothing removed"
  elif mark="$(spl_psql_mark "$out" refuse-last-owner)"; then
    do_log "FATAL $mark is the last owner of $1: refused, nothing removed"
  elif mark="$(spl_psql_mark "$out" refuse-last-admin)"; then
    do_log "FATAL $mark is the last admin (members.invite) of $1: refused, nothing removed"
  elif (( rc != 0 )); then
    do_log "FATAL member remove of $who in $1 failed: $out"
  elif [[ $(grep -c '^removed | ' <<<"$out") -ne 1 || $(grep -c '^audit | ' <<<"$out") -ne 1 ]]; then
    do_log "FATAL member remove of $who in $1 returned no single removed+audit result: $out"
  else
    do_log "OK removed from $1 ($GCP_ACCOUNT): $(grep '^removed | ' <<<"$out"); $(grep '^audit | ' <<<"$out")"
    return 0
  fi
  return 1
}

# _spl_tenant_member_remove_sql: the one-transaction removal script. Each
# refusal ROLLBACKs, prints "refuse-<why> | <value>" and quits; success prints
# "removed | tenant | human | role" and "audit | activity_id | subject | actor".
_spl_tenant_member_remove_sql() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT CASE
         WHEN :'human' <> '' THEN 1
         ELSE (SELECT count(DISTINCT human_id)::int FROM human_identities WHERE email = :'email')
       END AS nhum \gset
SELECT (:nhum = 1)::int AS onehuman \gset
\if :onehuman
\else
ROLLBACK;
SELECT format('refuse-human | %s', :nhum);
\quit
\endif
SELECT CASE
         WHEN :'human' <> '' THEN :'human'
         ELSE (SELECT min(human_id) FROM human_identities WHERE email = :'email')
       END AS hid \gset
SELECT count(*) AS locked FROM (SELECT 1 FROM tenants WHERE tenant_id = :'tenant' FOR UPDATE) AS l \gset
SELECT count(*)::int AS ismember, coalesce(max(m.role), '') AS cur,
       coalesce(bool_or(r.tenant_owner), false)::int AS isowner
  FROM tenant_memberships m JOIN rbac_roles r ON r.role_id = m.role
 WHERE m.tenant_id = :'tenant' AND m.human_id = :'hid' \gset
\if :ismember
\else
ROLLBACK;
SELECT format('refuse-not-member | %s', :'hid');
\quit
\endif
SELECT (:isowner = 0 OR EXISTS (
          SELECT 1 FROM tenant_memberships m
            JOIN rbac_roles r ON r.role_id = m.role JOIN humans h ON h.human_id = m.human_id
           WHERE m.tenant_id = :'tenant' AND m.human_id <> :'hid' AND r.tenant_owner
             AND h.disabled_at IS NULL AND m.disabled_at IS NULL))::int AS ownerok \gset
\if :ownerok
\else
ROLLBACK;
SELECT format('refuse-last-owner | %s', :'hid');
\quit
\endif
SELECT (NOT EXISTS (SELECT 1 FROM rbac_role_permissions
                     WHERE role_id = :'cur' AND permission_id = 'members.invite')
        OR EXISTS (
          SELECT 1 FROM tenant_memberships m
            JOIN rbac_role_permissions g ON g.role_id = m.role AND g.permission_id = 'members.invite'
            JOIN humans h ON h.human_id = m.human_id
           WHERE m.tenant_id = :'tenant' AND m.human_id <> :'hid'
             AND h.disabled_at IS NULL AND m.disabled_at IS NULL))::int AS adminok \gset
\if :adminok
\else
ROLLBACK;
SELECT format('refuse-last-admin | %s', :'hid');
\quit
\endif
DELETE FROM tenant_memberships WHERE tenant_id = :'tenant' AND human_id = :'hid'
RETURNING format('removed | %s | %s | %s', tenant_id, human_id, role);
SELECT (:ROW_COUNT = 1)::int AS onerow \gset
\if :onerow
\else
ROLLBACK;
SELECT format('refuse-not-member | %s', :'hid');
\quit
\endif
INSERT INTO member_activity (tenant_id, subject_hum, actor_hum, kind, detail)
VALUES (:'tenant', :'hid', 'operator', 'removed', '')
RETURNING format('audit | %s | %s | %s', activity_id, subject_hum, actor_hum);
COMMIT;
SQL
}
