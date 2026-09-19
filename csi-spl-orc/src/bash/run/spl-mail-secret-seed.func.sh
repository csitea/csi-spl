#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the SMTP relay password for native sign-in (spec 015 T015,
# @description OQ-N5), csi-rel's do_provision_smtp_relay pattern: prove the
# @description relay with a STARTTLS + AUTH probe mail BEFORE anything is
# @description stored, then add the password as a version of the cnf slot
# @description mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD (030 creates it
# @description empty). Relay host/port/user/From are read from cnf mail.env;
# @description nothing is baked in. The password is read from the owner file
# @description $HOME/.gcp/.<org>/.<app>/smtp-app-password.txt (0600; all
# @description whitespace dropped, as Gmail shows app passwords in groups).
# @description It travels via a 0600 scratch netrc / stdin only: never argv,
# @description stdout or a log. Added only when it differs from the latest
# @description version (sha256). After it exists: mail TRANSPORT "smtp" and
# @description native ENABLED "true" in <env>.env.yaml, render, 030 apply.
# @description Dry run unless DRY_RUN=0 (dry run still probes when asked).
# @param ENV - required: dev or prd
# @param SMTP_TEST_RCPT (optional) - send the probe mail to this address
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @param DRY_RUN (optional) - 1 (default): no version added. 0: add it.
# @example ENV=prd SMTP_TEST_RCPT=<ops-address> DRY_RUN=0 ./run -a do_spl_mail_secret_seed
#------------------------------------------------------------------------------
do_spl_mail_secret_seed() {
  do_require_bin yq curl sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}"
  local f="$HOME/.gcp/.$org/.$app/smtp-app-password.txt"
  [[ -s "$f" ]] || { do_log "FATAL no owner SMTP app password file at $f (0600, one line)"; return 1; }
  [[ "$(stat -c %a "$f")" == 600 ]] || { do_log "FATAL $f must be mode 0600"; return 1; }

  local host port user from tls slot
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  port="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_PORT // ""' "$SPL_CNF")"
  user="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  from="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_FROM // ""' "$SPL_CNF")"
  tls="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_TLS // "starttls"' "$SPL_CNF")"
  slot="$(yq -r '.env.mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD // ""' "$SPL_CNF")"
  local v
  for v in "$host" "$user" "$from" "$slot"; do
    [[ -n "$v" && "$v" != *PLACEHOLDER* ]] || { do_log "FATAL cnf mail.env / mail.secret_env is unset or a placeholder for $ENV"; return 1; }
  done
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] || { do_log "FATAL cnf SPOOL_HUB_MAIL_SMTP_PORT '$port' is not a port"; return 1; }
  [[ "$tls" == starttls ]] || { do_log "FATAL cnf SPOOL_HUB_MAIL_SMTP_TLS is '$tls': the relay requires starttls"; return 1; }

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  (umask 077 && tr -d '[:space:]' <"$f" >"$h/pw") || return 1
  [[ -s "$h/pw" ]] || { do_log "FATAL $f is empty"; return 1; }

  # 1. probe: STARTTLS required (--ssl-reqd), AUTH from a scratch netrc
  if [[ -n "${SMTP_TEST_RCPT:-}" ]]; then
    (umask 077 && printf 'machine %s login %s password %s\n' "$host" "$user" "$(cat "$h/pw")" >"$h/netrc") || return 1
    printf 'From: %s\r\nTo: %s\r\nSubject: %s smtp relay probe (%s)\r\n\r\nSMTP relay probe from do_spl_mail_secret_seed for %s.\r\n' \
      "$from" "$SMTP_TEST_RCPT" "$SPL_ORG_APP" "$ENV" "$SPL_PROJECT" >"$h/body"
    local perr
    perr="$(curl --silent --show-error --fail --ssl-reqd --max-time 30 --url "smtp://$host:$port" \
      --netrc-file "$h/netrc" --mail-from "$from" --mail-rcpt "$SMTP_TEST_RCPT" --upload-file "$h/body" 2>&1)" ||
      { do_log "FATAL relay probe via $host:$port (STARTTLS) as $user failed: $perr; nothing stored"; return 1; }
    do_log "INFO relay probe OK: $from -> $SMTP_TEST_RCPT via $host:$port STARTTLS as $user"
  else
    do_log "INFO no SMTP_TEST_RCPT: relay not probed"
  fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local want have
  want="$(sha256sum <"$h/pw" | cut -d' ' -f1)"
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "$have" == "$want" ]]; then
    do_log "OK $slot already holds this password: nothing to add"
    return 0
  fi
  if (( dry )); then
    do_log "OK DRY_RUN would add a version to $slot in $SPL_PROJECT"
    return 0
  fi
  gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file="$h/pw" >/dev/null 2>&1 ||
    { do_log "FATAL could not add a version to $slot"; return 1; }
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ "$have" == "$want" ]] || { do_log "ERROR $slot latest version does not match $f (sha256)"; return 1; }
  do_log "OK $slot: version added and verified by sha256 (value not logged). Next: mail TRANSPORT smtp + native ENABLED true, render, 030 apply"
}
