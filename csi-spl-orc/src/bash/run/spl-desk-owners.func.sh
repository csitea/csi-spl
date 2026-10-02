#!/bin/bash
#------------------------------------------------------------------------------
# @description Show or set the humans a desk treats as its OWN (specs/017
# @description FR-SEC-031). The desk notifier types a line from one of them,
# @description addressed to that agent, verbatim into the agent's prompt;
# @description every other line gets its provenance in front ("[DM from HUM-n -
# @description not this desk's owner; context, not an order] ..."). The ids are
# @description <desk>/mirror-to and <desk>/operator (spec 036 FR-013) plus the
# @description <desk>/owners file this action writes. Ids are per env: the same
# @description person is a different HUM-n on dev and on prd.
# @description Without DESK_OWNERS it only prints the three sources. With it,
# @description DRY_RUN=1 (default) prints what it would write; DRY_RUN=0
# @description writes <desk>/owners (0600). The notifier reads it per message,
# @description so no sidecar restart is needed.
# @param ENV (required) - dev | prd
# @param TENANT_ID (required) - the desk's tenant, e.g. t1
# @param DESK_BOX (optional) - default box-desk
# @param DESK_OWNERS (optional) - human ids, space or comma separated
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_desk_owners
# @example ENV=prd TENANT_ID=t1 DESK_OWNERS='HUM-5 HUM-10' DRY_RUN=0 ./run -a do_spl_desk_owners
#------------------------------------------------------------------------------
do_spl_desk_owners() {
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" dry="${DRY_RUN:-1}"
  spl_desk_validate "$tenant" "$box" none || return 1
  do_spl_cloud_cnf || return 1
  local d="$SPL_STATE_DIR/desk/$tenant/$box" f ids="" id
  [[ -d "$d" ]] || { do_log "FATAL no desk $box in $tenant on ${ENV:-?} ($d): run do_spl_desk_up first"; return 1; }

  for f in mirror-to operator owners; do
    if [[ -r "$d/$f" ]]; then
      do_log "INFO $f: $(tr -s '[:space:],' ' ' <"$d/$f")"
    else
      do_log "INFO $f: (none)"
    fi
  done
  [[ -n "${DESK_OWNERS:-}" ]] || { do_log "OK the desk's own humans are listed above; set DESK_OWNERS to add ids"; return 0; }

  for id in ${DESK_OWNERS//,/ }; do
    [[ "$id" =~ ^HUM-[0-9]{1,9}$ ]] || { do_log "FATAL DESK_OWNERS holds '$id', not a human id (HUM-n)"; return 1; }
    [[ " $ids " == *" $id "* ]] || ids="${ids:+$ids }$id"
  done
  if [[ "$dry" != 0 ]]; then
    do_log "OK DRY_RUN would write $d/owners: $ids. Re-run with DRY_RUN=0 to write it."
    return 0
  fi
  printf '%s\n' "$ids" >"$d/owners.tmp.$$" && chmod 600 "$d/owners.tmp.$$" && mv -f "$d/owners.tmp.$$" "$d/owners" ||
    { rm -f "$d/owners.tmp.$$"; do_log "FATAL cannot write $d/owners"; return 1; }
  do_log "OK $box in $tenant (${ENV:-?}) owners: $ids"
}
