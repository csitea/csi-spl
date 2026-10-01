#!/bin/bash
#------------------------------------------------------------------------------
# @description Shared helpers of the satellite actions (spec 057): the cnf of
# @description step 060 (prd.env.yaml, where the satellite's steps live) and
# @description the ssh options that reach the VM through the IAP tunnel
# @description (satellite-iap-proxy.sh, as the csi-spl-all SA). No action here
# @description changes GCP.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# @description Print one value of steps."060-gcp-vm-satellite" (or $2 = the
# @description step), from the cnf yaml. Fails when it is empty.
# @param $1 the key, e.g. vm_name
# @param $2 (optional) the step, default 060-gcp-vm-satellite
# @example vm=$(do_satellite_cnf vm_name) || exit 1
#------------------------------------------------------------------------------
do_satellite_cnf() {
  local key=$1 step=${2:-060-gcp-vm-satellite} f v
  if [[ -z "${SATELLITE_CNF_FILE:-}" ]]; then
    do_resolve_oap ORG >&2
    do_resolve_oap APP >&2
  fi
  f="${SATELLITE_CNF_FILE:-${APP_PATH}/${ORG}-${APP}-cnf/${ORG}-${APP}/prd.env.yaml}"
  [[ -f "$f" ]] || { do_log "FATAL no satellite cnf at $f" >&2; return 1; }
  v=$(yq -r ".env.steps.\"${step}\".${key} // \"\"" "$f" 2>/dev/null)
  [[ -n "$v" && "$v" != null ]] || { do_log "FATAL steps.${step}.${key} is not set in $f" >&2; return 1; }
  printf '%s\n' "$v"
}

#------------------------------------------------------------------------------
# @description The private key path: the cnf ssh_public_key_file minus .pub,
# @description with ~ expanded against $HOME.
#------------------------------------------------------------------------------
do_satellite_private_key() {
  local pub
  pub=$(do_satellite_cnf ssh_public_key_file) || return 1
  pub="${pub/#\~/$HOME}"
  printf '%s\n' "${pub%.pub}"
}

#------------------------------------------------------------------------------
# @description Fill the array SATELLITE_SSH (ssh options + user@host) that
# @description reach the satellite over the IAP tunnel. The host key is pinned
# @description on first use into ~/.ssh/known_hosts.satellite.
#------------------------------------------------------------------------------
do_satellite_ssh_opts() {
  local vm zone proj user key proxy
  vm=$(do_satellite_cnf vm_name) || return 1
  zone=$(do_satellite_cnf gcp_zone) || return 1
  proj=$(do_satellite_cnf gcp_project) || return 1
  user=$(do_satellite_cnf os_user) || return 1
  key=$(do_satellite_private_key) || return 1
  [[ -f "$key" ]] || { do_log "FATAL no private key $key: run ./run -a do_satellite_ssh_keygen" >&2; return 1; }
  proxy="${PROJ_PATH}/src/bash/scripts/satellite-iap-proxy.sh"
  SATELLITE_HOST="$vm"
  SATELLITE_SSH=(
    -o "ProxyCommand=bash ${proxy} ${proj} ${zone} %h %p"
    -o "IdentityFile=${key}" -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts.satellite"
    -o ServerAliveInterval=30 -o ConnectTimeout=60
    "${user}@${vm}"
  )
}
