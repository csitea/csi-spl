#!/usr/bin/env bash
# spool-send-box-guard.inc.sh — `--to <ID>@<box>` names the box the lane is
# live on (SPL-6270, specs/058 N1). Sourced by scripts/spool-send.sh after
# spool-env.inc.sh and spool-fleet.inc.sh.
#
# Why: on 2026-11-22 18:18Z a GO went `--to c-346@<box2>` while c-346 was
# live on <box1>; the relay took the named box at its word, the message never
# reached c-346, and its lane stayed idle ~50 min (msg b7bf44b6, n=1).
#
#   send_box_guard <ID> <BOX>   0 send; 8 refuse (the ERROR is on stderr)
#
# Refused only when the fleet lane map has <ID> live on another box and NOT
# on <BOX>. Sent as before: a role seat (001-003, on every box), an id the map
# has live on <BOX>, an id the map does not know (no evidence). A map that
# cannot be read (hub down, timeout, `hub` not ok) never blocks: ONE WARN line.
#
# The map is lane-map.sh --json (the fleet reader, unchanged), kept in
# <spool root>/dispatch/lane-map-send.cache.json for SPOOL_LANE_MAP_TTL s
# (default 120): one read took 2.7..3.4 s on a fleet box (n=3, 2026-11-22),
# a cached one is a jq call. Only a send that names another box reads it.
#
# Stale-while-revalidate (SPL-6512, latency action 2): a usable cache is the
# answer at any age; past the TTL the send starts ONE detached refresh (flock
# on <cache>.lock) and does not wait for it. The synchronous rebuild cost
# p50 9,850 ms on a send past the TTL (lat-hub a-600, n=3, 2026-11-25). Two
# cases still read on the send path: no usable cache at all (a box's first
# send), and a refusal from a stale cache, re-read before it refuses, so a
# refusal always rests on a map younger than the TTL. An id the stale cache
# does not know (a lane spawned since) sends as before: no evidence.
#
# lane-map.sh runs ./run without --json, so its stdout can carry do_log lines
# (INFO/WARN/OK, e.g. "INFO the hub answered on try 2") before the JSON: the
# map is the first JSON value from the first line that starts with `{`
# (R7 W1, g-379 msg 3563e4f6: read whole, such a map failed open).
#
# SPOOL_LANE_MAP_CMD (tests): replaces lane-map.sh --json, prints the map's
# JSON. Under SPOOL_TEST=1 without it the guard is off (no real hub).
# SPOOL_LANE_MAP_TIMEOUT: seconds a fresh read may take, default 15.
# SPOOL_SEND_BOX_GUARD=0 turns the guard off.

# A usable map: the hub answered and lanes is a list (the cache and a fresh read, R7 N2).
_SEND_BOX_MAP_OK='.hub == "ok" and (.lanes | type == "array")'
_send_box_cache() { printf '%s/dispatch/lane-map-send.cache.json' "$SPOOL_ROOT"; }

_send_box_ttl() {
  local t="${SPOOL_LANE_MAP_TTL:-120}"
  [[ "$t" =~ ^[0-9]+$ ]] || t=120
  echo "$t"
}

# The age in s of a usable cache on stdout; rc 1 when there is none.
_send_box_cache_age() {
  local c
  c="$(_send_box_cache)"
  [ -r "$c" ] && jq -e "$_SEND_BOX_MAP_OK" "$c" >/dev/null 2>&1 || return 1
  echo $(( $(date +%s) - $(stat -c %Y "$c" 2>/dev/null || echo 0) ))
}

# A usable cache younger than the TTL: rc 0.
_send_box_cache_fresh() {
  local age
  age="$(_send_box_cache_age)" || return 1
  [ "$age" -ge 0 ] && [ "$age" -lt "$(_send_box_ttl)" ]
}

# Read the map now: its JSON on stdout; rc 1 when it cannot be read. A fresh
# read is cached only when the hub answered (`hub: ok`): a local-only map is
# not the fleet's.
send_box_map_read() {
  local c lim="${SPOOL_LANE_MAP_TIMEOUT:-15}" out tmp
  c="$(_send_box_cache)"
  [[ "$lim" =~ ^[1-9][0-9]*$ ]] || lim=15
  if [ -n "${SPOOL_LANE_MAP_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(timeout -k 1 "$lim" $SPOOL_LANE_MAP_CMD 2>/dev/null)" || return 1
  else
    out="$(timeout -k 1 "$lim" bash "$SPOOL_FEATURE_DIR/scripts/lane-map.sh" --json 2>/dev/null)" || return 1
  fi
  out="$(sed -n '/^{/,$p' <<<"$out" | jq -c -n 'first(inputs)' 2>/dev/null)" || return 1
  jq -e "$_SEND_BOX_MAP_OK" >/dev/null 2>&1 <<<"$out" || return 1
  if [ -d "${c%/*}" ] && tmp="$(mktemp "${c%/*}/.lane-map-send.XXXXXX" 2>/dev/null)"; then
    if printf '%s\n' "$out" >"$tmp" && chmod 0664 "$tmp" 2>/dev/null && mv -f "$tmp" "$c" 2>/dev/null; then :; else rm -f "$tmp"; fi
  fi
  printf '%s\n' "$out"
}

# ONE detached refresh of the cache: a second one while it runs is a no-op
# (flock -n), and so is one that finds the cache fresh again. Every fd is
# redirected: a caller's $(...) never waits for it.
send_box_map_refresh_bg() {
  local c
  c="$(_send_box_cache)"
  [ -d "${c%/*}" ] || return 0
  (
    exec 9>>"$c.lock" || exit 0
    chmod 0664 "$c.lock" 2>/dev/null
    flock -n 9 || exit 0
    _send_box_cache_fresh && exit 0
    send_box_map_read >/dev/null
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# The map's JSON on stdout; rc 1 when it cannot be read. A usable cache is
# the answer at any age; only a missing or unusable one is read on the send
# path. Past the TTL the guard starts the detached refresh, on an allow.
send_box_map() {
  if _send_box_cache_age >/dev/null; then
    cat "$(_send_box_cache)"; return 0
  fi
  send_box_map_read
}

# Allow the send: start the detached refresh when the cache is past the TTL.
_send_box_allow() { _send_box_cache_fresh || send_box_map_refresh_bg; return 0; }

# The boxes MAP has ID live on, one per line.
_send_box_live() {  # ID MAP
  jq -r --arg id "$1" '[.lanes[] | select(.agent_id == $id and .state == "live") | .agent_box] | unique | .[]' <<<"$2" 2>/dev/null
}

send_box_guard() {  # ID BOX
  local id="$1" box="$2" map boxes fix
  [ -n "$box" ] || return 0
  [ "${SPOOL_SEND_BOX_GUARD:-1}" != 0 ] || return 0
  spl_is_role_seat "$id" && return 0
  spl_is_agent_id "$id" || return 0
  [ "${SPOOL_TEST:-}" != 1 ] || [ -n "${SPOOL_LANE_MAP_CMD:-}" ] || return 0
  if ! map="$(send_box_map)"; then
    echo "to: WARN cannot read the fleet lane map; sent to ${id}@${box} unchecked" >&2
    return 0
  fi
  boxes="$(_send_box_live "$id" "$map")"
  [ -n "$boxes" ] || { _send_box_allow; return 0; }
  grep -qxF -- "$box" <<<"$boxes" && { _send_box_allow; return 0; }
  # A refusal rests on a map younger than the TTL: re-read a stale one first.
  if ! _send_box_cache_fresh && map="$(send_box_map_read)"; then
    boxes="$(_send_box_live "$id" "$map")"
    [ -n "$boxes" ] || return 0
    grep -qxF -- "$box" <<<"$boxes" && return 0
  fi
  if [ "$(grep -c . <<<"$boxes")" -eq 1 ]; then
    fix="${id}@${boxes}"
    [ "$boxes" = "$(spool_fleet_box)" ] && fix="$id"
  else
    fix="${id}@<one of: $(paste -sd' ' <<<"$boxes")>"
  fi
  echo "ERROR: ${id} is live on $(paste -sd' ' <<<"$boxes" | sed 's/ /, /g'), not on ${box} (fleet lane map); send it with --to ${fix}. Nothing was sent." >&2
  return 8
}
