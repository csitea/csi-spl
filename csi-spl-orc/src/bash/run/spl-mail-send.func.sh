#!/bin/bash
#------------------------------------------------------------------------------
# @description Send ONE plain-text mail over the env's cnf relay: the same
# @description relay the hub mails through (cnf mail.env host, port, user,
# @description From; STARTTLS required) and the same password slot
# @description (mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD), read from
# @description Secret Manager as the env's project service account
# @description (do_gcp_pin_account, --account; never the owner account). The
# @description password travels via a 0600 scratch netrc only: never argv,
# @description stdout or a log. The action sets the Message-ID and prints it
# @description as the send id. DRY_RUN=1 (default): print the whole message
# @description and the relay, call no cloud and dial no SMTP.
# @description do_spl_hub_invite_email_send stays the path for invitations.
# @param ENV - required: dev or prd
# @param TO - required: the one recipient address
# @param SUBJECT - required: one line, UTF-8
# @param BODY_FILE - required: the plain-text (UTF-8) body
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TO=<address> SUBJECT='Test box access' BODY_FILE=/path/body.txt ./run -a do_spl_mail_send
# @example ENV=prd TO=<address> SUBJECT='Test box access' BODY_FILE=/path/body.txt DRY_RUN=0 ./run -a do_spl_mail_send
#------------------------------------------------------------------------------
do_spl_mail_send() {
  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  local to="${TO:-}" subject="${SUBJECT:-}" body="${BODY_FILE:-}" dry=1
  [[ "$to" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL TO is not one email address: '$to'"; return 1; }
  [[ -n "$subject" && "$subject" != *$'\n'* && "$subject" != *$'\r'* ]] || { do_log "FATAL SUBJECT must be one non-empty line"; return 1; }
  [[ -s "$body" ]] || { do_log "FATAL BODY_FILE is missing or empty: '$body'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local host port user from name tls slot v
  IFS=$'\t' read -r host port user from name tls slot < <(yq -r '[
      .env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // "",
      .env.mail.env.SPOOL_HUB_MAIL_SMTP_PORT // "",
      .env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // "",
      .env.mail.env.SPOOL_HUB_MAIL_FROM // "",
      .env.mail.env.SPOOL_HUB_MAIL_FROM_NAME // "",
      .env.mail.env.SPOOL_HUB_MAIL_SMTP_TLS // "starttls",
      .env.mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD // ""
    ] | @tsv' "$SPL_CNF")
  for v in "$host" "$user" "$from" "$slot"; do
    [[ -n "$v" && "$v" != *PLACEHOLDER* ]] || { do_log "FATAL cnf mail.env / mail.secret_env is unset or a placeholder for $ENV"; return 1; }
  done
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] || { do_log "FATAL cnf SPOOL_HUB_MAIL_SMTP_PORT '$port' is not a port"; return 1; }
  [[ "$tls" == starttls ]] || { do_log "FATAL cnf SPOOL_HUB_MAIL_SMTP_TLS is '$tls': the relay requires starttls"; return 1; }
  [[ -z "$name" || "$name" == *PLACEHOLDER* ]] && name=""

  local h mid
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  mid="<$(cat /proc/sys/kernel/random/uuid).spl-mail-send@${from#*@}>"
  _spl_mail_send_message "$from" "$name" "$to" "$subject" "$mid" "$body" >"$h/msg" || return 1

  if (( dry )); then
    do_log "OK DRY_RUN would mail this message to $to via $host:$port (STARTTLS) as $user, the relay password read as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    tr -d '\r' <"$h/msg"
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  (umask 077 && gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" \
    --account="$GCP_ACCOUNT" 2>/dev/null | tr -d '[:space:]' >"$h/pw") || true
  [[ -s "$h/pw" ]] || { do_log "FATAL cannot read the relay password from $slot as $GCP_ACCOUNT"; return 1; }
  (umask 077 && printf 'machine %s login %s password %s\n' "$host" "$user" "$(cat "$h/pw")" >"$h/netrc") || return 1
  local err
  err="$(curl --silent --show-error --fail --ipv4 --ssl-reqd --max-time 60 --url "smtp://$host:$port" \
    --netrc-file "$h/netrc" --mail-from "$from" --mail-rcpt "$to" --upload-file "$h/msg" 2>&1)" ||
    { do_log "FATAL the relay $host:$port refused the mail to $to: $err"; return 1; }
  do_log "OK sent '$subject' to $to via $host:$port at $(date -u +%FT%TZ) ($ENV, $GCP_ACCOUNT): message_id $mid"
}

# _spl_mail_send_message <from> <name> <to> <subject> <message-id> <body-file>
# -> the RFC 5322 message on stdout, CRLF line ends, UTF-8 8bit text. A
# non-ASCII subject or name is RFC 2047 base64 encoded.
_spl_mail_send_message() {
  local from="$1" name="$2" to="$3" subject="$4" mid="$5" body="$6" fromhdr="$1"
  [[ -n "$name" ]] && fromhdr="$(_spl_mail_send_word "$name") <$from>"
  printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n' \
    "$fromhdr" "$to" "$(_spl_mail_send_word "$subject")" "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" "$mid"
  sed 's/\r$//; s/$/\r/' "$body"
}

# _spl_mail_send_word <text> -> the text as is when ASCII, else =?UTF-8?B?..?=
_spl_mail_send_word() {
  if LC_ALL=C grep -q '[^ -~]' <<<"$1"; then
    printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"
  else
    printf '%s' "$1"
  fi
}
