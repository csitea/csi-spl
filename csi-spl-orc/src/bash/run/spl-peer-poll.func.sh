#!/bin/bash
#------------------------------------------------------------------------------
# @description The peer poll loop of one OD seat (spec 068 section 4.1, lane
# @description L3), on spec 093's two-phase claim (section 4, task T010): a
# @description shell loop, no model call. The loop never owns a job: it tells
# @description its agent about one (a stub), and only the agent's own
# @description `spool claim --accept` makes it the owner (T2). Every
# @description PEER_POLL_SEC (5) s, while the agent is able (spl_peer_able):
# @description   1. the heartbeat verdict (spec 5.3, <root>/<id>/heartbeat.json):
# @description      fresh (progress within PEER_HB_FRESH, or a tool call within
# @description      its cap) with its anchor, else able; an api_error is stale.
# @description      idle = the hook's state idle, anything else busy
# @description   2. the renew (T4) carries that verdict: the hub moves an owned
# @description      lock to anchor + 120 s while fresh, a parked one while able,
# @description      never to now + TTL. Its answer is <dir>/held and the touch
# @description      marks the Stop hook reads
# @description   3. ready (fresh or idle, fewer than PEER_MAX_HELD owned): a
# @description      parked job whose wait_token has answered in the inbox is
# @description      re-offered to its holder alone (T7b); then the round poll
# @description      (--state idle|busy, the box's other ready seats): the hub
# @description      opens and joins the rounds (idle first, BUSY_DELAY, OFFER_K,
# @description      the harness mix) and returns each round this seat is in
# @description   4. one stub per (job, round) into the agent's inbox, only for
# @description      a round whose offer_set names this seat; an idle agent is rung
# @description   5. inbox reconciliation (4.5): a stub whose round lapsed, was
# @description      taken or closed moves to archive/ with "lost"
# @description Not able: no hub call and no renew; its locks run out 120 s
# @description after its anchor and another seat's round takes them.
# @description Hub down (the renew fails): the LOCAL LOCK. Each seat of
# @description this machine takes a local-origin message (<spool root>/peers/
# @description inbox) by an O_EXCL create of <spool root>/claims/<msg id>;
# @description exactly one seat wins. Back on the hub, each local lock is
# @description pushed as the message's responsible, insert-if-absent.
# @description INERT until a seat exists: no <spool root>/peer/seats line for
# @description PEER_SEAT = nothing runs and nothing is written.
# @description The hub calls (box frame `claim`, CLI `spool claim`, 093 T009):
# @description   --renew --seat S --hb fresh|able --anchor-age A -> JSON array
# @description           of the jobs S holds (msg_id, responsible_gen,
# @description           claim_state, touched_at, wait_token)
# @description   --poll  --seat S --state idle|busy --max N [--ready s,s] -> JSON
# @description           array of the open rounds S is in (msg_id, round,
# @description           offer_set, offer_until, the v:1 head, no body); a row
# @description           the poll closed dead carries "dead": true
# @description   --reoffer M --seat S --gen G -> T7b
# @description   --check --seat S --msg M --gen G -> exit 0 still mine, 1 lost
# @description   --adopt --seat S --msg M -> set responsible if absent
# @description Any other exit, or a timeout, is "hub down".
# @param PEER_SEAT - required: this seat's agent id (c-001 .. g-004)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param PEER_BOX (optional) - this machine's box, default its desk box id
# @param PEER_POLL_SEC (optional) - seconds between ticks, default 5
# @param PEER_MAX_HELD (optional) - jobs one seat owns at most, default 3
# @param PEER_HB_FRESH (optional) - s of fresh after the last progress, default 120 (the hub's HB_FRESH)
# @param PEER_TOOL_MAX (optional) - "Tool=sec,..." caps of a tool call in progress (spec 6.1 S4)
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
  PEER_MAX_HELD="${PEER_MAX_HELD:-3}"
  PEER_HB_FRESH="${PEER_HB_FRESH:-120}"
  local k
  for k in PEER_POLL_SEC PEER_MAX_HELD PEER_HB_FRESH; do
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

# One tick of seat <id> (PEER_HARNESS set). <dir>/held is "<msg_id> <gen>"
# per job the seat holds (the hub's answer to the last renew; S1 and the
# Stop hook read it), <dir>/ready the epoch of its last ready tick (the
# other seats of this box name it in their poll's --ready).
spl_peer_tick() {
  local id="$1" d="$PEER_DIR/$1" pid now out held offered="" owned room
  mkdir -p "$d/seen"
  now="$(spl_lease_now)"
  pid="$(spl_peer_able "$id")"
  if [[ -z "$pid" ]]; then
    rm -f "$d/ready"
    spl_peer_once "$id" "idle: not able" "$(cat "$LEASE_DIR/able.$id" 2>/dev/null)"; return 0
  fi
  spl_peer_hb "$id" "$pid" "$now"
  if ! out="$(spl_peer_hub --renew --seat "$id@$PEER_BOX" --hb "$PEER_HB" --anchor-age "$PEER_ANCHOR_AGE" 2>/dev/null)" ||
     ! held="$(spl_peer_held_rows "$out")"; then
    rm -f "$d/ready"; spl_peer_hub_down "$id"; return 0
  fi
  awk '{print $1, $2}' <<<"$held" | grep . > "$d/held.new"; mv -f "$d/held.new" "$d/held"
  spl_peer_hub_back "$id"
  spl_peer_touch_marks "$id" "$held"
  owned="$(awk '$3 == "owned"' <<<"$held" | grep -c .)"
  room=$((PEER_MAX_HELD - owned))
  if [[ "$PEER_HB" == stale ]] || [[ "$PEER_HB" != fresh && "$PEER_STATE" != idle ]] || (( room < 1 )); then
    rm -f "$d/ready"
    spl_peer_reconcile "$id" "$held" "" "$now"
    spl_peer_once "$id" "not ready: $PEER_HB $PEER_STATE" "owns $owned"; return 0
  fi
  echo "$now" > "$d/ready"
  spl_peer_reoffer "$id" "$held"
  if ! out="$(spl_peer_hub --poll --seat "$id@$PEER_BOX" --state "$PEER_STATE" --max "$room" \
        ${PEER_READY:+--ready "$PEER_READY"} 2>/dev/null)" ||
     ! offered="$(spl_peer_offer_rows "$id@$PEER_BOX" "$out")"; then
    rm -f "$d/ready"; spl_peer_hub_down "$id"; return 0
  fi
  if spl_peer_offer "$id" "$offered" "$out" && [[ "$PEER_STATE" == idle ]]; then spl_peer_ring "$id"; fi
  # an answer as long as --max may have left a round out: then reconcile by time only
  if (( $(grep -c '^O ' <<<"$offered") >= room )); then offered=""; else offered="$(printf 'P\n%s' "$offered")"; fi
  spl_peer_reconcile "$id" "$held" "$offered" "$now"
  spl_peer_once "$id" "polling"
  return 0
}

# The heartbeat verdict of seat <id> (pid <pid>) at <now> (spec 5.3): sets
# PEER_HB (fresh | able | stale), PEER_ANCHOR_AGE (s since the anchor, for a
# fresh renew), PEER_STATE (idle | busy) and PEER_READY (the other seats of
# this box that were ready within two ticks). No heartbeat.json (hooks not
# installed): the transcript's last progress (spl_lease_activity) is the
# anchor, and an able agent with none within PEER_HB_FRESH waits at its prompt.
spl_peer_hb() {
  local id="$1" pid="$2" now="$3" f="${SPOOL_ROOT:-/var/spool-hub}/$1/heartbeat.json" st=busy prog=0 since=0 err=0 tool=- s r
  PEER_HB=able PEER_ANCHOR_AGE=0 PEER_STATE=busy PEER_READY=""
  if [[ -s "$f" ]]; then
    read -r st prog since err tool < <(jq -r 'def ep: (. // "" | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) | floor;
        "\(.state // "-") \(.progress_ts | ep) \(.tool_since | ep) \(if .api_error then 1 else 0 end) \(.tool // "-")"' "$f" 2>/dev/null)
    [[ "$prog" =~ ^[0-9]+$ && "$since" =~ ^[0-9]+$ ]] || { prog=0 since=0; }
    [[ "$st" == idle ]] && PEER_STATE=idle
  else
    prog="$(spl_lease_activity "$pid" 2>/dev/null)"; [[ "$prog" =~ ^[0-9]+$ ]] || prog=0
    (( now - prog > PEER_HB_FRESH )) && PEER_STATE=idle
  fi
  if [[ "$err" == 1 ]]; then PEER_HB=stale
  elif (( prog > 0 && now - prog <= PEER_HB_FRESH )); then PEER_HB=fresh PEER_ANCHOR_AGE=$(( now > prog ? now - prog : 0 ))
  elif [[ "$st" == in-tool ]] && (( since > 0 && now - since <= $(spl_peer_tool_cap "$tool") )); then PEER_HB=fresh
  fi
  while read -r s _; do
    [[ "$s" == "$id" ]] && continue
    r=""; { read -r r < "$PEER_DIR/$s/ready"; } 2>/dev/null
    [[ "$r" =~ ^[0-9]+$ ]] && (( now - r <= 2 * PEER_POLL_SEC )) && PEER_READY+="${PEER_READY:+,}$s"
  done < <(spl_peer_seats)
  return 0
}

# The S4 cap (s) of a tool call in progress: PEER_TOOL_MAX first, then the
# spec's defaults (Agent, Monitor, Workflow 60 min; WebFetch, WebSearch
# 5 min; anything else 15 min).
spl_peer_tool_cap() {
  local kv
  for kv in ${PEER_TOOL_MAX//,/ }; do
    [[ "${kv%%=*}" == "$1" && "${kv#*=}" =~ ^[0-9]+$ ]] && { echo "${kv#*=}"; return 0; }
  done
  case "$1" in
    Agent|Task|Monitor|Workflow) echo 3600 ;;
    WebFetch|WebSearch) echo 300 ;;
    *) echo 900 ;;
  esac
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

# The renew answer as one line per job: "<msg_id> <gen> <state> <touched
# epoch> <wait_token>" ("-" for none; a row without claim_state is 068's
# owned lock). Non-zero when the answer is no array.
spl_peer_held_rows() {
  jq -er 'def ep: (. // "" | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) | floor;
      if type != "array" then error("not an array") else
        (.[] | "\(.msg_id) \(.responsible_gen // 0) \(.claim_state // "owned") \(.touched_at | ep) \((.wait_token // "") | if . == "" then "-" else gsub("\\s"; "") end)"),
        "" end' <<<"$1" 2>/dev/null | grep -E '^([A-Za-z0-9-]+ [0-9]+ [a-z]+ [0-9]+ [^ ]+)?$'
}

# The poll answer as one line per row: "O <msg_id> <round> <1 when
# offer_set names <seat>, else 0> <offer_until epoch>" or "D <msg_id>" for a
# row the poll closed dead. Non-zero when the answer is no array.
spl_peer_offer_rows() {
  jq -er --arg me "$1" 'def ep: (. // "" | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) | floor;
      if type != "array" then error("not an array") else
        (.[] | if .dead == true then "D \(.msg_id)"
               else "O \(.msg_id) \(.round // 0) \(if (.offer_set // []) | index($me) then 1 else 0 end) \(.offer_until | ep)" end),
        "" end' <<<"$2" 2>/dev/null | grep -E '^(O [A-Za-z0-9-]+ [0-9]+ [01] [0-9]+|D [A-Za-z0-9-]+)?$'
}

# One stub per (job, round) of the poll into <id>'s inbox: msg id, round,
# title, no body (spec 4.3; the accept returns the body). A round whose
# offer_set does not name this seat gets no stub: a stub reaches only the
# round's seats. A row the poll closed dead is delivered once as a note for
# the agent to tell the owner (T10). <rows> from spl_peer_offer_rows, <out>
# the hub's answer. 0 when a new stub was written.
spl_peer_offer() {
  local id="$1" rows="$2" out="$3" t mid n mine new=1
  while read -r t mid n mine _; do
    case "$t" in
      D) spl_peer_deliver "$id" "$mid" "$(jq -c --arg m "$mid" '.[] | select(.msg_id == $m) | .kind = "note"
           | .body = ("DEAD: no seat took this job (claim_n \(.claim_n // 0)); tell the owner. " + (.body // ""))' <<<"$out")" &&
           spl_peer_log "$id DEAD $mid" ;;
      O) [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
         if [[ "$mine" != 1 ]]; then spl_peer_log "$id NOT-OFFERED $mid round $n: no stub"; continue; fi
         spl_peer_stub "$id" "$mid" "$n" "$out" && { new=0; spl_peer_log "$id OFFER $mid round $n"; } ;;
    esac
  done <<<"$rows"
  return "$new"
}

# Write the stub of <mid> round <n> once (<dir>/seen/<mid>.r<n>); the inbox
# file name carries the round so a new round is a new file.
spl_peer_stub() {
  local id="$1" mid="$2" n="$3" in="${SPOOL_ROOT:-/var/spool-hub}/$1/inbox" row ts from f
  ( set -o noclobber; : > "$PEER_DIR/$id/seen/$mid.r$n" ) 2>/dev/null || return 1
  mkdir -p "$in"
  row="$(jq -c --arg m "$mid" 'first(.[] | select(.msg_id == $m))' <<<"$4")"
  ts="$(jq -r '.ts // empty' <<<"$row")"; [[ -n "$ts" ]] || ts="$(date -u -d "@$(spl_lease_now)" +%FT%TZ)"
  from="$(jq -r '.from // "peers"' <<<"$row" | tr -c 'A-Za-z0-9@_\n-' '-')"
  f="$in/$(tr -d ':-' <<<"$ts")--${from}--peer-offer-${mid:0:8}-r$n.json"
  jq -c --arg mid "$mid" --arg to "$id" --arg ts "$ts" --argjson n "$n" '
    ("\(.kind // "msg") from \(.from // "peers") in \(.channel // .task_id // $mid)") as $t
    | {v: 1, msg_id: $mid, task_id: (.task_id // $mid), ts: $ts, from: (.from // "peers"), to: $to,
       kind: (.kind // "msg"), round: $n, title: $t, offer_until: (.offer_until // ""), files: [],
       body: "offered job, round \($n): \($t). Accept with: spool claim --accept \($mid) --round \($n)"}' <<<"$row" > "$f.tmp" &&
    mv -f "$f.tmp" "$f"
}

# Inbox reconciliation (spec 4.5): every stub in <id>'s inbox that is not a
# round the seat is still in moves to archive/ with "lost": done (the poll
# closed it), taken (another seat won it), lapsed (its window passed), or
# "accepted" when this seat owns it now. <offered> is this tick's complete
# poll answer (a "P" line, then spl_peer_offer_rows); "" when the seat did
# not poll or the answer may be cut at --max: then a stub moves only once
# it is held or its window has passed.
spl_peer_reconcile() {
  local id="$1" held="$2" offered="$3" now="$4" root="${SPOOL_ROOT:-/var/spool-hub}" f mid n until why
  compgen -G "$root/$id/inbox/*-r[0-9]*.json" >/dev/null || return 0
  while read -r f mid n until; do
    [[ "$mid" =~ ^[A-Za-z0-9-]+$ && "$n" =~ ^[0-9]+$ && "$until" =~ ^[0-9]+$ ]] || continue
    why=""
    grep -q "^O $mid $n 1 " <<<"$offered" && continue
    if grep -q "^$mid [0-9]* owned " <<<"$held"; then why=accepted
    elif [[ -n "$offered" ]]; then
      if grep -qx "D $mid" <<<"$offered"; then why="done"
      elif (( until > 0 && now <= until )); then why=taken
      else why=lapsed; fi
    elif (( until > 0 && now > until )); then why=lapsed
    fi
    [[ -n "$why" ]] || continue
    mkdir -p "$root/$id/archive"
    if [[ "$why" == accepted ]]; then jq -c '.accepted = true' "$f" > "$root/$id/archive/${f##*/}"
    else jq -c --arg w "$why" '.lost = $w' "$f" > "$root/$id/archive/${f##*/}"; fi && rm -f "$f"
    spl_peer_log "$id STUB-ARCHIVED $mid round $n ($why)"
  done < <(jq -r --arg me "$id" 'select(.round != null and .to == $me)
      | "\(input_filename) \(.msg_id) \(.round) \(.offer_until // "" | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0 | floor)"' \
      "$root/$id"/inbox/*-r[0-9]*.json 2>/dev/null)
  return 0
}

# T7b: a job <id> holds parked on a wait_token (a lane id or a task id) goes
# back to a round for <id> alone once a message from that lane, or in that
# topic, is in its inbox. Once per (job, gen); the stub follows from the poll.
spl_peer_reoffer() {
  local id="$1" held="$2" root="${SPOOL_ROOT:-/var/spool-hub}" mid gen st tok
  while read -r mid gen st _ tok; do
    [[ "$st" == parked && -n "$tok" && "$tok" != - ]] || continue
    [[ -e "$PEER_DIR/$id/seen/$mid.reoffer.$gen" ]] && continue
    compgen -G "$root/$id/inbox/*.json" >/dev/null || return 0
    jq -e -n --arg t "$tok" --arg m "$mid" 'any(inputs; type == "object" and .round == null and .msg_id != $m
        and (((.from // "") | split("@")[0]) == $t or .task_id == $t))' "$root/$id"/inbox/*.json >/dev/null 2>&1 || continue
    : > "$PEER_DIR/$id/seen/$mid.reoffer.$gen"
    if spl_peer_hub --reoffer "$mid" --seat "$id@$PEER_BOX" --gen "$gen" >/dev/null 2>&1; then
      spl_peer_log "$id REOFFER $mid gen $gen: $tok answered"
    else
      spl_peer_log "$id REOFFER-REFUSED $mid gen $gen"
    fi
  done <<<"$held"
  return 0
}

# <dir>/touch/<msg>: one file per held job, its mtime the hub's touched_at
# (the Stop hook blocks once on a job untouched for 10 min).
spl_peer_touch_marks() {
  local id="$1" held="$2" t="$PEER_DIR/$1/touch" mid at f
  mkdir -p "$t"
  while read -r mid _ _ at _; do
    [[ -n "$mid" ]] || continue
    if [[ "$at" =~ ^[1-9][0-9]*$ ]]; then touch -d "@$at" "$t/$mid"
    elif [[ ! -e "$t/$mid" ]]; then touch -d "@$(spl_lease_now)" "$t/$mid"; fi
  done <<<"$held"
  for f in "$t"/*; do
    [[ -f "$f" ]] || continue
    grep -q "^${f##*/} " <<<"$held" || rm -f "$f"
  done
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
