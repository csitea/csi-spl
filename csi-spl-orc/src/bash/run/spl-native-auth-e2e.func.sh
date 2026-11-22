#!/bin/bash
#------------------------------------------------------------------------------
# @description The whole native (email + password) account flow on a cloud
# @description env, end to end, with no human step (SPL-6182, owner HUM-10 msg
# @description e4eb9fff): sign-up, the verify mail, verify (signed in), sign-in,
# @description a wrong password refused, forgot, the reset mail, reset (signed
# @description in), the old password refused, sign-in with the new one. The
# @description account is a NEW plus-address of the relay mailbox
# @description (mail.env.SPOOL_HUB_MAIL_SMTP_USER), so both mails are read
# @description over IMAP (native-auth-e2e.py with m3-e2e.py's reader). The
# @description relay password is read as the env's project SA into a 0600 file
# @description removed after the run (spl_m3_imap_pass). Every step prints a
# @description PASS/FAIL line with http codes, the mail Message-ID and the
# @description served /version; never a token, password, cookie or address.
# @description Each run leaves one verified, tenant-less native credential
# @description for its plus-address in the env's hub: no hub route erases a
# @description native credential yet, so the run logs that address for a
# @description later clean-up. prd runs are picked by hand, never scheduled.
# @description NAE_MODE=wui runs the same flow in the deployed WUI instead
# @description (csi-spl-wui tests/e2e/native-auth-live.proof.mjs, headless
# @description Chrome): the forms are filled and submitted in the pages, and
# @description each human-visible step is a screenshot in the state dir
# @description (owner HUM-10 msg 1bd9911f). Its mails are read with
# @description do_spl_mail_verify_token (MAIL_TOKEN_KIND verify / reset).
# @param ENV (required) - dev or prd
# @param NAE_MODE (optional) - api (default) or wui
# @param NAE_CRED_FILE (optional) - wui: the address + final password of the account, 0600, for a person to inspect it
# @param NAE_SEAT_TENANT (optional) - wui: seat the account as a member of this TEST tenant after verify
# @param   (do_spl_tenant_member_add CREATE_HUMAN=1, no password touched), so the WUI sign-in on that
# @param   tenant's host can open; the unseated refusal is kept as a control step. A tenant write: prd only on a go
# @param   The proof then runs on that tenant's host <tenant>.<fqdn> (t1: the apex); a tenant not in env.dns.mapped_tenants is refused
# @param NAE_SEAT_ROLE (optional) - the seat's role, default regular_user
# @param NAE_ORDERED_BY / NAE_ORDERED_VIA (with NAE_SEAT_TENANT) - the seat's provenance (ORDERED_BY HUM-*, ORDERED_VIA)
# @param NAE_EMAIL (optional) - <relay>+<tag>@<relay domain> with no earlier mail; default <relay>+native-e2e-<utc>@<relay domain>
# @param NAE_FLOOR_S (optional) - seconds between the two mails (default 65; the hub floor is 60)
# @param M3_IMAP_TIMEOUT (optional) - seconds to wait for each mail (default 240)
# @param SPL_STATE_DIR (optional) - default $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=dev ./run -a do_spl_native_auth_e2e
#------------------------------------------------------------------------------
do_spl_native_auth_e2e() {
  do_require_bin yq python3 || return 1
  spl_require_cloud_env || return 1
  do_spl_cloud_cnf || return 1
  local relay host email api_fqdn st rc=0
  relay="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  relay="${relay,,}"
  [[ "$relay" =~ ^[^@+]+@[^@]+$ ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER mailbox in the $ENV cnf (got '$relay')"; return 1; }
  email="${NAE_EMAIL:-${relay%@*}+native-e2e-$(date -u +%Y%m%dt%H%M%S)@${relay#*@}}"
  [[ "${email,,}" == "${relay%@*}"+?*"@${relay#*@}" ]] ||
    { do_log "FATAL NAE_EMAIL '$email' is no plus-address of the relay mailbox: use ${relay%@*}+<tag>@${relay#*@}"; return 1; }
  spl_cnf_api_fqdn api_fqdn || return 1
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  st="${SPL_STATE_DIR:-$HOME/.local/share/$SPL_ORG_APP/cloud/$ENV}/native-auth-e2e/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$st" && chmod 700 "$st" || return 1
  export NAE_AUTH_URL="https://$api_fqdn" NAE_EMAIL="$email" NAE_STATE="$st" \
    M3_IMAP_USER="$relay" M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" M3_IMAP_PASS_FILE="$st/imap-pass"
  do_log "INFO native auth e2e on $ENV: auth $NAE_AUTH_URL, account $email (left in the hub), state $st"
  if [[ "${NAE_MODE:-api}" == wui ]]; then
    spl_native_auth_e2e_wui "$st" "$email" || { do_log "FAIL native auth WUI proof on $ENV: $st/results.json"; return 1; }
    do_log "OK native auth WUI proof on $ENV: every step held, screenshots + results.json in $st"
    return 0
  fi
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE" || { rm -f "$M3_IMAP_PASS_FILE"; return 1; }
  ${NAE_CMD_PY:-python3 $APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/native-auth-e2e.py} || rc=$?
  rm -f "$M3_IMAP_PASS_FILE"
  (( rc == 0 )) || { do_log "FAIL native auth e2e on $ENV (exit $rc): $st/results.json"; return 1; }
  do_log "OK native auth e2e on $ENV: every step PASS, $st/results.json"
}

# spl_native_auth_e2e_wui <state dir> <email>: the flow in the WUI (NAE_MODE=wui)
spl_native_auth_e2e_wui() {
  local st="$1" email="$2" fqdn
  fqdn="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
  [[ -n "$fqdn" ]] || { do_log "FATAL env.dns.fqdn is not set in $SPL_CNF"; return 1; }
  [[ -z "${NAE_CRED_FILE:-}" || "$NAE_CRED_FILE" == /* ]] || { do_log "FATAL NAE_CRED_FILE must be an absolute path, got: '$NAE_CRED_FILE'"; return 1; }
  local seat=""
  if [[ -n "${NAE_SEAT_TENANT:-}" ]]; then
    spl_require_tenant_slug "$NAE_SEAT_TENANT" || return 1
    [[ "${NAE_ORDERED_BY:-}" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL NAE_SEAT_TENANT needs NAE_ORDERED_BY=HUM-<n>, got: '${NAE_ORDERED_BY:-}'"; return 1; }
    [[ "${NAE_SEAT_ROLE:-regular_user}" =~ ^[a-z_]+$ ]] || { do_log "FATAL NAE_SEAT_ROLE must be a role id, got: '$NAE_SEAT_ROLE'"; return 1; }
    # the apex host is t1; any other tenant signs in on its own <tenant>.<fqdn> host
    if [[ "$NAE_SEAT_TENANT" != t1 ]]; then
      yq -r '.env.dns.mapped_tenants // [] | .[]' "$SPL_CNF" | grep -xF "$NAE_SEAT_TENANT" >/dev/null ||
        { do_log "FATAL NAE_SEAT_TENANT '$NAE_SEAT_TENANT' has no tenant host in env.dns.mapped_tenants of $SPL_CNF"; return 1; }
      fqdn="$NAE_SEAT_TENANT.$fqdn"
    fi
    seat="cd $APP_PATH/$SPL_ORG_APP-orc && ENV=$ENV TENANT_ID=$NAE_SEAT_TENANT EMAIL=\"\$SEAT_EMAIL\" DISPLAY_NAME='Native E2E' MEMBER_ROLE=${NAE_SEAT_ROLE:-regular_user} CREATE_HUMAN=1 ORDERED_BY=$NAE_ORDERED_BY ORDERED_VIA='${NAE_ORDERED_VIA:-native-auth-e2e}' DRY_RUN=0 ./run -a do_spl_tenant_member_add"
  fi
  ( cd "$APP_PATH/$SPL_ORG_APP-wui" &&
    BASE="https://$fqdn" API="$NAE_AUTH_URL" EMAIL="$email" OUT="$st" CRED_FILE="${NAE_CRED_FILE:-}" SEAT_CMD="$seat" \
    MAIL_TOKEN_CMD="cd $APP_PATH/$SPL_ORG_APP-orc && ENV=$ENV ./run -a do_spl_mail_verify_token" \
      ${NAE_CMD_NODE:-node tests/e2e/native-auth-live.proof.mjs} )
}
