#!/bin/bash
#------------------------------------------------------------------------------
# @description (Re)send the invitation email for an existing, unaccepted,
# @description unexpired invite (010 FR-016): `spool hub-invite-mail` through
# @description the Cloud SQL proxy, as the env's project service account
# @description (do_gcp_pin_account: its key, never the owner account), over
# @description the env's cnf relay (env.mail; the password is read from its
# @description Secret Manager slot into the child's environment only). The
# @description hub enforces the resend gap and cap in the DB; an accepted or
# @description expired invite is never mailed. The mail names the tenant, the
# @description role, the address, https://<fqdn>/login?tenant=<t> and the
# @description expiry; it carries no token. Logs carry a digest of the
# @description address, never the address. DRY_RUN=1 (default): print what
# @description would be sent, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param EMAIL - required: the invitee's email (the invite key)
# @param LOCALE (optional) - mail locale; default cnf env.i18n.default_locale
# @param MIN_GAP (optional) - least time between two sends, default 10m
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=prd TENANT_ID=t1 EMAIL=<invitee-email> ./run -a do_spl_hub_invite_email_send
# @example ENV=prd TENANT_ID=t1 EMAIL=<invitee-email> DRY_RUN=0 ./run -a do_spl_hub_invite_email_send
#------------------------------------------------------------------------------
do_spl_hub_invite_email_send() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" email="${EMAIL:-${INVITE_EMAIL:-}}" locale="${LOCALE:-}" gap="${MIN_GAP:-10m}" dry=1
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL EMAIL is not an email: '$email'"; return 1; }
  [[ -z "$locale" || "$locale" =~ ^[a-z]{2}$ ]] || { do_log "FATAL LOCALE must be a two-letter locale, got: '$locale'"; return 1; }
  [[ "$gap" =~ ^[0-9]+(s|m|h)$ ]] || { do_log "FATAL MIN_GAP must look like 10m, got: '$gap'"; return 1; }
  email="${email,,}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local transport host from
  transport="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_TRANSPORT // "none"' "$SPL_CNF")"
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  from="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_FROM_NAME // ""' "$SPL_CNF")"
  if [[ "$transport" != smtp ]]; then
    do_log "FATAL the $ENV cnf mail transport is '$transport', not smtp: no relay, nothing would reach $email (010 FR-016)"
    return 1
  fi
  if (( dry )); then
    do_log "OK DRY_RUN would mail the $tenant invitation to $email via $host (From '$from'), sign-in https://$SPL_FQDN/login?tenant=$tenant, locale ${locale:-cnf default}, as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_host_spool || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_invite_mail_env || return 1
  spl_via_proxy _spl_hub_invite_email_run "$tenant" "$email" "$locale" "$gap"
}

_spl_hub_invite_email_run() {
  local out rc=0 args=(hub-invite-mail --tenant "$1" --email "$2" --min-gap "$4")
  [[ -n "$3" ]] && args+=(--locale "$3")
  out="$(SPOOL_HUB_DB_DSN="$SPL_PROXY_DSN" spl_run_with_mail_env "$SPL_SPOOL" "${args[@]}" 2>"$SPL_STATE_DIR/invite-mail.log")" || rc=$?
  local outcome mid
  outcome="$(yq -p json -r '.mail.outcome // ""' <<<"$out" 2>/dev/null)"
  mid="$(yq -p json -r '.mail.message_id // ""' <<<"$out" 2>/dev/null)"
  if (( rc == 0 )) && [[ "$outcome" == sent ]]; then
    do_log "OK the relay accepted the $1 invitation for $2 at $(date -u +%FT%TZ) ($ENV, $GCP_ACCOUNT): message_id $mid, $out"
    return 0
  fi
  if (( rc == 3 )); then
    do_log "WARN NOT SENT: the $1 invitation for $2 is $outcome (accepted / expired / rate limited / not found): $out"
    return 3
  fi
  do_log "FATAL hub-invite-mail $2 on $1 (rc=$rc): $out $(tail -3 "$SPL_STATE_DIR/invite-mail.log" 2>/dev/null)"
  return 1
}
