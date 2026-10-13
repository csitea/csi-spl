#!/bin/bash
#------------------------------------------------------------------------------
# @description The OD pool seat's shell loop (spec 134 sections 3.3, 3.4 and
# @description 6.4, step P3 / task T2): the lock is renewed by this loop, never
# @description by the model. One loop per seat (flock); every OD_TICK seconds:
# @description   BEAT   - <spool root>/od/<id>/beat = now
# @description   ABLE   - spl_lease_agent_able, the ONE able function the lease
# @description            and the supervisor use too (rule 6.5)
# @description   HOLD   - a seat that holds a job (od/<id>/job.json) renews it
# @description            at its gen while it is able AND its heartbeat's
# @description            progress_ts is at most OD_PROGRESS_MAX old; otherwise
# @description            it stops renewing and the lock runs out on the hub
# @description            (lazy expiry, no tick). A 409 (ask_closed: the agent
# @description            closed it; ask_held / unknown_ask: the lock was lost)
# @description            drops the job; a hub that does not answer keeps it
# @description   LOCK   - an able seat holding nothing calls `spool ask
# @description            lock-next`; the hub picks the row (rule 6.3: no agent
# @description            judgement in the lock path). With od_pool.kinds empty
# @description            (P3) the hub answers none, so nothing is locked
# @description   HAND   - a locked row goes to the seat's own inbox as a task
# @description            (pointers only: topic, issue key, ask id, gen), which
# @description            rings its pane
# @description A seat marked od/<id>/retire (an extra seat after a vendor came
# @description back, 4.3) takes no new job; the supervisor retires it once it
# @description holds none. od/<id>/seat.log keeps one line per change.
# @param OD_SEAT_ID - required (default SPOOL_AGENT_ID): the seat, c-NNN or g-NNN
# @param OD_VENDOR (optional) - claude or grok, default from the id letter
# @param OD_TICK (optional) - seconds between ticks, default 15
# @param OD_PROGRESS_MAX (optional) - seconds without heartbeat progress before a held job stops renewing, default 900
# @param OD_SEAT_TICKS (optional) - stop after N ticks, default 0 = run until killed
# @param OD_CAPS (optional) - the seat's caps for lock-next, comma-separated (prd)
# @param OD_FLEET / OD_BOX (optional) - the fleet (default lease.conf LEASE_FLEET) and this box (default the desk box)
# @param OD_HUB_CMD (optional, tests) - replaces the hub: gets `ask <op> <args>` or `lease <args>`, prints the answer
# @param OD_SEND (optional, tests) - replaces spool-send.sh
# @example OD_SEAT_ID=c-512 ./run -a do_spl_od_seat
# @example OD_SEAT_ID=g-513 OD_SEAT_TICKS=1 ./run -a do_spl_od_seat
#------------------------------------------------------------------------------
declare -F spl_lease_agent_able >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

do_spl_od_seat() {
  local id="${OD_SEAT_ID:-${SPOOL_AGENT_ID:-}}" vendor n=0 ticks="${OD_SEAT_TICKS:-0}"
  id="${id%@*}"
  [[ "$id" =~ ^[cg]-[0-9]{3}$ ]] || { do_log "FATAL OD_SEAT_ID must be a pool seat id (c-NNN or g-NNN), got: '$id'"; return 1; }
  [[ "$ticks" =~ ^[0-9]+$ ]] || { do_log "FATAL OD_SEAT_TICKS must be a number, got: '$ticks'"; return 1; }
  spl_od_init || return 1
  vendor="$(spl_od_vendor "$id")"
  mkdir -p "$OD_DIR/$id" || { do_log "FATAL cannot create $OD_DIR/$id"; return 1; }
  exec 8>>"$OD_DIR/$id/loop.lock"
  flock -n 8 || { do_log "INFO the seat loop of $id runs already"; return 0; }
  echo "$BASHPID" > "$OD_DIR/$id/loop.pid"
  while :; do
    spl_od_seat_tick "$id" "$vendor"
    n=$((n + 1))
    (( ticks > 0 && n >= ticks )) && break
    sleep "$OD_TICK"
  done
  return 0
}

# ---- shared by the seat and the supervisor ---------------------------------------

# spl_od_init: OD_DIR, OD_FLEET, OD_BOX, OD_TICK, OD_PROGRESS_MAX and the
# lease dir the able function writes to.
spl_od_init() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  OD_DIR="$SPOOL_ROOT/od"
  : "${OD_TICK:=15}" "${OD_PROGRESS_MAX:=900}"
  [[ "$OD_TICK" =~ ^[1-9][0-9]*$ && "$OD_PROGRESS_MAX" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL OD_TICK and OD_PROGRESS_MAX must be positive integers"; return 1; }
  spl_lease_init || return 1
  spl_lease_conf
  OD_FLEET="${OD_FLEET:-${LEASE_FLEET:-}}"
  [[ "$OD_FLEET" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL OD_FLEET is not set (env or lease.conf LEASE_FLEET)"; return 1; }
  OD_BOX="${OD_BOX:-${SPOOL_BOX_TAG:-$(spl_desk_box_default 2>/dev/null)}}"
  [[ "$OD_BOX" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { do_log "FATAL OD_BOX is not set (env, SPOOL_BOX_TAG or the desk box)"; return 1; }
  mkdir -p "$OD_DIR" || { do_log "FATAL cannot create $OD_DIR"; return 1; }
}

# spl_od_vendor ID: claude for c-, grok for g-.
spl_od_vendor() {
  case "$1" in g-*) echo grok ;; *) echo claude ;; esac
}

# spl_od_hub ask|lease <args>: the hub. `ask` is `spool ask` through the asks
# actions' desk (spl_asks_hub), `lease` the fleet lease call (spl_fleet_hub).
spl_od_hub() {
  local what="$1"; shift
  if [[ -n "${OD_HUB_CMD:-}" ]]; then "$OD_HUB_CMD" "$what" "$@"; return; fi
  if [[ "$what" == lease ]]; then
    spl_fleet_hub_init >/dev/null 2>&1 || return 1
    spl_fleet_hub "$@"; return
  fi
  if [[ -z "${OD_ASKS_READY:-}" ]]; then
    declare -F spl_asks_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-asks-open.func.sh"
    ASKS_FLEET="$OD_FLEET" spl_asks_init >/dev/null 2>&1 || return 1
    [[ "${LANE_MODE:-}" == hub ]] || return 1
    OD_ASKS_READY=1
  fi
  spl_asks_hub "$@"
}

# spl_od_why ID: why the able function last refused ID (its able.<id> file).
spl_od_why() { cat "$LEASE_DIR/able.$1" 2>/dev/null || echo unknown; }

# spl_od_log ID LINE: one line in od/<id>/seat.log and on stdout.
spl_od_log() {
  local line
  line="$(date -u -d "@$(spl_lease_now)" +%FT%TZ) $1 $2"
  mkdir -p "$OD_DIR/$1" 2>/dev/null
  printf '%s\n' "$line" >> "$OD_DIR/$1/seat.log"
  do_log "INFO $line"
}

# spl_od_log_once ID KEY LINE: spl_od_log only when KEY changed since the
# last call (a seat refused every 15 s logs it once).
spl_od_log_once() {
  local f="$OD_DIR/$1/last.$2" prev=""
  [[ -f "$f" ]] && prev="$(cat "$f")"
  [[ "$prev" == "$3" ]] && return 0
  printf '%s\n' "$3" > "$f"
  spl_od_log "$1" "$3"
}

# ---- the seat's tick ---------------------------------------------------------------

spl_od_seat_tick() {
  local id="$1" vendor="$2" d="$OD_DIR/$1" now pid out row
  local -a caps=()
  now="$(spl_lease_now)"
  echo "$now" > "$d/beat"
  pid="$(spl_lease_agent_able "$id")"
  if [[ -s "$d/job.json" ]]; then spl_od_seat_hold "$id" "$pid" "$now"; return 0; fi
  if [[ -z "$pid" ]]; then spl_od_log_once "$id" state "IDLE not able: $(spl_od_why "$id")"; return 0; fi
  if [[ -e "$d/retire" ]]; then spl_od_log_once "$id" state "RETIRING: no new job"; return 0; fi
  spl_od_log_once "$id" state "IDLE able"
  [[ -n "${OD_CAPS:-}" ]] && caps=(--caps "$OD_CAPS")
  out="$(spl_od_hub ask lock-next --fleet "$OD_FLEET" --seat "$id@$OD_BOX" --vendor "$vendor" --harness "$vendor" "${caps[@]}" 2>&1)" ||
    { spl_od_log_once "$id" hub "WARN lock-next failed: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 0; }
  rm -f "$d/last.hub"
  jq -r '.dead[]? | "DEAD-LETTER \(.ask_id) \(.kind) after \(.raised_n) lost locks"' <<<"$out" 2>/dev/null |
    while IFS= read -r row; do spl_od_log "$id" "$row"; done
  row="$(jq -c '.asks[0] // empty' <<<"$out" 2>/dev/null)"
  [[ -n "$row" ]] || return 0
  printf '%s\n' "$row" > "$d/job.json"
  spl_od_log "$id" "LOCK $(jq -r '"\(.ask_id) \(.kind) gen \(.gen)"' <<<"$row")"
  spl_od_seat_hand "$id" "$row"
}

# spl_od_seat_hold ID PID NOW: renew the held job, or let it run out.
spl_od_seat_hold() {
  local id="$1" pid="$2" now="$3" d="$OD_DIR/$1" aid gen why="" out
  aid="$(jq -r '.ask_id' "$d/job.json")"; gen="$(jq -r '.gen' "$d/job.json")"
  if [[ -z "$pid" ]]; then why="not able: $(spl_od_why "$id")"
  elif ! spl_od_progress "$id" "$now"; then why="no progress for more than ${OD_PROGRESS_MAX}s"
  fi
  if [[ -n "$why" ]]; then spl_od_log_once "$id" state "NO-RENEW $aid: $why"; return 0; fi
  if out="$(spl_od_hub ask renew --fleet "$OD_FLEET" --id "$aid" --by "$id@$OD_BOX" --gen "$gen" 2>&1)"; then
    rm -f "$d/last.hub"
    spl_od_log_once "$id" state "HOLD $aid gen $gen"
    return 0
  fi
  if grep -qE 'ask_closed|ask_held|unknown_ask' <<<"$out"; then
    rm -f "$d/job.json"
    spl_od_log "$id" "END $aid gen $gen: $(grep -oE -m1 'ask_closed|ask_held|unknown_ask' <<<"$out")"
    return 0
  fi
  spl_od_log_once "$id" hub "WARN renew $aid failed (kept): $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
}

# spl_od_progress ID NOW: 0 while the seat's heartbeat progress_ts is at most
# OD_PROGRESS_MAX old. No heartbeat or no progress_ts = no proof of a stall.
spl_od_progress() {
  local f="$SPOOL_ROOT/$1/heartbeat.json" ts at
  [[ -s "$f" ]] || return 0
  ts="$(jq -r '.progress_ts // empty' "$f" 2>/dev/null)"
  [[ -n "$ts" ]] || return 0
  at="$(date -u -d "$ts" +%s 2>/dev/null)" || return 0
  (( $2 - at <= OD_PROGRESS_MAX ))
}

# spl_od_seat_hand ID ROW: the job to the seat's own inbox (pointers only, Q4).
spl_od_seat_hand() {
  local id="$1" row="$2" aid kind gen topic issue send task rc=0
  send="${OD_SEND:-$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/spool-send.sh}"
  IFS=$'\t' read -r aid kind gen topic issue < <(jq -r '[.ask_id, .kind, .gen, (.topic // ""), (.issue_key // "")] | @tsv' <<<"$row")
  task="${topic:-od-$aid}"
  SPOOL_ROOT="$SPOOL_ROOT" bash "$send" --from "$id" --to "$id" --kind task --task "$task" --body \
    "OD JOB $aid ($kind), locked for you at gen $gen (spec 134). The context is the row, not your memory: ${issue:+read \`spool issue get $issue\`, }read \`spool tail --task $task\`. Your seat loop renews the lock while you are able. Close it: \`spool ask done --id $aid --by $id@$OD_BOX --gen $gen\` (or decline with --reason)." \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  if (( rc < 10 && rc != 2 )); then spl_od_log "$id" "HAND $aid to the $id inbox"
  else spl_od_log "$id" "WARN HAND $aid: spool-send exit $rc"; fi
  return 0
}
