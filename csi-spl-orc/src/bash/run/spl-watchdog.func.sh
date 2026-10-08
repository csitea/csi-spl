#!/bin/bash
#------------------------------------------------------------------------------
# @description The box watchdog of spec 093 section 6: one loop per box, no
# @description model call. Every WD_TICK s it walks every local agent (a tmux
# @description window named <id>[@<this box>], or a process carrying
# @description SPOOL_AGENT_ID), fills its context dir once, runs each
# @description situation script features/watchdog/situations/s[1-9].sh under
# @description `timeout WD_SCRIPT_TIMEOUT` (a hung script costs one script one
# @description tick, never the tick: FR-014), debounces the hits (6.1), applies
# @description the guards of 6.2 and the limits of 6.3, writes the verdict
# @description <spool root>/dispatch/wd.<id> ("HIT <code> <epoch>" or "OK <epoch>")
# @description for the able check, prints one verdict line per agent and
# @description acts: S1 rings at 120 s and takes over at 240 s, S2 never
# @description restarts (a login: ONE blocker to the orchestrator), S3 takes
# @description over, S4 Escape then takeover, S5 Escape + note then takeover,
# @description S6 clears a poke-shaped box and re-pokes, S7 Escape once (the
# @description default-mode offer: bypass settings re-asserted + takeover,
# @description "No, keep bypass permissions" as the fallback), S8 reports the
# @description hook GAP once, S9 (spec 102 8, stuck: a keystroke that never
# @description reached the model) sends the orchestrator the scrubbed pane
# @description once, then takes over; an unpoked unread inbox file is poked
# @description once (S9's POKE line). A takeover is do_spl_agent_restart
# @description (spec 102 4.1, T008), started detached; past
# @description RESTART_MAX_PER_HOUR restarts of an id in an hour (ONE counter,
# @description <id>/lifetime/restarts) the id is held out until the admin
# @description clears <id>/lifetime/heldout. DRY_RUN=1 (the default) writes
# @description the verdicts and only prints the actions.
# @description Spec 102 10.4.1 (T023a): up to 3 instances run at once
# @description (WD_INST 1..3), each under its own run.<inst>.lock with its own
# @description scratch (tick.<inst>/, ctx.<inst>/, last.tick.<inst>,
# @description resume.<inst>, heartbeat.<inst>.json); every agent is judged
# @description under <id>.judge.lock (flock -n), once per tick period by the
# @description pool, so the per-agent state (<id>.hits, .ep.*, the since
# @description files, s9.poked) is written by one instance at a time. The
# @description watchdog never takes the T003 id lock: the detached restart does.
# @description Spec 102 10.4.2 (T023b): at its tick start an instance checks
# @description its two peers and the crontab starter (spl-wd-peers.func.sh);
# @description every start goes through spl_wd_inst_start
# @description (spl-wd-inst-start.func.sh).
# @description Spec 102 10.4.4 (T025): after its peer checks an instance
# @description rolls out new desk-cron code by exec (spl-wd-self-update.func.sh).
# @param WD_INST / INSTANCE (optional) - this loop's instance 1..3; empty = the one 093 loop (run.lock, tick/, ctx/)
# @param WD_INST_START (optional) - instances to start detached when missing ("1 2 3"), then return: the cron entry (spl_wd_inst_start)
# @param WD_PEERS (optional) - 1 (default; 0 under SPOOL_TEST=1): an instance checks its peers and the crontab starter
# @param WD_JUDGE_LOCK (optional) - 1 (default); 0 drops the judge lock (the tests' control only)
# @param WD_TICKS (optional) - ticks to run, default 0 = forever (the loop); 1 = one proof tick
# @param WD_TICK (optional) - seconds per tick, default 30
# @param DRY_RUN (optional) - 1 (default): no key, ring, note or takeover; 0: act
# @param WD_SCRIPT_TIMEOUT (optional) - seconds per situation script, default 5
# @param WD_START_GRACE (optional) - seconds after a session start or a box resume with no situation, default 180
# @param RESTART_MAX_PER_HOUR (optional) - restarts per id per rolling hour, default 3 (spec 102 6.1)
# @param WD_TAKEOVER_MAX (optional) - do_spl_wd_takeover's own limit (a seat's request), default 2
# @param WD_TAKEOVER_RETRY (optional) - seconds after an S3 takeover whose session is dead again before it is retried, default WD_START_WAIT + WD_START_GRACE (300)
# @param WD_JOBS (optional) - agents checked at once, default 8
# @param WD_S1_TOOL_CAP (optional) - seconds a running tool call (heartbeat tool + tool_since) holds S1, default 900
# @param WD_SITUATIONS (optional) - the situation scripts dir (tests)
# @param WD_ONLY (optional) - space-separated ids: check only these (a drill on scratch ids next to the live loop)
# @param WD_STATE_DIR (optional) - the state dir (lock, debounces, ctx), default <spool root>/dispatch/wd; another one runs beside the live loop
# @param WD_PS_CMD / WD_SEND / WD_TAKEOVER_CMD / ROTATE_TMUX (optional) - seams for the tests: ps, spool-send.sh, the restart, tmux
# @example WD_TICKS=1 ./run -a do_spl_watchdog
# @example DRY_RUN=0 ./run -a do_spl_watchdog
# @example WD_ONLY="c-981 c-982" WD_STATE_DIR=/var/tmp/wd-drill DRY_RUN=0 WD_TICKS=20 ./run -a do_spl_watchdog
# @example WD_INST_START="1 2 3" ./run -a do_spl_watchdog
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"
declare -F spl_wd_log_rotate >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-ensure.func.sh"
declare -F spl_wd_peers >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-peers.func.sh"
declare -F spl_wd_self_update >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-self-update.func.sh"

SPL_WD_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

do_spl_watchdog() {
  if [[ -n "${WD_INST_START:-}" ]]; then
    local i rc=0
    for i in $WD_INST_START; do spl_wd_inst_start "$i" || rc=1; done
    return "$rc"
  fi
  spl_wd_init || return 1
  local n=0 t0 left
  if [[ -z "$WD_INST" && -f "$WD_DIR/run.1.lock" ]] && ! flock -n "$WD_DIR/run.1.lock" true; then
    do_log "INFO watchdog instance 1 runs on this box: no 093 loop beside it ($WD_DIR/run.1.lock)"
    return 0
  fi
  # an instance that self-updated (exec, 10.4.4) still holds its lock on fd 7
  [[ -n "${WD_UPD_EXEC:-}" ]] && flock -n 7 2>/dev/null || exec 7>>"$WD_DIR/run$WD_SFX.lock"
  if ! flock -w "$(( WD_TICKS > 0 ? WD_TICK : 0 ))" 7; then
    do_log "INFO watchdog${WD_INST:+ instance $WD_INST} already runs on this box ($WD_DIR/run$WD_SFX.lock)"
    return 0
  fi
  echo "$$" > "$WD_DIR/run$WD_SFX.pid"
  while :; do
    t0="$(date +%s)"
    spl_wd_keeper_lock
    spl_wd_tick
    n=$((n + 1))
    if (( WD_TICKS > 0 && n >= WD_TICKS )); then break; fi
    left=$(( WD_TICK - ($(date +%s) - t0) ))
    if (( left > 0 )); then spl_wd_upd_sleep "$left"; fi
  done
  return 0
}

# Instance 1 also holds the 093 keeper's run.lock (fd 9) and writes its
# run.pid and last.tick, so do_spl_wd_ensure reads it as the box's loop and
# starts no second one; retried every tick while a 093 loop still holds it.
spl_wd_keeper_lock() {
  [[ "$WD_INST" == 1 && -z "${WD_KEEPER_HELD:-}" ]] || return 0
  exec 9>>"$WD_DIR/run.lock"
  if flock -n 9; then
    WD_KEEPER_HELD=1
    echo "$$" > "$WD_DIR/run.pid"
  else
    exec 9>&-
  fi
  return 0
}

spl_wd_init() {
  spl_rotate_conf || return 1
  WD_DIR="${WD_STATE_DIR:-$LEASE_DIR/wd}"
  WD_LOG="$LEASE_DIR/wd.log"
  WD_SITUATIONS="${WD_SITUATIONS:-$SPL_WD_RUN_DIR/../features/watchdog/situations}"
  WD_INST="${WD_INST:-${INSTANCE:-}}"
  [[ -z "$WD_INST" || "$WD_INST" =~ ^[1-3]$ ]] || { do_log "FATAL WD_INST (INSTANCE) must be 1, 2 or 3, got: '$WD_INST'"; return 1; }
  WD_SFX="${WD_INST:+.$WD_INST}"
  WD_CODE_SHA="$(spl_wd_code_sha "$SPL_WD_RUN_DIR")"
  WD_SHA="${WD_CODE_SHA:0:9}"
  WD_TICK_SEQ=0 WD_PROGRESS_SEQ=0
  : "${WD_TICKS:=0}" "${WD_TICK:=30}" "${WD_SCRIPT_TIMEOUT:=5}" "${WD_START_GRACE:=180}"
  : "${WD_TAKEOVER_MAX:=2}" "${WD_JOBS:=8}" "${WD_JOB_WAIT:=120}" "${WD_LOOP_N:=5}" "${RESTART_MAX_PER_HOUR:=3}" "${WD_S1_TOOL_CAP:=900}"
  local k
  for k in WD_TICKS WD_TICK WD_SCRIPT_TIMEOUT WD_START_GRACE WD_TAKEOVER_MAX WD_JOBS WD_JOB_WAIT WD_LOOP_N RESTART_MAX_PER_HOUR WD_S1_TOOL_CAP; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  k="${WD_START_WAIT:-120}"; [[ "$k" =~ ^[0-9]+$ ]] || k=120
  : "${WD_TAKEOVER_RETRY:=$(( k + WD_START_GRACE ))}"
  [[ "$WD_TAKEOVER_RETRY" =~ ^[0-9]+$ ]] || { do_log "FATAL WD_TAKEOVER_RETRY must be a whole number, got: '$WD_TAKEOVER_RETRY'"; return 1; }
  (( WD_TICK > 0 && WD_JOBS > 0 && WD_SCRIPT_TIMEOUT > 0 )) ||
    { do_log "FATAL WD_TICK, WD_JOBS and WD_SCRIPT_TIMEOUT must be at least 1"; return 1; }
  [[ -d "$WD_SITUATIONS" ]] || { do_log "FATAL no situation scripts in $WD_SITUATIONS"; return 1; }
  WD_FROM="${WD_FROM:-${LEASE_ORCH:-c-001}}"
  WD_SEND="${WD_SEND:-$ROTATE_SEND}"
  WD_BOX="${ROTATE_BOX:-}"
  export WD_JOB_WAIT WD_LOOP_N WD_BOX WD_S1_TOOL_CAP
  mkdir -p "$WD_DIR/ctx$WD_SFX" || { do_log "FATAL cannot create $WD_DIR"; return 1; }
  spl_wd_peers_conf || return 1
  spl_wd_upd_conf || return 1
  return 0
}

# ---- one tick ------------------------------------------------------------------

spl_wd_tick() {
  local now last tick="$WD_DIR/tick$WD_SFX" id pid pane
  now="$(spl_lease_now)"
  last="$(cat "$WD_DIR/last.tick$WD_SFX" 2>/dev/null || true)"
  # a box back from suspend or power loss: every age looks huge (6.2). The
  # debounces reset per agent, in its skip, under its judge lock (10.4.1).
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last > 3 * WD_TICK )); then
    echo "$now" > "$WD_DIR/resume$WD_SFX"
    spl_wd_log "RESUME${WD_INST:+ instance $WD_INST} tick gap $((now - last))s: debounces and graces reset"
  fi
  echo "$now" > "$WD_DIR/last.tick$WD_SFX"
  if [[ -n "${WD_KEEPER_HELD:-}" ]]; then echo "$now" > "$WD_DIR/last.tick"; fi
  WD_TICK_SEQ=$((WD_TICK_SEQ + 1))
  # shellcheck disable=SC2034 # read by spl_wd_peers (spl-wd-peers.func.sh)
  WD_HB_OK=1
  spl_wd_heartbeat start
  # peers only from a judge that wrote its heartbeat and did not just resume (10.4.2)
  [[ "$last" =~ ^[0-9]+$ ]] || last="$now"
  spl_wd_peers "$now" "$(( now - last ))"
  # desk-cron moved: the rolling restart of 10.4.4 (may exec into the new code)
  spl_wd_self_update "$now"
  rm -rf "$tick" && mkdir -p "$tick"
  spl_wd_ps > "$tick/ps"
  spl_wd_tmux_lists "$tick"
  WD_BOX_BUSY=""
  if [[ -e "$SPOOL_ROOT/peer/restart.lock" ]] && ! flock -n "$SPOOL_ROOT/peer/restart.lock" true; then
    WD_BOX_BUSY="a restart holds peer/restart.lock"
  fi
  spl_wd_agents "$tick" > "$tick/agents"
  spl_wd_fence "$now" "$tick"
  spl_wd_boot "$now" "$tick"
  spl_wd_heartbeat agents
  # named pids only: a bare `wait` also waits for ./run's tee process substitutions
  local -a jp=()
  while IFS=$'\t' read -r id pid pane; do
    while (( $(spl_wd_running "${jp[@]}") >= WD_JOBS )); do sleep 0.2; done
    spl_wd_one "$id" "$pid" "$pane" "$now" "$tick" > "$tick/out.$id" 2>>"$tick/err" &
    jp+=("$!")
    spl_wd_heartbeat agents
  done < "$tick/agents"
  if (( ${#jp[@]} )); then wait "${jp[@]}" 2>/dev/null || true; fi
  spl_wd_heartbeat "done"
  while IFS=$'\t' read -r id _; do
    cat "$tick/out.$id" 2>/dev/null || true
  done < "$tick/agents" | tee -a "$WD_LOG.tmp.$$" || true
  if [[ -f "$WD_LOG.tmp.$$" ]]; then
    sed "s/^/$(date -u -d "@$now" +%FT%TZ) /" "$WD_LOG.tmp.$$" >> "$WD_LOG"
    rm -f "$WD_LOG.tmp.$$"
  fi
  spl_wd_log_trim
  # the first tick after a self-update exec is its self-check (10.4.4)
  spl_wd_upd_checked "$tick" "$now"
  return 0
}

# How many of <pid>... still run.
spl_wd_running() {
  local p n=0
  for p in "$@"; do if kill -0 "$p" 2>/dev/null; then n=$((n + 1)); fi; done
  echo "$n"
}

spl_wd_log() { echo "$(date -u +%FT%TZ) $*" >> "$WD_LOG"; }

# spl_wd_heartbeat PHASE: <WD_DIR>/heartbeat<.inst>.json (spec 102 10.4.2),
# written at the tick start and as each agent is started, so a long tick
# under load still shows progress; atomically. A failed write (ENOSPC)
# clears WD_HB_OK: this instance then judges no peer this tick.
# WD_HB_SINK replaces the file (tests: /dev/full).
spl_wd_heartbeat() {
  local f="$WD_DIR/heartbeat$WD_SFX.json" now
  now="$(spl_lease_now)"
  WD_PROGRESS_SEQ=$((WD_PROGRESS_SEQ + 1))
  if printf '{"instance": %s, "pid": %s, "ts": %s, "tick_seq": %s, "tick_phase": "%s", "last_progress_ts": %s, "progress_seq": %s, "status": "ok", "git_sha": "%s"}\n' \
    "${WD_INST:-0}" "$$" "$now" "$WD_TICK_SEQ" "$1" "$now" "$WD_PROGRESS_SEQ" "$WD_SHA" > "${WD_HB_SINK:-$f.tmp.$$}" 2>/dev/null &&
    { [[ -n "${WD_HB_SINK:-}" ]] || mv -f "$f.tmp.$$" "$f" 2>/dev/null; }; then
    return 0
  fi
  rm -f "$f.tmp.$$" 2>/dev/null || true
  # shellcheck disable=SC2034 # read by spl_wd_peers (spl-wd-peers.func.sh)
  WD_HB_OK=0
  spl_wd_log "HEARTBEAT${WD_INST:+ instance $WD_INST} cannot write $f (disk full?)" 2>/dev/null || true
  return 0
}

# wd.log keeps a day or two: spl_wd_log_rotate copies it to wd.log.1 once a
# day (WD_LOG_KEEP) or past WD_LOG_MAX_BYTES. A line cap held about an hour on
# a busy box (5000 lines; 2026-10-06: ~5000/h on one box, ~600/h on another).
spl_wd_log_trim() {
  spl_wd_log_rotate "$WD_LOG" "$(spl_lease_now)"
}

# tmux, bounded: a hung server costs one call 5 s. ROTATE_TMUX replaces it in tests.
spl_wd_tmux() {
  if [[ -n "${ROTATE_TMUX:-}" ]]; then
    timeout -k 1 5 "$ROTATE_TMUX" "$@" 6>&- 9>&-
    return
  fi
  spool_tmux_argv
  timeout -k 1 5 "${SPOOL_TM[@]}" "$@" 6>&- 9>&-
}

# "pid ppid etimes comm" for every process. WD_PS_CMD replaces ps in tests.
spl_wd_ps() {
  local -a cmd=(ps -e -o "pid=,ppid=,etimes=,comm=")
  # shellcheck disable=SC2206 # a command line, split on purpose
  [[ -n "${WD_PS_CMD:-}" ]] && cmd=($WD_PS_CMD)
  "${cmd[@]}" 2>/dev/null | awk '{print $1, $2, $3, $4}' || true
}

# ---- the reboot path (spec 102 10.1, T014) -------------------------------------

# spl_wd_boot NOW TICK: once per boot of this box, restart every agent that
# ran here when the box went down, cause `reboot`, through spl_wd_takeover
# (do_spl_agent_restart: a new session from the handoff, never a --resume).
# Restarted: an open registry row, not done (4.3), running_box this box
# (10.2), and seen running: its verdict dispatch/wd.<id> written at most
# WD_BOOT_SEEN s (900) before the last verdict of the previous boot. An open
# row alone is no proof (sat 2026-10-07: 110 open rows with a worktree and
# no done marker, 9 of them running). A boot is /proc/stat's btime (60 s
# either way) against <WD_DIR>/boot.seen, the last boot handled; no
# boot.seen (this code's first run) acts only on a boot younger than
# WD_BOOT_RECENT s (1800), else records the baseline. It waits out
# WD_START_GRACE after the boot and the resume (the restart's own resume
# grace refuses earlier). Left alone: an id with a window or a process (the
# old boot restore or a peer brought it back). A fenced box (10.2: T017's
# spl_wd_box_fenced, when it exists) starts nothing and retries. One instance at
# a time (boot.lock); the restarts queued (spl_wd_boot_queue), each under its
# judge lock (held: the next tick); each id done once per boot (boot.d/<id> =
# the btime) when it is back or judged; boot.seen once none waits.
# WD_BOOT=0 turns it off.
spl_wd_boot() {
  [[ "${WD_BOOT:-1}" != 0 ]] || return 0
  local bt seen
  bt="$(spl_wd_boot_time)"
  [[ "$bt" =~ ^[0-9]+$ ]] || return 0
  seen="$(cat "$WD_DIR/boot.seen" 2>/dev/null || true)"
  if [[ "$seen" =~ ^[0-9]+$ ]] && (( bt - seen <= 60 && seen - bt <= 60 )); then return 0; fi
  (
    flock -w 5 5 || exit 0
    spl_wd_boot_pass "$1" "$2" "$bt" "$seen"
  ) 5>>"$WD_DIR/boot.lock"
  return 0
}

# The box's boot time in epoch s: btime of <proc root>/stat; WD_BOOT_TIME (tests).
spl_wd_boot_time() {
  if [[ -n "${WD_BOOT_TIME:-}" ]]; then echo "$WD_BOOT_TIME"; return 0; fi
  awk '$1 == "btime" {print $2; exit}' "${LEASE_PROC_ROOT:-/proc}/stat" 2>/dev/null || true
}

spl_wd_boot_pass() {
  local now="$1" tick="$2" bt="$3" seen="$4" snap last r at
  at="$(date -u -d "@$bt" +%FT%TZ)"
  snap="$WD_DIR/boot.$bt.seen"
  # who ran here before the boot: taken before any verdict of this boot is written
  [[ -f "$snap" ]] || spl_wd_boot_snap "$bt" > "$snap"
  last="$(awk '$1 > m {m = $1} END {if (m) print m}' "$snap")"
  if [[ -z "$seen" ]] && { [[ -z "$last" ]] || (( now - bt > ${WD_BOOT_RECENT:-1800} )); }; then
    spl_wd_boot_seen "$bt" "BOOT $at baseline: recorded, nothing started (no boot.seen; boot $((now - bt))s ago, ${last:+a }${last:-no} verdict before it)"
    return 0
  fi
  if [[ -z "$last" ]]; then spl_wd_boot_seen "$bt" "BOOT $at: no verdict before the boot, nothing ran here"; return 0; fi
  r="$(cat "$WD_DIR/resume$WD_SFX" 2>/dev/null || true)"
  [[ "$r" =~ ^[0-9]+$ ]] && (( r > bt )) || r="$bt"
  if (( now - r < WD_START_GRACE )); then echo "BOOT $at: waits $(( WD_START_GRACE - now + r ))s (start and resume grace)"; return 0; fi
  if declare -F spl_wd_box_fenced >/dev/null && spl_wd_box_fenced; then
    spl_wd_log "BOOT $at fenced (102 10.2): nothing started; retried next tick"; return 0
  fi
  [[ "${DRY_RUN:-1}" == 1 ]] || mkdir -p "$WD_DIR/boot.d" "$WD_DIR/boot.q" || return 0
  spl_wd_boot_queue "$now" "$tick" "$bt" "$at" "$snap" "$last"
}

# spl_wd_boot_queue NOW TICK BT AT SNAP LAST: the boot's restarts as a queue
# (sat drill 2, 2026-10-08: 11 started at once, 8 refused by the pass's own
# slots and its own rotate.hold, all logged "started"). Seats first, one at a
# time; a role seat (001..003) holds rotate.hold, so nothing else starts in
# its pass, and nothing starts while any rotate.hold stands; a lane only
# into a free peer/restart.slot.1..RESTART_SLOTS. A started id waits in
# boot.q/<id> until it runs (back) or its attempt ends: refused (its
# restart.<id>.out) or not back in WD_BOOT_BACK_WAIT s (1200); then it is
# started again, WD_BOOT_TRIES (3) times at most. boot.seen once none waits.
spl_wd_boot_queue() {
  local now="$1" tick="$2" bt="$3" at="$4" snap="$5" last="$6" id why st out rc
  local n=0 ref=0 q=0 fly=0 back=0 lanes stop="" seat=1
  lanes="$(spl_wd_boot_free_lanes)"
  spl_wd_boot_slot_free 0 || seat=""
  stop="$(spl_wd_boot_hold "$bt" "$at")"
  while read -r id; do
    [[ "$(cat "$WD_DIR/boot.d/$id" 2>/dev/null || true)" == "$bt" ]] && continue
    why="$(spl_wd_boot_why "$id" "$tick" "$snap" "$last")"
    if [[ -n "$why" ]]; then
      if [[ -f "$WD_DIR/boot.q/$id" ]]; then spl_wd_log "BOOT $at $id back: $why"; back=$((back + 1))
      else spl_wd_log "BOOT $at $id left alone: $why"; fi
      spl_wd_boot_done "$id" "$bt"; continue
    fi
    st="$(spl_wd_boot_attempt "$id" "$bt" "$now" "$at")"
    if [[ "$st" == fly ]]; then fly=$((fly + 1)); continue; fi
    [[ "$st" != refused* ]] || ref=$((ref + 1))
    if [[ "$st" == *spent ]]; then spl_wd_boot_done "$id" "$bt"; continue; fi
    if [[ -n "$stop" ]]; then q=$((q + 1)); continue; fi
    if spl_wd_boot_seat "$id"; then [[ -n "$seat" ]] || { q=$((q + 1)); continue; }
    elif (( lanes < 1 )); then q=$((q + 1)); continue; fi
    rc=0; out="$(spl_wd_boot_start "$id" "$bt" "$now" "$at")" || rc=$?
    spl_wd_log "BOOT $at $id: $out"
    case "$rc" in
      0) n=$((n + 1)) ;;
      1) q=$((q + 1)); continue ;;
      *) ref=$((ref + 1)); spl_wd_boot_done "$id" "$bt"; continue ;;
    esac
    if spl_wd_boot_seat "$id"; then seat=""; [[ "$id" =~ -00[1-3]$ ]] && stop="its restart of $id holds rotate.hold"
    else lanes=$((lanes - 1)); fi
  done < <(spl_wd_boot_ids | spl_wd_boot_order)
  if (( n + q + fly == 0 )); then
    spl_wd_boot_seen "$bt" "BOOT $at done: $n restart(s) started, $ref refused, $back back (cause reboot)"
  else
    spl_wd_log "BOOT $at: $n started, $ref refused, $q queued${stop:+ ($stop)}, $fly in flight, $back back (cause reboot); retried next tick"
  fi
  return 0
}

# Seats first (their order), then the lanes.
spl_wd_boot_order() {
  local -a ids; local id
  mapfile -t ids
  for id in "${ids[@]}"; do spl_wd_boot_seat "$id" && echo "$id"; done
  for id in "${ids[@]}"; do spl_wd_boot_seat "$id" || echo "$id"; done
  return 0
}

# A seat restarts in slot 0 (do_spl_agent_restart's spl_ars_is_seat): 001..004, an expected seat.
spl_wd_boot_seat() {
  [[ "$1" =~ -00[1-4]$ ]] && return 0
  grep -qx -- "$1" <<<"$(spl_wd_expected)"
}

# spl_wd_boot_slot_free N: peer/restart.slot.<N> is not held by a restart.
spl_wd_boot_slot_free() {
  local f="${PEER_DIR:-$SPOOL_ROOT/peer}/restart.slot.$1"
  [[ ! -e "$f" ]] || flock -n "$f" true 2>/dev/null
}

# The free lane slots (1..RESTART_SLOTS, default 4) right now.
spl_wd_boot_free_lanes() {
  local n c=0
  for (( n = 1; n <= ${RESTART_SLOTS:-4}; n++ )); do spl_wd_boot_slot_free "$n" && c=$((c + 1)); done
  echo "$c"
}

# spl_wd_boot_hold BT AT: why nothing starts this pass (a rotate.hold), empty
# when free. A hold written before the boot BT died with the box: removed.
spl_wd_boot_hold() {
  local h="$LEASE_DIR/rotate.hold" hid ht
  [[ -s "$h" ]] || return 0
  read -r hid ht _ < "$h" || true
  if [[ "$ht" =~ ^[0-9]+$ ]] && (( ht < $1 )); then
    spl_wd_log "BOOT $2: rotate.hold names ${hid:-?} from before the boot: its run died with the box"
    if [[ "${DRY_RUN:-1}" != 1 ]]; then rm -f "$h"; return 0; fi
  fi
  echo "rotate.hold names ${hid:-?}"
}

# spl_wd_boot_attempt ID BT NOW AT: the state of <id>'s last start of this
# boot (boot.q/<id> = "<bt> <started> <tries> <out offset>"): new (none),
# fly (running), refused / late (ended, not back: start it again), with
# " spent" when WD_BOOT_TRIES are used (given up).
spl_wd_boot_attempt() {
  local id="$1" bt="$2" now="$3" at="$4" f="$WD_DIR/boot.q/$1" b t k o out line sz st=late
  read -r b t k o 2>/dev/null < "$f" || true
  [[ "$b" == "$bt" && "$t" =~ ^[0-9]+$ && "$k" =~ ^[0-9]+$ && "$o" =~ ^[0-9]+$ ]] || { echo new; return 0; }
  out="$WD_DIR/restart.$id.out"
  sz="$(stat -c %s "$out" 2>/dev/null || echo 0)"
  line="$(tail -c +$(( o + 1 )) "$out" 2>/dev/null | grep -m1 "^REFUSED $id:" || true)"
  if [[ -n "$line" ]]; then
    st=refused
    echo "$bt $t $k $sz" > "$f"
    spl_wd_log "BOOT $at $id refused (try $k): ${line#REFUSED "$id": }"
  elif (( now - t < ${WD_BOOT_BACK_WAIT:-1200} )); then echo fly; return 0
  else spl_wd_log "BOOT $at $id not back $(( now - t ))s after try $k"; fi
  if (( k >= ${WD_BOOT_TRIES:-3} )); then spl_wd_log "BOOT $at $id given up: not back after $k tries"; st="$st spent"; fi
  echo "$st"
}

# spl_wd_boot_done ID BT: <id> is handled for this boot.
spl_wd_boot_done() {
  [[ "${DRY_RUN:-1}" == 1 ]] && return 0
  echo "$2" > "$WD_DIR/boot.d/$1"
  rm -f "$WD_DIR/boot.q/$1"
}

# "<verdict mtime> <id>" per dispatch/wd.<id> written before the boot BT.
spl_wd_boot_snap() {
  local f m
  for f in "$LEASE_DIR"/wd.[acgq]-[0-9][0-9][0-9]; do
    [[ -f "$f" ]] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || true)"
    [[ "$m" =~ ^[0-9]+$ ]] && (( m < $1 )) && echo "$m ${f##*/wd.}"
  done
  return 0
}

# spl_wd_boot_seen BT LINE: the boot is handled; older snapshots go.
spl_wd_boot_seen() {
  spl_wd_log "$2"
  [[ "${DRY_RUN:-1}" == 1 ]] && return 0
  echo "$1" > "$WD_DIR/boot.seen"
  find "$WD_DIR" -maxdepth 1 -name 'boot.*.seen' ! -name "boot.$1.seen" -delete 2>/dev/null || true
  return 0
}

# The ids of the open registry rows of this box (<id> or <id>@<this box>).
spl_wd_boot_ids() {
  awk -F'\t' -v b="$ROTATE_BOX" -v t="${SPOOL_BOX_TAG:-}" '{i = $1; h = ""; if (i ~ /@/) {h = i; sub(/^[^@]*@/, "", h); sub(/@.*/, "", i)}
    if (h == "" || h == b || h == t) print i}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null | grep -xE '[acgq]-[0-9]{3}' | sort -u || true
}

# Why <id> is not restarted by this boot; nothing when it is.
spl_wd_boot_why() {
  local id="$1" tick="$2" snap="$3" last="$4" rd rb ctx m start
  if awk -F'\t' -v i="$id" '$1 == i && ($2 != "-" || $3 != "-") {f = 1} END {exit !f}' "$tick/agents"; then
    echo "it runs (a window or a process carries it)"; return 0
  fi
  rd="$(awk -F'\t' -v i="$id" '$1 == i {d = $4} END {print d}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true)"
  if [[ "$rd" == /* && ! -d "$rd" ]]; then echo "done: its workdir $rd is gone"; return 0; fi
  ctx="$WD_DIR/ctx$WD_SFX/boot.$id"
  rm -rf "$ctx" && mkdir -p "$ctx"
  spl_wd_lifetime "$id" "$ctx"
  start="$(cat "$ctx/session_start" 2>/dev/null || true)"; [[ "$start" =~ ^[0-9]+$ ]] || start=0
  if [[ -s "$ctx/done" ]] && (( $(cat "$ctx/done") >= start )); then echo "done: lifetime/done is newer than the session start"; return 0; fi
  if [[ -e "$SPOOL_ROOT/$id/lifetime/heldout" ]]; then echo "held out until the admin clears it"; return 0; fi
  rb="$(spl_wd_boot_running_box "$id")"
  if [[ -n "$rb" && "$rb" != "$ROTATE_BOX" && "$rb" != "${SPOOL_BOX_TAG:-}" ]]; then echo "running_box is $rb, not this box"; return 0; fi
  m="$(awk -v i="$id" '$2 == i {print $1; exit}' "$snap")"
  if [[ ! "$m" =~ ^[0-9]+$ ]]; then echo "not running here at the boot (no verdict before it)"; return 0; fi
  if (( last - m > ${WD_BOOT_SEEN:-900} )); then
    echo "not running here at the boot (its last verdict $(( last - m ))s before the box's last one)"; return 0
  fi
  return 0
}

# The box a lane runs on (10.2): T018's spl_lane_running_box when it exists,
# else <id>/lifetime/running_box, else the box of its session.json; empty =
# this box.
spl_wd_boot_running_box() {
  local lt="$SPOOL_ROOT/$1/lifetime" b=""
  if declare -F spl_lane_running_box >/dev/null; then spl_lane_running_box "$1"; return 0; fi
  read -r b 2>/dev/null < "$lt/running_box" || true
  [[ -n "$b" ]] || b="$(jq -r '.box // empty' "$lt/session.json" 2>/dev/null || true)"
  echo "$b"
}

# spl_wd_boot_start ID BT NOW AT: the restart under the id's judge lock
# (exit 1: held, the next tick; exit 2: not started). Started: boot.q/<id>
# (spl_wd_boot_attempt). WD_BOOT_ID lists the windowless id for the
# restart's gate (spl_wd_agents); the S3 takeover flag keeps a dead seat's
# S3 from a second restart of the same boot.
spl_wd_boot_start() {
  local id="$1" bt="$2" now="$3" at="$4" out rc=0 k=0 o
  if [[ "${DRY_RUN:-1}" == 1 ]]; then echo "would restart (cause reboot)"; return 0; fi
  read -r _ _ k _ 2>/dev/null < "$WD_DIR/boot.q/$id" || true
  [[ "$k" =~ ^[0-9]+$ ]] || k=0
  (
    exec 6>>"$WD_DIR/$id.judge.lock"
    flock -n 6 || { echo "its judge lock is held: next tick"; exit 1; }
    o="$(stat -c %s "$WD_DIR/restart.$id.out" 2>/dev/null || echo 0)"
    out="$(WD_BOOT_ID="$id" spl_wd_takeover "$id" reboot "boot $at" 5>&-)" || rc=$?
    if (( rc != 0 )); then echo "not started: ${out:-takeover exit $rc}"; exit 2; fi
    echo "$bt $now $(( k + 1 )) $o" > "$WD_DIR/boot.q/$id"
    echo "$now" > "$WD_DIR/$id.ep.S3.takeover"; echo "restart started, try $(( k + 1 )) (cause reboot)"
  )
}

# The id spl_wd_boot_start is restarting (WD_BOOT_ID), for the restart's
# gate: a lane after a boot has no window and no process.
spl_wd_boot_listed() {
  [[ "${WD_BOOT_ID:-}" =~ ^[acgq]-[0-9]{3}$ ]] && echo "$WD_BOOT_ID"
  return 0
}

# ---- who is checked -------------------------------------------------------------

# "<id>\t<pid>\t<pane>" for every local agent: a window named <id> or
# <id>@<this box> (a "<tag>: " prefix allowed), and every process that carries
# SPOOL_AGENT_ID. pid is the harness process (a claude/grok/agy/qwen comm
# first, else the lowest node/bun), "-" when none; pane "-" when none. The
# expected seats of spl_wd_expected are listed too, with neither.
spl_wd_agents() {
  local tick="$1" re='^([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)$'
  local pane name id box
  : > "$tick/win"
  while IFS=$'\t' read -r pane _ _ name _; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:\  ]] && name="${name#*: }"
    name="${name%% *}"
    id="${name%%@*}"; box=""
    [[ "$name" == *@* ]] && box="${name#*@}"
    [[ "$id" =~ $re ]] || continue
    [[ -z "$box" || "$box" == "${SPOOL_BOX_TAG:-}" || "$box" == "$ROTATE_BOX" ]] || continue
    printf '%s\t%s\n' "$id" "$pane" >> "$tick/win"
  done < "$tick/panes"
  spl_wd_proc_ids "$tick" > "$tick/procs"
  { spl_wd_expected; spl_wd_boot_listed; } > "$tick/expected"
  awk -F'\t' -v w="$tick/win" -v x="$tick/expected" '
    FILENAME == w { if (!($1 in wp)) { wp[$1] = $2; ids[$1] = 1 } ; next }
    FILENAME == x { ids[$1] = 1; next }
    { if (!($2 in pid)) { pid[$2] = $1; ids[$2] = 1 } }
    END { for (i in ids) {
            p = (i in pid) ? pid[i] : "-"; w = (i in wp) ? wp[i] : "-"
            # an id names files: a SPOOL_AGENT_ID of any other shape is not checked
            if (i ~ /^[A-Za-z][A-Za-z0-9-]*$/) print i "\t" p "\t" w } }' "$tick/win" "$tick/expected" "$tick/procs" |
    sort | spl_wd_only > "$tick/agents.raw"
  spl_wd_pane_of_pids "$tick"
}

# The seats this box expects to run, one id per line (spec 102 4.3): the
# role ids of lease.conf (orch, master, failover), the ids of peer/seats and
# the seat records <spool root>/agents/<role id>.json of this box. A seat
# whose sessions died and whose window closed has neither a window nor a
# process: without this list it is never checked again (sat, 2026-10-06,
# 13 h). Lane ids are never listed: a lane that finished is not resurrected.
spl_wd_expected() {
  local f sn
  {
    printf '%s\n' "${LEASE_ORCH:-}" "${LEASE_MASTER:-}" "${LEASE_FAILOVER:-}"
    awk '$1 !~ /^#/ && NF {print $1}' "$SPOOL_ROOT/peer/seats" 2>/dev/null || true
    for f in "$SPOOL_ROOT"/agents/[acgq]-00[1-3].json; do
      [[ -f "$f" ]] || continue
      sn="$(jq -r '.session_name // empty' "$f" 2>/dev/null || true)"
      [[ "$sn" != *@* || "${sn#*@}" == "$ROTATE_BOX" || "${sn#*@}" == "${SPOOL_BOX_TAG:-}" ]] && basename "$f" .json
    done
  } | grep -xE '[acgq]-[0-9]{3}' | sort -u || true
}

# The agent lines whose id is in WD_ONLY; all of them when it is empty.
spl_wd_only() {
  if [[ -z "${WD_ONLY:-}" ]]; then cat; return 0; fi
  awk -F'\t' -v only=" ${WD_ONLY//,/ } " 'index(only, " " $1 " ")'
}

# The pane of an agent found by its process only: the pane whose pane_pid is
# the pid or one of its ancestors (the ps dump's ppid chain).
spl_wd_pane_of_pids() {
  local tick="$1"
  cut -f1,2 "$tick/panes" > "$tick/panepids"
  awk -F'\t' -v OFS='\t' -v ps="$tick/ps" -v pp_="$tick/panepids" '
    FILENAME == ps { split($0, a, " "); pp[a[1]] = a[2]; next }
    FILENAME == pp_ { pane[$2] = $1; next }
    { if ($3 == "-" && $2 != "-") {
        p = $2
        for (k = 0; k < 64 && p > 1; k++) { if (p in pane) { $3 = pane[p]; break }; p = pp[p] }
      }
      print $1, $2, $3 }' "$tick/ps" "$tick/panepids" "$tick/agents.raw"
}

# "<pid>\t<id>" per agent id: the harness process carrying SPOOL_AGENT_ID=<id>.
# Another user's environ goes through the owner hop (proc-owner.inc.sh).
spl_wd_proc_ids() {
  local tick="$1" root="${LEASE_PROC_ROOT:-/proc}" pid comm e
  local -a env other=()
  {
    while read -r pid _ _ comm; do
      case "$comm" in claude|grok|agy|qwen|node|bun) ;; *) continue ;; esac
      if [[ -r "$root/$pid/environ" ]]; then
        env=(); { mapfile -d '' -t env < "$root/$pid/environ"; } 2>/dev/null || continue
        for e in "${env[@]}"; do
          [[ "$e" == SPOOL_AGENT_ID=* ]] && { echo "$pid ${e#SPOOL_AGENT_ID=}"; break; }
        done
      else
        other+=("$pid")
      fi
    done < "$tick/ps"
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" 2>/dev/null || true
    fi
  } | awk -v ps="$tick/ps" 'FILENAME == ps { c[$1] = $4; next }
      $2 != "" { r = (c[$1] ~ /^(claude|grok|agy|qwen)$/) ? 0 : 1; print r, $1, $2 }' "$tick/ps" - |
    sort -k1,1n -k2,2n | awk '!seen[$3]++ { print $2 "\t" $3 }'
}

# ---- one agent -------------------------------------------------------------------

# Check one agent and print its verdict line, under its judge lock (spec 102
# 10.4.1): <WD_DIR>/<id>.judge.lock, flock -n on fd 6 for the whole check, so
# its state files (.hits, .ep.*, the since files, s9.poked, s9.reported) and
# its actions have one writer. Held by a peer instance, or judged by another
# instance less than WD_TICK - 5 s ago (<id>.judged "<epoch> <inst>"): no
# line, the peer's verdict stands. Children that may outlive the check close
# fd 6. The T003 id lock is not taken here: the detached restart takes it.
spl_wd_one() {
  local id="$1" pid="$2" pane="$3" now="$4" tick="$5" ctx skip line jt="" ji=""
  if [[ "${WD_JUDGE_LOCK:-1}" != 0 ]]; then
    exec 6>>"$WD_DIR/$id.judge.lock"
    flock -n 6 || spl_wd_upd_lock_wait 6 || return 0
    read -r jt ji 2>/dev/null < "$WD_DIR/$id.judged" || true
    if [[ "$jt" =~ ^[0-9]+$ && "$ji" != "${WD_INST:-0}" ]] && (( now - jt < WD_TICK - 5 )) && ! spl_wd_upd_force "$id"; then return 0; fi
  fi
  ctx="$WD_DIR/ctx$WD_SFX/$id"
  rm -rf "$ctx" && mkdir -p "$ctx"
  [[ "$pid" == - ]] && pid=""
  [[ "$pane" == - ]] && pane=""
  spl_wd_gather "$id" "$pid" "$pane" "$now" "$tick" "$ctx"
  skip="$(spl_wd_skip "$id" "$pid" "$now" "$tick" "$ctx")"
  if [[ -n "$skip" ]]; then
    rm -f "$WD_DIR/$id.hits"
    spl_wd_verdict "$id" OK "$now"
    spl_wd_judged "$id" "$now"
    echo "$id SKIP $skip"
    return 0
  fi
  spl_wd_run_scripts "$id" "$pid" "$pane" "$ctx"
  line="$(spl_wd_judge "$id" "$pid" "$pane" "$now" "$ctx")"
  spl_wd_judged "$id" "$now"
  echo "$id $line"
  return 0
}

spl_wd_judged() { printf '%s %s\n' "$2" "${WD_INST:-0}" > "$WD_DIR/$1.judged"; }

# Every situation script at once, each under `timeout`: the agent costs at
# most WD_SCRIPT_TIMEOUT s whatever hangs (FR-014). An id with neither a
# pane nor a process (an expected seat, spl_wd_expected) runs S3 alone: a
# dead seat is S3's gone pane, and a waiting inbox (S1) or a stale login
# (S2) of a seat that is not running on this box is no reason to start one.
spl_wd_run_scripts() {
  local id="$1" pid="$2" pane="$3" ctx="$4" s
  local -a sp=()
  for s in "$WD_SITUATIONS"/s[0-9]*.sh; do
    [[ -f "$s" ]] || continue
    [[ -z "$pid$pane" && "${s##*/}" != s3.sh ]] && continue
    ( WD_CTX="$ctx" timeout -k 1 "$WD_SCRIPT_TIMEOUT" bash "$s" "$id" "${pid:--}" "${pane:--}" \
        > "$ctx/out.$(basename "$s" .sh)" 2>/dev/null 6>&- 7>&- 9>&- || true ) &
    sp+=("$!")
  done
  if (( ${#sp[@]} )); then wait "${sp[@]}" 2>/dev/null || true; fi
  return 0
}

# spl_wd_tmux_lists TICK: <tick>/panes, one line per pane "<pane>\t<pane pid>\t
# <session>\t<window name>\t<fg command>\t<window id>", and <tick>/clients,
# one line per client "<session> <activity epoch> <window id>": the window the
# client shows NOW, which the human guard compares (spec 102 3, the R3 note).
spl_wd_tmux_lists() {
  spl_wd_tmux list-panes -a -F '#{pane_id}	#{pane_pid}	#{session_id}	#{window_name}	#{pane_current_command}	#{window_id}' \
    > "$1/panes" 2>/dev/null || true
  spl_wd_tmux list-clients -F '#{session_id} #{client_activity} #{window_id}' > "$1/clients" 2>/dev/null || true
}

# The context dir of one agent (situations/lib.inc.sh names the files).
spl_wd_gather() {
  local id="$1" pid="$2" pane="$3" now="$4" tick="$5" ctx="$6" ppid sess win act rundir
  echo "$now" > "$ctx/now"
  cp "$SPOOL_ROOT/$id/heartbeat.json" "$ctx/heartbeat" 2>/dev/null || true
  # S9 (spec 102 8.1): what was typed into the pane, and when the model got a prompt
  tail -n 50 "$SPOOL_ROOT/$id/lifetime/input.log" > "$ctx/input_log" 2>/dev/null || true
  tail -n 200 "$SPOOL_ROOT/$id/heartbeat.log" > "$ctx/hblog" 2>/dev/null || true
  cp "$SPOOL_ROOT/peer/$id/held" "$ctx/held" 2>/dev/null || true
  if awk -v i="$id" '$1 == i {f = 1} END {exit !f}' "$SPOOL_ROOT/peer/seats" 2>/dev/null; then echo "$id" > "$ctx/seat"; fi
  spl_wd_inbox "$SPOOL_ROOT/$id/inbox" > "$ctx/inbox"
  rundir="$(awk -F'\t' -v i="$id" '$1 == i {d = $4} END {print d}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true)"
  if [[ "$rundir" == /* && ! -d "$rundir" ]]; then echo "$rundir" > "$ctx/rundir_gone"; fi
  spl_wd_lifetime "$id" "$ctx"
  if [[ -n "$pid" ]]; then
    awk -v p="$pid" '$1 == p {print $3}' "$tick/ps" > "$ctx/proc_age"
    spl_wd_transcript "$pid" > "$ctx/transcript"
    spl_rotate_user "$pid" > "$ctx/user" 2>/dev/null || true
  fi
  [[ -n "$pane" ]] || return 0
  spl_wd_tmux capture-pane -p -t "$pane" > "$ctx/pane" 2>/dev/null || rm -f "$ctx/pane"
  if [[ -s "$ctx/pane" ]]; then
    spl_wd_since "$id" s9pane "$(timeout -k 1 "$WD_SCRIPT_TIMEOUT" bash "$WD_SITUATIONS/s9.sh" --norm 2>/dev/null < "$ctx/pane" 6>&- 7>&- 9>&- || true)" "$now" "$ctx/pane_age"
  fi
  IFS=$'\t' read -r ppid sess win < <(awk -F'\t' -v p="$pane" '$1 == p {print $2 "\t" $3 "\t" $6}' "$tick/panes") || true
  awk -F'\t' -v p="$pane" '$1 == p {print $5}' "$tick/panes" > "$ctx/fg"
  [[ -n "${ppid:-}" ]] && spl_wd_tree "$ppid" "$tick/ps" > "$ctx/tree"
  # the human guard: only a client showing THIS window counts, not one
  # anywhere in its session (a box whose fleet windows share the owner's session).
  # A line without a window id (an older capture) counts on its session.
  act="$(awk -v s="${sess:-none}" -v w="${win:-}" '$1 == s && (w == "" || $3 == "" || $3 == w) && $2 > m {m = $2} END {print m + 0}' "$tick/clients")"
  if (( act > 0 )); then echo $(( now - act )) > "$ctx/client_age"; fi
  spl_wd_since "$id" spin "$(grep -v '^[[:space:]]*$' "$ctx/pane" 2>/dev/null | tail -n 12 |
    grep -oE -- '…[[:space:]]*\([0-9][^)]*\)' | tail -1 | grep -oE '\(.*\)' || true)" "$now" "$ctx/spin_age"
  # shellcheck disable=SC2317 # called by spl_rotate_input
  ( spl_rotate_tmux() { spl_wd_tmux "$@"; }; spl_rotate_input "$pane" ) > "$ctx/input" 2>/dev/null || : > "$ctx/input"
  spl_wd_since "$id" input "$(cat "$ctx/input")" "$now" "$ctx/input_age"
  return 0
}

# S3's done or died (spec 102 4.3): the mtime of lifetime/done and
# lifetime/rebirth, the session start (session.json's `started`, else its
# mtime) and the pane of an open registry row ("-" when it names none).
spl_wd_lifetime() {
  local id="$1" ctx="$2" lt="$SPOOL_ROOT/$1/lifetime" f s
  for f in "done" rebirth; do
    [[ -f "$lt/$f" ]] && { stat -c %Y "$lt/$f" > "$ctx/$f" 2>/dev/null || true; }
  done
  if [[ -f "$lt/session.json" ]]; then
    s="$(jq -r '.started // empty' "$lt/session.json" 2>/dev/null || true)"
    s="$(date -u -d "${s:-x}" +%s 2>/dev/null || stat -c %Y "$lt/session.json" 2>/dev/null || true)"
    [[ -n "$s" ]] && echo "$s" > "$ctx/session_start"
  fi
  awk -F'\t' -v i="$id" '$1 == i {p = ($3 == "" ? "-" : $3); f = 1} END {if (f) print p}' \
    "$SPOOL_ROOT/registry.tsv" > "$ctx/registry_open" 2>/dev/null || true
  return 0
}

# "<mtime epoch> <file> <kind> <from>" per <dir>/*.json, one jq for the
# whole inbox; a file that does not parse reads "- -" (S1 counts it as a job).
spl_wd_inbox() {
  local dir="$1" q f
  local -a fs=()
  q='[.kind, .from] | map(. // "-" | tostring | gsub("[[:space:]]"; "") | if . == "" then "-" else . end)
    | "\(input_filename | sub(".*/"; "")) \(join(" "))"'
  mapfile -t fs < <(find "$dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null)
  (( ${#fs[@]} )) || return 0
  {
    # a file that does not parse stops jq: then one jq per file
    jq -r "$q" "${fs[@]}" 2>/dev/null ||
      for f in "${fs[@]}"; do jq -r "$q" "$f" 2>/dev/null || true; done
    echo "--"
    find "$dir" -maxdepth 1 -type f -name '*.json' -printf '%T@ %f\n' 2>/dev/null | sed 's/\.[0-9]* / /'
  } | awk '$0 == "--" {m = 1; next} !m {k[$1] = $2 " " $3; next}
      {print $1, $2, (($2 in k) ? k[$2] : "- -")}'
  return 0
}

# The transcript tail of <pid> (LEASE_TRANSCRIPT_CMD replaces it), bounded.
spl_wd_transcript() {
  ( spl_lease_transcript_tail "$1" ) 2>/dev/null | tail -n "${LEASE_TRANSCRIPT_TAIL:-400}" || true
}

# The comm of every process under <pid> (the pane's tree), from the ps dump.
spl_wd_tree() {
  awk -v root="$1" '{ pp[$1] = $2; c[$1] = $4 }
    END { for (p in pp) { q = p
            for (k = 0; k < 64 && q > 1; k++) { if (q == root) { print c[p]; break }; q = pp[q] } } }' "$2" | sort -u
}

# How long <id>'s <what> has held <text>: state <WD_DIR>/<id>.<what> keeps
# "<since epoch>\t<text hash>"; the age goes to <out>, nothing for empty text.
spl_wd_since() {
  local id="$1" what="$2" text="$3" now="$4" out="$5" f h since="" old=""
  f="$WD_DIR/$id.$what"
  if [[ -z "$text" ]]; then rm -f "$f"; return 0; fi
  h="$(printf '%s' "$text" | cksum | cut -d' ' -f1)"
  if [[ -f "$f" ]]; then IFS=$'\t' read -r since old < "$f" || true; fi
  if [[ "$old" != "$h" || ! "$since" =~ ^[0-9]+$ ]]; then
    since="$now"
    printf '%s\t%s\n' "$now" "$h" > "$f"
  fi
  echo $(( now - since )) > "$out"
  return 0
}

# Why <id> is out of the situations this tick (6.2); nothing when it is checked.
spl_wd_skip() {
  local id="$1" pid="$2" now="$3" tick="$4" ctx="$5" hid ht r age st hbt
  if [[ -s "$LEASE_DIR/rotate.hold" ]]; then
    read -r hid ht _ < "$LEASE_DIR/rotate.hold" || true
    if [[ "$hid" == "$id" && "$ht" =~ ^[0-9]+$ ]] && (( now - ht < ${ROTATE_HOLD_MAX:-1800} )); then
      echo "rotation: rotate.hold names it"; return 0
    fi
  fi
  r="$(spl_wd_rotating "$id" "$now")"
  if [[ -n "$r" ]]; then echo "rotation: $r"; return 0; fi
  age="$(cat "$ctx/proc_age" 2>/dev/null || true)"
  if [[ "$age" =~ ^[0-9]+$ ]] && (( age < WD_START_GRACE )); then
    echo "start grace: session ${age}s old"; return 0
  fi
  st="$(jq -r '.state // empty' "$ctx/heartbeat" 2>/dev/null || true)"
  hbt="$(jq -r '.ts // empty' "$ctx/heartbeat" 2>/dev/null || true)"
  hbt="$(date -u -d "${hbt:-x}" +%s 2>/dev/null || true)"
  if [[ "$st" == starting && "$hbt" =~ ^[0-9]+$ ]] && (( now - hbt < WD_START_GRACE )); then
    echo "start grace: SessionStart $((now - hbt))s ago"; return 0
  fi
  r="$(cat "$WD_DIR/resume$WD_SFX" 2>/dev/null || true)"
  if [[ "$r" =~ ^[0-9]+$ ]] && (( now - r < WD_START_GRACE )); then
    echo "resume grace: box back $((now - r))s ago"; return 0
  fi
  return 0
}

# The phase of a rotation or takeover of <id> still in flight: the last
# rotate.log line whose run id ends in -<id>, when it is not final and is
# younger than 15 min. Read under the judge lock: a restart one instance
# started is seen by the next judge, which does not start another.
spl_wd_rotating() {
  local id="$1" now="$2" ts rid phase res t
  [[ -f "$ROTATE_LOG" ]] || return 0
  read -r ts rid phase res _ < <(awk -v s="-$id" 'substr($2, length($2) - length(s) + 1) == s {l = $0} END {print l}' "$ROTATE_LOG") || return 0
  [[ -n "${rid:-}" ]] || return 0
  case "$phase" in DONE|FAIL|ABORT|ALERT) return 0 ;; esac
  [[ "$res" == FAIL ]] && return 0
  t="$(date -u -d "$ts" +%s 2>/dev/null || true)"
  [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < 900 )) && echo "$rid $phase $res"
  return 0
}

# ---- verdicts ----------------------------------------------------------------------

# The order a verdict is picked in when several situations hit. S8 is never
# the verdict: a silent hook is not a stuck agent (6.1). S7 before S9: a known
# dialog gets its answer in one tick, S9 is the net for the rest (102 8.2).
WD_ORDER="S3 S2 S7 S4 S5 S9 S1 S6"

# The debounce of a code in ticks (6.1): S2, S3 and S8 2, the rest 1 (S1 and
# S6 carry their own age).
spl_wd_need() { case "$1" in S2|S3|S8) echo 2 ;; *) echo 1 ;; esac; }

# Debounce, verdict file, act; prints the rest of the agent's verdict line.
spl_wd_judge() {
  local id="$1" pid="$2" pane="$3" now="$4" ctx="$5" code ev cnt need main="" mainev="" pend="" extra="" act
  cat "$ctx"/out.s* 2>/dev/null | grep -E '^HIT S[0-9]+( |$)' | sort -u > "$ctx/hits" || true
  : > "$WD_DIR/$id.hits.new.$BASHPID"
  while read -r _ code ev; do
    cnt="$(awk -v c="$code" '$1 == c {print $2}' "$WD_DIR/$id.hits" 2>/dev/null || true)"
    cnt=$(( ${cnt:-0} + 1 ))
    echo "$code $cnt" >> "$WD_DIR/$id.hits.new.$BASHPID"
    need="$(spl_wd_need "$code")"
    if (( cnt < need )); then pend+=" (pending $code $cnt/$need: $ev)"; continue; fi
    printf '%s\t%s\n' "$code" "$ev" >> "$ctx/confirmed"
  done < "$ctx/hits"
  mv -f "$WD_DIR/$id.hits.new.$BASHPID" "$WD_DIR/$id.hits"
  spl_wd_episodes_end "$id" "$ctx/hits"
  for code in $WD_ORDER; do
    ev="$(awk -F'\t' -v c="$code" '$1 == c {print $2; exit}' "$ctx/confirmed" 2>/dev/null || true)"
    if awk -F'\t' -v c="$code" '$1 == c {f = 1} END {exit !f}' "$ctx/confirmed" 2>/dev/null; then
      main="$code"; mainev="$ev"; break
    fi
  done
  if [[ -n "$main" ]]; then
    spl_wd_verdict "$id" "HIT $main" "$now"
    act="$(spl_wd_act "$id" "$main" "$mainev" "$pane" "$now" "$ctx")"
    printf 'HIT %s %s%s' "$main" "$mainev" "${act:+ -> $act}"
  else
    spl_wd_verdict "$id" OK "$now"
    printf 'OK'
  fi
  ev="$(awk -F'\t' '$1 == "S8" {print $2; exit}' "$ctx/confirmed" 2>/dev/null || true)"
  if [[ -n "$ev" ]]; then
    act="$(spl_wd_act "$id" S8 "$ev" "$pane" "$now" "$ctx")"
    extra=" (S8 $ev${act:+ -> $act})"
  fi
  act="$(spl_wd_s9_pokes "$id" "$now" "$ctx")"
  printf '%s%s%s\n' "$extra" "$pend" "${act:+ (S9 $act)}"
  return 0
}

# <spool root>/dispatch/wd.<id>: "HIT <code> <epoch>" or "OK <epoch>", atomically.
spl_wd_verdict() {
  local f="$LEASE_DIR/wd.$1"
  printf '%s %s\n' "$2" "$3" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  return 0
}

# A code that no longer hits ends its episode: its once-flags and counters go.
spl_wd_episodes_end() {
  local id="$1" hits="$2" f code
  for f in "$WD_DIR/$id".ep.S*; do
    [[ -e "$f" ]] || continue
    code="${f#"$WD_DIR/$id".ep.}"; code="${code%%.*}"
    grep -qE "^HIT $code( |$)" "$hits" || rm -f "$f"
  done
  return 0
}

# ---- actions ------------------------------------------------------------------------

# Why the watchdog may not act on <id> now; nothing when it may (6.2, 6.3).
# WD_GATE_NO_HUMAN=1 (the hard end, spec 102 R3) skips the human guards.
# The client guard reads ctx/client_age: a client whose CURRENT window is the
# agent's window (spl_wd_gather), so an owner typing in another window of the
# same session blocks nothing. A rebirth or a died session (S3) has no harness
# left to guard, but its restart still renames and closes that window and
# spawns next to it: the same window check (and a .human-hold) holds it.
# A hold of spec 102 6.1 (<id>/lifetime/heldout) never expires; the hour of
# a hold do_spl_wd_takeover wrote (<WD_DIR>/<id>.heldout) still does.
spl_wd_gate() {
  local id="$1" now="$2" ctx="$3" h c
  if [[ -z "${WD_GATE_NO_HUMAN:-}" ]]; then
    h="$(cat "$SPOOL_ROOT/$id/.human-hold" 2>/dev/null || true)"
    if [[ "$h" =~ ^[0-9]+$ ]] && (( h > now )); then echo "human hold for $(( (h - now + 59) / 60 )) min"; return 0; fi
    c="$(cat "$ctx/client_age" 2>/dev/null || true)"
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c <= ${WD_HUMAN_IDLE:-120} )); then echo "a human client was active ${c}s ago"; return 0; fi
  fi
  if [[ -z "${WD_GATE_NO_HELDOUT:-}" && -e "$SPOOL_ROOT/$id/lifetime/heldout" ]]; then
    echo "held out until the admin clears it ($(head -c 120 "$SPOOL_ROOT/$id/lifetime/heldout" 2>/dev/null || true))"; return 0
  fi
  h="$(cat "$WD_DIR/$id.heldout" 2>/dev/null || true)"
  if [[ -z "${WD_GATE_NO_HELDOUT:-}" && "$h" =~ ^[0-9]+$ ]] && (( now - h < 3600 )); then
    echo "held out after $WD_TAKEOVER_MAX takeovers in an hour"; return 0
  fi
  if [[ -n "${WD_BOX_BUSY:-}" ]]; then echo "$WD_BOX_BUSY"; return 0; fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then echo "dry run"; return 0; fi
  return 0
}

# Act on one confirmed code; prints what was done (or would be).
spl_wd_act() {
  local id="$1" code="$2" ev="$3" pane="$4" now="$5" ctx="$6" age
  case "$code" in
    S1) age="${ev#age=}"; age="${age%% *}"
        # no progress signal at all (no heartbeat, no readable transcript):
        # "no progress" is unproven, so a ring, never a takeover
        if (( age >= 2 * WD_JOB_WAIT )) && [[ " $ev " != *" prog=unknown "* ]]; then spl_wd_once "$id" S1 takeover "$now" "$ctx" spl_wd_takeover "$id" S1 "$ev"
        else spl_wd_once "$id" S1 ring "$now" "$ctx" spl_wd_ring "$id"; fi ;;
    S2) if [[ "$ev" == kind=login* ]]; then
          spl_wd_once "$id" S2 dm "$now" "$ctx" spl_wd_send orchestrator blocker "$id" \
            "WATCHDOG (093 S2): $id cannot act, a login or access screen: ${ev#kind=login }. Harness $(spl_wd_harness "$id"), OS user $(spl_wd_user "$ctx"), box $ROTATE_BOX, pane ${pane:-none}. A restart does not fix a login: a human runs /login in that pane."
        else echo "not able until the reset; no restart"; fi ;;
    S3) spl_wd_once "$id" S3 takeover "$now" "$ctx" spl_wd_takeover "$id" S3 "$ev" ;;
    S4) spl_wd_s4 "$id" "$ev" "$pane" "$now" "$ctx" ;;
    S5) spl_wd_s5 "$id" "$ev" "$pane" "$now" "$ctx" ;;
    S6) if [[ "$ev" == poke=1* ]]; then spl_wd_once "$id" S6 repoke "$now" "$ctx" spl_wd_repoke "$id" "$pane"
        else echo "not poke-shaped: left alone"; fi ;;
    S7) if [[ "$ev" == modal=2* ]]; then spl_wd_s7_offer "$id" "$ev" "$pane" "$now" "$ctx" | paste -sd ';' -
        elif [[ "$ev" == modal=1* && ! -e "$WD_DIR/$id.ep.S7.esc" ]]; then spl_wd_once "$id" S7 esc "$now" "$ctx" spl_wd_key "$pane" Escape
        else spl_wd_once "$id" S7 note "$now" "$ctx" spl_wd_send peers note "$id" "WATCHDOG (093 S7): $id is blocked by a dialog (${ev#modal=? }) and is not able."; fi ;;
    S9) spl_wd_s9 "$id" "$ev" "$pane" "$now" "$ctx" | paste -sd ';' - ;;
    S8) spl_wd_once "$id" S8 gap "$now" "$ctx" spl_wd_send peers note "$id" \
          "WATCHDOG (093 S8): GAP $id - its hook is silent ($ev). Progress is read from its transcript until spool-agent-hook.sh runs for it." ;;
  esac
  return 0
}

# spl_wd_once ID CODE TAG NOW CTX CMD...: run CMD once per episode of CODE,
# unless the gate says no ("would TAG (why)"). The flag
# <WD_DIR>/<id>.ep.<code>.<tag> holds the epoch it ran at. One exception: an
# S3 takeover WD_TAKEOVER_RETRY s ago whose fresh session is dead again
# (S3 still confirmed past the start wait and the grace) failed, and is
# retried in the same episode; spl_wd_takeover's hourly cap bounds it and
# sends the orchestrator the blocker (sat 2026-10-06: 13 h of "done ago").
spl_wd_once() {
  local id="$1" code="$2" tag="$3" now="$4" ctx="$5" f why t
  shift 5
  f="$WD_DIR/$id.ep.$code.$tag"
  if [[ -e "$f" ]]; then
    t="$(cat "$f" 2>/dev/null || true)"; [[ "$t" =~ ^[0-9]+$ ]] || t="$now"
    if [[ "$code.$tag" != S3.takeover ]] || (( now - t < WD_TAKEOVER_RETRY )); then echo "$tag done $(( now - t ))s ago"; return 0; fi
    rm -f "$f"
    spl_wd_log "TAKEOVER-FAILED $id S3: still no live session $(( now - t ))s after the takeover; retry"
  fi
  why="$(spl_wd_gate "$id" "$now" "$ctx")"
  if [[ -n "$why" ]]; then echo "would $tag ($why)"; return 0; fi
  local out
  if out="$("$@")"; then echo "$now" > "$f"; echo "$tag"; else echo "$tag not done${out:+: $out}"; fi
  return 0
}

# S9 (spec 102 8.2), an unknown screen that swallowed what was typed: nothing
# is typed into it. The pane, scrubbed, goes to <WD_DIR>/<id>.s9.pane and its
# path to the orchestrator ONCE, then a takeover (do_spl_agent_restart
# CAUSE=S9). The same pane reported less than WD_NOTE_DEBOUNCE s (300) ago
# (<id>/lifetime/s9.reported "<epoch> <pane cksum>") is not reported again.
spl_wd_s9() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5"
  spl_wd_once "$id" S9 snapshot "$now" "$ctx" spl_wd_s9_snapshot "$id" "$ev" "$pane" "$ctx"
  spl_wd_once "$id" S9 takeover "$now" "$ctx" spl_wd_takeover "$id" S9 "$ev"
}

spl_wd_s9_snapshot() {
  local id="$1" ev="$2" pane="$3" ctx="$4" f="$WD_DIR/$1.s9.pane" r="$SPOOL_ROOT/$1/lifetime/s9.reported" h now rt="" rh=""
  now="$(cat "$ctx/now")"
  h="$(cksum < "$ctx/pane" | cut -d' ' -f1)"
  read -r rt rh 2>/dev/null < "$r" || true
  if [[ "$rh" == "$h" && "$rt" =~ ^[0-9]+$ ]] && (( now - rt < ${WD_NOTE_DEBOUNCE:-300} )); then
    echo "this pane was reported $(( now - rt ))s ago"; return 1
  fi
  if ! timeout -k 1 "$WD_SCRIPT_TIMEOUT" bash "$WD_SITUATIONS/s9.sh" --scrub 2>/dev/null < "$ctx/pane" > "$f.tmp.$$" 6>&- 7>&- 9>&-; then
    rm -f "$f.tmp.$$"; echo "no snapshot"; return 1
  fi
  mv -f "$f.tmp.$$" "$f"
  spl_wd_send orchestrator note "$id" \
    "WATCHDOG (102 S9): $id is stuck: what was typed into its pane never reached the model ($ev). The screen is not a known dialog; nothing was typed into it. Pane snapshot (scrubbed): $f. Box $ROTATE_BOX, pane ${pane:-none}. A takeover follows." || return 1
  mkdir -p "${r%/*}" 2>/dev/null && printf '%s %s\n' "$now" "$h" > "$r" 2>/dev/null
  return 0
}

# S9's POKE lines: an unread inbox file nobody poked is poked ONCE (102 8.1;
# the poke is what starts S9's window). <WD_DIR>/<id>.s9.poked keeps the
# files poked, pruned to those still in the inbox. A poke recorded in
# <id>/lifetime/input.log less than 60 s ago (by any sender) means no poke
# now. Prints what was done.
spl_wd_s9_pokes() {
  local id="$1" now="$2" ctx="$3" f="$WD_DIR/$1.s9.poked" new why x t
  grep -q '^POKE ' "$ctx/out.s9" 2>/dev/null || return 0
  touch "$f"
  while read -r x; do
    if [[ -e "$SPOOL_ROOT/$id/inbox/$x" ]]; then echo "$x"; fi
  done < "$f" > "$f.tmp.$$"
  mv -f "$f.tmp.$$" "$f"
  new="$(awk '$1 == "POKE" && $2 != "" { print $2 }' "$ctx/out.s9" | grep -vxF -f "$f" || true)"
  [[ -n "$new" ]] || return 0
  t="$(tail -n 1 "$SPOOL_ROOT/$id/lifetime/input.log" 2>/dev/null | cut -d' ' -f1)"
  t="$(date -u -d "${t:-x}" +%s 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < 60 )); then echo "a poke was recorded $(( now - t ))s ago: none now"; return 0; fi
  why="$(spl_wd_gate "$id" "$now" "$ctx")"
  if [[ -n "$why" ]]; then echo "would poke an unpoked inbox file ($why)"; return 0; fi
  spl_wd_ring "$id"
  echo "$new" >> "$f"
  echo "poked once: an unread inbox file nobody poked"
}

# S4: Escape once; still in the call 60 s later: takeover.
spl_wd_s4() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5" t
  t="$(cat "$WD_DIR/$id.ep.S4.esc" 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]] && (( now - t >= 60 )); then
    spl_wd_once "$id" S4 takeover "$now" "$ctx" spl_wd_takeover "$id" S4 "$ev"
  else
    spl_wd_once "$id" S4 esc "$now" "$ctx" spl_wd_key "$pane" Escape
  fi
}

# S5: the hook warned at WD_LOOP_N repeats; WD_LOOP_N more: Escape and a note
# to the peers; WD_LOOP_N more again: takeover. Repeats are counted per call
# (<WD_DIR>/<id>.ep.S5.n: "<count> <last call ts>").
spl_wd_s5() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5" f n last sig res cnt=0 lts="" new
  f="$WD_DIR/$id.ep.S5.n"
  n="$(grep -oE 'n=[0-9]+' <<<"$ev" | sed -n 1p)"; n="${n#n=}"
  last="$(grep -oE 'last=[^ ]+' <<<"$ev" | sed -n 1p)"; last="${last#last=}"
  sig="$(grep -oE 'sig=[^ ]+' <<<"$ev" | sed -n 1p)"; sig="${sig#sig=}"
  res="$(grep -oE 'res=[^ ]+' <<<"$ev" | sed -n 1p)"; res="${res#res=}"
  if [[ -f "$f" ]]; then read -r cnt lts < "$f" || true; fi
  if [[ -z "$lts" ]]; then cnt="${n:-0}"
  elif [[ "$last" != "$lts" ]]; then
    new="$(jq --arg s "$sig" --arg r "$res" --arg t "$lts" \
      '[(.calls // [])[] | select(.sig == $s and .res == $r and .ts > $t)] | length' "$ctx/heartbeat" 2>/dev/null || echo 1)"
    cnt=$(( cnt + ${new:-1} ))
  fi
  echo "$cnt $last" > "$f"
  if (( cnt >= 3 * WD_LOOP_N )); then
    spl_wd_once "$id" S5 takeover "$now" "$ctx" spl_wd_takeover "$id" S5 "$ev"
  elif (( cnt >= 2 * WD_LOOP_N )); then
    spl_wd_once "$id" S5 esc "$now" "$ctx" spl_wd_s5_esc "$id" "$pane" "$cnt"
  else
    echo "the hook warned ($cnt repeats)"
  fi
}

spl_wd_s5_esc() {
  spl_wd_key "$2" Escape &&
    spl_wd_send peers note "$1" "WATCHDOG (093 S5): $1 repeated the same call with the same result $3 times; Escape was sent once."
}

# S7 modal=2, "Make auto mode your default permission mode?". The owner allows
# bypassPermissions only (t1 4a1966d8): "The watchdog should change all of the
# settings to this most permissive mode, kill that non-starting orchestrator,
# and start a new one with the most permissive mode and dangerous skip
# permissions on." So: (1) the agent user's settings.json gets bypass back,
# (2) a takeover (spawn-claude.sh: --dangerously-skip-permissions), and only
# when the takeover is refused, or the dialog outlives it by WD_S7_FALLBACK s
# (300), (3) the answer "No, keep bypass permissions".
spl_wd_s7_offer() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5" f out t
  spl_wd_once "$id" S7 settings "$now" "$ctx" spl_wd_s7_settings "$(spl_wd_user "$ctx")" "$now"
  f="$WD_DIR/$id.ep.S7.takeover"
  if [[ ! -e "$f" ]]; then
    out="$(spl_wd_once "$id" S7 takeover "$now" "$ctx" spl_wd_takeover "$id" S7 "$ev")"
    echo "$out"
    [[ "$out" == takeover || "$out" == would* ]] && return 0
  else
    t="$(cat "$f" 2>/dev/null || echo "$now")"
    if (( now - t < ${WD_S7_FALLBACK:-300} )); then echo "takeover started $(( now - t ))s ago"; return 0; fi
  fi
  # held out bars takeovers, not the answer that keeps bypass
  WD_GATE_NO_HELDOUT=1 spl_wd_once "$id" S7 no "$now" "$ctx" spl_wd_s7_no "$id" "$pane"
}

# permissions.defaultMode = bypassPermissions and skipDangerousModePermission-
# Prompt = true in <user>'s ~/.claude/settings.json (other keys kept), written
# as that user, the old file kept as settings.json.bak-wd-<epoch>.
# WD_SETTINGS_HOME replaces the home (tests: no sudo).
spl_wd_s7_settings() {
  local user="$1" now="$2" home f
  local -a as=()
  [[ "$user" == unknown || -z "$user" ]] && user="${SPOOL_AGENT_USER:-$(id -un)}"
  home="${WD_SETTINGS_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
  [[ -n "$home" && -d "$home" ]] || { echo "no home for $user"; return 1; }
  f="$home/.claude/settings.json"
  if jq -e '.permissions.defaultMode == "bypassPermissions" and .skipDangerousModePermissionPrompt == true' "$f" >/dev/null 2>&1; then return 0; fi
  [[ -z "${WD_SETTINGS_HOME:-}" && "$user" != "$(id -un)" ]] && as=(sudo -n -u "$user")
  # shellcheck disable=SC2016 # expanded by the inner bash
  "${as[@]}" bash -c 'f="$1"; mkdir -p "${f%/*}" || exit 1
    if [ -f "$f" ]; then cp -p "$f" "$f.bak-wd-$2" || exit 1; fi
    { if [ -s "$f" ]; then cat "$f"; else echo "{}"; fi; } |
      jq ".permissions.defaultMode = \"bypassPermissions\" | .skipDangerousModePermissionPrompt = true" > "$f.tmp.$$" &&
      mv -f "$f.tmp.$$" "$f"' _ "$f" "$now" || { echo "settings not written: $f"; return 1; }
  spl_wd_log "S7 SETTINGS $user $f: defaultMode=bypassPermissions skipDangerousModePermissionPrompt=true"
  return 0
}

# The fallback: "No, keep bypass permissions". Never Escape, never Yes: Down
# while s7.sh reads the cursor on Yes, then Enter only once it reads the
# cursor on No, from a fresh capture each time.
spl_wd_s7_no() {
  local id="$1" pane="$2" cur _
  for _ in 1 2 3; do
    cur="$(spl_wd_s7_cursor "$id" "$pane")"
    case "$cur" in
      no) spl_wd_key "$pane" Enter; return ;;
      yes) spl_wd_key "$pane" Down || return 1; sleep "${WD_KEY_WAIT:-0.5}" ;;
      *) echo "cursor ${cur:-gone}, no key"; return 1 ;;
    esac
  done
  echo "cursor never reached No"
  return 1
}

# yes|no|? from s7.sh on a fresh capture of <pane>; nothing when it is gone.
spl_wd_s7_cursor() {
  local d out
  d="$(mktemp -d)"
  spl_wd_tmux capture-pane -p -t "$2" > "$d/pane" 2>/dev/null || true
  out="$(WD_CTX="$d" timeout -k 1 "$WD_SCRIPT_TIMEOUT" bash "$WD_SITUATIONS/s7.sh" "$1" act "$2" 2>/dev/null 6>&- 7>&- 9>&- || true)"
  rm -rf "$d"
  [[ "$out" =~ ^HIT\ S7\ modal=2\ cursor=([a-z?]+) ]] && echo "${BASH_REMATCH[1]}"
  return 0
}

# ---- the outside world (seams: ROTATE_TMUX, WD_SEND, WD_TAKEOVER_CMD) ---------------

spl_wd_key() {
  [[ -n "$1" ]] || return 1
  spl_wd_tmux send-keys -t "$1" "$2" >/dev/null 2>&1
}

spl_wd_ring() {
  bash "$WD_SEND" --poke-only --from "$WD_FROM" --to "$1" >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&-
  return 0
}

# S6: empty the whole box (C-c: every row, spl_rotate_type's rule), then ring.
spl_wd_repoke() { spl_wd_key "$2" C-c && spl_wd_ring "$1"; }

# spl_wd_send TO KIND ID BODY: a spool message on task wd-<id>. spool-send.sh
# 1-9 = delivered (only the poke did not ring); 10+ or 2 = not delivered.
spl_wd_send() {
  local rc=0
  bash "$WD_SEND" --from "$WD_FROM" --to "$1" --kind "$2" --task "wd-$3" --body "$4" >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- || rc=$?
  (( rc < 10 && rc != 2 ))
}

spl_wd_harness() { awk -F'\t' -v i="$1" '$1 == i {k = $2} END {print (k == "" ? "unknown" : k)}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || echo unknown; }
spl_wd_user() { local u; u="$(cat "$1/user" 2>/dev/null || true)"; echo "${u:-unknown}"; }

# A takeover is the one restart path, do_spl_agent_restart (spec 102 4.1,
# T008), started detached; WD_TAKEOVER_CMD replaces it. CAUSE is the code,
# `rebirth` for an S3 hit that carries the rebirth marker. ONE counter (6.1):
# the restarts of the last hour in <id>/lifetime/restarts, written by the
# restart; at RESTART_MAX_PER_HOUR the id is held out (no expiry) and the
# orchestrator gets ONE blocker naming the verdicts.
spl_wd_takeover() {
  local id="$1" code="$2" ev="$3" now n cause
  if spl_wd_box_fenced; then echo "fenced: this box starts nothing (spec 102 10.2)"; return 1; fi
  now="$(spl_lease_now)"
  n="$(spl_wd_restarts_n "$id" "$now")"
  if (( n >= RESTART_MAX_PER_HOUR )); then
    spl_wd_hold_out "$id" "$now" "$n restarts in the last hour, then $code again ($ev)"
    spl_wd_send orchestrator blocker "$id" "WATCHDOG (102 6.1): $id was restarted $n times in the last hour and hit $code again ($ev); it is held out of the watchdog until the admin clears $SPOOL_ROOT/$id/lifetime/heldout. Recent verdicts: $(grep " $id HIT " "$WD_LOG" 2>/dev/null | tail -n 2 | cut -c1-200 | tr '\n' ';')" || true
    echo "held out: $n restarts in the last hour"
    return 1
  fi
  if [[ -z "${WD_TAKEOVER_CMD:-}" ]] && ! declare -F do_spl_agent_restart >/dev/null; then
    if [[ ! -e "$WD_DIR/$id.ep.$code.want" ]]; then
      echo "$now" > "$WD_DIR/$id.ep.$code.want"
      spl_wd_log "WANT-RESTART $id $code $ev (do_spl_agent_restart is not on this tree yet)"
    fi
    echo "do_spl_agent_restart is not on this tree yet"
    return 1
  fi
  cause="$code"
  [[ "$code" == S3 && "$ev" == rebirth:* ]] && cause=rebirth
  spl_wd_log "TAKEOVER $id $code $ev (do_spl_agent_restart CAUSE=$cause)"
  # shellcheck disable=SC2086 # a command line, split on purpose
  ( ID="$id" CAUSE="$cause" REASON="$code" WD_EVIDENCE="$ev" setsid ${WD_TAKEOVER_CMD:-$ROTATE_RUN -a do_spl_agent_restart} \
      >> "$WD_DIR/restart.$id.out" 2>&1 < /dev/null 6>&- 7>&- 8>&- 9>&- & )
  return 0
}

# spl_wd_restarts_n ID NOW: the restarts of <id> in the rolling hour, from the
# ONE counter <id>/lifetime/restarts ("<epoch> <cause>" per restart, written
# by do_spl_agent_restart); older lines are pruned.
spl_wd_restarts_n() {
  local f="$SPOOL_ROOT/$1/lifetime/restarts"
  [[ -f "$f" ]] || { echo 0; return 0; }
  awk -v n="$2" '$1 + 3600 > n' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null || true
  awk -v n="$2" '$1 + 3600 > n' "$f" 2>/dev/null | grep -c . || true
}

# spl_wd_hold_out ID NOW WHY: the hold of 6.1, <id>/lifetime/heldout. It does
# not expire (the admin clears it). <WD_DIR>/<id>.heldout too: the reaper
# reads that one.
spl_wd_hold_out() {
  local d="$SPOOL_ROOT/$1/lifetime"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s %s\n' "$(date -u -d "@$2" +%FT%TZ)" "$3" > "$d/heldout" 2>/dev/null || true
  echo "$2" > "$WD_DIR/$1.heldout" 2>/dev/null || true
  spl_wd_log "HELDOUT $1: $3"
  return 0
}

# ---- the box beat and the fence (spec 102 10.2, T017) ---------------------------
# Every tick beats the hub (`spool box-beat put --pid <loop pid>`, rdb 0147);
# its answer is the ack, kept in <WD_DIR>/beat.ack (epoch) and beat.down_min
# (the hub's box_down_min). No ack for box_down_min -> FENCED: <WD_DIR>/fenced
# exists, spl_wd_takeover starts nothing, every LANE of this box is TERMed
# once after its wip push (the seats keep running) and the orchestrator gets
# ONE note. The next ack lifts it. A box with no hub (no fleet in lease.conf)
# or WD_BEAT=0 never beats and is never fenced. Seams: WD_BEAT_CMD (the hub
# call: `<cmd> put --pid <pid>`), WD_WIP_CMD (the wip push), WD_KILL_CMD.

# spl_wd_fence NOW TICK: the tick's one call (after its agents are listed).
spl_wd_fence() {
  local now="$1" tick="$2" id pid _pane
  spl_wd_beat "$now"
  if ! spl_wd_fence_due "$now"; then
    if [[ -e "$WD_DIR/fenced" ]]; then
      rm -f "$WD_DIR/fenced" "$WD_DIR"/fence.term.*
      spl_wd_log "UNFENCED${WD_INST:+ instance $WD_INST}: the hub acked this box's beat again; restarts resume"
    fi
    return 0
  fi
  if ( set -C; echo "$now" > "$WD_DIR/fenced" ) 2>/dev/null; then
    spl_wd_log "FENCED${WD_INST:+ instance $WD_INST}: no beat ack for $(( now - $(spl_wd_beat_ack) ))s (box_down_min $(spl_wd_down_min)): this box starts nothing and stops its lanes"
    if [[ "${DRY_RUN:-1}" == 0 ]]; then
      spl_wd_send orchestrator note "fence-${WD_BOX:-box}" "FENCED (spec 102 10.2): box ${WD_BOX:-?} has had no beat ack from the hub for box_down_min ($(spl_wd_down_min) min). It starts nothing and TERMs its lanes after their wip push; seats keep running. It lifts at the next ack." || true
    fi
  fi
  local -a jp=()
  while IFS=$'\t' read -r id pid _pane; do
    spl_wd_fence_is_seat "$id" && continue
    ( set -C; echo "$now" > "$WD_DIR/fence.term.$id" ) 2>/dev/null || continue
    spl_wd_fence_lane "$id" "$pid" &
    jp+=("$!")
  done < "$tick/agents"
  if (( ${#jp[@]} )); then wait "${jp[@]}" 2>/dev/null || true; fi
  return 0
}

# spl_wd_box_fenced: 0 while this box is fenced (spl_wd_takeover's gate).
spl_wd_box_fenced() { [[ -e "$WD_DIR/fenced" ]]; }

# spl_wd_fence_lane ID PID: the wip push (bounded: origin may be as far away
# as the hub), then TERM. DRY_RUN=1 only logs.
spl_wd_fence_lane() {
  local id="$1" pid="$2" rc=0
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    spl_wd_log "FENCE-DRY $id: would push its wip ref, then TERM pid $pid"; return 0
  fi
  # shellcheck disable=SC2086 # a command line, split on purpose
  ID="$id" DRY_RUN=0 timeout -k 5 "${WD_FENCE_WIP_TIMEOUT:-60}" ${WD_WIP_CMD:-$ROTATE_RUN -a do_spl_lane_wip_push} \
    >> "$WD_DIR/fence.$id.out" 2>&1 < /dev/null 6>&- 7>&- 8>&- 9>&- || rc=$?
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    spl_wd_log "FENCE $id: wip push rc=$rc; no process to TERM"; return 0
  fi
  ${WD_KILL_CMD:-kill} -TERM "$pid" 2>/dev/null || true
  spl_wd_log "FENCE $id: wip push rc=$rc, TERM pid $pid"
}

# A seat never moves (10.2): ids 001..004, a peer seat, an expected seat.
spl_wd_fence_is_seat() {
  if declare -F spl_ars_is_seat >/dev/null; then spl_ars_is_seat "$1"; return; fi
  [[ "$1" =~ -00[1-4]$ ]]
}

# spl_wd_beat NOW: one beat, bounded by WD_BEAT_TIMEOUT (10 s). An answer
# with "ok": true is the ack. The first beat of a box with no ack yet starts
# the clock (a box that never reached the hub is fenced box_down_min later).
spl_wd_beat() {
  local now="$1" out dm
  spl_wd_beat_on || return 0
  out="$(spl_wd_beat_call 2>/dev/null)" || out=""
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$out"; then
    echo "$now" > "$WD_DIR/beat.ack.$$" && mv -f "$WD_DIR/beat.ack.$$" "$WD_DIR/beat.ack"
    dm="$(jq -r '.box_down_min // empty' 2>/dev/null <<<"$out")"
    if [[ "$dm" =~ ^[0-9]+$ ]] && (( dm >= 1 )); then
      echo "$dm" > "$WD_DIR/beat.down_min.$$" && mv -f "$WD_DIR/beat.down_min.$$" "$WD_DIR/beat.down_min"
    fi
  else
    spl_wd_log "BEAT${WD_INST:+ instance $WD_INST}: no ack from the hub ($(head -c 160 <<<"${out:-no answer}" | tr '\n' ' '))"
    [[ -s "$WD_DIR/beat.ack" ]] || echo "$now" > "$WD_DIR/beat.ack"
  fi
  return 0
}

# On when the beat has a hub: WD_BEAT_CMD, or the lane map's hub (lease.conf
# fleet), read once per loop and retried every 20 ticks while missing.
spl_wd_beat_on() {
  [[ "${WD_BEAT:-1}" != 0 ]] || return 1
  [[ -n "${WD_BEAT_CMD:-}" ]] && return 0
  [[ "${WD_BEAT_MODE:-}" == hub ]] && return 0
  if [[ -n "${WD_BEAT_MODE:-}" ]] && (( WD_TICK_SEQ % 20 != 1 )); then return 1; fi
  WD_BEAT_MODE=off
  declare -F spl_lane_init >/dev/null || return 1
  if spl_lane_init >/dev/null 2>&1 6>&- && [[ "${LANE_MODE:-}" == hub ]]; then WD_BEAT_MODE=hub; return 0; fi
  return 1
}

spl_wd_beat_call() {
  if [[ -n "${WD_BEAT_CMD:-}" ]]; then
    timeout -k 1 "${WD_BEAT_TIMEOUT:-10}" "$WD_BEAT_CMD" put --pid "$$" 6>&- 7>&- 8>&- 9>&-
    return
  fi
  LANE_TIMEOUT="${WD_BEAT_TIMEOUT:-10}" spl_lane_spool box-beat put --pid "$$" 6>&- 7>&- 8>&- 9>&-
}

spl_wd_beat_ack() { local a; a="$(cat "$WD_DIR/beat.ack" 2>/dev/null)"; [[ "$a" =~ ^[0-9]+$ ]] && echo "$a" || echo ""; }

# box_down_min: WD_BOX_DOWN_MIN, else the hub's (beat.down_min), else 2.
spl_wd_down_min() {
  local m="${WD_BOX_DOWN_MIN:-$(cat "$WD_DIR/beat.down_min" 2>/dev/null)}"
  [[ "$m" =~ ^[0-9]+$ ]] && (( m >= 1 )) || m=2
  echo "$m"
}

# spl_wd_fence_due NOW: 0 when the beat is on and its last ack is
# box_down_min or more old.
spl_wd_fence_due() {
  local ack
  spl_wd_beat_on || return 1
  ack="$(spl_wd_beat_ack)"
  [[ -n "$ack" ]] || return 1
  (( $1 - ack >= $(spl_wd_down_min) * 60 ))
}
