#!/bin/bash
#------------------------------------------------------------------------------
# @description Watchdog peer supervision (spec 102 10.4.1, 10.4.2, 15.6; WD4).
# @description At the start of its tick each watchdog instance checks the
# @description other two: a peer whose run.<inst>.lock is free, or whose pid
# @description is gone, is DEAD and is started again at once; a peer that is
# @description alive but whose heartbeat.<inst>.json last_progress_ts has not
# @description moved for WD_HUNG = max(3 * WD_TICK, 180) s is HUNG: under
# @description run.<inst>.start.lock it gets TERM, ROTATE_TERM_WAIT s, then
# @description KILL (its whole process group: a child that inherited the
# @description instance lock would keep it held), then the one start command
# @description spl_wd_inst_start. A judge checks its peers only when it wrote
# @description its own heartbeat this tick (a full disk must not turn into
# @description mutual kills: it alerts instead) and its own previous tick is
# @description less than 3 * WD_TICK ago (a box back from suspend sees every
# @description heartbeat old). The same tick checks that the crontab starter
# @description lines are in the box user's crontab and puts them back with
# @description do_spl_wd_ensure_install_cron, and alerts when the starter has
# @description not run for WD_STARTER_STALE s (cron is dead; restarting cron
# @description needs root, so that is an alert, not a fix). Alerts are ONE
# @description blocker to the orchestrator per cause per WD_ALERT_DEBOUNCE s
# @description (the hub admin message of 11.2 is T026). Lock files are never
# @description removed. Every action is a line in <wd dir>/peers.log.
# @description The action prints each instance's state, read-only.
# @param WD_PEERS (optional) - 1 checks peers, 0 not; default 1, and 0 under SPOOL_TEST=1
# @param WD_STARTER_STALE (optional) - seconds without a starter run before the cron alert, default 300
# @param WD_ALERT_DEBOUNCE (optional) - seconds between two alerts of one cause, default 300
# @param WD_HB_SINK (optional) - write the heartbeat here instead (tests: /dev/full is a full disk)
# @example ./run -a do_spl_wd_peers
#------------------------------------------------------------------------------
declare -F spl_wd_inst_start >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-inst-start.func.sh"

SPL_WD_PEERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

do_spl_wd_peers() {
  local dir now i
  spl_rotate_conf || return 1
  dir="${WD_STATE_DIR:-$LEASE_DIR/wd}"
  now="$(spl_lease_now)"
  WD_DIR="$dir" WD_TICK="${WD_TICK:-30}"
  spl_wd_peers_conf || return 1
  for i in 1 2 3; do echo "instance $i: $(spl_wd_peer_state "$i" "$now")"; done
  echo "starter: $(spl_wd_starter_age "$now")"
  return 0
}

# WD_HUNG (the floor is not configurable), WD_PEERS, the debounces.
spl_wd_peers_conf() {
  local k
  WD_HUNG=$(( 3 * WD_TICK > 180 ? 3 * WD_TICK : 180 ))
  if [[ -z "${WD_PEERS:-}" ]]; then
    WD_PEERS=1
    [[ "${SPOOL_TEST:-}" == 1 ]] && WD_PEERS=0
  fi
  : "${WD_STARTER_STALE:=300}" "${WD_ALERT_DEBOUNCE:=300}"
  for k in WD_PEERS WD_STARTER_STALE WD_ALERT_DEBOUNCE; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  return 0
}

# spl_wd_peers NOW GAP: the peer part of one tick of instance WD_INST. GAP
# is the seconds since this instance's previous tick (0 on its first).
spl_wd_peers() {
  local now="$1" gap="$2" p
  [[ -n "${WD_INST:-}" && "$WD_PEERS" == 1 ]] || return 0
  if [[ "${WD_HB_OK:-1}" != 1 ]]; then
    spl_wd_peer_log "SKIP peers: instance $WD_INST could not write its own heartbeat (disk full?)"
    spl_wd_peer_alert disk "$now" \
      "WATCHDOG (102 10.4.2): instance $WD_INST on box $(spl_wd_peer_box) cannot write $WD_DIR/heartbeat.$WD_INST.json (disk full?). Peer checks are off until it can: no peer is killed."
    return 0
  fi
  if (( gap >= 3 * WD_TICK )); then
    spl_wd_peer_log "SKIP peers: instance $WD_INST ticked ${gap}s ago (suspend or freeze): no peer verdict this tick"
    return 0
  fi
  for p in 1 2 3; do
    [[ "$p" == "$WD_INST" ]] && continue
    spl_wd_peer_check "$p" "$now"
  done
  spl_wd_cron_heal "$now"
  spl_wd_starter_watch "$now"
  return 0
}

spl_wd_peer_box() { echo "${ROTATE_BOX:-${LEASE_MACHINE:-$(hostname -s)}}"; }

# One line to peers.log (and the tick's output).
spl_wd_peer_log() {
  local line
  line="$(date -u -d "@$(spl_lease_now)" +%FT%TZ) instance ${WD_INST:-0}: $*"
  echo "PEER $*"
  echo "$line" >> "$WD_DIR/peers.log" 2>/dev/null || true
}

spl_wd_held() { [[ -f "$1" ]] && ! flock -n "$1" true; }

# spl_wd_peer_state INST NOW: "ok <detail>", "dead <detail>",
# "dead-held <pid> <detail>" (the pid is gone but a child of it still holds
# the lock) or "hung <pid> <detail>".
spl_wd_peer_state() {
  local p="$1" now="$2" pid hb hpid prog start age
  pid="$(cat "$WD_DIR/run.$p.pid" 2>/dev/null || true)"
  if ! spl_wd_held "$WD_DIR/run.$p.lock"; then echo "dead run.$p.lock is free"; return 0; fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then echo "ok run.$p.lock held, no pid yet"; return 0; fi
  if ! kill -0 "$pid" 2>/dev/null; then echo "dead-held $pid pid $pid is gone, run.$p.lock still held"; return 0; fi
  hb="$WD_DIR/heartbeat.$p.json" prog=0
  read -r hpid prog < <(jq -r '"\(.pid // 0) \(.last_progress_ts // 0)"' "$hb" 2>/dev/null || echo "0 0")
  [[ "$hpid" == "$pid" && "$prog" =~ ^[0-9]+$ ]] || prog=0
  # no heartbeat of this pid yet: it counts from its start (run.<inst>.pid)
  start="$(stat -c %Y "$WD_DIR/run.$p.pid" 2>/dev/null || echo 0)"
  (( start > prog )) && prog="$start"
  age=$(( now - prog ))
  if (( age >= WD_HUNG )); then echo "hung $pid no progress for ${age}s (limit ${WD_HUNG}s)"
  else echo "ok pid $pid progress ${age}s ago"; fi
}

# spl_wd_peer_check P NOW: dead -> start; hung or dead-held -> stop, start.
# The verdict is taken again under run.<p>.start.lock: a second judge that
# comes after the first one's restart sees the new pid, and does nothing.
spl_wd_peer_check() {
  local p="$1" now="$2" st
  st="$(spl_wd_peer_state "$p" "$now")"
  [[ "$st" == ok* ]] && return 0
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_wd_peer_log "DRY_RUN would restart instance $p: $st"
    return 0
  fi
  (
    exec 8>>"$WD_DIR/run.$p.start.lock"
    flock -n 8 || { spl_wd_peer_log "instance $p: another starter holds run.$p.start.lock"; exit 0; }
    st="$(spl_wd_peer_state "$p" "$now")"
    [[ "$st" == ok* ]] && exit 0
    local verdict="${st%% *}" pid
    if [[ "$verdict" == hung || "$verdict" == dead-held ]]; then
      pid="$(cut -d' ' -f2 <<<"$st")"
      spl_wd_peer_stop "$p" "$pid"
    fi
    spl_wd_peer_log "RESTART instance $p ($verdict): ${st#* }"
    spl_wd_inst_start_locked "$p" "$WD_DIR" >/dev/null 2>&1 ||
      spl_wd_peer_log "FAILED to start instance $p (see $WD_DIR/run.$p.out)"
  ) || true
  return 0
}

# spl_wd_peer_stop P PID: TERM, ROTATE_TERM_WAIT s, KILL. The process group
# when PID leads one (an instance is setsid: its sleep and its situation
# scripts are in it and inherit the instance lock), else PID alone. CONT
# after TERM: a stopped process acts on nothing else.
spl_wd_peer_stop() {
  local p="$1" pid="$2" tgt="$2" pg i
  pg="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ "$pg" == "$pid" ]] && tgt="-$pid"
  spl_wd_peer_log "TERM instance $p (pid $pid${pg:+, group $pg})"
  kill -TERM -- "$tgt" 2>/dev/null || true
  kill -CONT -- "$tgt" 2>/dev/null || true
  for (( i = 0; i < ${ROTATE_TERM_WAIT:-30} * 10; i++ )); do
    spl_wd_held "$WD_DIR/run.$p.lock" || return 0
    sleep 0.1
  done
  spl_wd_peer_log "KILL instance $p (pid $pid): still holds run.$p.lock after ${ROTATE_TERM_WAIT:-30}s"
  kill -KILL -- "$tgt" 2>/dev/null || true
  for (( i = 0; i < 50; i++ )); do
    spl_wd_held "$WD_DIR/run.$p.lock" || return 0
    sleep 0.1
  done
  return 0
}

# spl_wd_peer_alert CAUSE NOW TEXT: ONE blocker to the orchestrator per
# CAUSE per WD_ALERT_DEBOUNCE s, across the instances (alert.<cause>, under
# alert.<cause>.lock); this process also remembers its own last send, for a
# disk too full to write the file.
spl_wd_peer_alert() {
  local cause="$1" now="$2" text="$3" f="$WD_DIR/alert.$1" last var="WD_ALERT_LAST_$1"
  last="${!var:-0}"
  (( now - last < WD_ALERT_DEBOUNCE )) && return 0
  (
    # no lock file (a full disk): send unlocked; held: a peer is alerting
    if exec 8>>"$f.lock"; then flock -n 8 || exit 3; fi 2>/dev/null
    last="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last < WD_ALERT_DEBOUNCE )) && exit 3
    echo "$now" > "$f" 2>/dev/null || true
    if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_wd_peer_log "DRY_RUN would alert ($cause): $text"; exit 0; fi
    spl_wd_peer_log "ALERT ($cause): $text"
    bash "$WD_SEND" --from "$WD_FROM" --to orchestrator --kind blocker --task "wd-box-$(spl_wd_peer_box)" \
      --body "$text" >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- || true
  ) || true
  # 3 = another instance alerted within the debounce: remember that too
  printf -v "$var" '%s' "$now"
  return 0
}

# ---- the crontab starter -----------------------------------------------------

# The starter's tags: <org>-<app>:wd-start and :wd-start-boot.
spl_wd_start_tags() {
  local app="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}"
  app="${app%-orc}"
  echo "$app:wd-start $app:wd-start-boot"
}

# spl_wd_cron_heal NOW: both starter lines in the crontab, else
# do_spl_wd_ensure_install_cron puts them back (from the checkout the
# starter last ran from, starter.src). One instance at a time (cron.lock).
spl_wd_cron_heal() {
  local now="$1" t missing="" cur src
  command -v crontab >/dev/null 2>&1 || return 0
  (
    exec 8>>"$WD_DIR/cron.lock" && flock -n 8 || exit 0
    cur="$(crontab -l 2>/dev/null || true)"
    for t in $(spl_wd_start_tags); do
      grep -qE " # ${t}\$" <<<"$cur" || missing+="$t "
    done
    [[ -z "$missing" ]] && exit 0
    if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_wd_peer_log "DRY_RUN would restore the crontab starter (missing: ${missing% })"; exit 0; fi
    declare -F do_spl_wd_ensure_install_cron >/dev/null ||
      source "$SPL_WD_PEERS_DIR/spl-wd-ensure-install-cron.func.sh"
    src="${DESK_CRON_SRC:-$(cat "$WD_DIR/starter.src" 2>/dev/null || true)}"
    local out rc=0
    out="$(DRY_RUN=0 WD_CRON_ACTION=install WD_CRON_KIND=start CRON_REMOVE=0 DESK_CRON_SRC="$src" \
      do_spl_wd_ensure_install_cron 2>&1)" || rc=$?
    if (( rc == 0 )); then
      echo "$now" > "$WD_DIR/cron.restored" 2>/dev/null || true
      spl_wd_peer_log "CRON restored the crontab starter (missing: ${missing% })"
    else
      spl_wd_peer_log "CRON could not restore the crontab starter (rc $rc): $(tail -n 3 <<<"$out" | tr '\n' ';')"
      spl_wd_peer_alert cronline "$now" \
        "WATCHDOG (102 15.6): the crontab starter line is missing on box $(spl_wd_peer_box) (${missing% }) and do_spl_wd_ensure_install_cron failed (rc $rc): $(tail -n 3 <<<"$out" | tr '\n' ';')"
    fi
  ) || true
  return 0
}

# "<age>s" since the starter last ran, or "never".
spl_wd_starter_age() {
  local t
  t="$(cat "$WD_DIR/starter.last" 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]]; then echo "$(( $1 - t ))s ago"; else echo never; fi
}

# spl_wd_starter_watch NOW: the starter has not run for WD_STARTER_STALE s
# while this watchdog runs: cron is dead (or the line points nowhere). Never
# run counts from the later of this instance's start and the last restore
# of the line, so a fresh box is not alerted.
spl_wd_starter_watch() {
  local now="$1" t base
  t="$(cat "$WD_DIR/starter.last" 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    base="$t"
  else
    base="$(stat -c %Y "$WD_DIR/run.$WD_INST.pid" 2>/dev/null || echo "$now")"
  fi
  t="$(cat "$WD_DIR/cron.restored" 2>/dev/null || true)"
  [[ "$t" =~ ^[0-9]+$ ]] && (( t > base )) && base="$t"
  (( now - base > WD_STARTER_STALE )) || return 0
  spl_wd_peer_alert cron "$now" \
    "WATCHDOG (102 10.4.1): the crontab starter has not run on box $(spl_wd_peer_box) for $(( now - base ))s (limit ${WD_STARTER_STALE}s; $WD_DIR/starter.last) while the watchdogs run: is cron dead? Restarting cron needs root (e.g. sudo systemctl restart cron)."
}
