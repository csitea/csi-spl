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
# @description dev only: prd refuses debug tokens and a prd probe member is the
# @description owner's call (c-001 msg fc2478ff: prd NO-GO).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev
# @param TENANT_ID - required: the workspace slug
# @param PROBE_MEMBER_EMAIL (optional) - default the one in probe/human-email,
# @param   else delivery-probe-<box>@example.com
# @param PROBE_BOX (optional) - default this machine's desk box id (spl_desk_box_default)
# @param PROBE_SEAT_CMD (optional) - the sign-in script (the tests' seam)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_probe_member_seat
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_probe_member_seat
#------------------------------------------------------------------------------
declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

do_spl_probe_member_seat() {
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev: a prd probe member is the owner's call, and prd refuses debug tokens"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-$(spl_desk_box_default)}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID is not a workspace slug: '$tenant'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL PROBE_BOX is not a box tag: '$box'"; return 1; }
  do_spl_cloud_cnf || return 1
  local ws="$SPL_STATE_DIR/m3-e2e/$tenant" st email
  st="$ws/probe"
  email="${PROBE_MEMBER_EMAIL:-$(spl_probe_seat_email "$st" "$ws")}"
  email="${email:-delivery-probe-$box@example.com}"
  [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}$ ]] || { do_log "FATAL PROBE_MEMBER_EMAIL is not an email: '$email'"; return 1; }
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    [[ -e "$ws/probe-invited" ]] && do_log "INFO DRY_RUN would: move the probe login the first version left in $ws into $st"
    do_log "INFO DRY_RUN would: $([[ -e "$st/probe-invited" || -e "$ws/probe-invited" ]] || echo "invite $email to $tenant as member, then ")register + verify + sign in $email, writing $st/human-email and pw-human"
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
    spl_m3_invite "$tenant" "$email" member || return 1
    touch "$st/probe-invited"
  fi
  printf '%s\n' "$email" >"$st/human-email"
  local api out rc=0
  spl_cnf_api_fqdn api || return 1
  out="$(M3_AUTH_URL="https://$api" M3_HUB_URL="https://$api" M3_TENANT="$tenant" M3_STATE="$st" M3_HUMAN_EMAIL="$email" \
    ${PROBE_SEAT_CMD:-python3 $PROJ_PATH/src/bash/scripts/probe-member-seat.py})" || rc=$?
  echo "$out"
  (( rc == 0 )) || { do_log "FAIL $email could not sign in to $tenant ($ENV): $out"; return 1; }
  [[ -s "$st/pw-human" ]] || { do_log "FAIL signed in, and no $st/pw-human was written"; return 1; }
  do_log "OK the probe member $email is seated in $tenant ($ENV): $st"
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
