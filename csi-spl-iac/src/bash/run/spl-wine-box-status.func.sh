#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: is the wine-box VM ready? Prints one KEY=value line
# @description each: VM, PROJECT, ZONE, STATE, MACHINE_TYPE, LAST_START, then,
# @description when RUNNING and the admin key is on this box, UPTIME and WINE
# @description over ssh through an IAP tunnel (start-iap-tunnel as ProxyCommand).
# @description The dev project SA only (do_gcp_pin_account), --account on
# @description every gcloud call. Changes nothing: start is do_spl_wine_box_start.
# @param WINE_BOX_SSH (optional) - 0: skip the ssh probe. Default 1.
# @example ./run -a do_spl_wine_box_status
# @example WINE_BOX_SSH=0 ./run -a do_spl_wine_box_status
#------------------------------------------------------------------------------
do_spl_wine_box_status() {
  local proj zone vm user key desc state mtype lstart proxy
  command -v gcloud >/dev/null 2>&1 || { do_log "FATAL gcloud is not installed"; return 1; }
  proj=$(do_spl_wine_box_cnf gcp_project) || return 1
  zone=$(do_spl_wine_box_cnf gcp_zone) || return 1
  vm=$(do_spl_wine_box_cnf vm_name) || return 1
  user=$(do_spl_wine_box_cnf os_user) || return 1
  unset ACCOUNT GCP_ACCOUNT
  export PROJ_ID="$proj"
  do_gcp_pin_account || return 1
  desc=$(gcloud compute instances describe "$vm" --zone="$zone" --project="$proj" \
    --account="$GCP_ACCOUNT" --format='value(status,machineType.basename(),lastStartTimestamp)') \
    || { do_log "FATAL cannot describe ${vm} in ${proj}/${zone}"; return 1; }
  read -r state mtype lstart <<<"$desc"
  printf 'VM=%s\nPROJECT=%s\nZONE=%s\nSTATE=%s\nMACHINE_TYPE=%s\nLAST_START=%s\n' \
    "$vm" "$proj" "$zone" "${state:-unknown}" "${mtype:-}" "${lstart:-}"
  if [[ "$state" != RUNNING ]]; then
    do_log "INFO ${vm} is ${state:-unknown}: start it with DRY_RUN=0 ./run -a do_spl_wine_box_start"
    return 0
  fi
  [[ "${WINE_BOX_SSH:-1}" == 1 ]] || return 0
  key=$(do_spl_wine_box_private_key) || return 1
  [[ -f "$key" ]] || { do_log "WARN no admin key at ${key}: ssh probe skipped"; return 0; }
  proxy="gcloud compute start-iap-tunnel ${vm} 22 --listen-on-stdin --zone=${zone} --project=${proj} --account=${GCP_ACCOUNT} --verbosity=error"
  # shellcheck disable=SC2016 # expanded on the box, not here
  ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ProxyCommand="$proxy" "${user}@${vm}" \
    'printf "UPTIME=%s\nWINE=%s\n" "$(uptime -p)" "$(wine --version 2>/dev/null || echo missing)"' \
    || { do_log "FATAL ssh probe to ${vm} failed"; return 1; }
}
