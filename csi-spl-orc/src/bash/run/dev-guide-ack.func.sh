#!/bin/bash

#------------------------------------------------------------------------------
# @description Confirm you have read the developer guide
#   (csi-spl-doc/doc/md/developer-guide.md): records one ack line
#   <ts> <who> <guide blob sha> in your per-user ack store. The pre-push hook
#   refuses a push to master by a coder with no ack for the guide HEAD carries;
#   any change to the guide's blob asks for a new ack. Store, who, grandfather
#   rule: spawn-agents/lib/dev-guide-ack.inc.sh. Owner t1 4e373f5d msg 56d7073e.
#   On a terminal it shows the guide and asks; otherwise it needs
#   DEV_GUIDE_ACK=yes, given after reading the guide.
# @param DEV_GUIDE_ACK (optional) - yes: confirm without the prompt
# @param AGENT_ID (optional) - the agent acking, default: SPOOL_AGENT_ID, the
#   lane branch's agent id, else $USER
# @param DEV_GUIDE_ACK_FILE (optional) - the store, default
#   ${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/dev-guide-ack.tsv
# @example ./run -a do_dev_guide_ack
# @example AGENT_ID=c-123 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack
#------------------------------------------------------------------------------
do_dev_guide_ack() {
  local tree="${APP_PATH:-}" guide sha who ans=""
  # shellcheck source=/dev/null
  . "${PROJ_PATH:-$tree/csi-spl-orc}/src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh" || return 1
  guide="$tree/$DGA_GUIDE_REL"
  [[ -f "$guide" ]] || { do_log "FATAL no developer guide at $guide"; return 1; }
  sha="$(git hash-object "$guide")" || return 1
  who="$(dga_who "$tree")"
  if dga_has_ack "$who" "$sha"; then
    do_log "OK $who already confirmed developer-guide.md blob ${sha:0:9} ($(dga_store))"
    return 0
  fi
  if [[ "${DEV_GUIDE_ACK:-}" != yes ]]; then
    if [[ ! -t 0 ]]; then
      do_log "FAIL not confirmed: read $DGA_GUIDE_REL (blob ${sha:0:9}), then run: AGENT_ID=$who DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack"
      return 1
    fi
    cat "$guide"
    read -r -p "Have you read the developer guide above, $who? Type yes to confirm: " ans || true
    [[ "$ans" == yes ]] || { do_log "FAIL not confirmed (answer '$ans'); nothing recorded"; return 1; }
  fi
  dga_record "$who" "$sha" || { do_log "FATAL cannot write the ack store $(dga_store)"; return 1; }
  do_log "ACK $who read developer-guide.md blob $sha ($(dga_store))"
}
