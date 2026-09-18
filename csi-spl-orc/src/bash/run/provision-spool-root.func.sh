#!/bin/bash
#------------------------------------------------------------------------------
# @description Make the box's shared spool dir (cnf env.box.spool_root) with
# @description the permissions model documented in all.env.yaml env.box:
# @description mode 2777 (setgid, NOT sticky) + default ACLs rwx for user,
# @description group and other (+ mask), applied to the root and everything
# @description already in it. Idempotent; re-running repairs drift.
# @description Needs root for /var: uses `sudo -n` when the caller is not root
# @description and fails with the exact commands when sudo would prompt.
# @description Called by do_setup_app_inf; a box install calls it too.
# @param SPOOL_ROOT_DIR (optional) - override cnf env.box.spool_root
# @example ./run -a do_provision_spool_root
#------------------------------------------------------------------------------
do_provision_spool_root() {
  do_require_bin setfacl getfacl || return 1
  do_lde_cnf || return 1
  local dir group other sudo_=()
  dir="${SPOOL_ROOT_DIR:-$(yq -r '.env.box.spool_root // ""' "$LDE_CNF")}"
  group="$(yq -r '.env.box.spool_root_group // ""' "$LDE_CNF")"
  other="$(yq -r '.env.box.spool_root_other // "rwx"' "$LDE_CNF")"
  [[ "$dir" == /* && "$dir" != / ]] || { do_log "FATAL env.box.spool_root must be an absolute path, got: '$dir'"; return 1; }
  [[ "$other" =~ ^[r-][w-][x-]$ ]] || { do_log "FATAL env.box.spool_root_other must look like rwx / ---, got: $other"; return 1; }
  (( EUID == 0 )) || sudo_=(sudo -n)

  local cmds=(
    "mkdir -p '$dir'"
    "chmod 2777 '$dir'"
    "chmod -t '$dir'"
  )
  [[ -n "$group" ]] && cmds+=("chgrp -R '$group' '$dir'")
  cmds+=(
    "setfacl -R -m u::rwx,g::rwx,o::$other,m::rwx '$dir'"
    "setfacl -R -d -m u::rwx,g::rwx,o::$other,m::rwx '$dir'"
  )
  local c
  for c in "${cmds[@]}"; do
    "${sudo_[@]}" bash -c "$c" 2>/dev/null || {
      do_log "FATAL could not run as root: $c"
      do_log "INFO run these once as root, then re-run:"
      printf '    %s\n' "${cmds[@]}"
      return 1
    }
  done
  # [[ -k ]] is the sticky test: it must be off (ack renames across users)
  if [[ -k "$dir" ]]; then do_log "FATAL $dir is still sticky"; return 1; fi
  getfacl -p "$dir" 2>/dev/null | grep -q "^default:other::$other" || { do_log "FATAL default ACL not set on $dir"; return 1; }
  do_log "OK spool root $dir: $(stat -c '%A %U:%G' "$dir"), default ACL u/g rwx, o $other"
}
