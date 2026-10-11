#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy the wine-box playbook out of this repo. csi-spl step 061
# @description is the source. DEST is the destination directory (required).
# @description Copied: box-playbook.yaml, roles/**, inventory.example.ini,
# @description vars.example.yml. A file already in DEST that this list does
# @description not name (a README) is left in place.
# @description Prints the csi-spl sha to pin the copy to.
# @param DEST (required) - the directory to copy into
# @param DRY_RUN (optional) - 1: print the plan. Default 1.
# @example DRY_RUN=0 DEST=/path/to/wine-box ./run -a do_spl_wine_box_ansible_sync
#------------------------------------------------------------------------------
do_spl_wine_box_ansible_sync() {
  local dest="${DEST:-}" src sha
  [[ -n "$dest" ]] || { do_log "FATAL DEST is required (the directory to copy the wine-box playbook into)"; return 1; }
  src="${PROJ_PATH}/src/terraform/061-gcp-vm-wine-box"
  [[ -f "$src/box-playbook.yaml" ]] || { do_log "FATAL no playbook at $src/box-playbook.yaml"; return 1; }
  sha=$(git -C "$PROJ_PATH" rev-parse HEAD) || return 1
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO DRY_RUN would copy box-playbook.yaml roles inventory.example.ini vars.example.yml"
    do_log "INFO a README already in DEST is left in place"
    do_log "INFO PIN csi-spl ${sha}"
    do_log "INFO DEST ${dest}"
    return 0
  fi
  mkdir -p "$dest/roles"
  cp -p "$src/box-playbook.yaml" "$src/inventory.example.ini" "$src/vars.example.yml" "$dest/" \
    || { do_log "FATAL copy into $dest failed"; return 1; }
  cp -a "$src/roles/." "$dest/roles/" || { do_log "FATAL copy of roles into $dest/roles failed"; return 1; }
  do_log "OK copied the wine-box playbook from csi-spl ${sha}"
  do_log "PIN csi-spl ${sha}"
  do_log "DEST ${dest}"
}
