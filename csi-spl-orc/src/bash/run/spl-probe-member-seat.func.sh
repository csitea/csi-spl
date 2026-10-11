#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat the probe human of ONE workspace for
# @description do_spl_workspace_delivery_probe: a native (015) account invited
# @description as a member BEFORE its first sign-in (spl_m3_invite, the env SA
# @description over the Cloud SQL proxy; the m3-e2e rule: a first sign-in on a
# @description zero-member tenant would make it the owner), then registered and
# @description verified with the dev hub's debug token and signed in once. Its
# @description login lands where the probe reads it:
# @description <state>/m3-e2e/<tenant>/human-email and pw-human (0600, dir 0700).
# @description A re-run with a password that still signs in changes nothing;
# @description the invite runs once per state dir (marker probe-invited).
# @description dev only: prd refuses debug tokens and a prd probe member is the
# @description owner's call (c-001 msg fc2478ff: prd NO-GO).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev
# @param TENANT_ID - required: the workspace slug
# @param PROBE_MEMBER_EMAIL (optional) - default delivery-probe-<box>@example.com
# @param PROBE_BOX (optional) - default the short host name
# @param PROBE_SEAT_CMD (optional) - the sign-in script (the tests' seam)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_probe_member_seat
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_probe_member_seat
#------------------------------------------------------------------------------
do_spl_probe_member_seat() {
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev: a prd probe member is the owner's call, and prd refuses debug tokens"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-$(hostname -s)}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID is not a workspace slug: '$tenant'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL PROBE_BOX is not a box tag: '$box'"; return 1; }
  local email="${PROBE_MEMBER_EMAIL:-delivery-probe-$box@example.com}"
  [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}$ ]] || { do_log "FATAL PROBE_MEMBER_EMAIL is not an email: '$email'"; return 1; }
  do_spl_cloud_cnf || return 1
  local st="$SPL_STATE_DIR/m3-e2e/$tenant"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO DRY_RUN would: $([[ -e "$st/probe-invited" ]] || echo "invite $email to $tenant as member, then ")register + verify + sign in $email, writing $st/human-email and pw-human"
    do_log "OK DRY_RUN nothing was invited or written. Re-run with DRY_RUN=0."
    return 0
  fi
  mkdir -p "$st" && chmod 700 "$st" || return 1
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
