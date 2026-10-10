#!/bin/bash
#------------------------------------------------------------------------------
# @description Install Cloud Storage FUSE (gcsfuse) on this box from Google's
# @description signed apt repository, so do_spl_box_state_mount can map the
# @description env's box state bucket to a folder (owner t1 151d85fc msg
# @description ef3d31e1). Idempotent: a box that already runs gcsfuse is OK
# @description and changes nothing. Debian / Ubuntu only (apt); the repo's
# @description suite is gcsfuse-<VERSION_CODENAME> of /etc/os-release.
# @description What it writes (as root, sudo -n):
# @description   /usr/share/keyrings/gcsfuse-archive-keyring.gpg  the repo key
# @description   /etc/apt/sources.list.d/gcsfuse.list            one signed-by line
# @description and then apt-get installs the package gcsfuse.
# @description DRY_RUN=1 (default) prints that plan and changes nothing.
# @param DRY_RUN (optional) - 1 (default): print the plan; 0 installs
# @param GCSFUSE_APT_URL (optional) - the apt repo, default Google's packages host
# @param GCSFUSE_OS_RELEASE (optional, tests) - default /etc/os-release
# @example ./run -a do_install_gcsfuse
# @example DRY_RUN=0 ./run -a do_install_gcsfuse
#------------------------------------------------------------------------------
do_install_gcsfuse() {
  local dry=1 drc
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if command -v gcsfuse >/dev/null 2>&1; then
    do_log "OK gcsfuse is installed: $(gcsfuse --version 2>/dev/null | sed -n 1p)"
    return 0
  fi
  local osr="${GCSFUSE_OS_RELEASE:-/etc/os-release}" code url ring list
  code="$(sed -n 's/^VERSION_CODENAME=//p' "$osr" 2>/dev/null | tr -d '"' | sed -n 1p)"
  [[ "$code" =~ ^[a-z]+$ ]] || { do_log "FATAL no VERSION_CODENAME in $osr: gcsfuse installs on Debian / Ubuntu (apt) only"; return 1; }
  command -v apt-get >/dev/null 2>&1 || { do_log "FATAL no apt-get on this box: gcsfuse installs on Debian / Ubuntu only"; return 1; }
  url="${GCSFUSE_APT_URL:-https://packages.cloud.google.com/apt}"
  ring=/usr/share/keyrings/gcsfuse-archive-keyring.gpg
  list=/etc/apt/sources.list.d/gcsfuse.list
  if (( dry )); then
    do_log "OK DRY_RUN: would write $ring (from $url/doc/apt-key.gpg) and $list (deb [signed-by=$ring] $url gcsfuse-$code main), then apt-get install gcsfuse. DRY_RUN=0 installs it."
    return 0
  fi
  # not do_require_bin: that list is what the satellite verify installs
  spl_box_state_tools curl gpg sudo || return 1
  curl -fsSL "$url/doc/apt-key.gpg" | gpg --dearmor | sudo -n tee "$ring" >/dev/null ||
    { do_log "FATAL cannot write the gcsfuse repo key $ring"; return 1; }
  echo "deb [signed-by=$ring] $url gcsfuse-$code main" | sudo -n tee "$list" >/dev/null ||
    { do_log "FATAL cannot write $list"; return 1; }
  sudo -n apt-get update -qq -o Dir::Etc::sourcelist="$list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 ||
    { do_log "FATAL apt-get update of the gcsfuse repo failed"; return 1; }
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcsfuse ||
    { do_log "FATAL apt-get install gcsfuse failed"; return 1; }
  command -v gcsfuse >/dev/null 2>&1 || { do_log "FATAL gcsfuse is not on PATH after the install"; return 1; }
  do_log "OK gcsfuse installed: $(gcsfuse --version 2>/dev/null | sed -n 1p)"
}
