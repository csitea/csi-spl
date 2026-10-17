#!/bin/bash
#------------------------------------------------------------------------------
# @description The verify token of a register, read from the relay mailbox
# @description over IMAP, for a tool that cannot speak IMAP: the WUI live
# @description proofs (their MAIL_TOKEN_CMD). Since SPL-2157 the dev hub
# @description answers no debug_token, so a proof that registers a fresh
# @description account verifies it with the link in its mail. MAIL_TOKEN_EMAIL
# @description must be a NEW plus-address of the relay mailbox
# @description (mail.env.SPOOL_HUB_MAIL_SMTP_USER). The relay password is read
# @description as the env's project SA into a 0600 file removed after the
# @description run (spl_m3_imap_pass). The token goes to MAIL_TOKEN_FILE (0600)
# @description only, never stdout or a log.
# @param ENV - required: dev or prd
# @param MAIL_TOKEN_EMAIL - required: <relay>+<tag>@<relay domain>, with no earlier mail
# @param MAIL_TOKEN_FILE - required: absolute path the token is written to (0600)
# @param M3_IMAP_TIMEOUT (optional) - seconds to wait for the mail (default 240)
# @example ENV=dev MAIL_TOKEN_EMAIL=<relay>+wui-proof-1@<relay domain> MAIL_TOKEN_FILE=/tmp/x/token ./run -a do_spl_mail_verify_token
#------------------------------------------------------------------------------
do_spl_mail_verify_token() {
  do_require_bin yq python3 || return 1
  spl_require_cloud_env || return 1
  local email="${MAIL_TOKEN_EMAIL:-}" tf="${MAIL_TOKEN_FILE:-}" relay host st out rc=0
  [[ "$tf" == /* && -d "$(dirname "$tf")" ]] || { do_log "FATAL MAIL_TOKEN_FILE must be an absolute path in an existing dir, got: '$tf'"; return 1; }
  do_spl_cloud_cnf || return 1
  relay="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  relay="${relay,,}"
  [[ "$relay" =~ ^[^@+]+@[^@]+$ ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER mailbox in the $ENV cnf (got '$relay')"; return 1; }
  [[ "${email,,}" == "${relay%@*}"+?*"@${relay#*@}" ]] ||
    { do_log "FATAL MAIL_TOKEN_EMAIL '$email' is no plus-address of the relay mailbox: use ${relay%@*}+<tag>@${relay#*@}"; return 1; }
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  st="$(mktemp -d)" || return 1
  export M3_IMAP_USER="$relay" M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" M3_IMAP_PASS_FILE="$st/imap-pass"
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE" || { rm -rf "$st"; return 1; }
  out="$(${MAIL_TOKEN_CMD_PY:-python3 $APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/mail-verify-token.py})" || rc=$?
  rm -rf "$st"
  (( rc == 0 )) || { do_log "FAIL no verify token for $email: $out"; return 1; }
  do_log "OK the verify token for $email is in $tf: $out"
}
