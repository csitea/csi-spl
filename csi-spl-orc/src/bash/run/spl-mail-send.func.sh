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
# @description BODY_HTML_FILE adds an HTML body: multipart/alternative, the
# @description BODY_FILE text first, the HTML (as is, base64) second.
# @description ATTACH_FILE adds one file as a base64 attachment: the top level
# @description is then multipart/mixed (the body, then the file). With either,
# @description DRY_RUN=1 prints the headers and the part tree (type, name,
# @description size, sha256), never the HTML or the file content. A message
# @description over MAIL_MAX_BYTES is a FATAL before any cloud call.
# @description do_spl_hub_invite_email_send stays the path for invitations.
# @param ENV (required) - dev or prd
# @param TO (required) - the one recipient address
# @param SUBJECT (required) - one line, UTF-8
# @param BODY_FILE (required) - the plain-text (UTF-8) body
# @param BODY_HTML_FILE (optional) - a UTF-8 HTML body, sent beside the text
# @param ATTACH_FILE (optional) - one regular file sent as an attachment
# @param MAIL_MAX_BYTES (optional) - cap on the whole message, default 10485760 (10 MB)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TO=<address> SUBJECT='Test box access' BODY_FILE=/path/body.txt ./run -a do_spl_mail_send
# @example ENV=prd TO=<address> SUBJECT='Scrum' BODY_FILE=/path/b.txt BODY_HTML_FILE=/path/b.html ATTACH_FILE=/path/b.md ./run -a do_spl_mail_send
# @example ENV=prd TO=<address> SUBJECT='Test box access' BODY_FILE=/path/body.txt DRY_RUN=0 ./run -a do_spl_mail_send
#------------------------------------------------------------------------------
do_spl_mail_send() {
  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  local to="${TO:-}" subject="${SUBJECT:-}" body="${BODY_FILE:-}" dry=1
  [[ "$to" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL TO is not one email address: '$to'"; return 1; }
  [[ -n "$subject" && "$subject" != *$'\n'* && "$subject" != *$'\r'* ]] || { do_log "FATAL SUBJECT must be one non-empty line"; return 1; }
  [[ -s "$body" ]] || { do_log "FATAL BODY_FILE is missing or empty: '$body'"; return 1; }
  local html="${BODY_HTML_FILE:-}" attach="${ATTACH_FILE:-}" max="${MAIL_MAX_BYTES:-10485760}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL MAIL_MAX_BYTES '$max' is not a positive byte count"; return 1; }
  _spl_mail_send_check_file BODY_HTML_FILE "$html" "$max" || return 1
  _spl_mail_send_check_file ATTACH_FILE "$attach" "$max" || return 1
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
  _spl_mail_send_message "$from" "$name" "$to" "$subject" "$mid" "$body" "$html" "$attach" >"$h/msg" || return 1
  local size; size="$(stat -c %s "$h/msg")"
  (( size <= max )) || { do_log "FATAL the message is $size bytes, over MAIL_MAX_BYTES $max: nothing sent"; return 1; }

  if (( dry )); then
    do_log "OK DRY_RUN would mail this message to $to ($size bytes) via $host:$port (STARTTLS) as $user, the relay password read as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    if [[ -z "$html$attach" ]]; then tr -d '\r' <"$h/msg"; else sed -n '/^\r$/q; s/\r$//p' "$h/msg"; _spl_mail_send_tree "$body" "$html" "$attach"; fi
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

# _spl_mail_send_check_file <param> <path> <max> -> 0 when the path is unset,
# or a readable regular file of at most <max> bytes; else one FATAL line.
_spl_mail_send_check_file() {
  local param="$1" f="$2" max="$3"
  [[ -z "$f" ]] && return 0
  [[ -f "$f" && -r "$f" ]] || { do_log "FATAL $param is not a readable regular file: '$f'"; return 1; }
  (( $(stat -c %s "$f") <= max )) || { do_log "FATAL $param '$f' is over MAIL_MAX_BYTES $max: nothing sent"; return 1; }
}

# _spl_mail_send_message <from> <name> <to> <subject> <message-id> <body-file>
#   [<html-file>] [<attach-file>]
# -> the RFC 5322 message on stdout, CRLF line ends. Text alone: one
# text/plain UTF-8 8bit part, as it always was. An HTML file makes the body
# multipart/alternative; an attachment makes the top multipart/mixed. A
# non-ASCII subject or name is RFC 2047 base64 encoded.
_spl_mail_send_message() {
  local from="$1" name="$2" to="$3" subject="$4" mid="$5" body="$6" html="${7:-}" attach="${8:-}" fromhdr="$1" b
  [[ -n "$name" ]] && fromhdr="$(_spl_mail_send_word "$name") <$from>"
  printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: %s\r\nMIME-Version: 1.0\r\n' \
    "$fromhdr" "$to" "$(_spl_mail_send_word "$subject")" "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" "$mid"
  if [[ -z "$attach" ]]; then
    _spl_mail_send_body "$body" "$html"
    return
  fi
  b="$(_spl_mail_send_boundary mixed)"
  printf 'Content-Type: multipart/mixed; boundary="%s"\r\n\r\n--%s\r\n' "$b" "$b"
  _spl_mail_send_body "$body" "$html"
  printf '\r\n--%s\r\n' "$b"
  _spl_mail_send_attachment "$attach"
  printf '\r\n--%s--\r\n' "$b"
}

# _spl_mail_send_body <text-file> [<html-file>] -> the body entity: its
# Content-Type header, a blank line and the content (text/plain 8bit alone,
# or multipart/alternative of the text and the base64 HTML).
_spl_mail_send_body() {
  local body="$1" html="${2:-}" b
  if [[ -z "$html" ]]; then
    printf 'Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n'
    sed 's/\r$//; s/$/\r/' "$body"
    return
  fi
  b="$(_spl_mail_send_boundary alt)"
  printf 'Content-Type: multipart/alternative; boundary="%s"\r\n\r\n--%s\r\n' "$b" "$b"
  printf 'Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n'
  sed 's/\r$//; s/$/\r/' "$body"
  printf '\r\n--%s\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' "$b"
  base64 -w76 "$html" | sed 's/$/\r/'
  printf '\r\n--%s--\r\n' "$b"
}

# _spl_mail_send_attachment <file> -> the attachment entity: type from the
# extension, the name RFC 2047 (name=) and RFC 2231 (filename*=) encoded when
# it is not plain ASCII, the content base64 in 76-column lines.
_spl_mail_send_attachment() {
  local f="$1" fn type
  fn="$(basename "$f")"; type="$(_spl_mail_send_type "$fn")"
  if LC_ALL=C grep -qx '[A-Za-z0-9._ +-]*' <<<"$fn"; then
    printf 'Content-Type: %s; name="%s"\r\nContent-Disposition: attachment; filename="%s"\r\n' "$type" "$fn" "$fn"
  else
    printf 'Content-Type: %s; name="%s"\r\nContent-Disposition: attachment; filename*=UTF-8'"''"'%s\r\n' \
      "$type" "$(_spl_mail_send_word "$fn")" "$(_spl_mail_send_pct "$fn")"
  fi
  printf 'Content-Transfer-Encoding: base64\r\n\r\n'
  base64 -w76 "$f" | sed 's/$/\r/'
}

# _spl_mail_send_type <filename> -> the MIME type for its extension
_spl_mail_send_type() {
  local ext="${1##*.}"; [[ "$1" == *.* ]] || ext=""
  case "${ext,,}" in
    md) echo 'text/markdown; charset=UTF-8' ;;
    html|htm) echo 'text/html; charset=UTF-8' ;;
    txt) echo 'text/plain; charset=UTF-8' ;;
    csv) echo 'text/csv; charset=UTF-8' ;;
    pdf) echo application/pdf ;;
    zip) echo application/zip ;;
    *) echo application/octet-stream ;;
  esac
}

# _spl_mail_send_pct <text> -> RFC 2231 percent-encoding of its UTF-8 bytes
_spl_mail_send_pct() {
  local LC_ALL=C s="$1" c i out=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$c" == [A-Za-z0-9._~-] ]]; then out+="$c"; else out+="$(printf '%%%02X' "'$c")"; fi
  done
  printf '%s' "$out"
}

# _spl_mail_send_boundary <tag> -> a fresh MIME boundary, never in base64 text
_spl_mail_send_boundary() {
  printf '=_spl_%s_%s' "$1" "$(tr -d '-' </proc/sys/kernel/random/uuid)"
}

# _spl_mail_send_tree <text-file> <html-file> <attach-file> -> the DRY_RUN
# part tree: type, name, size and sha256 per part, never the content.
_spl_mail_send_tree() {
  local body="$1" html="$2" attach="$3" pad=""
  [[ -n "$attach" ]] && { echo "part multipart/mixed"; pad="  "; }
  if [[ -n "$html" ]]; then
    echo "${pad}part multipart/alternative"
    _spl_mail_send_part "$pad  " 'text/plain; charset=UTF-8' "$body"
    _spl_mail_send_part "$pad  " 'text/html; charset=UTF-8 (base64)' "$html"
  else
    _spl_mail_send_part "$pad" 'text/plain; charset=UTF-8' "$body"
  fi
  [[ -z "$attach" ]] || _spl_mail_send_part "$pad" "attachment $(_spl_mail_send_type "$(basename "$attach")") (base64)" "$attach"
}

# _spl_mail_send_part <indent> <type> <file> -> one part tree line
_spl_mail_send_part() {
  printf '%spart %s name=%s size=%s sha256=%s\n' "$1" "$2" "$(basename "$3")" "$(stat -c %s "$3")" "$(sha256sum <"$3" | cut -d' ' -f1)"
}

# _spl_mail_send_word <text> -> the text as is when ASCII, else =?UTF-8?B?..?=
_spl_mail_send_word() {
  if LC_ALL=C grep -q '[^ -~]' <<<"$1"; then
    printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"
  else
    printf '%s' "$1"
  fi
}
