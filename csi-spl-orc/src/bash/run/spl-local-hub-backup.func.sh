#!/bin/bash
#------------------------------------------------------------------------------
# @description The local hub's backups (lane L4): run the backup job once now.
# @description The job is the compose service `backup`
# @description (src/docker/docker-compose-local-hub-backup.yaml, started by
# @description do_spl_local_hub_up), which does the same once a day at
# @description LOCAL_HUB_BACKUP_AT (UTC): pg_dump -Fc of the pg service piped
# @description through age to the backups volume, a .meta (sha256, counts)
# @description beside it, the newest LOCAL_HUB_BACKUP_KEEP kept. No clear dump
# @description ever lands on disk.
# @description Keys (owner msg 8fbbb8e0, an OWNER-HELD key): the job holds the
# @description age PUBLIC key only. The secret identity is passphrase-wrapped
# @description (do_spl_local_hub_backup_keygen) and kept off the box; a clear
# @description identity file is refused. No key is ever printed.
# @param LOCAL_HUB_BACKUP_RECIPIENT_FILE - required: the age public key file (age1...)
# @param LOCAL_HUB_BACKUP_IDENTITY_FILE (optional) - checked when set: must be passphrase-wrapped
# @param LOCAL_HUB_BACKUP_DIR (optional) - a host dir instead of the named volume
# @param LOCAL_HUB_BACKUP_AT / LOCAL_HUB_BACKUP_KEEP (optional) - 03:15 UTC / 14
# @example ./run -a do_spl_local_hub_backup
# @example ./run -a do_spl_local_hub_backup_list
#------------------------------------------------------------------------------
do_spl_local_hub_backup() {
  do_spl_local_hub_backup_check || return 1
  spl_lhb_env || return 1
  lde_compose run --rm -T backup once || { do_log "FATAL local hub backup failed (above)"; return 1; }
  do_log "OK local hub backup written"
}

# do_spl_local_hub_backup_list -> the dumps in the backups volume, newest last
do_spl_local_hub_backup_list() {
  spl_lhb_env || return 1
  lde_compose run --rm -T backup list
}

# do_spl_local_hub_backup_check -> 0 when the keys are fit for the job: the
# recipient is an age public key and no clear identity sits on the box. The
# lead's _up calls it before it starts anything. Prints paths' env names only.
do_spl_local_hub_backup_check() {
  local rec="${LOCAL_HUB_BACKUP_RECIPIENT_FILE:-}" idf="${LOCAL_HUB_BACKUP_IDENTITY_FILE:-}"
  [[ -n "$rec" && -r "$rec" && -s "$rec" ]] || {
    do_log "FATAL LOCAL_HUB_BACKUP_RECIPIENT_FILE must name a readable age public key file (do_spl_local_hub_backup_keygen makes one)"; return 1; }
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
# so lde_compose carries this overlay); never a compose list of our own
spl_lhb_env() {
  declare -F spl_local_hub_env >/dev/null || { do_log "FATAL spl_local_hub_env is missing (lib/bash/funcs/spl-local-hub.func.sh)"; return 1; }
  spl_local_hub_env
}

# spl_lhr_tty -> 0 when stdin is a terminal. The owner's rule (msg 3cfe43ce):
# a passphrase is typed on the terminal only, never from env, argv, a file
# or piped stdin.
spl_lhr_tty() { [[ -t 0 ]]; }

#------------------------------------------------------------------------------
# @description A NEW owner key pair for the backups, made in the backup image
# @description (no host tool): LOCAL_HUB_BACKUP_KEY_DIR/identity.age (the age
# @description secret key wrapped with a passphrase the owner types on the
# @description terminal, never echoed) and .../recipient (the public key). The
# @description clear secret key exists only in a pipe. Move identity.age OFF
# @description the box; point LOCAL_HUB_BACKUP_RECIPIENT_FILE at recipient.
# @description Refuses stdin that is not a terminal; never overwrites a key.
# @param LOCAL_HUB_BACKUP_KEY_DIR - required: an existing dir, owned by this user
# @example LOCAL_HUB_BACKUP_KEY_DIR=$HOME/.config/csi-spl/backup-key ./run -a do_spl_local_hub_backup_keygen
#------------------------------------------------------------------------------
do_spl_local_hub_backup_keygen() {
  local dir="${LOCAL_HUB_BACKUP_KEY_DIR:-}"
  spl_lhr_tty || { do_log "FATAL keygen needs a terminal: the owner types the passphrase there (never piped, env or a file)"; return 1; }
  [[ -n "$dir" && -d "$dir" && -w "$dir" ]] || { do_log "FATAL LOCAL_HUB_BACKUP_KEY_DIR must be an existing writable dir"; return 1; }
  [[ ! -e "$dir/identity.age" && ! -e "$dir/recipient" ]] || { do_log "FATAL LOCAL_HUB_BACKUP_KEY_DIR already holds a key: never overwritten"; return 1; }
  spl_lhb_env || return 1
  printf '\n  type the passphrase here (twice; it is not echoed)\n\n' >/dev/tty
  # uid 0 in a rootless daemon is this user on the host; else this user's uid.
  # The recipient is not there yet: a missing bind source would be created as
  # a DIR by docker, so the run mounts /dev/null for it.
  LOCAL_HUB_BACKUP_RECIPIENT_FILE=/dev/null lde_compose run --rm -u "$(spl_lhb_host_uid "")" -v "$dir:/keys" backup keygen /keys || { do_log "FATAL keygen failed (above)"; return 1; }
  do_log "OK keygen: move identity.age OFF this box; set LOCAL_HUB_BACKUP_RECIPIENT_FILE to the recipient file"
}

# spl_lhb_host_uid [gid] -> the container user that reads / writes host files
# as this user: uid 0 in a rootless daemon (it maps to this user), else this
# user's uid; the group is [gid] (70 = the image's postgres group, which may
# read the backups volume) or this user's
spl_lhb_host_uid() {
  local u
  if [[ "${DOCKER_HOST:-}" == unix:///run/user/* ]]; then u=0; else u="$(id -u)"; fi
  echo "$u:${1:-$(id -g)}"
}
