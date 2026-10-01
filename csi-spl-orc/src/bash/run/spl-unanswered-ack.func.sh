#!/bin/bash
#------------------------------------------------------------------------------
# @description Mark an unanswered-sweep item as handled (SPEC-spool-fleet-roles.md
# @description 3.2): the dispatcher read it and it needs no agent reply (an
# @description announcement, a link, a topic the owner closed in words). Appends
# @description "<epoch> <topic> <by> <reason>" to <spool root>/dispatch/unanswered.acks;
# @description do_spl_unanswered_sweep then leaves every human post in that topic
# @description received up to that moment out (column "handled"), so it is not
# @description re-sent or escalated. A NEW human post in the topic opens it again.
# @description Local, no hub call. ACK_LIST=1 prints the acks instead.
# @param TOPIC - required: the topic (task) uuid, or its first 8+ hex characters as the sweep note shows it
# @param REASON - required: why it needs no reply, one line
# @param ACK_BY (optional) - who acks; default SPOOL_AGENT_ID, else the login
# @param ACK_LIST (optional) - 1 prints the acks and exits
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example TOPIC=1b03a790 REASON='channel description post' ./run -a do_spl_unanswered_ack
# @example ACK_LIST=1 ./run -a do_spl_unanswered_ack
#------------------------------------------------------------------------------
do_spl_unanswered_ack() {
  spl_lease_init || return 1
  local f="$LEASE_DIR/unanswered.acks"
  if [[ "${ACK_LIST:-0}" == 1 ]]; then
    [[ -f "$f" ]] || { echo "no acks yet ($f)"; return 0; }
    echo "| when | topic | by | reason |"
    echo "|---|---|---|---|"
    awk -F'\t' '{ cmd = "date -u -d @" $1 " +%FT%TZ"; cmd | getline w; close(cmd); printf "| %s | %s | %s | %s |\n", w, $2, $3, $4 }' "$f"
    return 0
  fi
  local topic="${TOPIC:-}" reason="${REASON:-}" by="${ACK_BY:-${SPOOL_AGENT_ID:-$(id -un)}}"
  topic="${topic,,}"
  [[ "$topic" =~ ^[0-9a-f]{8}(-[0-9a-f-]{1,27})?$ ]] ||
    { do_log "FATAL TOPIC must be a topic uuid or its first 8+ hex characters, got: '${TOPIC:-}'"; return 1; }
  reason="$(tr '\t\n\r' '   ' <<<"$reason")"; reason="${reason%% }"
  [[ -n "${reason// }" ]] || { do_log "FATAL REASON is required: say why the item needs no agent reply"; return 1; }
  [[ "$by" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL ACK_BY is not an id: '$by'"; return 1; }
  ( flock -w 10 9 || exit 1
    printf '%s\t%s\t%s\t%s\n' "$(spl_lease_now)" "$topic" "$by" "$reason" >> "$f" ) 9> "$LEASE_DIR/unanswered.acks.lock" ||
    { do_log "FATAL could not write $f"; return 1; }
  echo "ACK $topic by $by: $reason (a new human post in it opens it again)"
}
