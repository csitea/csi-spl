#!/bin/bash
#------------------------------------------------------------------------------
# @description Shared helpers of the wine-box actions: one value of
# @description steps."061-gcp-vm-wine-box" from the dev cnf, and the private
# @description key path (the cnf .pub minus .pub, ~ expanded). No GCP call.
#------------------------------------------------------------------------------

# the cnf file the wine-box step lives in (WINE_BOX_CNF_FILE in tests)
_wine_box_cnf_file() {
  if [[ -z "${WINE_BOX_CNF_FILE:-}" ]]; then
    do_resolve_oap ORG >&2
    do_resolve_oap APP >&2
  fi
  printf '%s\n' "${WINE_BOX_CNF_FILE:-${APP_PATH}/${ORG}-${APP}-cnf/${ORG}-${APP}/dev.env.yaml}"
}

#------------------------------------------------------------------------------
# @description Print one scalar of steps."061-gcp-vm-wine-box" (or $2).
# @param $1 the key, e.g. vm_name
# @param $2 (optional) the step, default 061-gcp-vm-wine-box
#------------------------------------------------------------------------------
do_spl_wine_box_cnf() {
  local key=$1 step=${2:-061-gcp-vm-wine-box} f v
  f=$(_wine_box_cnf_file)
  [[ -f "$f" ]] || { do_log "FATAL no wine-box cnf at $f" >&2; return 1; }
  v=$(yq -r ".env.steps.\"${step}\".${key} // \"\"" "$f" 2>/dev/null)
  [[ -n "$v" && "$v" != null ]] || { do_log "FATAL steps.${step}.${key} is not set in $f" >&2; return 1; }
  printf '%s\n' "$v"
}

#------------------------------------------------------------------------------
# @description The private key path: ssh_public_key_file minus .pub.
#------------------------------------------------------------------------------
do_spl_wine_box_private_key() {
  local pub
  pub=$(do_spl_wine_box_cnf ssh_public_key_file) || return 1
  pub="${pub/#\~/$HOME}"
  printf '%s\n' "${pub%.pub}"
}
