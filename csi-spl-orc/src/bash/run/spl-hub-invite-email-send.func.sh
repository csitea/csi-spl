#!/bin/bash
#------------------------------------------------------------------------------
# @description (Re)send the invitation email for an existing, unaccepted,
# @description unexpired invite (010 FR-016) THROUGH THE HUB on Cloud Run
# @description (CLE-77780, owner 2026-09-30): POST /v1/operator/invites/mail,
# @description authenticated as the env's project service account
# @description (do_gcp_pin_account: its key mints a Google id token for the
# @description hub's own URL; never the owner account). The HUB sends over its
# @description cnf relay from GCP — this box never dials SMTP, so there is no
# @description IPv6 / home-network dependency and no 70 s hang. The hub enforces
# @description the resend gap and cap in the DB; an accepted or expired invite
# @description is never mailed. The mail names the tenant, the role, the
# @description address, the sign-in URL (which lands in #lobby) and the expiry;
# @description it carries no token. The invitee address is never logged beyond
# @description this box's own echo. DRY_RUN=1 (default): print what would be
# @description asked of the hub, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param EMAIL - required: the invitee's email (the invite key)
# @param LOCALE (optional) - mail locale; default the tenant's default locale
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 EMAIL=<invitee-email> ./run -a do_spl_hub_invite_email_send
# @example ENV=prd TENANT_ID=t1 EMAIL=<invitee-email> DRY_RUN=0 ./run -a do_spl_hub_invite_email_send
#------------------------------------------------------------------------------
do_spl_hub_invite_email_send() {
  do_require_bin yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  local tenant="${TENANT_ID:-}" email="${EMAIL:-${INVITE_EMAIL:-}}" locale="${LOCALE:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL EMAIL is not an email: '$email'"; return 1; }
  [[ -z "$locale" || "$locale" =~ ^[a-z]{2}$ ]] || { do_log "FATAL LOCALE must be a two-letter locale, got: '$locale'"; return 1; }
  email="${email,,}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to mail the $tenant invitation to $email (locale ${locale:-tenant default}), as the $SPL_PROJECT service account. The hub sends from GCP; this box dials no SMTP. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local body
  body="$(spl_hub_operator_json tenant "$tenant" email "$email" locale "$locale")" || { do_log "FATAL could not build the request body"; return 1; }
  spl_hub_operator_call POST /v1/operator/invites/mail "$body" || return 1
  _spl_hub_invite_email_report "$tenant" "$email"
}

# _spl_hub_invite_email_report <tenant> <email>: read SPL_HUB_OP_STATUS /
# SPL_HUB_OP_BODY and map them to the action's contract (0 sent, 3 not sent, 1
# error), the same exit codes the local path used.
_spl_hub_invite_email_report() {
  local tenant="$1" email="$2" outcome mid delivered
  outcome="$(jq -r '.mail.outcome // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  mid="$(jq -r '.mail.message_id // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  delivered="$(jq -r '.mail.delivered // false' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    404)
      if [[ "$SPL_HUB_OP_BODY" == *"not enabled"* ]]; then
        do_log "FATAL the hub operator route is not enabled (404): apply the operator cnf to $ENV (SPOOL_HUB_OPERATOR_* via the 030 apply)"
      else
        do_log "FATAL the hub refused (404): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
      fi
      return 1 ;;
    400) do_log "FATAL the hub rejected the request (400): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS and the audience $SPL_HUB_URL right? $SPL_HUB_OP_BODY"; return 1 ;;
  esac
  if [[ "$SPL_HUB_OP_STATUS" == 2* ]] && { [[ "$outcome" == sent ]] || [[ "$outcome" == logged ]]; }; then
    do_log "OK the hub relay accepted the $tenant invitation for $email at $(date -u +%FT%TZ) ($ENV, $GCP_ACCOUNT): outcome $outcome, delivered $delivered, message_id ${mid:-?}"
    return 0
  fi
  if [[ "$SPL_HUB_OP_STATUS" == 2* ]] && [[ -n "$outcome" ]]; then
    do_log "WARN NOT SENT: the $tenant invitation for $email is $outcome (accepted / expired / rate limited / not found): $SPL_HUB_OP_BODY"
    return 3
  fi
  do_log "FATAL hub-invite-mail for $email on $tenant failed (http $SPL_HUB_OP_STATUS): $SPL_HUB_OP_BODY"
  return 1
}
