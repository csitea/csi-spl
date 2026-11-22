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
# @param ENV (required) - dev or prd
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
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE" || { rm -f "$M3_IMAP_PASS_FILE"; return 1; }
  ${NAE_CMD_PY:-python3 $APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/native-auth-e2e.py} || rc=$?
  rm -f "$M3_IMAP_PASS_FILE"
  (( rc == 0 )) || { do_log "FAIL native auth e2e on $ENV (exit $rc): $st/results.json"; return 1; }
  do_log "OK native auth e2e on $ENV: every step PASS, $st/results.json"
}
