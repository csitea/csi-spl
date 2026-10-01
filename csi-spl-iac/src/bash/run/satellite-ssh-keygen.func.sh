#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057 round 2 Q3 b: mint the satellite's ssh key pair on THIS
# @description box, at the cnf ssh_public_key_file (steps.060) minus .pub for
# @description the private half (mode 0600). Terraform (060) reads only the
# @description .pub, so no private key ever reaches state. Idempotent: an
# @description existing pair is kept, a lone half is refused. No GCP call.
# @param DRY_RUN (optional) - 1: print the plan only. Default 0 (local only).
# @example ./run -a do_satellite_ssh_keygen
#------------------------------------------------------------------------------
do_satellite_ssh_keygen() {
  local key pub
  key=$(do_satellite_private_key) || return 1
  pub="${key}.pub"
  if [[ -f "$key" && -f "$pub" ]]; then
    do_log "OK the satellite key pair exists: $pub"
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
  chmod 600 "$key"; chmod 644 "$pub"
  do_log "OK minted $pub (private half $key, 0600; terraform reads the .pub only)"
}
