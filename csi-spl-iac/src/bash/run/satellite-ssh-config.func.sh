#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057 5.5: write a `Host satellite` block into the box
# @description user's ~/.ssh/config (between marker lines, replaced on a
# @description re-run), so `ssh satellite` reaches the VM through the IAP
# @description tunnel as the csi-spl-all SA (satellite-iap-proxy.sh). The block
# @description names the key minted by do_satellite_ssh_keygen, and re-pins the
# @description VM's host key (do_satellite_pin_host_key), so a destroy +
# @description recreate never ends in "Host key ... has changed".
# @param SSH_CONFIG (optional) - default $HOME/.ssh/config
# @param SATELLITE_ALIAS (optional) - default satellite
# @example ./run -a do_satellite_ssh_config
#------------------------------------------------------------------------------
do_satellite_ssh_config() {
  local cfg="${SSH_CONFIG:-$HOME/.ssh/config}" alias="${SATELLITE_ALIAS:-satellite}"
  local vm zone proj user key proxy tmp
  vm=$(do_satellite_cnf vm_name) || return 1
  zone=$(do_satellite_cnf gcp_zone) || return 1
  proj=$(do_satellite_cnf gcp_project) || return 1
  user=$(do_satellite_cnf os_user) || return 1
  key=$(do_satellite_private_key) || return 1
  proxy="${PROJ_PATH}/src/bash/scripts/satellite-iap-proxy.sh"
  local begin="# >>> csi-spl satellite (do_satellite_ssh_config) >>>"
  local end="# <<< csi-spl satellite (do_satellite_ssh_config) <<<"
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"; chmod 600 "$cfg"
  tmp=$(mktemp) || return 1
  awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$cfg" >"$tmp"
  {
    printf '%s\n' "$begin"
    printf 'Host %s %s\n' "$alias" "$vm"
    printf '  HostName %s\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$vm" "$user" "$key"
    printf '  ProxyCommand bash %s %s %s %%h %%p\n' "$proxy" "$proj" "$zone"
    printf '  StrictHostKeyChecking accept-new\n  UserKnownHostsFile ~/.ssh/known_hosts.satellite\n'
    printf '  ServerAliveInterval 30\n'
    printf '%s\n' "$end"
  } >>"$tmp"
  cat "$tmp" >"$cfg" && rm -f "$tmp"
  do_satellite_pin_host_key || return 1
  do_log "OK $cfg: 'ssh $alias' -> $user@$vm over IAP ($proj/$zone)"
}
