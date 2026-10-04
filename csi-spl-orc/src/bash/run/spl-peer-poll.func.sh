#!/bin/bash
#------------------------------------------------------------------------------
# @description The peer poll loop of one OD seat (spec 068 section 4.1, lane
# @description L3): a shell loop, no model call. Every PEER_POLL_SEC (5) s:
# @description   1. is my agent able (spl_lease_agent_able) and, while it holds
# @description      a message, has its transcript grown within
# @description      PEER_PROGRESS_MAX (600) s of the later of its last write
# @description      and its last claim? No: no claim, no renew - its locks run
# @description      out in LOCK_TTL on the hub and another peer takes them
# @description   2. renew the lock of every message my seat holds
# @description   3. claim at most PEER_MAX_HELD (3) minus what I hold
# @description   4. write each claimed message into my agent's inbox (once per
# @description      msg_id) and ring its pane
# @description Hub down (the claim call fails): the LOCAL LOCK. Each seat of
# @description this machine takes a local-origin message (<spool root>/peers/
# @description inbox) by an O_EXCL create of <spool root>/claims/<msg id>;
# @description exactly one seat wins. Back on the hub, each local lock is
# @description pushed as the message's responsible, insert-if-absent.
# @description INERT until a seat exists: no <spool root>/peer/seats line for
# @description PEER_SEAT = nothing runs and nothing is written.
# @description The hub calls (L1's box frame `claim`, CLI `spool claim`):
# @description   --poll  --seat S --harness H --max N --ttl T -> JSON array of the
# @description           claimed messages (msg_id, responsible_gen, and the v:1
# @description           fields task_id, ts, from, to, kind, body, files)
# @description   --renew --seat S --ttl T -> JSON array (msg_id, responsible_gen)
# @description           of every message S holds and has not closed
# @description   --check --seat S --msg M --gen G -> exit 0 still mine, 1 lost
# @description   --adopt --seat S --msg M -> set responsible if absent
# @description Any other exit, or a timeout, is "hub down".
# @param PEER_SEAT - required: this seat's agent id (c-001 .. g-004)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param PEER_BOX (optional) - this machine's box, default its desk box id
# @param PEER_POLL_SEC (optional) - seconds between ticks, default 5
# @param PEER_LOCK_TTL (optional) - the lock the hub sets, default 120 s
# @param PEER_MAX_HELD (optional) - messages one seat holds at most, default 3
# @param PEER_PROGRESS_MAX (optional) - s without a transcript write while holding, default 600
# @param PEER_HUB_TIMEOUT (optional) - one hub call's limit, default 10 s
# @param PEER_TICKS (optional) - stop after N ticks (tests)
# @param PEER_HUB_CMD / PEER_POKE_CMD (optional) - replace the hub call / the pane ring (tests)
# @example PEER_SEAT=c-001 ./run -a do_spl_peer_poll
# @example PEER_SEAT=c-001 PEER_MSG=<msg id> PEER_GEN=3 ./run -a do_spl_peer_fence
#------------------------------------------------------------------------------
declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"
declare -F spl_lease_agent_able >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"
SPL_PEER_SRC="${BASH_SOURCE[0]}"

do_spl_peer_poll() {
  spl_peer_init ro || return 1
  spl_peer_seated "${PEER_SEAT:-}" || { do_log "INFO ${PEER_SEAT:-<no PEER_SEAT>} is no seat in $PEER_SEATS - nothing to poll"; return 0; }
  spl_peer_init || return 1
  spl_peer_loop
}

# The fence (spec 068 section 4.2): 0 when PEER_SEAT still holds PEER_MSG at
# generation PEER_GEN on the hub; 1 when it lost it; 2 when the hub cannot
# say (split brain: the caller stops, it never acts on an unconfirmed lock).
do_spl_peer_fence() {
  spl_peer_init ro || return 2
  [[ "${PEER_SEAT:-}" =~ ^[acgq]-[0-9]{3}$ && "${PEER_MSG:-}" =~ ^[A-Za-z0-9-]+$ && "${PEER_GEN:-}" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL PEER_SEAT, PEER_MSG and PEER_GEN are required"; return 2; }
  spl_peer_fence "$PEER_SEAT" "$PEER_MSG" "$PEER_GEN"
}

spl_peer_fence() {
  local rc=0
  spl_peer_hub --check --seat "$1@$PEER_BOX" --msg "$2" --gen "$3" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) spl_peer_log "$1 FENCE lost $2 gen $3"; return 1 ;;
    *) spl_peer_log "$1 FENCE unconfirmed $2 gen $3 (hub exit $rc)"; return 2 ;;
  esac
}

# Settings and dirs ("ro": create nothing). LEASE_NOW (an epoch) drives the
# clock in the tests, as for the lease.
spl_peer_init() {
  PEER_DIR="${SPOOL_ROOT:-/var/spool-hub}/peer"
  PEER_SEATS="$PEER_DIR/seats"
  PEER_LOG="$PEER_DIR/peer.log"
  PEER_BOX="${PEER_BOX:-$(spl_desk_box_default)}"
  PEER_POLL_SEC="${PEER_POLL_SEC:-5}"
  PEER_LOCK_TTL="${PEER_LOCK_TTL:-120}"
  PEER_MAX_HELD="${PEER_MAX_HELD:-3}"
  PEER_PROGRESS_MAX="${PEER_PROGRESS_MAX:-600}"
  local k
  for k in PEER_POLL_SEC PEER_LOCK_TTL PEER_MAX_HELD PEER_PROGRESS_MAX; do
    [[ "${!k}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $k must be a positive integer"; return 1; }
  done
  [[ "$PEER_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL PEER_BOX is not a box id: '$PEER_BOX'"; return 1; }
  [[ "${1:-}" == ro ]] && return 0
  spl_lease_init || return 1
}

# The seats of this machine: <spool root>/peer/seats, "<id> <harness>" lines
# (# comments), written by the seat setup (L7). Read, never sourced.
spl_peer_seats() {
  [[ -f "$PEER_SEATS" ]] || return 0
  sed 's/#.*//' "$PEER_SEATS" | awk '$1 ~ /^[acgq]-[0-9][0-9][0-9]$/ && $2 ~ /^[a-z]+$/ {print $1, $2}'
}

# 0 when <id> has a seat here; sets PEER_HARNESS.
spl_peer_seated() {
  local id h
  [[ -n "$1" ]] || return 1
  while read -r id h; do
    [[ "$id" == "$1" ]] && { PEER_HARNESS="$h"; return 0; }
  done < <(spl_peer_seats)
  return 1
}

spl_peer_log() { echo "$(date -u +%FT%TZ) $*" >> "$PEER_LOG"; }

# A line logged once per state change of <seat>, not every tick.
spl_peer_once() {
  local f="$PEER_DIR/$1/state"
  [[ "$(cat "$f" 2>/dev/null)" == "$2" ]] && return 0
  echo "$2" > "$f"; spl_peer_log "$1 $2${3:+ ($3)}"
}

# One hub call: PEER_HUB_CMD (tests) or `spool claim` with this machine's
# box identity, under a timeout so a hung dial never stalls the tick.
spl_peer_hub() {
  if [[ -n "${PEER_HUB_CMD:-}" ]]; then "$PEER_HUB_CMD" claim "$@"; return; fi
  if [[ -z "${SPOOL_BIN:-}" ]]; then
    declare -F spool_env_resolve >/dev/null ||
      source "$(dirname "$SPL_PEER_SRC")/../features/spawn-agents/lib/spool-env.inc.sh" || return 90
    spool_env_resolve >/dev/null 2>&1 || return 90
  fi
  timeout "${PEER_HUB_TIMEOUT:-10}" "$SPOOL_BIN" claim "$@"
}

spl_peer_loop() {
  local d="$PEER_DIR/$PEER_SEAT" n
  mkdir -p "$d/seen" || { do_log "FATAL cannot create $d"; return 1; }
  exec 7> "$d/poll.run"
  flock -w 2 7 || { do_log "INFO the $PEER_SEAT poll loop already runs - nothing to do"; return 0; }
  echo "$$" > "$d/poll.pid"
  spl_peer_code_ver > "$d/poll.ver"
  spl_peer_log "$PEER_SEAT poll start pid=$$ harness=$PEER_HARNESS"
  # four seats started together (a reboot) still poll at different seconds
  n="${PEER_SEAT#*-}"; n=$((10#$n))
  [[ -z "${PEER_TICKS:-}" ]] && sleep "$(awk -v n="$n" -v p="$PEER_POLL_SEC" 'BEGIN { printf "%.2f", ((n - 1) % 4) * p / 4 }')"
  while :; do
    spl_peer_tick "$PEER_SEAT"
    [[ -n "${PEER_TICKS:-}" ]] && { PEER_TICKS=$((PEER_TICKS - 1)); (( PEER_TICKS > 0 )) || break; }
    sleep "$PEER_POLL_SEC"
  done
}

# The code a loop runs (this file and the seats): ensure replaces a loop
# whose code or seat list has changed.
spl_peer_code_ver() {
  { cat "$SPL_PEER_SRC"; cat "$PEER_SEATS" 2>/dev/null; } | sha1sum | cut -c1-12
}

# One tick of seat <id> (PEER_HARNESS set). The held list is
# <dir>/held ("<msg_id> <gen>" lines, the hub's answer to the last renew or
# claim); <dir>/claimed_at is the epoch of the last claim.
spl_peer_tick() {
  local id="$1" d="$PEER_DIR/$1" pid now act ref out room held=0
  mkdir -p "$d/seen"
  now="$(spl_lease_now)"
  pid="$(spl_peer_able "$id")"
  if [[ -z "$pid" ]]; then
    spl_peer_once "$id" "idle: not able" "$(cat "$LEASE_DIR/able.$id" 2>/dev/null)"; return 0
  fi
  [[ -s "$d/held" ]] && held="$(grep -c . "$d/held")"
  if (( held > 0 )); then
    act="$(spl_lease_activity "$pid" 2>/dev/null)"
    ref="$(cat "$d/claimed_at" 2>/dev/null)"; [[ "$ref" =~ ^[0-9]+$ ]] || ref=0
    [[ "$act" =~ ^[0-9]+$ ]] && (( act > ref )) && ref="$act"
    if (( ref > 0 && now - ref > PEER_PROGRESS_MAX )); then
      spl_peer_once "$id" "idle: no progress" "holds $held, no transcript write for $((now - ref))s > ${PEER_PROGRESS_MAX}s"; return 0
    fi
  fi
  if ! out="$(spl_peer_hub --renew --seat "$id@$PEER_BOX" --ttl "$PEER_LOCK_TTL" 2>/dev/null)" ||
     ! spl_peer_rows "$out" > "$d/held.new"; then
    rm -f "$d/held.new"; spl_peer_hub_down "$id"; return 0
  fi
  mv -f "$d/held.new" "$d/held"
  spl_peer_hub_back "$id"
  held="$(grep -c . "$d/held")"
  room=$((PEER_MAX_HELD - held))
  if (( room > 0 )); then
    if ! out="$(spl_peer_hub --poll --seat "$id@$PEER_BOX" --harness "$PEER_HARNESS" --max "$room" --ttl "$PEER_LOCK_TTL" 2>/dev/null)" ||
       ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
      spl_peer_hub_down "$id"; return 0
    fi
    spl_peer_take "$id" "$out" "$now"
  fi
  spl_peer_once "$id" "polling"
  return 0
}

# The pid of seat <id> when it is live and able (spl_lease_agent_able: the
# process, the pane stall); empty otherwise. That check counts claude
# processes only, so a seat of another harness (the grok seats, 3.3) is
# found here by the CLI's own process name (PEER_HARNESS, node, bun) and
# then passes the same pane stall check. Why not: $LEASE_DIR/able.<id>.
spl_peer_able() {
  local id="$1" pid why root="${LEASE_PROC_ROOT:-/proc}" d comm
  pid="$(spl_lease_agent_able "$id")"
  [[ -n "$pid" || "${PEER_HARNESS:-claude}" == claude ]] && { echo "$pid"; return 0; }
  pid="$(for d in "$root"/[0-9]*; do
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null
      [[ "$comm" == "$PEER_HARNESS" || "$comm" == node || "$comm" == bun ]] || continue
      if [[ -r "$d/environ" ]]; then grep -qzx "SPOOL_AGENT_ID=$id" "$d/environ" 2>/dev/null && echo "${d##*/}"
      elif declare -F spool_proc_env_get >/dev/null; then
        spool_proc_env_get "$root" SPOOL_AGENT_ID "${d##*/}" | awk -v id="$id" '$2 == id {print $1}'
      fi
    done | sort -n | sed -n 1p)"
  [[ -n "$pid" ]] || return 0
  why="$(spl_lease_stall "$pid")"
  if [[ -n "$why" ]]; then printf 'stalled pid=%s: %s\n' "$pid" "$why" > "$LEASE_DIR/able.$id"; return 0; fi
  echo able > "$LEASE_DIR/able.$id"; echo "$pid"
}

# "<msg_id> <gen>" per row of a hub JSON array (an empty array prints
# nothing); non-zero when the answer is no array.
spl_peer_rows() {
  jq -e 'type == "array"' <<<"$1" >/dev/null 2>&1 || return 1
  jq -r '.[] | "\(.msg_id) \(.responsible_gen // 0)"' <<<"$1" | grep -E '^[A-Za-z0-9-]+ [0-9]+$'
  return 0
}

# Deliver each claimed row once and ring the pane once.
spl_peer_take() {
  local id="$1" out="$2" now="$3" row mid gen got=0
  while IFS= read -r row; do
    mid="$(jq -r '.msg_id // empty' <<<"$row")"; gen="$(jq -r '.responsible_gen // 0' <<<"$row")"
    [[ "$mid" =~ ^[A-Za-z0-9-]+$ ]] || continue
    grep -q "^$mid " "$PEER_DIR/$id/held" 2>/dev/null || echo "$mid $gen" >> "$PEER_DIR/$id/held"
    echo "$now" > "$PEER_DIR/$id/claimed_at"
    spl_peer_log "$id CLAIM $mid gen $gen"
    spl_peer_deliver "$id" "$mid" "$row" && got=$((got + 1))
  done < <(jq -c '.[]' <<<"$out" 2>/dev/null)
  (( got > 0 )) && spl_peer_ring "$id"
  return 0
}

# Write <row> into <id>'s inbox as a v:1 message, once per msg_id (the
# <dir>/seen marker); non-zero when it was there already.
spl_peer_deliver() {
  local id="$1" mid="$2" row="$3" in="${SPOOL_ROOT:-/var/spool-hub}/$1/inbox" ts from f
  ( set -o noclobber; : > "$PEER_DIR/$id/seen/$mid" ) 2>/dev/null || return 1
  mkdir -p "$in"
  ts="$(jq -r '.ts // empty' <<<"$row")"; [[ -n "$ts" ]] || ts="$(date -u -d "@$(spl_lease_now)" +%FT%TZ)"
  from="$(jq -r '.from // "peers"' <<<"$row" | tr -c 'A-Za-z0-9@_\n-' '-')"
  f="$in/$(tr -d ':-' <<<"$ts")--${from}--peer-claim-${mid:0:8}.json"
  jq -c --arg mid "$mid" --arg to "$id" --arg ts "$ts" '{v: 1, msg_id: $mid, task_id: (.task_id // $mid), ts: $ts,
      from: (.from // "peers"), to: $to, kind: (.kind // "msg"), body: (.body // ""), files: (.files // []),
      responsible_gen: (.responsible_gen // 0)}' <<<"$row" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

spl_peer_ring() {
  if [[ -n "${PEER_POKE_CMD:-}" ]]; then "$PEER_POKE_CMD" "$1" >/dev/null 2>&1; return 0; fi
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$(dirname "$SPL_PEER_SRC")/../features/spawn-agents/scripts/spool-send.sh" \
    --poke-only --to "$1" --from "$1" >/dev/null 2>&1 7>&-
  return 0
}

# ---- the local lock (spec 068 section 7, "hub down") -------------------------
# Nothing crosses machines without the hub, so a machine's own seats only
# need to agree among themselves: an O_EXCL create of <root>/claims/<msg id>
# ("<seat>@<box> <epoch>") is the lock. Local-origin messages only: the ones
# in <root>/peers/inbox (a terminal report to the peers).
spl_peer_hub_down() {
  local id="$1" root="${SPOOL_ROOT:-/var/spool-hub}" f mid held room got=0
  spl_peer_once "$id" "hub down: local lock"
  touch "$PEER_DIR/$id/hub.down"
  mkdir -p "$root/claims"
  held="$(grep -lx "$id@$PEER_BOX [0-9]*" "$root"/claims/* 2>/dev/null | grep -vc '\.pushed$')"
  room=$((PEER_MAX_HELD - held))
  for f in "$root"/peers/inbox/*.json; do
    (( room > got )) || break
    [[ -f "$f" ]] || continue
    mid="$(jq -r '.msg_id // empty' "$f" 2>/dev/null)"
    [[ "$mid" =~ ^[A-Za-z0-9-]+$ ]] || continue
    [[ -e "$root/claims/$mid.pushed" ]] && continue
    ( set -o noclobber; echo "$id@$PEER_BOX $(spl_lease_now)" > "$root/claims/$mid" ) 2>/dev/null || continue
    spl_peer_log "$id LOCAL-CLAIM $mid"
    spl_peer_deliver "$id" "$mid" "$(cat "$f")" && got=$((got + 1))
  done
  (( got > 0 )) && spl_peer_ring "$id"
  return 0
}

# Back on the hub: push each of this seat's local locks as the message's
# responsible, insert-if-absent (the hub keeps a seat that holds it already).
spl_peer_hub_back() {
  local id="$1" root="${SPOOL_ROOT:-/var/spool-hub}" f mid
  [[ -f "$PEER_DIR/$id/hub.down" ]] || return 0
  for f in "$root"/claims/*; do
    [[ -f "$f" && "$f" != *.pushed ]] || continue
    grep -qx "$id@$PEER_BOX [0-9]*" "$f" || continue
    mid="${f##*/}"
    if spl_peer_hub --adopt --seat "$id@$PEER_BOX" --msg "$mid" >/dev/null 2>&1; then
      mv -f "$f" "$f.pushed"; spl_peer_log "$id ADOPT $mid"
    else
      spl_peer_log "$id ADOPT-FAILED $mid (kept for the next tick)"; return 0
    fi
  done
  rm -f "$PEER_DIR/$id/hub.down"
  spl_peer_log "$id hub back: local locks pushed"
}
