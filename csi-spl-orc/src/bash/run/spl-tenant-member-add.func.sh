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
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered this seat,
# @param   a HUM-* id (CLE-77778 provenance). Recorded on the accepted invite
# @param   (coalesced: an existing invite orderer is kept). A direct seat with
# @param   no pending invite has nowhere in the DB to store it — the operator
# @param   log line then carries it; the membership keeps admitted_by=operator.
# @param ORDERED_VIA (optional) - the agent/channel that carried the order,
# @param   e.g. CLE-34967 or '[terminal]'. At most 64 chars.
# @param CREATE_HUMAN (optional) - 1 seats a person who has NEVER signed in
# @param   (CLE-77781: "added, not invited"). Needs EMAIL (not HUMAN_ID) and
# @param   DISPLAY_NAME. Goes through the hub CLI (store.ProvisionMember): it
# @param   creates the human, an 'operator' identity carrying the verified
# @param   address (so a later Google/native sign-in LINKS to the same human,
# @param   yet the identity itself can never sign in), the membership, and
# @param   accepts any pending invite. Idempotent. No mail. Default 0 (the
# @param   SQL path above, which needs an existing human_identities row).
# @param DISPLAY_NAME - required with CREATE_HUMAN=1: the member's shown name.
# @param PASSWORD_FILE (optional, CREATE_HUMAN=1 only) - a 0600 file holding a
# @param   native password. The member also gets an email+password credential
# @param   (email pre-verified, NO mail), so a first native login lands on the
# @param   same human. The password rides only the CLI's STDIN — never an
# @param   argument, env var, or log — and one trailing newline is stripped.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 EMAIL=person@example.com MEMBER_ROLE=developer ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_tenant_member_add
# @example ENV=prd TENANT_ID=acme EMAIL=office@example.com DISPLAY_NAME='FirstName LastName' MEMBER_ROLE=biz_owner CREATE_HUMAN=1 PASSWORD_FILE=$HOME/.spool/.csi/acme.pw ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_tenant_member_add
#------------------------------------------------------------------------------
do_spl_tenant_member_add() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" human="${HUMAN_ID:-}" email="${EMAIL:-}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" role dry=1
  local create="${CREATE_HUMAN:-0}" name="${DISPLAY_NAME:-}" pwfile="${PASSWORD_FILE:-}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
  [[ "$create" == 0 || "$create" == 1 ]] || { do_log "FATAL CREATE_HUMAN must be 0 or 1, got: '$create'"; return 1; }
  # CREATE_HUMAN seats a person who has NEVER signed in (CLE-77781): it needs an
  # EMAIL (there is no HUMAN_ID yet) and a DISPLAY_NAME, and goes through the hub
  # CLI (store.ProvisionMember), not the SQL below which resolves an existing
  # human. A PASSWORD_FILE is only meaningful there.
  if (( create )); then
    [[ -n "$email" && -z "$human" ]] || { do_log "FATAL CREATE_HUMAN=1 needs EMAIL (and not HUMAN_ID): the person has no human id yet"; return 1; }
    [[ -n "$name" ]] || { do_log "FATAL CREATE_HUMAN=1 needs DISPLAY_NAME (the member's shown name)"; return 1; }
    [[ ${#name} -le 200 ]] || { do_log "FATAL DISPLAY_NAME is at most 200 chars"; return 1; }
  else
    [[ -z "$pwfile" ]] || { do_log "FATAL PASSWORD_FILE needs CREATE_HUMAN=1 (only a provisioned member gets a native credential)"; return 1; }
  fi
  if [[ -n "$pwfile" ]]; then
    [[ -f "$pwfile" ]] || { do_log "FATAL PASSWORD_FILE not found: $pwfile"; return 1; }
    local _pwperm; _pwperm="$(stat -c '%a' "$pwfile" 2>/dev/null)"
    [[ "$_pwperm" == 600 ]] || { do_log "FATAL PASSWORD_FILE must be mode 0600 (got ${_pwperm:-?}): $pwfile"; return 1; }
    [[ -s "$pwfile" ]] || { do_log "FATAL PASSWORD_FILE is empty: $pwfile"; return 1; }
  fi
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
    if (( create )); then
      do_log "OK DRY_RUN would PROVISION $email ('$name') on $tenant as $role (admitted_by=operator, ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia})$([[ -n "$pwfile" ]] && echo ', with a native email+password credential from PASSWORD_FILE (email pre-verified, no mail)') via the hub CLI on $SPL_SQL_CONN, accepting any pending invite. A later Google/native sign-in links to the same human. Re-run with DRY_RUN=0."
    elif [[ -n "$email" ]]; then
      do_log "OK DRY_RUN would add $email to $tenant as $role (admitted_by=operator, ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}) and mark a pending invite for $email accepted on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    else
      do_log "OK DRY_RUN would add $human to $tenant as $role (admitted_by=operator, ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}) and mark a pending invite for that human's email accepted on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    fi
    return 0
  fi
  [[ -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this seat) is required with DRY_RUN=0 (CLE-77778 provenance)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if (( create )); then
    spl_host_spool || return 1
    spl_via_proxy _spl_tenant_member_provision_run "$tenant" "$email" "$name" "$role" "$ordby" "$ordvia" "$pwfile"
  else
    spl_via_proxy _spl_tenant_member_add_run "$tenant" "$human" "$email" "$role" "$ordby" "$ordvia"
  fi
}

_spl_tenant_member_add_run() {
  local out rc=0 n_added n_already n_invite line who="$2" mark
  [[ -n "$who" ]] || who="$3"
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v tenant="$1" -v human="$2" -v email="$3" -v role="$4" -v ordby="$5" -v ordvia="$6" <<'SQL'
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
   SET accepted_at = now(), accepted_by = :'hid',
       ordered_by  = coalesce(ti.ordered_by, nullif(:'ordby', '')),
       ordered_via = coalesce(ti.ordered_via, nullif(:'ordvia', ''))
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
    do_log "OK added $who to $1 (ordered_by=$5${6:+ via $6}) ($GCP_ACCOUNT): $line"
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

# _spl_tenant_member_provision_run <tenant> <email> <name> <role> <ordby> <ordvia> <pwfile>
# CREATE_HUMAN path: the hub CLI (store.ProvisionMember) seats a person who has
# never signed in. The password, when a file is given, rides ONLY on the CLI's
# STDIN (the shell opens the file as fd 0) — never an argument, an env var, or a
# log line — and the CLI strips one trailing newline. SPL_PROXY_DSN is the hub
# DB through the proxy (spl_via_proxy); SPL_SPOOL is the host binary spl_host_spool built.
_spl_tenant_member_provision_run() {
  local tenant="$1" email="$2" name="$3" role="$4" ordby="$5" ordvia="$6" pwfile="$7" rc=0
  local -a args=(hub-provision-member --db "$SPL_PROXY_DSN" --tenant "$tenant" --email "$email" --role "$role" --name "$name")
  [[ -n "$ordby" ]] && args+=(--ordered-by "$ordby")
  [[ -n "$ordvia" ]] && args+=(--ordered-via "$ordvia")
  local out
  if [[ -n "$pwfile" ]]; then
    args+=(--password-stdin)
    out="$("$SPL_SPOOL" "${args[@]}" <"$pwfile" 2>&1)" || rc=$?
  else
    out="$("$SPL_SPOOL" "${args[@]}" </dev/null 2>&1)" || rc=$?
  fi
  if (( rc != 0 )); then
    do_log "FATAL provision of $email on $tenant failed ($GCP_ACCOUNT): $out"
    return 1
  fi
  do_log "OK provisioned $email ('$name') on $tenant as $role (ordered_by=$ordby${ordvia:+ via $ordvia})$([[ -n "$pwfile" ]] && echo ', native credential set') ($GCP_ACCOUNT): $out"
}
