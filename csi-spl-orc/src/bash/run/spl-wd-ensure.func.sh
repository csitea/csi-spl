#!/bin/bash
#------------------------------------------------------------------------------
# @description Start this box's watchdog when it is not running (spec 093
# @description section 6, the `* * * * *` keeper). Starts ONLY do_spl_watchdog.
# @description It does not start poll loops, and it runs with or without
# @description <spool root>/peer/seats (P0/P1 have none). A second run while the
# @description loop holds dispatch/wd/run.lock starts nothing. The loop it
# @description starts acts (DRY_RUN=0) and runs forever (WD_TICKS cleared): a
# @description proof tick stays on the caller's own do_spl_watchdog.
# @description It also watches the watchdog (spec 093 6.4): a restart of a dead
# @description loop, a crash loop (more than WD_ENSURE_LOOP_MAX restarts in an
# @description hour) and a hung loop (alive, no tick for WD_ENSURE_HUNG s) each
# @description send ONE blocker to the orchestrator per WD_ENSURE_DEBOUNCE s;
# @description the crash loop and the hung loop also DM the owner (ASKS_OWNER
# @description of lease.conf) through do_spl_desk_reply, the orch take-over's
# @description owner path. It rotates run.out and its own ensure.out to .1
# @description once a day (spl_wd_log_rotate).
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param WD_RUN (optional) - the ./run that starts the loop (tests)
# @param WD_ENSURE_WATCH_DRY (optional) - DRY_RUN handed to the loop, default 0
# @param WD_ENSURE_SEND (optional) - spool-send.sh (tests: a stub)
# @param WD_ENSURE_OWNER_CMD (optional) - replaces the owner DM, gets the text on stdin (tests)
# @param WD_ENSURE_OUT (optional) - this keeper's own log, default <WD_CRON_LOG_DIR>/ensure.out (/var/<org>/<org>-<app>/wd)
# @param WD_ENSURE_HUNG / WD_ENSURE_LOOP_MAX / WD_ENSURE_DEBOUNCE (optional) - 180 s, 3, 1800 s
# @param WD_LOG_KEEP / WD_LOG_MAX_BYTES (optional) - rotate a log after 86400 s or 64 MiB
# @example ./run -a do_spl_wd_ensure
#------------------------------------------------------------------------------
declare -F spl_lease_detach >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

SPL_WD_ENSURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The watchdog dir. Seats are not required and are not read here.
spl_wd_ensure_init() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  export SPOOL_ROOT
  spl_lease_init || return 1
  spl_lease_conf
  WD_DIR="$LEASE_DIR/wd"
  mkdir -p "$WD_DIR" || { do_log "FATAL cannot create $WD_DIR"; return 1; }
  : "${WD_ENSURE_HUNG:=180}" "${WD_ENSURE_LOOP_MAX:=3}" "${WD_ENSURE_DEBOUNCE:=1800}"
  local k
  for k in WD_ENSURE_HUNG WD_ENSURE_LOOP_MAX WD_ENSURE_DEBOUNCE; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  return 0
}

# 0 when a watchdog holds the same lock do_spl_watchdog takes for its life.
spl_wd_ensure_running() {
  [[ -f "$WD_DIR/run.lock" ]] || return 1
  ! flock -n "$WD_DIR/run.lock" true
}

# Start the acting loop, detached. The subshell keeps the DRY_RUN / WD_TICKS
# prefix off the caller (bash keeps a function prefix assignment).
spl_wd_ensure_start() {
  local run="${WD_RUN:-${PROJ_PATH:-}/run}"
  [[ -x "$run" ]] || { do_log "FATAL watchdog runner is missing or not executable: ${run:-<none>}"; return 1; }
  (
    export DRY_RUN="${WD_ENSURE_WATCH_DRY:-0}"
    export WD_TICKS=""
    spl_lease_detach "$WD_DIR/run.out" "$run" -a do_spl_watchdog
  )
  do_log "INFO watchdog started (log $WD_DIR/run.out)"
  return 0
}

do_spl_wd_ensure() {
  spl_wd_ensure_init || return 1
  local now last dead
  now="$(spl_lease_now)"
  last="$(cat "$WD_DIR/ensure.last" 2>/dev/null || true)"
  echo "$now" > "$WD_DIR/ensure.last"
  if spl_wd_ensure_running; then
    spl_wd_ensure_logs "$now"
    do_log "INFO watchdog running (pid $(cat "$WD_DIR/run.pid" 2>/dev/null || echo unknown))"
    # a box back from suspend: the loop's tick is as old as the gap, not hung
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last > WD_ENSURE_HUNG )); then
      do_log "INFO the keeper was silent $((now - last))s (suspend or cron gap): no hung check this run"
      return 0
    fi
    spl_wd_ensure_hung "$now"
    return 0
  fi
  if [[ ! -s "$SPOOL_ROOT/peer/seats" ]]; then
    do_log "INFO no seats in $SPOOL_ROOT/peer/seats - starting the watchdog anyway"
  fi
  # the dead loop's last words, before the new loop appends to run.out
  dead="$(cat "$WD_DIR/run.pid" 2>/dev/null || true)"
  tail -n 5 "$WD_DIR/run.out" 2>/dev/null | cut -c1-200 > "$WD_DIR/run.out.prev" || true
  spl_wd_ensure_logs "$now"
  spl_wd_ensure_start || return 1
  # no run.pid: the first start on this box, nothing died
  [[ -n "$dead" ]] && spl_wd_ensure_restarted "$now" "$dead"
  return 0
}

# ---- watching the watchdog (spec 093 6.4) -------------------------------------------

spl_wd_ensure_box() { echo "${LEASE_MACHINE:-$(spl_desk_box_default 2>/dev/null || hostname -s)}"; }

# A dead loop was started again: one blocker; more than WD_ENSURE_LOOP_MAX in
# the last hour is a crash loop: a blocker and the owner DM.
spl_wd_ensure_restarted() {
  local now="$1" dead="$2" f="$WD_DIR/ensure.restarts" n box tail5
  touch "$f"
  { awk -v n="$now" '$1 + 3600 > n' "$f"; echo "$now"; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  n="$(grep -c . "$f" || true)"
  box="$(spl_wd_ensure_box)"
  tail5="$(tr '\n' ';' < "$WD_DIR/run.out.prev" 2>/dev/null || true)"
  do_log "WARN the watchdog on $box was dead (pid $dead) and was started again ($n restart(s) in the last hour)"
  spl_wd_ensure_alert restart "$now" "" \
    "WATCHDOG KEEPER (093 6.4): the watchdog on box $box was dead (pid $dead) and was started again; $n restart(s) in the last hour. Last 5 lines of $WD_DIR/run.out: ${tail5:-<empty>}"
  if (( n > WD_ENSURE_LOOP_MAX )); then
    spl_wd_ensure_alert crashloop "$now" owner \
      "WATCHDOG KEEPER (093 6.4): CRASH LOOP - the watchdog on box $box was started $n times in the last hour (more than $WD_ENSURE_LOOP_MAX). Last 5 lines of $WD_DIR/run.out: ${tail5:-<empty>}"
  fi
  return 0
}

# Alive but no tick for WD_ENSURE_HUNG s (last.tick is written at every tick
# start; run.pid at the loop's start, before its first tick): a blocker and
# the owner DM.
spl_wd_ensure_hung() {
  local now="$1" t p age box wl
  t="$(cat "$WD_DIR/last.tick" 2>/dev/null || true)"
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  p="$(stat -c %Y "$WD_DIR/run.pid" 2>/dev/null || echo 0)"
  (( p > t )) && t="$p"
  (( t > 0 )) || return 0
  age=$(( now - t ))
  (( age > WD_ENSURE_HUNG )) || return 0
  box="$(spl_wd_ensure_box)"
  wl="$(stat -c %Y "$LEASE_DIR/wd.log" 2>/dev/null || echo "$now")"
  do_log "WARN the watchdog on $box is alive but has not ticked for ${age}s"
  spl_wd_ensure_alert hung "$now" owner \
    "WATCHDOG KEEPER (093 6.4): HUNG - the watchdog on box $box (pid $(cat "$WD_DIR/run.pid" 2>/dev/null || echo unknown)) is alive but has not ticked for ${age}s (limit ${WD_ENSURE_HUNG}s); wd.log last written $(( now - wl ))s ago. Last 5 lines of $WD_DIR/run.out: $(tail -n 5 "$WD_DIR/run.out" 2>/dev/null | cut -c1-200 | tr '\n' ';')"
  return 0
}

# spl_wd_ensure_alert COND NOW [owner] TEXT: one blocker to the orchestrator
# (and, with "owner", one owner DM) per COND per WD_ENSURE_DEBOUNCE s. The
# flag <WD_DIR>/ensure.alert.<cond> holds the epoch it was sent at.
spl_wd_ensure_alert() {
  local cond="$1" now="$2" owner="$3" text="$4" f t rc=0
  f="$WD_DIR/ensure.alert.$cond"
  t="$(cat "$f" 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < WD_ENSURE_DEBOUNCE )); then
    do_log "INFO $cond alert already sent $(( now - t ))s ago: not again before ${WD_ENSURE_DEBOUNCE}s"
    return 0
  fi
  echo "$now" > "$f"
  bash "${WD_ENSURE_SEND:-$SPL_WD_ENSURE_DIR/../features/spawn-agents/scripts/spool-send.sh}" \
    --from "${LEASE_ORCH:-c-001}" --to orchestrator --kind blocker --task "wd-keeper-$(spl_wd_ensure_box)" \
    --body "$text" 7>&- 8>&- || rc=$?
  # spool-send.sh 1-9: delivered, only the poke did not ring
  if (( rc >= 10 || rc == 2 )); then do_log "WARN $cond blocker NOT delivered (spool-send.sh exit $rc)"
  else do_log "INFO $cond blocker sent to the orchestrator"; fi
  [[ "$owner" == owner ]] && spl_wd_ensure_owner "$text"
  return 0
}

# The owner DM, the path the orch take-over uses (spl_fleet_owner_dm):
# do_spl_desk_reply from this box's desk to ASKS_OWNER, in the background.
spl_wd_ensure_owner() {
  local text="$1" owner
  if [[ -n "${WD_ENSURE_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $WD_ENSURE_OWNER_CMD <<<"$text" >/dev/null 2>&1 || do_log "WARN owner DM failed (WD_ENSURE_OWNER_CMD)"
    return 0
  fi
  owner="$(sed -n 's/^ASKS_OWNER=\(HUM-[0-9][0-9]*\)$/\1/p' "$LEASE_CONF" 2>/dev/null | sed -n 1p)"
  [[ "$owner" =~ ^HUM-[0-9]+$ && -n "${LEASE_ENV:-}" && -n "${LEASE_TENANT:-}" ]] ||
    { do_log "WARN no owner DM: $LEASE_CONF names no ASKS_OWNER, LEASE_ENV or LEASE_TENANT"; return 0; }
  ( ENV="$LEASE_ENV" TENANT_ID="$LEASE_TENANT" DESK_BOX="${LEASE_DESK_BOX:-$(spl_desk_box_default)}" \
      DESK_AGENT="${LEASE_ORCH:-c-001}" DESK_TO="$owner" DESK_TASK="$(cat /proc/sys/kernel/random/uuid)" \
      DESK_KIND=note DESK_BODY="$text" DRY_RUN=0 \
      timeout 120 "${PROJ_PATH:-}/run" -a do_spl_desk_reply \
      >> "$WD_DIR/owner-dm.out" 2>&1 < /dev/null 7>&- 8>&- & ) 2>/dev/null
  do_log "INFO owner DM to $owner started (log $WD_DIR/owner-dm.out)"
  return 0
}

# ---- retention -------------------------------------------------------------------------

# Rotate run.out and this keeper's own ensure.out (wd.log is the loop's own).
spl_wd_ensure_logs() {
  local now="$1" out="${WD_ENSURE_OUT:-}" app
  spl_wd_log_rotate "$WD_DIR/run.out" "$now"
  if [[ -z "$out" ]]; then
    app="$(basename "${PROJ_PATH:-csi-spl-orc}")"; app="${app%-orc}"
    out="${WD_CRON_LOG_DIR:-/var/${app%%-*}/$app/wd}/ensure.out"
  fi
  spl_wd_log_rotate "$out" "$now"
  return 0
}

# spl_wd_log_rotate FILE NOW: once FILE's generation is WD_LOG_KEEP s old
# (default a day) or FILE is past WD_LOG_MAX_BYTES (64 MiB), it is copied to
# FILE.1 and emptied in place (the loop keeps it open for append), so a log
# always holds one to two days. FILE.since holds the generation's start.
spl_wd_log_rotate() {
  local f="$1" now="$2" s="$1.since" t sz
  [[ -f "$f" ]] || return 0
  t="$(cat "$s" 2>/dev/null || true)"
  if [[ ! "$t" =~ ^[0-9]+$ ]]; then echo "$now" > "$s" 2>/dev/null; return 0; fi
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  (( now - t >= ${WD_LOG_KEEP:-86400} || sz > ${WD_LOG_MAX_BYTES:-67108864} )) || return 0
  cp -f "$f" "$f.1" && : > "$f" && echo "$now" > "$s"
  return 0
}
