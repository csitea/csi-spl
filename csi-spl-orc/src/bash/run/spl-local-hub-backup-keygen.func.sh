#!/bin/bash
#------------------------------------------------------------------------------
# @description A NEW owner key pair for the backups, made in the backup image
# @description (no host tool), as the hub user (re-executes as it), in
# @description LOCAL_HUB_BACKUP_KEY_DIR (default <config dir>/backup-key, 0700):
# @description identity.age (the age secret key wrapped with a passphrase the
# @description owner types on the terminal, never echoed) and recipient (the
# @description public key, 0644: the private config finds it there). The clear
# @description secret key exists only in a pipe. Then move identity.age OFF
# @description the box. Refuses stdin that is not a terminal; never
# @description overwrites a key.
# @param LOCAL_HUB_BACKUP_KEY_DIR (optional) - a dir the hub user owns
# @example ./run -a do_spl_local_hub_backup_keygen
#------------------------------------------------------------------------------
do_spl_local_hub_backup_keygen() {
  spl_lhr_tty || { do_log "FATAL keygen needs a terminal: the owner types the passphrase there (never piped, env or a file)"; return 1; }
  spl_lhb_as_hub_user do_spl_local_hub_backup_keygen LOCAL_HUB_BACKUP_KEY_DIR || return "$SPL_LHB_RC"
  local dir="${LOCAL_HUB_BACKUP_KEY_DIR:-${LOCAL_HUB_CONFIG%/*}/backup-key}"
  [[ -d "$dir" ]] || (umask 077; mkdir -p "$dir") || return 1
  [[ -w "$dir" ]] || { do_log "FATAL LOCAL_HUB_BACKUP_KEY_DIR must be a dir this user writes"; return 1; }
  [[ ! -e "$dir/identity.age" && ! -e "$dir/recipient" ]] || { do_log "FATAL LOCAL_HUB_BACKUP_KEY_DIR already holds a key: never overwritten"; return 1; }
  spl_lhb_env || return 1
  printf '\n  type the passphrase here (twice; it is not echoed)\n\n' >/dev/tty 2>/dev/null || true
  # --no-deps: keygen needs no DB, so it works with the stack down or pg locked.
  # --tty: ./run tees stdout, so compose would give the container no /dev/tty
  # and age could not ask for the passphrase.
  # The recipient is not there yet: a missing bind source would be created as
  # a DIR by docker, so the run mounts /dev/null for it.
  LOCAL_HUB_BACKUP_RECIPIENT_FILE=/dev/null lde_compose run --rm --no-deps --tty -u "$(spl_lhb_host_uid "")" -v "$dir:/keys" backup keygen /keys || { do_log "FATAL keygen failed (above)"; return 1; }
  chmod 644 "$dir/recipient" || return 1
  do_log "OK keygen in LOCAL_HUB_BACKUP_KEY_DIR: move identity.age OFF this box; recipient stays (the job reads it)"
}
