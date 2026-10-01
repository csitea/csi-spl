#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057: put the satellite box user's stateful home dirs on the
# @description DATA disk (/mnt/data/home/<user>/<dir>, linked into the home),
# @description so a destroy + recreate keeps them, a claude login made ON the
# @description VM (~/.claude) included. Only the "home" part of
# @description satellite-replicate-ai-user.sh: nothing leaves this box, nothing
# @description is copied to the VM. Idempotent; on a recreate the data copy
# @description wins and the fresh boot one is kept aside as <dir>.boot-aside.
# @param SATELLITE_PERSIST (optional) - space list of home dirs, default
# @param        ".claude .local .config .cache .gcp .github go .npm .terraform.d .tmux"
# @example ./run -a do_satellite_home_persist
#------------------------------------------------------------------------------
do_satellite_home_persist() {
  do_satellite_ssh_opts || return 1
  local persist="${SATELLITE_PERSIST:-.claude .local .config .cache .gcp .github go .npm .terraform.d .tmux}"
  # shellcheck disable=SC2029
  ssh "${SATELLITE_SSH[@]}" "PARTS=home BOXHOME=/nonexistent PERSIST='${persist}' bash -s" \
    <"${PROJ_PATH}/src/bash/scripts/satellite-replicate-ai-user.sh" \
    || { do_log "FATAL the home part failed (the REPL line above)"; return 1; }
  do_log "OK the satellite's home dirs live on the data disk: ./run -a do_satellite_verify"
}
