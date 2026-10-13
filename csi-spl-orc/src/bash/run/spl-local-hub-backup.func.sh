#!/bin/bash
#------------------------------------------------------------------------------
# @description The local hub's backups (lane L4): run the backup job once now.
# @description The job is the compose service `backup`
# @description (src/docker/docker-compose-local-hub-backup.yaml, started by
# @description do_spl_local_hub_up), which does the same once a day at
# @description LOCAL_HUB_BACKUP_AT (UTC): pg_dump -Fc of the pg service piped
# @description through age to the backups volume, a .meta (sha256, counts)
# @description beside it, the newest LOCAL_HUB_BACKUP_KEEP kept. No clear dump
# @description ever lands on disk. Runs as the hub user (re-executes as it).
# @description Keys (owner msg 8fbbb8e0, an OWNER-HELD key): the job holds the
# @description age PUBLIC key only: LOCAL_HUB_BACKUP_RECIPIENT_FILE in the
# @description private config, default <config dir>/backup-key/recipient
# @description (do_spl_local_hub_backup_keygen writes it). The secret identity
# @description is passphrase-wrapped and kept off the box. No key is printed.
# @param LOCAL_HUB_BACKUP_DIR (optional) - a host dir instead of the named volume
# @param LOCAL_HUB_BACKUP_AT / LOCAL_HUB_BACKUP_KEEP (optional) - 03:15 UTC / 14
# @example ./run -a do_spl_local_hub_backup
#------------------------------------------------------------------------------
do_spl_local_hub_backup() {
  spl_lhb_as_hub_user do_spl_local_hub_backup || return "$SPL_LHB_RC"
  spl_lhb_env && spl_lhb_keys_ok || return 1
  lde_compose run --rm -T backup once || { do_log "FATAL local hub backup failed (above)"; return 1; }
  do_log "OK local hub backup written"
}

# spl_lhb_as_hub_user <action> [VAR...] -> 0: the caller is the hub user, go
# on. Else the action re-ran as the hub user (passing the named VARs) and
# 1 is returned with its exit status in SPL_LHB_RC.
spl_lhb_as_hub_user() {
  SPL_LHB_RC=1
  spl_local_hub_cnf || return 1
  spl_local_hub_is_user && return 0
  LOCAL_HUB_REEXEC_PASS="${*:2}" spl_local_hub_reexec "$1"; SPL_LHB_RC=$?
  return 1
}

# spl_lhb_keys_ok -> 0 when the keys are fit for the job: the recipient is a
# world-readable age public key and no clear identity sits on the box.
# Prints env names only, never a key.
spl_lhb_keys_ok() {
  local rec="${LOCAL_HUB_BACKUP_RECIPIENT_FILE:-}" idf="${LOCAL_HUB_BACKUP_IDENTITY_FILE:-}"
  [[ -n "$rec" && -r "$rec" && -s "$rec" ]] || {
    do_log "FATAL no backup recipient: run do_spl_local_hub_backup_keygen, or set LOCAL_HUB_BACKUP_RECIPIENT_FILE in the private config"; return 1; }
  if grep -q 'AGE-SECRET-KEY' "$rec"; then
    do_log "FATAL LOCAL_HUB_BACKUP_RECIPIENT_FILE holds a SECRET key: the job takes the public key only"; return 1; fi
  grep -q '^age1' "$rec" || { do_log "FATAL LOCAL_HUB_BACKUP_RECIPIENT_FILE is not an age recipient file (no age1... line)"; return 1; }
  # the job reads it as the image's postgres user: a public key, so 0644
  [[ "$(stat -L -c %A "$rec")" == ???????r?? ]] || { do_log "FATAL LOCAL_HUB_BACKUP_RECIPIENT_FILE must be world-readable (a public key: chmod 644)"; return 1; }
  if [[ -n "$idf" ]]; then spl_lhb_identity_ok "$idf" || return 1; fi
  do_log "OK local hub backup keys: public recipient set${idf:+, identity passphrase-wrapped}"
}

# spl_lhb_identity_ok <file> -> 0 for a passphrase-wrapped age identity; a
# clear AGE-SECRET-KEY file is refused (owner msg 8fbbb8e0)
spl_lhb_identity_ok() {
  [[ -r "$1" && -s "$1" ]] || { do_log "FATAL LOCAL_HUB_BACKUP_IDENTITY_FILE is not a readable file"; return 1; }
  if grep -q 'AGE-SECRET-KEY' "$1"; then
    do_log "FATAL LOCAL_HUB_BACKUP_IDENTITY_FILE is a CLEAR secret key: refused; wrap it with a passphrase (age -p) and keep it off the box"; return 1; fi
  [[ "$(sed -n 1p "$1")" =~ ^(age-encryption\.org/v1|-----BEGIN\ AGE\ ENCRYPTED\ FILE-----)$ ]] ||
    { do_log "FATAL LOCAL_HUB_BACKUP_IDENTITY_FILE is not a passphrase-wrapped age identity"; return 1; }
}

# spl_lhb_env -> the lead's local hub env (every LDE_*, LDE_COMPOSE_EXTRA_FILES
# so lde_compose carries this overlay, the recipient from the private config)
spl_lhb_env() {
  declare -F spl_local_hub_env >/dev/null || { do_log "FATAL spl_local_hub_env is missing (lib/bash/funcs/spl-local-hub.func.sh)"; return 1; }
  spl_local_hub_env
}

# spl_lhr_tty -> 0 when stdin is a terminal. The owner's rule (msg 3cfe43ce):
# a passphrase is typed on the terminal only, never from env, argv, a file
# or piped stdin.
spl_lhr_tty() { [[ -t 0 ]]; }

# spl_lhb_host_uid [gid] -> the container user that reads / writes host files
# as this user: uid 0 in a rootless daemon (it maps to this user), else this
# user's uid; the group is [gid] (70 = the image's postgres group, which may
# read the backups volume) or this user's
spl_lhb_host_uid() {
  local u
  if [[ "${DOCKER_HOST:-}" == unix:///run/user/* ]]; then u=0; else u="$(id -u)"; fi
  echo "$u:${1:-$(id -g)}"
}
