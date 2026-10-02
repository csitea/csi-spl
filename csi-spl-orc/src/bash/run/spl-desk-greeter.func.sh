#!/bin/bash
#------------------------------------------------------------------------------
# @description Show or set a desk's GREETER: the one agent that welcomes a
# @description person admitted to the tenant (do_spl_desk_welcome, SPL-961).
# @description One agent per workspace, never every seated bot (CLE-77896:
# @description three unrelated lanes once each welcomed one new member within
# @description 2 s). No greeter = nobody greets, which is the default.
# @description Without DESK_GREETER it only prints the current one. With it,
# @description DRY_RUN=1 (default) prints what it would write; DRY_RUN=0
# @description writes <desk>/greeter, or removes it for DESK_GREETER=none.
# @description The welcome run reads it per admit, so no restart is needed.
# @param ENV (required) - dev | prd
# @param TENANT_ID (required) - the desk's tenant, e.g. t1
# @param DESK_BOX (optional) - default box-desk
# @param DESK_GREETER (optional) - one agent id (CLE-n, GRK-n, ...) or none
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_desk_greeter
# @example ENV=prd TENANT_ID=t1 DESK_GREETER=CLE-7 DRY_RUN=0 ./run -a do_spl_desk_greeter
# @example ENV=prd TENANT_ID=t1 DESK_GREETER=none DRY_RUN=0 ./run -a do_spl_desk_greeter
#------------------------------------------------------------------------------
do_spl_desk_greeter() {
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" dry="${DRY_RUN:-1}" g="${DESK_GREETER:-}"
  spl_desk_validate "$tenant" "$box" none || return 1
  do_spl_cloud_cnf || return 1
  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  [[ -d "$d" ]] || { do_log "FATAL no desk $box in $tenant on ${ENV:-?} ($d): run do_spl_desk_up first"; return 1; }

  local cur
  cur="$(spl_desk_greeter "$tenant" "$box")"
  do_log "INFO greeter: ${cur:-(none - nobody greets)}"
  [[ -n "$g" ]] || { do_log "OK set DESK_GREETER to an agent id, or none to clear it"; return 0; }
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ "$g" == none ]] || spl_is_agent_id "$g" ||
    { do_log "FATAL DESK_GREETER '$g' is not an agent id (CLE-n, GRK-n, ...) or none"; return 1; }
  [[ "$g" == none || -d "$d/spool/$g" ]] ||
    do_log "WARN $g is not seated on $box in $tenant yet; it greets once it is seated and live"
  if [[ "$dry" != 0 ]]; then
    do_log "OK DRY_RUN would $([[ "$g" == none ]] && echo "remove $d/greeter" || echo "write $d/greeter: $g"). Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$g" == none ]]; then
    rm -f "$d/greeter" || { do_log "FATAL cannot remove $d/greeter"; return 1; }
    do_log "OK $box in $tenant (${ENV:-?}) has no greeter: nobody greets a new member"
    return 0
  fi
  printf '%s\n' "$g" >"$d/greeter.tmp.$$" && mv -f "$d/greeter.tmp.$$" "$d/greeter" ||
    { rm -f "$d/greeter.tmp.$$"; do_log "FATAL cannot write $d/greeter"; return 1; }
  do_log "OK $box in $tenant (${ENV:-?}) greeter: $g"
}
