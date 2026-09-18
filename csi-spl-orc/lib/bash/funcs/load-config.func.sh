#!/bin/bash
#------------------------------------------------------------------------------
# @description Project configuration loader — file-free.
# @description Auto-derives ORG, APP, PROJ, VAR_DIR, ZIP_*_DIR, and
# @description PROJ_SYMLINK_MANIFEST from APP_PATH / PROJ_PATH set by run.sh.
# @description No external config files are sourced.
# @example do_load_config
#------------------------------------------------------------------------------
do_load_config() {
  # Auto-derive project identity. APP_PATH and PROJ_PATH are set by run.sh
  # before this function runs. Examples:
  #   APP_PATH=/opt/csi/csi-spl              -> ORG=csi, APP=csi-spl
  #   PROJ_PATH=/opt/csi/csi-spl/csi-spl-iac -> PROJ=csi-spl-iac
  # If a caller has already exported any of these, we respect their values.
  if [[ -n "${APP_PATH:-}" ]]; then
    : "${ORG:=$(basename "$(dirname "$APP_PATH")")}"
    : "${APP:=$(basename "$APP_PATH")}"
    export ORG APP
  fi
  if [[ -n "${PROJ_PATH:-}" ]]; then
    : "${PROJ:=$(basename "$PROJ_PATH")}"
    export PROJ
  fi

  # /var-rooted output directories.
  : "${VAR_DIR:=${VAR_BASE_PATH:-/var}}"
  : "${ZIP_ALL_DIR:=${VAR_DIR}/${ORG}/${APP}/${APP}-all/dat/zip}"
  : "${ZIP_DIR:=${VAR_DIR}/${ORG}/${APP}/${APP}-dat/dat/zip}"
  : "${ZIP_PROJ_DIR:=${VAR_DIR}/${ORG}/${APP}/${PROJ}/dat/zip}"
  export VAR_DIR ZIP_ALL_DIR ZIP_DIR ZIP_PROJ_DIR

  # csi-spl: no dat/log -> /var symlink manifest. Logs fall back to
  # $PROJ_PATH/dat/log/bash (git-ignored) when /var is not writable.
}
# csi-spl ::: copied from pas-psf-utl
