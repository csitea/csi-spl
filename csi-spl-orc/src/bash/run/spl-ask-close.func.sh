#!/bin/bash
# @description Close one ask to the orchestrator (CLE-77929;
# @description SPEC-spool-fleet-roles.md 4.3): done, or declined with a reason.
# @description The ask leaves do_spl_asks_open and the re-raise, and its
# @description carrying message moves from the inbox to archive/ on this
# @description machine. Closing an ask another holder already closed is exit 3
# @description and prints who closed it and why. Tell the sender what you
# @description decided in the same topic: the record is the state, not the
# @description answer.
# @param ASK_ID (required) - the ask id, or its first 8 hex digits
# @param ASK_STATE (optional) - done (default) or declined
# @param ASK_REASON (optional for done, required for declined) - one line: what was done or why not
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator at its box
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=39451306 ASK_REASON='given to CLE-77915, 50-commit target' ./run -a do_spl_ask_close
# @example ASK_ID=7b7f6e64 ASK_STATE=declined ASK_REASON='duplicate of 39451306' ./run -a do_spl_ask_close

do_spl_ask_close() {
  local state="${ASK_STATE:-"done"}" reason
  [[ "$state" =~ ^(done|declined)$ ]] || { do_log "FATAL ASK_STATE must be done or declined"; return 1; }
  reason="$(printf '%s' "${ASK_REASON:-}" | tr '\t\r\n' '   ' | tr -d '\000-\037\177' | cut -b 1-500)"
  [[ "$state" == "done" || -n "$reason" ]] || { do_log "FATAL a decline needs ASK_REASON"; return 1; }
  local op="done"
  [[ "$state" == declined ]] && op="decline"
  spl_ask_update "$op" "$state" "$reason"
}
