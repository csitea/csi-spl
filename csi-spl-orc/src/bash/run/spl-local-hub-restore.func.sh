#!/bin/bash
#------------------------------------------------------------------------------
# @description The local hub's restore (lane L4). One dump from the backups
# @description volume, decrypted with the OWNER-HELD passphrase-wrapped age
# @description identity: age asks for the passphrase on the terminal (owner
# @description msg 3cfe43ce: on the terminal only, so stdin must be a tty).
# @description Runs as the hub user: an operator's identity file is staged
# @description (still wrapped) in a 0700 dir under the hub's state dir for
# @description the run and removed after it.
# @description Its sha256 is checked against the .meta first.
# @description Default = the restore PROOF: into a NEW scratch DB, then the
# @description base-table and migration counts must equal the .meta (PASS /
# @description FAIL line), then the scratch DB is dropped.
# @description LOCAL_HUB_RESTORE_LIVE=1 restores into the live DB instead
# @description (pg_restore --clean, one transaction): only with the hub
# @description stopped and LOCAL_HUB_RESTORE_CONFIRM=<the live DB name>.
# @param LOCAL_HUB_BACKUP_IDENTITY_FILE - required: the passphrase-wrapped age identity
# @param LOCAL_HUB_RESTORE_FILE (optional) - a dump name; default latest
# @param LOCAL_HUB_RESTORE_DB (optional) - the scratch DB; default <db>_restore_<stamp>
# @param LOCAL_HUB_RESTORE_KEEP (optional) - 1 keeps the scratch DB
# @param LOCAL_HUB_RESTORE_LIVE / LOCAL_HUB_RESTORE_CONFIRM (optional) - see above
# @example LOCAL_HUB_BACKUP_IDENTITY_FILE=/media/usb/identity.age ./run -a do_spl_local_hub_restore
#------------------------------------------------------------------------------
do_spl_local_hub_restore() {
  local idf="${LOCAL_HUB_BACKUP_IDENTITY_FILE:-}" live="${LOCAL_HUB_RESTORE_LIVE:-0}"
  spl_lhr_tty || { do_log "FATAL restore needs a terminal: the owner types the passphrase there (never piped, env or a file)"; return 1; }
  [[ -n "$idf" ]] || { do_log "FATAL LOCAL_HUB_BACKUP_IDENTITY_FILE must name the passphrase-wrapped age identity"; return 1; }
  spl_lhb_identity_ok "$idf" || return 1
  [[ "$live" == 0 || "$live" == 1 ]] || { do_log "FATAL LOCAL_HUB_RESTORE_LIVE must be 0 or 1, got '$live'"; return 1; }
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then spl_lhr_reexec "$idf"; return; fi
  spl_lhb_env || return 1
  if [[ "$live" == 1 ]]; then spl_lhr_live_ok || return 1; fi
  printf '\n  type the passphrase here (it is not echoed)\n\n' >/dev/tty 2>/dev/null || true
  # as this user (it alone reads the identity) in the postgres group (70: it
  # reads the backups volume, 0750)
  # --tty: ./run tees stdout, so compose would give the container no /dev/tty
  # and age could not ask for the passphrase.
  lde_compose run --rm --tty -u "$(spl_lhb_host_uid 70)" -v "$idf:/run/keys/identity:ro" -e "RESTORE_DB=${LOCAL_HUB_RESTORE_DB:-}" -e "RESTORE_LIVE=$live" \
    -e "RESTORE_KEEP=${LOCAL_HUB_RESTORE_KEEP:-0}" backup restore "${LOCAL_HUB_RESTORE_FILE:-latest}" ||
    { do_log "FATAL local hub restore failed (above)"; return 1; }
  do_log "OK local hub restore $([[ "$live" == 1 ]] && echo "into the live $LDE_PG_DB" || echo proof)"
}

# spl_lhr_reexec <identity> -> the restore re-run as the hub user, the
# wrapped identity staged in a 0700 dir the hub user owns, removed after
spl_lhr_reexec() {
  local su="${LOCAL_HUB_SUDO:-sudo}" d rc
  d="$($su -n -u "$LOCAL_HUB_USER" mktemp -d "$LOCAL_HUB_HOME/state/restore-key.XXXXXX")" ||
    { do_log "FATAL cannot stage the identity for $LOCAL_HUB_USER (is the hub up? do_spl_local_hub_up)"; return 1; }
  $su -n -u "$LOCAL_HUB_USER" sh -c 'umask 077; cat >"$1"' _ "$d/identity.age" <"$1" || { $su -n -u "$LOCAL_HUB_USER" rm -rf "$d"; return 1; }
  LOCAL_HUB_BACKUP_IDENTITY_FILE="$d/identity.age" LOCAL_HUB_REEXEC_PASS="LOCAL_HUB_BACKUP_IDENTITY_FILE LOCAL_HUB_RESTORE_FILE LOCAL_HUB_RESTORE_DB LOCAL_HUB_RESTORE_KEEP LOCAL_HUB_RESTORE_LIVE LOCAL_HUB_RESTORE_CONFIRM" \
    spl_local_hub_reexec do_spl_local_hub_restore; rc=$?
  $su -n -u "$LOCAL_HUB_USER" rm -rf "$d"
  return "$rc"
}

# spl_lhr_live_ok -> 0 when a LIVE restore may run: the confirm names the
# live DB and the hub container of the project is not running
spl_lhr_live_ok() {
  [[ "${LOCAL_HUB_RESTORE_CONFIRM:-}" == "$LDE_PG_DB" ]] || {
    do_log "FATAL a LIVE restore overwrites $LDE_PG_DB: set LOCAL_HUB_RESTORE_CONFIRM=$LDE_PG_DB"; return 1; }
  local id
  id="$(docker ps -q --filter "name=^${LDE_COMPOSE_PROJECT}-hub-1$" --filter status=running)"
  [[ -z "$id" ]] || { do_log "FATAL the hub is running: stop it first (do_spl_local_hub_down), then restore LIVE"; return 1; }
}
