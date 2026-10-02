#!/bin/bash
#------------------------------------------------------------------------------
# @description Invite a human to a cloud tenant THROUGH THE HUB on Cloud Run
# @description (CLE-77780, owner 2026-09-30): POST /v1/operator/invites creates
# @description (or replaces) the invite and mails it from GCP, authenticated as
# @description the env's project service account (do_gcp_pin_account: its key
# @description mints a Google id token for the hub's own URL; never the owner
# @description account). No box dials SMTP — no IPv6 / home-network dependency,
# @description no 70 s hang. The first OWNER of a tenant is seated this way,
# @description BEFORE anyone signs in: on a zero-member tenant a first sign-in
# @description becomes the bootstrap owner (010 OQ-A5). The hub decides the role
# @description (rbac_roles FK): an unknown id fails the invite. The invitee
# @description address is never logged beyond this box's own echo. Resend the
# @description mail: do_spl_hub_invite_email_send. DRY_RUN=1 (default): print the
# @description invite, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param INVITE_EMAIL - required: the human's email
# @param INVITE_ROLE (optional) - a role id (specs/025): biz_owner (the tenant
# @param   owner), product_owner, admin, developer (default), tester,
# @param   pure_agent, biz_customer, regular_user; legacy owner|member map to biz_owner|developer.
# @param INVITED_BY (optional) - who is recorded as the inviter: a HUM-* id or
# @param   'operator' (default). The owner wants a real HUM-* here, not
# @param   'operator', when a human ordered the seat.
# @param ORDERED_BY - required when DRY_RUN=0: the human who ordered this
# @param   invite, a HUM-* id (CLE-77778 provenance).
# @param ORDERED_VIA (optional) - the agent or channel that carried the order,
# @param   e.g. CLE-34967 or '[terminal]'. At most 64 chars.
# @param TTL_HOURS (optional) - how long the invite stays open, 1..720; default the hub's 168h.
# @param NO_MAIL (optional) - 1 stores the invite without mailing it (0 default).
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 INVITE_EMAIL=<owner-email> INVITE_ROLE=biz_owner INVITED_BY=HUM-10 ORDERED_BY=HUM-10 ORDERED_VIA=CLE-34967 DRY_RUN=0 ./run -a do_spl_hub_invite
#------------------------------------------------------------------------------
do_spl_hub_invite() {
  do_require_bin yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  local tenant="${TENANT_ID:-}" email="${INVITE_EMAIL:-}" invby="${INVITED_BY:-}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" ttl="${TTL_HOURS:-}" nomail="${NO_MAIL:-0}" role dry=1
  role="$(spl_role_id "${INVITE_ROLE:-developer}")" || { do_log "FATAL INVITE_ROLE must be a role id ($SPL_ROLE_IDS), got: '${INVITE_ROLE:-}'"; return 1; }
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL INVITE_EMAIL is not an email: '$email'"; return 1; }
  [[ -z "$invby" || "$invby" =~ ^(HUM-[0-9]+|operator)$ ]] || { do_log "FATAL INVITED_BY must be a HUM-* id or 'operator', got: '$invby'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
  [[ -z "$ttl" || "$ttl" =~ ^[0-9]+$ ]] || { do_log "FATAL TTL_HOURS must be a number of hours (1..720), got: '$ttl'"; return 1; }
  [[ "$nomail" == 0 || "$nomail" == 1 ]] || { do_log "FATAL NO_MAIL must be 0 or 1, got: '$nomail'"; return 1; }
  email="${email,,}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to invite $email to $tenant as $role (invited_by=${invby:-operator}, ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia})$([[ "$nomail" == 1 ]] && echo ', no mail') and mail it from GCP, as the $SPL_PROJECT service account. This box dials no SMTP. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this invite) is required with DRY_RUN=0 (CLE-77778 provenance)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  # no_mail is a JSON bool and ttl_hours a JSON number: the hub decodes strictly
  # (DisallowUnknownFields), so a stringified "true"/"168" is a 400.
  local body nm=false
  [[ "$nomail" == 1 ]] && nm=true
  body="$(jq -cn --arg tenant "$tenant" --arg email "$email" --arg role "$role" \
      --arg invited_by "$invby" --arg ordered_by "$ordby" --arg ordered_via "$ordvia" \
      --arg ttl "$ttl" --argjson no_mail "$nm" '
      {tenant: $tenant, email: $email, role: $role}
      + (if $invited_by  != "" then {invited_by:  $invited_by}  else {} end)
      + (if $ordered_by  != "" then {ordered_by:  $ordered_by}  else {} end)
      + (if $ordered_via != "" then {ordered_via: $ordered_via} else {} end)
      + (if $ttl         != "" then {ttl_hours:   ($ttl|tonumber)} else {} end)
      + (if $no_mail then {no_mail: true} else {} end)')" \
    || { do_log "FATAL could not build the request body"; return 1; }
  spl_hub_operator_call POST /v1/operator/invites "$body" || return 1
  _spl_hub_invite_report "$tenant" "$email" "$role" "$ordby" "$ordvia"
}

# _spl_hub_invite_report <tenant> <email> <role> <ordered_by> <ordered_via>:
# read SPL_HUB_OP_STATUS / SPL_HUB_OP_BODY. 201 = the invite row exists; then
# the mail outcome decides the exit (0 mailed, 3 row created but mail not sent),
# so a mail hiccup never reads as 'nothing created'. Any other status = nothing
# created (1).
_spl_hub_invite_report() {
  local tenant="$1" email="$2" role="$3" ordby="$4" ordvia="$5" invby outcome mid delivered
  case "$SPL_HUB_OP_STATUS" in
    404)
      if [[ "$SPL_HUB_OP_BODY" == *"not enabled"* ]]; then
        do_log "FATAL the hub operator route is not enabled (404): apply the operator cnf to $ENV (SPOOL_HUB_OPERATOR_* via the 030 apply). Nothing created."
      else
        do_log "FATAL the hub refused (404): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null). Nothing created."
      fi
      return 1 ;;
    400) do_log "FATAL the hub rejected the invite (400): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null). Nothing created."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS and the audience $SPL_HUB_URL right? Nothing created. $SPL_HUB_OP_BODY"; return 1 ;;
  esac
  if [[ "$SPL_HUB_OP_STATUS" != 201 ]]; then
    do_log "FATAL hub-invite $email to $tenant failed (http $SPL_HUB_OP_STATUS): nothing created. $SPL_HUB_OP_BODY"
    return 1
  fi
  invby="$(jq -r '.invited_by // "operator"' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  outcome="$(jq -r '.mail.outcome // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  mid="$(jq -r '.mail.message_id // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  delivered="$(jq -r '.mail.delivered // false' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  if [[ "$outcome" == sent || "$outcome" == logged || "$outcome" == skipped_no_mail ]]; then
    do_log "OK invited $email to $tenant as $role (invited_by=$invby, ordered_by=$ordby${ordvia:+ via $ordvia}) and the hub mailed it (outcome $outcome, delivered $delivered, message_id ${mid:-?}) ($GCP_ACCOUNT)"
    return 0
  fi
  do_log "WARN INVITE ROW CREATED but mail NOT sent for $email on $tenant (mail outcome ${outcome:-?}): the invite stands; resend with do_spl_hub_invite_email_send. $SPL_HUB_OP_BODY"
  return 3
}
