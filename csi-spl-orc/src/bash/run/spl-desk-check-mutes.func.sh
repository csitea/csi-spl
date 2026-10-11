#!/bin/bash
#------------------------------------------------------------------------------
# @description A muted seat is never silent again (M2 of the 2026-10-11 desk
# @description gap). A seat's .no-poke marker stops every poke line, and the
# @description seated-only reconcile kept two customer desks' dispatcher seats
# @description muted from 2026-10-10 14:14Z on, so owner posts sat unread while
# @description every check said ok. This lists EVERY seat under
# @description $SPL_STATE_DIR/desk/<tenant>/<box>/spool/<seat> that carries the
# @description marker (seat, tenant, box, age), skipping DESK_AGENT when one is
# @description named. A mute older than DESK_MUTE_ALARM_SECS raises ONE ask
# @description (escalation) to DESK_MUTE_ALARM_TO naming seat, tenant and age.
# @description The raise is marked with the marker's mtime: the same mute is
# @description never raised twice, a new mute (a new mtime) is. A failed send
# @description leaves no mark, so the next run raises it. Never removes a
# @description marker. The desk reconcile cron runs it every tick. Exit 0, 1 cnf, 2 usage.
# @param DESK_AGENT (optional) - the seat being checked, left out of the list
# @param DESK_MUTE_ALARM_SECS (optional) - default 86400 (24 h)
# @param DESK_MUTE_ALARM_TO (optional) - who is asked, default c-001
# @param DESK_MUTE_ALARM_STATE_DIR (optional) - the raise marks, default <spool root>/dispatch/desk-mutes
# @param DESK_MUTE_ALARM_SEND (optional) - the sender, default spool-send.sh (tests)
# @param DESK_MUTE_ALARM_RAISE (optional) - 0 lists only, default 1
# @example ./run -a do_spl_desk_check_mutes
#------------------------------------------------------------------------------
do_spl_desk_check_mutes() {
  local max="${DESK_MUTE_ALARM_SECS:-86400}" raise="${DESK_MUTE_ALARM_RAISE:-1}"
  [[ "$max" =~ ^[0-9]+$ ]] || { do_log "FATAL DESK_MUTE_ALARM_SECS must be seconds, got '$max'"; return 2; }
  [[ "$raise" == 0 || "$raise" == 1 ]] || { do_log "FATAL DESK_MUTE_ALARM_RAISE must be 0 or 1, got '$raise'"; return 2; }
  # Run by the cron through ./run, nothing has read the cnf yet: SPL_STATE_DIR
  # comes from it (do_spl_desk_check calls this with it already set).
  [[ -n "${SPL_STATE_DIR:-}" ]] || do_spl_cloud_cnf || return 1
  local state="${DESK_MUTE_ALARM_STATE_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/desk-mutes}"
  local now m rel tenant box seat mt age n=0
  now="$(date +%s)"
  for m in "$SPL_STATE_DIR"/desk/*/*/spool/*/.no-poke; do
    [[ -e "$m" ]] || continue
    rel="${m#"$SPL_STATE_DIR"/desk/}"
    tenant="${rel%%/*}"; rel="${rel#*/}"; box="${rel%%/*}"
    seat="${m%/.no-poke}"; seat="${seat##*/}"
    [[ "$seat" == "${DESK_AGENT:-}" ]] && continue
    mt="$(stat -c %Y "$m" 2>/dev/null)" || continue
    age=$(( now - mt )); n=$(( n + 1 ))
    printf '%s MUTED seat %s tenant %s box %s age %s since %s\n' "$(date -u +%FT%TZ)" \
      "$seat" "$tenant" "$box" "$(spl_desk_mute_age "$age")" "$(date -u -d "@$mt" +%FT%TZ)"
    (( raise && age > max )) && spl_desk_mute_raise "$tenant" "$box" "$seat" "$mt" "$age" "$state"
  done
  (( n )) || printf '%s OK no muted seat under %s/desk\n' "$(date -u +%FT%TZ)" "$SPL_STATE_DIR"
  return 0
}

# spl_desk_mute_age <secs>: "<h>h<mm>m".
spl_desk_mute_age() { printf '%dh%02dm' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )); }

# spl_desk_mute_raise <tenant> <box> <seat> <marker mtime> <age> <state>: one
# ask per mute. The mark <state>/<tenant>.<box>.<seat>.raised holds the
# marker's mtime: the same value means this mute was raised already.
spl_desk_mute_raise() {
  local tenant="$1" box="$2" seat="$3" mt="$4" age="$5" state="$6" mark to body rc=0
  mark="$state/$tenant.$box.$seat.raised"
  [[ "$(cat "$mark" 2>/dev/null)" == "$mt" ]] && return 0
  mkdir -p "$state" 2>/dev/null || true
  to="${DESK_MUTE_ALARM_TO:-c-001}"
  body="MUTED SEAT: $seat in tenant $tenant (box $box) has carried .no-poke for $(spl_desk_mute_age "$age") (since $(date -u -d "@$mt" +%FT%TZ)). A muted seat is never told of a message. Unmute: TENANT_ID=$tenant DESK_BOX=$box DESK_AGENT=$seat DESK_POKE=1 DRY_RUN=0 ./run -a do_spl_desk_up"
  bash "${DESK_MUTE_ALARM_SEND:-$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/spool-send.sh}" \
    --from "$to" --to "$to" --kind note --task desk-mute-alarm --ask escalation --body "$body" >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  if (( rc == 0 )); then
    printf '%s\n' "$mt" >"$mark.tmp.$$" 2>/dev/null && mv -f "$mark.tmp.$$" "$mark" 2>/dev/null || true
    printf '%s INFO raised an ask to %s: %s %s %s\n' "$(date -u +%FT%TZ)" "$to" "$seat" "$tenant" "$(spl_desk_mute_age "$age")"
  else
    printf '%s WARN could not raise the mute of %s in %s (spool-send exit %s): raised again next run\n' \
      "$(date -u +%FT%TZ)" "$seat" "$tenant" "$rc"
  fi
  return 0
}
