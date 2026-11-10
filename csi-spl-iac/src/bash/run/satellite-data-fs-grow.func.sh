#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-5224 (spec 069, SPL-5086): grow the satellite's data
# @description filesystem online after terraform 060 grew its data disk
# @description (google_compute_disk.data, cnf data_disk_size_gb). Runs
# @description src/bash/scripts/satellite-data-fs-grow.sh on the VM as root,
# @description over the IAP tunnel as the csi-spl-all SA (do_satellite_ssh_opts):
# @description resize2fs (ext4) or xfs_growfs (xfs), never on a partition.
# @description Prints df before and after. Dry run unless DRY_RUN=0. The box
# @description playbook (role 01_data_disk) runs the same script on a rebuild.
# @param DRY_RUN (optional) - 1 (default) plans, 0 grows
# @param SATELLITE_DATA_MNT (optional) - the mountpoint, default /mnt/data
# @example ./run -a do_satellite_data_fs_grow
# @example DRY_RUN=0 ./run -a do_satellite_data_fs_grow
#------------------------------------------------------------------------------
do_satellite_data_fs_grow() {
  local dry="${DRY_RUN:-1}" mnt="${SATELLITE_DATA_MNT:-/mnt/data}"
  local script="${PROJ_PATH}/src/bash/scripts/satellite-data-fs-grow.sh"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 2; }
  [[ "$mnt" =~ ^/[A-Za-z0-9/_.-]+$ ]] || { do_log "FATAL SATELLITE_DATA_MNT must be an absolute path, got '$mnt'"; return 2; }
  [[ -r "$script" ]] || { do_log "FATAL no $script"; return 1; }
  do_satellite_ssh_opts || return 1
  ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" "sudo -n env FS_MNT='${mnt}' FS_DRY='${dry}' bash -s" <"$script" \
    || { do_log "FATAL the data filesystem grow failed on the satellite (lines above)"; return 1; }
}
