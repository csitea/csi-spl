#!/bin/bash
#------------------------------------------------------------------------------
# @description Invite a human to a cloud tenant: `spool hub-invite` against the
# @description hub DB through the Cloud SQL proxy, as the env's project service
# @description account (do_gcp_pin_account: its key, never the owner account).
# @description The first
# @description OWNER of a tenant is seated this way, BEFORE anyone signs in:
# @description on a zero-member tenant a first sign-in becomes the bootstrap
# @description owner (010 OQ-A5). Harvested from the 2026-09-19 t1-owner.sh /
# @description prd-hub-invite.sh (adhoc-harvest.md). The DSN is never logged.
# @description It then mails the invitation once (010 FR-016) over the env's
# @description cnf relay (spl_invite_mail_env; transport not smtp = no mail,
# @description said in the output). Resend: do_spl_hub_invite_email_send.
# @description DRY_RUN=1 (default): print the invite, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param INVITE_EMAIL - required: the human's email
# @param INVITE_ROLE (optional) - a role id (specs/025): biz_owner (the tenant
# @param   owner), product_owner, admin, developer (default), tester,
# @param   pure_agent, biz_customer, regular_user; legacy owner|member map to biz_owner|developer. The hub
# @param   DB decides (rbac_roles FK): an unknown id fails the invite.
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered this
# @param   invite, a HUM-* id (CLE-77778 provenance). invited_by stays
# @param   'operator'; ORDERED_BY records who actually asked for the seat, so
# @param   the answer is in the DB, not in a retired agent's outbox.
# @param ORDERED_VIA (optional) - the agent or channel that carried the order,
# @param   e.g. CLE-34967 or '[terminal]'. At most 64 chars.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=prd TENANT_ID=t1 INVITE_EMAIL=<owner-email> INVITE_ROLE=biz_owner ORDERED_BY=HUM-10 ORDERED_VIA=CLE-34967 DRY_RUN=0 ./run -a do_spl_hub_invite
#------------------------------------------------------------------------------
do_spl_hub_invite() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" email="${INVITE_EMAIL:-}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" role dry=1
  role="$(spl_role_id "${INVITE_ROLE:-developer}")" || { do_log "FATAL INVITE_ROLE must be a role id ($SPL_ROLE_IDS), got: '${INVITE_ROLE:-}'"; return 1; }
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL INVITE_EMAIL is not an email: '$email'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would invite $email to $tenant as $role (ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}) on $SPL_SQL_CONN, as the $SPL_PROJECT service account, and mail the invitation (cnf mail transport: $(yq -r '.env.mail.env.SPOOL_HUB_MAIL_TRANSPORT // "none"' "$SPL_CNF")). Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this invite) is required with DRY_RUN=0 (CLE-77778 provenance)"; return 1; }
  spl_host_spool || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_invite_mail_env || return 1
  spl_via_proxy _spl_hub_invite_run "$tenant" "$email" "$role" "$ordby" "$ordvia"
}

_spl_hub_invite_run() {
  local out rc=0
  out="$(SPOOL_HUB_DB_DSN="$SPL_PROXY_DSN" spl_run_with_mail_env "$SPL_SPOOL" hub-invite --tenant "$1" --email "$2" --role "$3" --ordered-by "$4" --ordered-via "$5" 2>&1)" || rc=$?
  (( rc == 0 )) || { do_log "FATAL hub-invite $2 to $1 as $3: $out"; return 1; }
  do_log "OK invited $2 to $1 as $3 (ordered_by=$4${5:+ via $5}) ($GCP_ACCOUNT): $out"
}

