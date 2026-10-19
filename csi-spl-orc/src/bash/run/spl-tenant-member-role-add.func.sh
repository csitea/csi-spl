#!/bin/bash
#------------------------------------------------------------------------------
# @description ADD one role to a tenant member's role set in a cloud env's hub
# @description DB (025 §10.2, rdb 0201 tenant_member_roles), keeping the
# @description PRIMARY role (tenant_memberships.role) as it is. Its sibling
# @description do_spl_tenant_member_role REPLACES the primary, and trigger 1 of
# @description 0201 then drops the old primary from the set; so a business
# @description owner who should also be a developer needs this action, not
# @description that one (SPL-2588). Through the Cloud SQL proxy as the env's
# @description project service account; values travel as psql variables
# @description (:'var', quoted by psql), never spliced into the SQL. The human
# @description must already be a member, or the transaction is rolled back. A
# @description role the member already holds is a no-op. demo_user and
# @description channel_guest are exclusive (0201 trigger 2): the insert fails
# @description and nothing changes.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param HUMAN_ID - required: e.g. HUM-4 (a member: an invite turns into one
# @param   when it is accepted)
# @param MEMBER_ROLE - required: the role id to add (biz_owner|product_owner|
# @param   admin|developer|tester|pure_agent|biz_customer|regular_user; legacy
# @param   owner|member map); an unknown id fails on the rbac_roles FK
# @description This is the OPERATOR path: it is outside the hub's RBAC checks.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=example-ws HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=0 ./run -a do_spl_tenant_member_role_add
#------------------------------------------------------------------------------
do_spl_tenant_member_role_add() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" human="${HUMAN_ID:-}" role dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$human" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  role="$(spl_role_id "${MEMBER_ROLE:-}")" || { do_log "FATAL MEMBER_ROLE must be a role id ($SPL_ROLE_IDS), got: '${MEMBER_ROLE:-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would add $role to the role set of $human in $tenant (primary role kept) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_member_role_add_run "$tenant" "$human" "$role"
}

# _spl_tenant_member_role_add_run <tenant> <human> <role>: one transaction.
# Output lines: 'refuse-not-member | ...', or 'added | ...' (absent when the
# role was already held) and then 'set | tenant | human | primary | roles'.
_spl_tenant_member_role_add_run() {
  local out set
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v human="$2" -v role="$3" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT count(*) = 1 AS member FROM tenant_memberships
 WHERE tenant_id = :'tenant' AND human_id = :'human' \gset
\if :member
INSERT INTO tenant_member_roles (tenant_id, human_id, role_id, granted_by)
VALUES (:'tenant', :'human', :'role', 'operator')
ON CONFLICT DO NOTHING
RETURNING format('added | %s | %s | %s', tenant_id, human_id, role_id);
SELECT format('set | %s | %s | %s | %s', m.tenant_id, m.human_id, m.role,
              string_agg(r.role_id, ',' ORDER BY r.role_id))
  FROM tenant_memberships m
  JOIN tenant_member_roles r ON r.tenant_id = m.tenant_id AND r.human_id = m.human_id
 WHERE m.tenant_id = :'tenant' AND m.human_id = :'human'
 GROUP BY m.tenant_id, m.human_id, m.role;
COMMIT;
\else
SELECT format('refuse-not-member | %s | %s', :'tenant', :'human');
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL adding $3 to $2 in $1 failed: $out"; return 1; }
  if grep -q '^refuse-not-member | ' <<<"$out"; then
    do_log "FATAL $2 is not a member of $1 (an open invite is not a membership: accept it first): nothing changed"
    return 1
  fi
  set="$(grep '^set | ' <<<"$out")"
  [[ -n "$set" ]] || { do_log "FATAL no role set read back for $2 in $1: $out"; return 1; }
  [[ ",${set##* | }," == *",$3,"* ]] || { do_log "FATAL $3 is not in the role set of $2 in $1 after the insert: $set"; return 1; }
  if grep -q '^added | ' <<<"$out"; then
    do_log "OK $1 member $2 now also holds $3 ($GCP_ACCOUNT): $set"
  else
    do_log "OK $1 member $2 already held $3, nothing changed ($GCP_ACCOUNT): $set"
  fi
}
