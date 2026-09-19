#!/bin/bash
#------------------------------------------------------------------------------
# spl_invite_mail_env -> SPL_MAIL_ENV: the K=V pairs `spool hub-invite` /
# `spool hub-invite-mail` need to mail an invitation (010 FR-016), read from
# the merged cnf ($SPL_CNF, do_spl_cloud_cnf): env.mail.env, the relay
# password from its Secret Manager slot env.mail.secret_env (read as
# $GCP_ACCOUNT, the env's project SA), SPOOL_HUB_AUTH_APP_URL
# (https://<env.dns.fqdn>) and SPOOL_HUB_DEFAULT_LOCALE (env.i18n).
# SPL_MAIL_TRANSPORT is the cnf transport. When it is not smtp, only the app
# URL and locale are set and the CLI sends nothing (skipped_no_relay).
# Pass SPL_MAIL_ENV with spl_run_with_mail_env, never as argv: it holds the
# password.
#------------------------------------------------------------------------------
spl_invite_mail_env() {
  SPL_MAIL_ENV=()
  SPL_MAIL_TRANSPORT="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_TRANSPORT // "none"' "$SPL_CNF")"
  local loc k slot pw
  loc="$(yq -r '.env.i18n.default_locale // ""' "$SPL_CNF")"
  [[ -n "$SPL_FQDN" ]] || { do_log "FATAL cnf env.dns.fqdn is empty: no sign-in URL for the invitation"; return 1; }
  SPL_MAIL_ENV+=("SPOOL_HUB_AUTH_APP_URL=https://$SPL_FQDN")
  [[ -n "$loc" ]] && SPL_MAIL_ENV+=("SPOOL_HUB_DEFAULT_LOCALE=$loc")
  [[ "$SPL_MAIL_TRANSPORT" == smtp ]] || return 0
  while IFS= read -r k; do
    [[ "$k" =~ ^SPOOL_HUB_MAIL_[A-Z_]+$ ]] || continue
    SPL_MAIL_ENV+=("$k=$(K="$k" yq -r '.env.mail.env[strenv(K)] // ""' "$SPL_CNF")")
  done < <(yq -r '.env.mail.env | keys | .[]' "$SPL_CNF")
  slot="$(yq -r '.env.mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD // ""' "$SPL_CNF")"
  [[ "$slot" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL cnf env.mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD is not a secret id: '$slot'"; return 1; }
  pw="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$pw" ]] || { do_log "FATAL cannot read the relay password $SPL_PROJECT/$slot as $GCP_ACCOUNT (seed it: do_gcp_copy_secret)"; return 1; }
  SPL_MAIL_ENV+=("SPOOL_HUB_MAIL_SMTP_PASSWORD=$pw")
}

# spl_run_with_mail_env <cmd> [args...] -> runs cmd in a subshell whose
# environment carries SPL_MAIL_ENV (export is a builtin: no argv holds a value).
spl_run_with_mail_env() {
  (
    local kv
    for kv in "${SPL_MAIL_ENV[@]}"; do export "${kv?}"; done
    "$@"
  )
}
