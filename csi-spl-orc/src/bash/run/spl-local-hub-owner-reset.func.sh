#!/bin/bash
#------------------------------------------------------------------------------
# @description Reset the local private hub owner's forgotten password. The
# @description local hub has no mail, so the reset link cannot reach the owner,
# @description and do_spl_local_hub_owner_add KEEPS an existing password. This
# @description replaces the native credential of LOCAL_HUB_OWNER_EMAIL (a member
# @description of LOCAL_HUB_TENANT, both from the private config) and revokes
# @description every session the owner holds, so neither the old password nor
# @description an open browser still gets in.
# @description
# @description The new password is read ONLY from the operator's terminal,
# @description without echo, typed twice (owner rule: passphrases on the
# @description terminal only). A non-tty stdin (a pipe, /dev/null, a file) is
# @description refused before anything runs; there is no env, argv or file
# @description option. It reaches the hub CLI (`spool hub-reset-password
# @description --password-stdin`, inside the running hub container) on STDIN
# @description only. Run as anyone: it re-runs itself as the hub user. With no
# @description owner seated yet the hub refuses and nothing changes.
# @param DRY_RUN (optional) - 1 (default): say what it would do, ask nothing
# @example ./run -a do_spl_local_hub_owner_reset
# @example DRY_RUN=0 ./run -a do_spl_local_hub_owner_reset
#------------------------------------------------------------------------------
do_spl_local_hub_owner_reset() {
  [[ -t 0 ]] || { do_log "FATAL do_spl_local_hub_owner_reset reads the password from a terminal only: run it on the owner's tty, not from a pipe, a file or a script"; return 1; }
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then spl_local_hub_reexec do_spl_local_hub_owner_reset; return; fi
  spl_local_hub_env || return 1
  [[ -n "${LOCAL_HUB_OWNER_EMAIL:-}" ]] ||
    { do_log "FATAL no LOCAL_HUB_OWNER_EMAIL in $LOCAL_HUB_CONFIG: there is no owner to reset"; return 1; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would ask on this terminal for a new password (twice), replace the password of LOCAL_HUB_OWNER_EMAIL in LOCAL_HUB_TENANT (both from $LOCAL_HUB_CONFIG) and sign the owner out everywhere. Re-run with DRY_RUN=0."
    return 0
  fi
  _slhor_reset
}

# _slhor_reset -- ask the new password on /dev/tty (the owner_add reader),
# pipe it into the hub CLI in the hub container. Prints the CLI's verdict
# without the tenant or the email (they stay in the private config).
_slhor_reset() {
  local pw out rc=0
  pw="$(_slho_read_password)" || return 1
  out="$(printf '%s\n' "$pw" | lde_compose exec -T hub /usr/local/bin/spool hub-reset-password \
    --tenant "$LOCAL_HUB_TENANT" --email "$LOCAL_HUB_OWNER_EMAIL" --password-stdin 2>&1)" || rc=$?
  pw=""
  out="${out//$LOCAL_HUB_OWNER_EMAIL/<owner>}"
  out="${out//$LOCAL_HUB_TENANT/<tenant>}"
  if (( rc != 0 )); then
    [[ "$out" == *'no password credential'* ]] &&
      { do_log "FATAL no owner with a password is seated yet: run ./run -a do_spl_local_hub_owner_add first; nothing changed"; return 1; }
    do_log "FATAL the hub refused the reset (is the hub up? ./run -a do_spl_local_hub_status): $out"
    return 1
  fi
  [[ "$out" == *'"status":"reset"'* && "$out" == *'"sessions_revoked":true'* ]] ||
    { do_log "FATAL unexpected hub answer: $out"; return 1; }
  local hum; hum="$(grep -o '"human_id":"[^"]*"' <<<"$out")"
  do_log "OK owner password replaced and every owner session revoked ($hum); sign in again on http://localhost:$LOCAL_HUB_WUI_PORT/"
}
