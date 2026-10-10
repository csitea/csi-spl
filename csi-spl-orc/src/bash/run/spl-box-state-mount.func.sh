#!/bin/bash
#------------------------------------------------------------------------------
# @description Map the env's box state bucket (iac 056) to two folders with
# @description Cloud Storage FUSE, so cp, rsync, ls and scripts work on it
# @description like on a local dir (owner t1 151d85fc msgs 6a6dcd7e, 68b543b1,
# @description ec950b4b). The two folders have FIXED NAMES in the code,
# @description resolved by spl_box_state_mounts from cnf env.box.box_state_mount:
# @description   SPL_BOX_STATE_RO  the whole bucket, READ-ONLY (-o ro), as the
# @description                     env's project SA (its key file)
# @description   SPL_BOX_STATE_RW  ONLY the <rw_prefix>/ of the bucket (default
# @description                     shared/), read-write, as the box writer SA
# @description                     (the project SA impersonates it, no key)
# @description The nightly backups (<box>/<date>/) are never under RW, and the
# @description writer's grant on <rw_prefix>/ is an IAM condition (step 056),
# @description so a box cannot change or remove a backup through either.
# @description Not POSIX: no locks, a rename is a copy + delete, a write
# @description reaches the bucket on close. Already mounted = OK, unchanged.
# @param ENV - required: dev or prd
# @param MOUNT (optional) - ro, rw or both (default both)
# @example ENV=dev ./run -a do_spl_box_state_mount
# @example ENV=dev MOUNT=ro ./run -a do_spl_box_state_mount
#------------------------------------------------------------------------------
do_spl_box_state_mount() {
  spl_require_cloud_env || return 1
  local which rc=0 k
  which="$(spl_box_state_which)" || return 1
  spl_box_state_tools gcsfuse || { do_log "INFO install it: DRY_RUN=0 ./run -a do_install_gcsfuse"; return 1; }
  spl_box_state_mounts || return 1
  for k in $which; do
    case "$k" in
      ro) spl_box_state_mount_ro || rc=1 ;;
      rw) spl_box_state_mount_rw || rc=1 ;;
    esac
  done
  return "$rc"
}

# spl_box_state_mount_prep <dir> -> 0 to mount, 2 when already mounted, 1 refused
spl_box_state_mount_prep() {
  local dir="$1"
  if mountpoint -q "$dir" 2>/dev/null; then return 2; fi
  (umask 077 && mkdir -p "$dir") || { do_log "FATAL cannot create the mount dir $dir"; return 1; }
  [[ -z "$(ls -A "$dir" 2>/dev/null)" ]] || { do_log "FATAL $dir is not empty: a mount would hide its files; empty it or set another dir in cnf"; return 1; }
}

# spl_box_state_gcsfuse_log <ro|rw> -> the gcsfuse log file (warnings only:
# names and errors, never object content)
spl_box_state_gcsfuse_log() {
  local d="${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}"
  mkdir -p "$d" && chmod 700 "$d" && printf '%s/gcsfuse-%s-%s.log' "$d" "$ENV" "$1"
}

# spl_box_state_mount_ro -> the whole bucket at $SPL_BOX_STATE_RO, read-only,
# as the project SA (its key file)
spl_box_state_mount_ro() {
  local dir="$SPL_BOX_STATE_RO" bucket key prc=0 log
  spl_box_state_mount_prep "$dir" || prc=$?
  (( prc == 2 )) && { do_log "OK $ENV ro: $dir is already mounted"; return 0; }
  (( prc == 0 )) || return 1
  bucket="$(spl_box_state_cnf state_bucket_name)" || return 1
  key="$(do_gcp_sa_key_file "$SPL_CNF")" || { do_log "FATAL $ENV ro: no project SA key for ${SPL_PROJECT:-$ENV} (~/.gcp/.<org>/key-<project>.json): never the owner account"; return 1; }
  log="$(spl_box_state_gcsfuse_log ro)" || return 1
  if spl_box_state_detached gcsfuse --key-file "$key" -o ro --implicit-dirs --log-severity warning --log-file "$log" "$bucket" "$dir" >>"$log" 2>&1; then
    do_log "OK $ENV ro: gs://$bucket -> $dir (read-only, as $(do_gcp_sa_key_email "$key"))"
  else
    do_log "FAIL $ENV ro: gcsfuse could not mount gs://$bucket at $dir: $(spl_box_state_last_error "$log")"; return 1
  fi
}

# spl_box_state_mount_rw -> <rw_prefix>/ of the bucket at $SPL_BOX_STATE_RW, as
# the writer SA. gcsfuse has no impersonation flag: its key file is an
# impersonated_service_account credential whose source is the project SA key,
# written 0600 into a 0700 temp dir and shredded as soon as the mount is up
# (the daemon holds the token source in memory).
spl_box_state_mount_rw() {
  local dir="$SPL_BOX_STATE_RW" pre="$SPL_BOX_STATE_RW_PREFIX" bucket writer key work cred prc=0 rc=0 log
  spl_box_state_mount_prep "$dir" || prc=$?
  (( prc == 2 )) && { do_log "OK $ENV rw: $dir is already mounted"; return 0; }
  (( prc == 0 )) || return 1
  bucket="$(spl_box_state_cnf state_bucket_name)" || return 1
  writer="$(spl_box_state_cnf writer_sa_account_id)@$SPL_PROJECT.iam.gserviceaccount.com" || return 1
  key="$(do_gcp_sa_key_file "$SPL_CNF")" || { do_log "FATAL $ENV rw: no project SA key for ${SPL_PROJECT:-$ENV}: never the owner account"; return 1; }
  log="$(spl_box_state_gcsfuse_log rw)" || return 1
  work="$(umask 077 && mktemp -d)" || return 1
  cred="$work/impersonated.json"
  (umask 077 && jq -n --slurpfile k "$key" --arg u "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$writer:generateAccessToken" \
    '{type: "impersonated_service_account", service_account_impersonation_url: $u, source_credentials: $k[0]}' >"$cred") ||
    { rm -rf "$work"; do_log "FATAL $ENV rw: cannot build the impersonation credential"; return 1; }
  spl_box_state_detached gcsfuse --key-file "$cred" --only-dir "$pre" --implicit-dirs --log-severity warning --log-file "$log" "$bucket" "$dir" >>"$log" 2>&1 || rc=$?
  shred -u "$cred" 2>/dev/null || rm -f "$cred"
  rm -rf "$work"
  if (( rc == 0 )); then
    do_log "OK $ENV rw: gs://$bucket/$pre/ -> $dir (read-write, as $writer)"; return 0
  fi
  do_log "FAIL $ENV rw: gcsfuse could not mount gs://$bucket/$pre/ at $dir: $(spl_box_state_last_error "$log")"
  grep -q 'storage.objects.list' "$log" &&
    do_log "INFO $ENV rw: $writer lacks list on $pre/: the step 056 grant (an IAM condition on the $pre/ prefix) is not applied yet; see csi-spl-doc/doc/md/box-state-mount.md"
  return 1
}

# spl_box_state_last_error <log> -> the last error line of a gcsfuse log, one line
spl_box_state_last_error() {
  grep -ihE 'error|denied' "$1" 2>/dev/null | tail -n 1 | grep -oE '(PermissionDenied|desc =|Error:).{0,220}' | sed -n 1p
}
