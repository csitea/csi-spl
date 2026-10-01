#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057 R16: print the newest dated debian-13 image (read
# @description only), to compare with / raise the pinned cnf boot_disk_image.
# @description Runs as the satellite project's SA (csi-spl-all), or PROJ_ID
# @description names another project whose key is on disk (images are public).
# @param PROJ_ID (optional) - default the cnf steps.060 gcp_project
# @example ./run -a do_satellite_image_latest
#------------------------------------------------------------------------------
do_satellite_image_latest() {
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  PROJ_ID="${PROJ_ID:-$(do_satellite_cnf gcp_project)}" || return 1
  export PROJ_ID
  do_gcp_pin_account || return 1
  local latest pinned
  latest=$(gcloud compute images describe-from-family debian-13 --project=debian-cloud \
    --account="${GCP_ACCOUNT}" --format='value(name)') || { do_log "FATAL cannot read the debian-13 family"; return 1; }
  pinned=$(do_satellite_cnf boot_disk_image) || return 1
  do_log "INFO newest : projects/debian-cloud/global/images/${latest}"
  do_log "INFO pinned : ${pinned}"
  [[ "${pinned##*/}" == "$latest" ]] && do_log "OK the pin is the newest image" \
    || do_log "WARN the pin is not the newest image: raise boot_disk_image in cnf if wanted"
  printf '%s\n' "projects/debian-cloud/global/images/${latest}"
}
