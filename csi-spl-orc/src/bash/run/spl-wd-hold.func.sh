#!/bin/bash
#------------------------------------------------------------------------------
# @description Put one agent out of the watchdog's reach for MIN minutes
# @description (spec 093 6.2 and 6.3: a human working in that pane): the
# @description watchdog still writes its verdict, but sends it no key, no ring
# @description and no takeover. Writes <spool root>/<id>/.human-hold holding
# @description the epoch the hold ends at; MIN=0 lifts it.
# @param ID - required: the agent id
# @param MIN (optional) - minutes, default 30; 0 lifts the hold
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ID=c-007 ./run -a do_spl_wd_hold
# @example ID=c-007 MIN=0 ./run -a do_spl_wd_hold
#------------------------------------------------------------------------------
do_spl_wd_hold() {
  local id="${ID:-}" min="${MIN:-30}" d f until
  d="${SPOOL_ROOT:-/var/spool-hub}/$id"
  f="$d/.human-hold"
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] || { do_log "FATAL ID must be an agent id, got: '$id'"; return 1; }
  [[ "$min" =~ ^[0-9]+$ ]] || { do_log "FATAL MIN must be a whole number of minutes, got: '$min'"; return 1; }
  [[ -d "$d" ]] || { do_log "FATAL no spool dir $d: not an agent of this box"; return 1; }
  if (( min == 0 )); then
    rm -f "$f"
    do_log "INFO $id: hold lifted, the watchdog acts on it again"
    return 0
  fi
  until=$(( ${WD_NOW:-$(date +%s)} + min * 60 ))
  printf '%s\n' "$until" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  do_log "INFO $id: held from the watchdog until $(date -u -d "@$until" +%FT%TZ) ($min min)"
  return 0
}
