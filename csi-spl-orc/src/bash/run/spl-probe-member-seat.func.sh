#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat the probe human of ONE workspace for
# @description do_spl_workspace_delivery_probe: a native (015) account invited
# @description as a member BEFORE its first sign-in (spl_m3_invite, the env SA
# @description over the Cloud SQL proxy; the m3-e2e rule: a first sign-in on a
# @description zero-member tenant would make it the owner), then registered and
# @description verified with the dev hub's debug token and signed in once. Its
# @description login lands in its OWN dir, where the probe reads it first:
# @description <state>/m3-e2e/<tenant>/probe/human-email and pw-human (0600,
# @description dirs 0700). It never writes <state>/m3-e2e/<tenant>/ itself: that
# @description dir is do_spl_m3_e2e's, and on dev its pw-human is the e2e
# @description member's with no human-email beside it (the first version wrote
# @description there and replaced that password, 2026-10-11).
# @description A login the first version left in <tenant>/ (it alone wrote the
# @description probe-invited marker there) is moved into probe/ first.
# @description A re-run with a password that still signs in changes nothing;
# @description the invite runs once per probe dir (marker probe-invited).
# @description prd (owner HUM-10, t1 msg bc92a373: "Create the second test
# @description space"): only a TEST workspace (^e2e(-[a-z0-9]+)?$), the way
# @description do_spl_m3_e2e seated the prd e2e login: the address is a
# @description plus-address of the relay mailbox (cnf
# @description mail.env.SPOOL_HUB_MAIL_SMTP_USER, <local>+spl-probe-<ws>@),
# @description prd refuses debug tokens so the verify mail is read over IMAP
# @description with the relay password (spl_m3_imap_pass: the prd project SA,
# @description a 0600 file in probe/ removed when the run ends).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev, or prd for a test workspace only
# @param TENANT_ID - required: the workspace slug (prd: ^e2e(-[a-z0-9]+)?$)
# @param PROBE_MEMBER_EMAIL (optional) - default the one in probe/human-email,
# @param   else delivery-probe-<box>@example.com (prd: <relay local>+spl-probe-<ws>@<relay domain>)
# @param PROBE_MEMBER_ROLE (optional) - the invite role, default member; e.g. biz_owner
# @param PROBE_BOX (optional) - default this machine's desk box id (spl_desk_box_default)
# @param PROBE_SEAT_CMD (optional) - the sign-in script (the tests' seam)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_probe_member_seat
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_probe_member_seat
# @example ENV=prd TENANT_ID=e2e-2 PROBE_MEMBER_ROLE=biz_owner DRY_RUN=0 ./run -a do_spl_probe_member_seat
#------------------------------------------------------------------------------
declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

do_spl_probe_member_seat() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd (a prd test workspace only)"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-$(spl_desk_box_default)}" role="${PROBE_MEMBER_ROLE:-member}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID is not a workspace slug: '$tenant'"; return 1; }
  [[ "$ENV" == dev || "$tenant" =~ ^e2e(-[a-z0-9]+)?$ ]] || { do_log "FATAL prd seats a probe login only in a test workspace (^e2e(-[a-z0-9]+)?$), got '$tenant': prd workspaces are real"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL PROBE_BOX is not a box tag: '$box'"; return 1; }
  [[ "$role" =~ ^[a-z][a-z_]{0,31}$ ]] || { do_log "FATAL PROBE_MEMBER_ROLE is not a role id: '$role'"; return 1; }
  do_spl_cloud_cnf || return 1
  local ws="$SPL_STATE_DIR/m3-e2e/$tenant" st email
  st="$ws/probe"
  email="${PROBE_MEMBER_EMAIL:-$(spl_probe_seat_email "$st" "$ws")}"
  [[ -n "$email" || "$ENV" == dev ]] || email="$(spl_probe_seat_relay_email "$tenant")" || return 1
  email="${email:-delivery-probe-$box@example.com}"
  [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}$ ]] || { do_log "FATAL PROBE_MEMBER_EMAIL is not an email: '$email'"; return 1; }
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    [[ -e "$ws/probe-invited" ]] && do_log "INFO DRY_RUN would: move the probe login the first version left in $ws into $st"
    do_log "INFO DRY_RUN would: $([[ -e "$st/probe-invited" || -e "$ws/probe-invited" ]] || echo "invite $email to $tenant as $role, then ")register + verify$([[ "$ENV" == prd ]] && echo " (the mail over IMAP)") + sign in $email, writing $st/human-email and pw-human"
    do_log "OK DRY_RUN nothing was invited or written. Re-run with DRY_RUN=0."
    return 0
  fi
  mkdir -p "$st" && chmod 700 "$ws" "$st" || return 1
  spl_probe_seat_migrate "$ws" "$st" || return 1
  if [[ -s "$st/human-email" && "$(tr -d '[:space:]' <"$st/human-email")" != "$email" ]]; then
    do_log "FATAL $st/human-email names another member: remove it first, or pass PROBE_MEMBER_EMAIL=$(cat "$st/human-email")"
    return 1
  fi
  if [[ ! -e "$st/probe-invited" ]]; then
    spl_host_spool || return 1
    spl_m3_invite "$tenant" "$email" "$role" || return 1
    touch "$st/probe-invited"
  fi
  printf '%s\n' "$email" >"$st/human-email"
  local api out rc=0
  spl_cnf_api_fqdn api || return 1
  [[ "$ENV" == dev ]] || spl_probe_seat_imap "$st" || return 1
  out="$(M3_AUTH_URL="https://$api" M3_HUB_URL="https://$api" M3_TENANT="$tenant" M3_STATE="$st" M3_HUMAN_EMAIL="$email" \
    ${PROBE_SEAT_CMD:-python3 $PROJ_PATH/src/bash/scripts/probe-member-seat.py})" || rc=$?
  spl_m3_imap_forget
  echo "$out"
  (( rc == 0 )) || { do_log "FAIL $email could not sign in to $tenant ($ENV): $out"; return 1; }
  [[ -s "$st/pw-human" ]] || { do_log "FAIL signed in, and no $st/pw-human was written"; return 1; }
  do_log "OK the probe member $email is seated in $tenant ($ENV): $st"
}

# spl_probe_seat_relay_email <ws>: the prd default address, a plus-address of
# the relay mailbox (cnf mail.env.SPOOL_HUB_MAIL_SMTP_USER), fixed per
# workspace so a dry run and the real run name the same member.
spl_probe_seat_relay_email() {
  local user
  user="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  [[ "$user" == *@* ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER in the $ENV cnf (the IMAP mailbox)"; return 1; }
  printf '%s+spl-probe-%s@%s\n' "${user%@*}" "$1" "${user#*@}"
}

# spl_probe_seat_imap <probe dir>: the IMAP env m3-e2e.py's native_login reads
# the verify mail with (prd has no debug token), the relay password in a 0600
# file in the probe dir; the caller removes it (spl_m3_imap_forget).
spl_probe_seat_imap() {
  local host
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  M3_IMAP_USER="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  export M3_IMAP_USER M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" M3_IMAP_PASS_FILE="$1/imap-pass"
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE"
}

# spl_probe_seat_email <probe dir> <ws dir>: the probe member already seated,
# in probe/ or (first version) in the ws dir next to its marker; else nothing.
spl_probe_seat_email() {
  local f
  for f in "$1/human-email" "$2/human-email"; do
    [[ "$f" == "$2/human-email" && ! -e "$2/probe-invited" ]] && continue
    [[ -s "$f" ]] && { tr -d '[:space:]' <"$f"; return 0; }
  done
  return 0
}

# spl_probe_seat_migrate <ws dir> <probe dir>: move the login the first version
# wrote into the ws dir (known by ITS marker probe-invited) into probe/. The
# ws dir's pw-human then still holds the probe password, not the e2e member's
# (that one was replaced, not kept): it is moved too, never left there to be
# read as the e2e member's, and do_spl_dev_password_reset restores that one.
spl_probe_seat_migrate() {
  local ws="$1" st="$2" f
  [[ -e "$ws/probe-invited" ]] || return 0
  [[ -e "$st/pw-human" ]] && { do_log "FATAL both $ws and $st hold a probe login: keep one by hand"; return 1; }
  for f in human-email pw-human verify-human.json probe-invited; do
    [[ -e "$ws/$f" ]] && { mv "$ws/$f" "$st/$f" || return 1; }
  done
  do_log "INFO moved the probe login out of $ws into $st"
}
