#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat the local private hub's owner: a biz_owner member of the
# @description private config's tenant (LOCAL_HUB_TENANT) with a native
# @description email + password credential for LOCAL_HUB_OWNER_EMAIL, email
# @description pre-verified, no mail. It is the ONLY way in: the local hub's
# @description cnf (env.lde.local_hub.hub.env) refuses HTTP register (503, no
# @description mail transport, no debug tokens), so sign-up stays closed.
# @description
# @description The password is read ONLY from the operator's terminal, without
# @description echo, typed twice (owner rule: passphrases on the terminal only).
# @description A non-tty stdin (a pipe, /dev/null, a file) is refused before
# @description anything runs; there is no env, argv or file option. It reaches
# @description the hub CLI (`spool hub-provision-member --password-stdin`, inside
# @description the running hub container) on STDIN only, never argv, env or a
# @description log line. Run as anyone: it re-runs itself as the hub user, in
# @description its long-lived tree. Idempotent: a seated owner is reported,
# @description and a re-run KEEPS an existing password (it is no reset).
# @param DRY_RUN (optional) - 1 (default): say what it would do, ask nothing
# @example ./run -a do_spl_local_hub_owner_add
# @example DRY_RUN=0 ./run -a do_spl_local_hub_owner_add
#------------------------------------------------------------------------------
do_spl_local_hub_owner_add() {
  [[ -t 0 ]] || { do_log "FATAL do_spl_local_hub_owner_add reads the password from a terminal only: run it on the owner's tty, not from a pipe, a file or a script"; return 1; }
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then spl_local_hub_reexec do_spl_local_hub_owner_add; return; fi
  spl_local_hub_env || return 1
  [[ -n "${LOCAL_HUB_OWNER_EMAIL:-}" ]] ||
    { do_log "FATAL no LOCAL_HUB_OWNER_EMAIL in $LOCAL_HUB_CONFIG: add the owner's sign-in email there first"; return 1; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would ask on this terminal for the owner's display name and password, then seat LOCAL_HUB_OWNER_EMAIL as biz_owner of LOCAL_HUB_TENANT (both from $LOCAL_HUB_CONFIG) with a verified email + password credential, no mail. Re-run with DRY_RUN=0."
    return 0
  fi
  _slho_provision
}

# _slho_provision -- ask the name and the password on /dev/tty, then pipe the
# password into the hub CLI in the hub container. Prints the CLI's verdict
# without the tenant or the email (they stay in the private config).
_slho_provision() {
  local name pw out rc=0
  printf 'display name of the owner (empty = none): ' >/dev/tty
  IFS= read -r name </dev/tty || return 1
  pw="$(_slho_read_password)" || return 1
  out="$(printf '%s\n' "$pw" | lde_compose exec -T hub /usr/local/bin/spool hub-provision-member \
    --tenant "$LOCAL_HUB_TENANT" --email "$LOCAL_HUB_OWNER_EMAIL" --name "$name" \
    --role biz_owner --ordered-via '[terminal]' --password-stdin 2>&1)" || rc=$?
  pw=""
  if (( rc != 0 )); then
    do_log "FATAL the hub refused the owner seat (is the hub up? ./run -a do_spl_local_hub_status): ${out//$LOCAL_HUB_OWNER_EMAIL/<owner>}"
    return 1
  fi
  [[ "$out" == *'"status":"provisioned"'* ]] || { do_log "FATAL unexpected hub answer: ${out//$LOCAL_HUB_OWNER_EMAIL/<owner>}"; return 1; }
  local hum; hum="$(grep -o '"human_id":"[^"]*"' <<<"$out")"
  # The CLI keeps an existing credential (ON CONFLICT DO NOTHING): a re-run
  # never changes the password, so do not claim it did.
  if [[ "$out" == *'"created_human":false'* ]]; then
    do_log "WARN the owner already existed ($hum): seat ensured, but an existing password was KEPT, not replaced by the one just typed"
    return 0
  fi
  do_log "OK owner seated as biz_owner with a verified password credential ($hum); sign in on http://localhost:$LOCAL_HUB_WUI_PORT/"
}

# _slho_read_password -- the password from /dev/tty, no echo, typed twice;
# printed on stdout for the caller's capture only (its FATALs go to stderr).
# Refuses a short one (the
# hub's native minimum, SPOOL_HUB_AUTH_NATIVE_PASSWORD_MIN_LEN default 12).
_slho_read_password() {
  local a b min="${LOCAL_HUB_PASSWORD_MIN_LEN:-12}"
  printf 'type the password here (not shown): ' >/dev/tty
  IFS= read -rs a </dev/tty || return 1
  printf '\ntype it again: ' >/dev/tty
  IFS= read -rs b </dev/tty || return 1
  printf '\n' >/dev/tty
  [[ "$a" == "$b" ]] || { do_log "FATAL the two passwords differ: nothing changed" >&2; return 1; }
  (( ${#a} >= min )) || { do_log "FATAL the password must be at least $min characters: nothing changed" >&2; return 1; }
  printf '%s' "$a"
}
