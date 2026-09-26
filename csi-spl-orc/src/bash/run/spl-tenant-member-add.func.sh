#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat one human on a cloud tenant. INSERT a tenant_memberships
# @description row with admitted_by='operator' (0006: an owner HUM-*, 'operator',
# @description or 'bootstrap') through the Cloud SQL proxy, as the env's
# @description project service account. ON CONFLICT (tenant_id, human_id) DO
# @description NOTHING: an existing member is reported and the role is left
# @description unchanged (do_spl_tenant_member_role changes a role). The same
# @description transaction stamps a pending tenant_invites row for that email
# @description (accepted_at IS NULL, expired or not) with accepted_by and
# @description accepted_at when one exists. EMAIL is resolved through
# @description human_identities to exactly one human, or the transaction is
# @description rolled back. A HUMAN_ID with no EMAIL accepts a pending invite
# @description whose email is on that human's identities. Values travel as
# @description psql variables (:'var'), never spliced into the SQL. The
# @description statement sets app.tenant_id for the transaction (rdb 0014).
# @description This is the OPERATOR path: outside the hub's RBAC checks.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param HUMAN_ID - a human id, e.g. HUM-4. Set this or EMAIL, not both.
# @param EMAIL - the human's email. Resolved through human_identities to
# @param   exactly one human_id, or the run refuses. Set this or HUMAN_ID,
# @param   not both. Stored and compared lower-cased.
# @param MEMBER_ROLE - required: a role id (biz_owner|product_owner|admin|
# @param   developer|tester|pure_agent|biz_customer|regular_user; legacy
# @param   owner|member map). An unknown id fails on the rbac_roles FK and
# @param   nothing changes.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 EMAIL=person@example.com MEMBER_ROLE=developer DRY_RUN=0 ./run -a do_spl_tenant_member_add
#------------------------------------------------------------------------------
do_spl_tenant_member_add() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" human="${HUMAN_ID:-}" email="${EMAIL:-}" role dry=1
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
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
  role="$(spl_role_id "${MEMBER_ROLE:-}")" || { do_log "FATAL MEMBER_ROLE must be a role id ($SPL_ROLE_IDS), got: '${MEMBER_ROLE:-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    if [[ -n "$email" ]]; then
      do_log "OK DRY_RUN would add $email to $tenant as $role (admitted_by=operator) and mark a pending invite for $email accepted on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    else
      do_log "OK DRY_RUN would add $human to $tenant as $role (admitted_by=operator) and mark a pending invite for that human's email accepted on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    fi
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_tenant_member_add_run "$tenant" "$human" "$email" "$role"
}

_spl_tenant_member_add_run() {
  local out rc=0 n_added n_already n_invite line who="$2" mark
  [[ -n "$who" ]] || who="$3"
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v tenant="$1" -v human="$2" -v email="$3" -v role="$4" <<'SQL'
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
\quit 1
\endif
SELECT CASE
         WHEN :'human' <> '' THEN :'human'
         ELSE (SELECT min(human_id) FROM human_identities WHERE email = :'email')
       END AS hid \gset
SELECT EXISTS (SELECT 1 FROM humans WHERE human_id = :'hid')::int AS humok \gset
\if :humok
\else
ROLLBACK;
SELECT format('refuse-missing-human | %s', :'hid');
\quit 1
\endif
INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
VALUES (:'tenant', :'hid', :'role', 'operator')
ON CONFLICT (tenant_id, human_id) DO NOTHING
RETURNING format('added | %s | %s | %s | %s', tenant_id, human_id, role, admitted_by);
SELECT (:ROW_COUNT = 1)::int AS inserted \gset
\if :inserted
\else
SELECT format('already | %s', :'hid');
\endif
UPDATE tenant_invites AS ti
   SET accepted_at = now(), accepted_by = :'hid'
 WHERE ti.tenant_id = :'tenant'
   AND ti.accepted_at IS NULL
   AND (
        (:'email' <> '' AND ti.email = :'email')
     OR (:'email' = '' AND ti.email IN (
           SELECT hi.email FROM human_identities hi
            WHERE hi.human_id = :'hid' AND hi.email IS NOT NULL))
       )
RETURNING format('invite | %s | %s | %s', ti.tenant_id, ti.email, ti.accepted_by);
COMMIT;
SQL
)" || rc=$?
  if (( rc != 0 )); then
    if grep -q '^refuse-human | ' <<<"$out"; then
      mark="$(grep '^refuse-human | ' <<<"$out" | head -n 1)"
      do_log "FATAL email $3 matches ${mark##*| } human(s) in human_identities; want exactly one"
    elif grep -q '^refuse-missing-human | ' <<<"$out"; then
      mark="$(grep '^refuse-missing-human | ' <<<"$out" | head -n 1)"
      do_log "FATAL human ${mark##*| } is not in humans"
    else
      do_log "FATAL member add of $who in $1 failed: $out"
    fi
    return 1
  fi
  n_added="$(grep -c '^added | ' <<<"$out" || true)"
  n_already="$(grep -c '^already | ' <<<"$out" || true)"
  n_invite="$(grep -c '^invite | ' <<<"$out" || true)"
  if (( n_added + n_already != 1 )); then
    do_log "FATAL member add of $who in $1 returned no single membership result: $out"
    return 1
  fi
  if (( n_added == 1 )); then
    line="$(grep '^added | ' <<<"$out" | head -n 1)"
    do_log "OK added $who to $1 ($GCP_ACCOUNT): $line"
  else
    line="$(grep '^already | ' <<<"$out" | head -n 1)"
    do_log "OK ${line#already | } is already a member of $1 ($GCP_ACCOUNT)"
  fi
  if (( n_invite > 0 )); then
    do_log "OK marked pending invite accepted ($GCP_ACCOUNT): $(grep '^invite | ' <<<"$out" | paste -sd ';' -)"
  else
    do_log "OK no pending invite to accept for $who on $1"
  fi
}
