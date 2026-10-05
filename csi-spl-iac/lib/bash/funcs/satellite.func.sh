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
# the cnf file the satellite's steps live in (SATELLITE_CNF_FILE in tests)
_satellite_cnf_file() {
  if [[ -z "${SATELLITE_CNF_FILE:-}" ]]; then
    do_resolve_oap ORG >&2
    do_resolve_oap APP >&2
  fi
  printf '%s\n' "${SATELLITE_CNF_FILE:-${APP_PATH}/${ORG}-${APP}-cnf/${ORG}-${APP}/prd.env.yaml}"
}

do_satellite_cnf() {
  local key=$1 step=${2:-060-gcp-vm-satellite} f v
  f=$(_satellite_cnf_file)
  [[ -f "$f" ]] || { do_log "FATAL no satellite cnf at $f" >&2; return 1; }
  v=$(yq -r ".env.steps.\"${step}\".${key} // \"\"" "$f" 2>/dev/null)
  # a value shared by every env lives in all.env.yaml or is derived (spec 072
  # A44, e.g. 120 gh_repo): read the effective prd cnf when the file lacks it
  if [[ -z "$v" || "$v" == null ]] && [[ -z "${SATELLITE_CNF_FILE:-}" ]]; then
    local m
    m=$(mktemp) || return 1
    do_spl_merged_cnf "$(dirname "$f")" prd "$m" >&2 && v=$(yq -r ".env.steps.\"${step}\".${key} // \"\"" "$m" 2>/dev/null)
    rm -f "$m"
  fi
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
# @output SATELLITE_SSH (array). The caller must not run this function inside
# @output $( ): a command substitution is a subshell, so the array would not
# @output survive it.
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
  # shellcheck disable=SC2034 # SATELLITE_HOST has no reader (grep -rn SATELLITE_HOST csi-spl-iac --include='*.sh' finds only this assignment)
  SATELLITE_HOST="$vm"
  # shellcheck disable=SC2034 # read by satellite-verify.func.sh:167,173
  SATELLITE_SSH=(
    -o "ProxyCommand=bash ${proxy} ${proj} ${zone} %h %p"
    -o "IdentityFile=${key}" -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts.satellite"
    -o ServerAliveInterval=30 -o ConnectTimeout=60
    "${user}@${vm}"
  )
}

#------------------------------------------------------------------------------
# @description After a (re)create the VM has NEW host keys. Drop every entry
# @description for it from ~/.ssh/known_hosts.satellite, then PIN the keys the
# @description guest published (guest attributes hostkeys/, read as the
# @description satellite project's SA; 060 sets enable-guest-attributes). When
# @description the guest has not published them, the first connect accepts the
# @description new key (StrictHostKeyChecking accept-new) and this says so.
# @example do_satellite_pin_host_key
#------------------------------------------------------------------------------
do_satellite_pin_host_key() {
  local vm zone proj kh out n
  vm=$(do_satellite_cnf vm_name) || return 1
  zone=$(do_satellite_cnf gcp_zone) || return 1
  proj=$(do_satellite_cnf gcp_project) || return 1
  kh="${HOME}/.ssh/known_hosts.satellite"
  mkdir -p "$(dirname "$kh")"; touch "$kh"; chmod 600 "$kh"
  ssh-keygen -R "$vm" -f "$kh" >/dev/null 2>&1; rm -f "${kh}.old"
  unset ACCOUNT GCP_ACCOUNT
  export PROJ_ID="$proj"
  do_gcp_pin_account >/dev/null || { do_log "WARN no ${proj} SA: host key not pinned, the first connect accepts it"; return 0; }
  out=$(gcloud compute instances get-guest-attributes "$vm" --zone="$zone" --project="$proj" \
    --query-path=hostkeys/ --account="${GCP_ACCOUNT}" --format='value(key,value)' 2>/dev/null)
  n=0
  while IFS=$'\t' read -r t k; do
    [[ "$t" == ssh-* || "$t" == ecdsa-* ]] && [[ -n "$k" ]] || continue
    printf '%s %s %s\n' "$vm" "$t" "$k" >>"$kh"; n=$((n + 1))
  done <<<"$out"
  if ((n > 0)); then do_log "OK pinned $n host key(s) of $vm from its guest attributes into $kh"
  else do_log "WARN $vm published no host keys (guest attributes): the stale entry is gone, the first connect accepts the new key"; fi
}
