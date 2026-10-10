#!/bin/bash
#------------------------------------------------------------------------------
# @description Unmount what do_spl_box_state_mount mounted (fusermount -u). A
# @description folder that is not mounted is OK. An open file keeps a mount
# @description busy: the action then fails and names the folder.
# @param ENV - required: dev or prd
# @param MOUNT (optional) - ro, rw or both (default both)
# @example ENV=dev ./run -a do_spl_box_state_unmount
#------------------------------------------------------------------------------
do_spl_box_state_unmount() {
  spl_require_cloud_env || return 1
  local which rc=0 k dir fu
  which="$(spl_box_state_which)" || return 1
  spl_box_state_mounts || return 1
  fu="$(command -v fusermount3 || command -v fusermount)" || { do_log "FATAL no fusermount3 / fusermount on this box"; return 1; }
  for k in $which; do
    [[ "$k" == ro ]] && dir="$SPL_BOX_STATE_RO" || dir="$SPL_BOX_STATE_RW"
    if ! mountpoint -q "$dir" 2>/dev/null; then
      do_log "OK $ENV $k: $dir is not mounted"; continue
    fi
    if "$fu" -u "$dir"; then do_log "OK $ENV $k: unmounted $dir"
    else do_log "FAIL $ENV $k: cannot unmount $dir (a file open in it? lsof +D $dir)"; rc=1
    fi
  done
  return "$rc"
}

