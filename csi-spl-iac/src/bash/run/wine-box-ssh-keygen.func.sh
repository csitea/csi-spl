#!/bin/bash
#------------------------------------------------------------------------------
# @description Mint the wine-box admin ssh key pair at the cnf
# @description ssh_public_key_file (steps.061) minus .pub for the private
# @description half (mode 0600). Terraform reads only the .pub. Idempotent:
# @description an existing pair is kept, a lone half is refused. No GCP call.
# @param DRY_RUN (optional) - 1: print the plan only. Default 0 (local only).
# @example ./run -a do_spl_wine_box_ssh_keygen
#------------------------------------------------------------------------------
do_spl_wine_box_ssh_keygen() {
  local key pub
  key=$(do_spl_wine_box_private_key) || return 1
  pub="${key}.pub"
  if [[ -f "$key" && -f "$pub" ]]; then
    do_log "OK the wine-box key pair exists: $pub"
    return 0
  fi
  if [[ -f "$key" || -f "$pub" ]]; then
    do_log "FATAL only one half of the pair exists ($key / $pub): move it aside, then re-run"
    return 1
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: ssh-keygen -t ed25519 -N '' -f $key"
    return 0
  fi
  mkdir -p "$(dirname "$key")" && chmod 700 "$(dirname "$key")"
  ssh-keygen -q -t ed25519 -N '' -C "$(basename "$key")" -f "$key" || { do_log "FATAL ssh-keygen failed"; return 1; }
  chmod 600 "$key"
  chmod 644 "$pub"
  do_log "OK minted $pub (private half mode 0600; terraform reads the .pub only)"
}
