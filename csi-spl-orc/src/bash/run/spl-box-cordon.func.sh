#!/bin/bash
#------------------------------------------------------------------------------
# @description Cordon a box: no new lane is placed on it until the cordon
# @description is lifted or expires (sat alone panel row 01, SPL-2629; owner
# @description HUM-10 t1 721ad6e4: prd and dev continue on sat alone at 10
# @description minutes' notice). The marker is <spool root>/dispatch/cordon/<box>,
# @description one line `until=<epoch> at=<UTC> by=<who> min=<N>`, written on
# @description the box that places (the orch holder's). do_spl_box_pick reads
# @description it: a cordoned box's BOX line says "CORDONED (until <UTC>)" and
# @description the box is never picked, not even by the every-box-degraded
# @description fallback; every box cordoned -> pick=hold. The placer's
# @description pinned-row check (spl-spawn-place.func.sh) holds a row pinned to
# @description it. A cordon past its until is none (no sweep needed); `off`
# @description removes the file. Unlike do_spl_box_leave (run ON the leaving
# @description box) the cordon is set from another box, for one that may be
# @description switched off already. It stops no lane and moves no lease.
# @param CORDON_CMD (optional) - show (default) | on | off
# @param BOX (on/off: required; show: optional) - the box id, e.g. <pc box>
# @param CORDON_MIN (optional) - on: minutes until it expires, 1..10080, default 240
# @param DRY_RUN (optional) - on/off: 1 (default) prints what it would do, 0 writes
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_box_cordon
# @example BOX=<pc box> CORDON_CMD=on CORDON_MIN=240 DRY_RUN=0 ./run -a do_spl_box_cordon
# @example BOX=<pc box> CORDON_CMD=off DRY_RUN=0 ./run -a do_spl_box_cordon
#------------------------------------------------------------------------------

do_spl_box_cordon() {
  local cmd="${CORDON_CMD:-show}" box="${BOX:-}" min="${CORDON_MIN:-240}" dry="${DRY_RUN:-1}"
  local dir f until w="WOULD "
  dir="$(spl_box_cordon_dir)"
  [[ "$cmd" =~ ^(show|on|off)$ ]] || { do_log "FATAL CORDON_CMD must be show, on or off, got '$cmd'"; return 1; }
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 1; }
  [[ -z "$box" || "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX must be a box id, got '$box'"; return 1; }
  [[ "$cmd" == show ]] && { spl_box_cordon_show "$dir" "$box"; return; }
  [[ -n "$box" ]] || { do_log "FATAL BOX is required for CORDON_CMD=$cmd"; return 1; }
  [[ "$dry" == 0 ]] && w=""
  f="$dir/$box"
  if [[ "$cmd" == off ]]; then
    [[ -e "$f" ]] || { echo "box-cordon: $box is not cordoned, nothing to lift"; return 0; }
    echo "box-cordon: ${w}lift the cordon on $box ($f)"
    [[ "$dry" == 0 ]] && { rm -f "$f" || { do_log "FATAL cannot remove $f"; return 1; }; }
    return 0
  fi
  [[ "$min" =~ ^[0-9]+$ ]] && ((min >= 1 && min <= 10080)) ||
    { do_log "FATAL CORDON_MIN must be whole minutes 1..10080, got '$min'"; return 1; }
  until=$(( $(date +%s) + min * 60 ))
  echo "box-cordon: ${w}cordon $box for $min min, until $(date -u -d "@$until" +%FT%TZ) ($f)"
  [[ "$dry" == 1 ]] && return 0
  mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  printf 'until=%s at=%s by=%s min=%s\n' "$until" "$(date -u +%FT%TZ)" "${SPOOL_AGENT_ID:-${AGENT_ID:-$USER}}" "$min" >"$f.tmp" &&
    mv -f "$f.tmp" "$f" || { do_log "FATAL cannot write $f"; return 1; }
}

# The cordon markers' directory.
spl_box_cordon_dir() { printf '%s/dispatch/cordon\n' "${SPOOL_ROOT:-/var/spool-hub}"; }

# spl_box_cordon_active [DIR] -> the live cordons as JSON {"<box>": until_epoch};
# a file past its until, unreadable or without until=<epoch> is none.
spl_box_cordon_active() {
  local dir="${1:-$(spl_box_cordon_dir)}" f b u now out="{}"
  now="$(date +%s)"
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    b="${f##*/}"
    [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
    u="$(sed -n '1s/^until=\([0-9]\{1,12\}\)\( .*\)\{0,1\}$/\1/p' "$f" 2>/dev/null)"
    [[ -n "$u" ]] && ((u > now)) || continue
    out="$(jq -c --arg b "$b" --argjson u "$u" '. + {($b): $u}' <<<"$out")"
  done
  printf '%s\n' "$out"
}

# One line per cordon file (BOX only: that box): active until <UTC>, or expired.
spl_box_cordon_show() {  # DIR [BOX]
  local act f b n=0
  act="$(spl_box_cordon_active "$1")"
  for f in "$1"/*; do
    [[ -f "$f" ]] || continue
    b="${f##*/}"
    [[ -z "${2:-}" || "$b" == "$2" ]] || continue
    n=$((n + 1))
    if jq -e --arg b "$b" 'has($b)' >/dev/null <<<"$act"; then
      echo "CORDONED $b until $(date -u -d "@$(jq -r --arg b "$b" '.[$b]' <<<"$act")" +%FT%TZ) ($(head -1 "$f"))"
    else
      echo "expired $b ($(head -1 "$f")): not a cordon"
    fi
  done
  ((n > 0)) || echo "box-cordon: no cordon${2:+ on $2} ($1)"
}
