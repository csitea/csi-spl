#!/bin/bash
#------------------------------------------------------------------------------
# @description Keep a reverse ssh tunnel from THIS box to another box of the
# @description fleet (SPL-1766, owner t1 0bb05176 pick B): this box runs
# @description `ssh -N -R 127.0.0.1:<port>:127.0.0.1:22 <dest>`, so the other
# @description box reaches this box's sshd at ITS OWN 127.0.0.1:<port>, when it
# @description has no route here (the satellite has none to the main box). What it may run once
# @description in is set by do_box_peer_ssh_grant (a forced command).
# @description   start     - record the tunnel (<state>/<box>.conf), then
# @description               reconcile it
# @description   reconcile - every recorded tunnel: up (its pid alive and its
# @description               cmdline holds the -R spec) = kept; else started,
# @description               detached (setsid, fds closed), and given
# @description               REVERSE_TUNNEL_START_WAIT s to stay up. The cron
# @description               row reverse-tunnel runs it every minute; no
# @description               recorded tunnel = nothing to do
# @description   stop      - stop the tunnel and drop its record
# @description   status    - one line per recorded tunnel: up | stuck | down
# @description A forward the other box refuses ("remote port forwarding
# @description failed": a stale listener holds its port) is STUCK: recorded in
# @description <state>/<box>.stuck and reported as one WARN line at most every
# @description REVERSE_TUNNEL_STUCK_EVERY minutes (SPL-1802); the other box frees
# @description the port with do_clear_reverse_tunnel_listener.
# @description start/reconcile/stop are a dry run unless DRY_RUN=0.
# @param REVERSE_TUNNEL_CMD (optional) - start (default) | reconcile | stop | status
# @param TO_BOX (optional) - the box that gets the tunnel (its BOX_TAG), default sat
# @param BOX_SSH_<BOX> (optional) - its ssh destination (<BOX>: upper case, - as _), default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite (do_satellite_ssh_config)
# @param REVERSE_TUNNEL_PORT (optional) - the port on the other box's 127.0.0.1, default 2222
# @param REVERSE_TUNNEL_STATE_DIR (optional) - default /var/csi/csi-spl/reverse-tunnel
# @param REVERSE_TUNNEL_START_WAIT (optional) - seconds a new tunnel must stay up, default 5
# @param REVERSE_TUNNEL_STUCK_EVERY (optional) - minutes between two reports of a stuck tunnel, default 15
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_reverse_tunnel
# @example DRY_RUN=0 ./run -a do_setup_reverse_tunnel
# @example REVERSE_TUNNEL_CMD=status ./run -a do_setup_reverse_tunnel
#------------------------------------------------------------------------------
do_setup_reverse_tunnel() {
  local cmd="${REVERSE_TUNNEL_CMD:-start}" box="${TO_BOX:-sat}" port="${REVERSE_TUNNEL_PORT:-2222}"
  local dir="${REVERSE_TUNNEL_STATE_DIR:-/var/csi/csi-spl/reverse-tunnel}" dry=1 k s dest
  case "$cmd" in start|reconcile|stop|status) ;; *) do_log "FATAL REVERSE_TUNNEL_CMD must be start, reconcile, stop or status, got: '$cmd'"; return 1 ;; esac
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TO_BOX must be a box id (e.g. sat), got: '$box'"; return 1; }
  if ! [[ "$port" =~ ^[0-9]{4,5}$ ]] || (( port < 1024 || port > 65535 )); then
    do_log "FATAL REVERSE_TUNNEL_PORT must be 1024..65535, got: '$port'"; return 1
  fi
  if [[ "$cmd" != status ]]; then
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  fi
  k="$(tr 'a-z-' 'A-Z_' <<<"$box")"; s="BOX_SSH_$k"
  dest="${!s:-${SATELLITE_ALIAS:-satellite}}"
  [[ "$dest" =~ ^[A-Za-z0-9_.@-]+$ ]] || { do_log "FATAL the ssh destination must be an ssh alias or user@host, got: '$dest'"; return 1; }

  case "$cmd" in
    start)
      if (( dry )); then
        do_log "INFO DRY_RUN would: record $box -> ssh $dest -R 127.0.0.1:$port:127.0.0.1:22 in $dir, start it, and keep it up from the cron row reverse-tunnel"
        do_log "OK DRY_RUN nothing was started. Re-run with DRY_RUN=0 to start."
        return 0
      fi
      mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
      printf 'dest=%s\nport=%s\n' "$dest" "$port" >"$dir/$box.conf"
      spl_rt_reconcile_one "$dir" "$box" 0 ;;
    reconcile)
      local f rc=0
      for f in "$dir"/*.conf; do
        [[ -f "$f" ]] || continue
        # 3 = stuck: recorded and reported by spl_rt_stuck, not a failure of
        # this run (a per-minute FATAL would bury the one line that says why)
        spl_rt_reconcile_one "$dir" "$(basename "$f" .conf)" "$dry" || { [[ $? -eq 3 ]] || rc=1; }
      done
      return "$rc" ;;
    stop)
      local pid
      pid="$(spl_rt_pid "$dir" "$box")"
      if (( dry )); then
        do_log "INFO DRY_RUN would: stop the tunnel to $box${pid:+ (pid $pid)} and drop $dir/$box.conf"
        return 0
      fi
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
      rm -f "$dir/$box.conf" "$dir/$box.pid" "$dir/$box.stuck"
      do_log "OK tunnel to $box stopped and its record dropped" ;;
    status)
      local f b
      for f in "$dir"/*.conf; do
        [[ -f "$f" ]] || { echo "reverse-tunnel: none recorded in $dir"; return 0; }
        b="$(basename "$f" .conf)"
        if [[ -n "$(spl_rt_pid "$dir" "$b")" ]]; then echo "reverse-tunnel: $b up ($(spl_rt_spec "$f"))"
        elif [[ -f "$dir/$b.stuck" ]]; then
          echo "reverse-tunnel: $b stuck since $(sed -n 's/^since=//p' "$dir/$b.stuck") ($(sed -n 's/^count=//p' "$dir/$b.stuck") tries; $(spl_rt_spec "$f"))"
        else echo "reverse-tunnel: $b down ($(spl_rt_spec "$f"))"; fi
      done ;;
  esac
}

# spl_rt_spec <conf> -> "<dest> -R 127.0.0.1:<port>:127.0.0.1:22"
spl_rt_spec() {
  local d p
  d="$(sed -n 's/^dest=//p' "$1")"; p="$(sed -n 's/^port=//p' "$1")"
  printf '%s -R 127.0.0.1:%s:127.0.0.1:22' "$d" "$p"
}

# spl_rt_pid <dir> <box> -> the pid of the live tunnel, or nothing: the pid file
# alone is no proof (a reused pid), its cmdline must hold the -R spec
spl_rt_pid() {
  local pf="$1/$2.pid" conf="$1/$2.conf" pid port
  [[ -f "$pf" && -f "$conf" ]] || return 0
  pid="$(<"$pf")"; port="$(sed -n 's/^port=//p' "$conf")"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 0
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -F -- "-R 127.0.0.1:$port:127.0.0.1:22" >/dev/null && echo "$pid"
  return 0
}

# spl_rt_reconcile_one <dir> <box> <dry> - start the recorded tunnel unless up
spl_rt_reconcile_one() {
  local dir="$1" box="$2" dry="$3" conf="$1/$2.conf" dest port pid w
  dest="$(sed -n 's/^dest=//p' "$conf")"; port="$(sed -n 's/^port=//p' "$conf")"
  [[ "$dest" =~ ^[A-Za-z0-9_.@-]+$ && "$port" =~ ^[0-9]+$ ]] || { do_log "FATAL $conf is malformed"; return 1; }
  pid="$(spl_rt_pid "$dir" "$box")"
  [[ -n "$pid" ]] && { rm -f "$dir/$box.stuck"; do_log "OK tunnel to $box is up (pid $pid)"; return 0; }
  (( dry )) && { do_log "INFO DRY_RUN would: start ssh $dest -R 127.0.0.1:$port:127.0.0.1:22"; return 0; }
  # setsid + every fd above 2 closed: the ssh outlives this action and must
  # not hold ./run's tee pipes open (a ./run that never returns). Its own
  # connection: through a ControlMaster the -R goes to the shared master and
  # the client exits at once (measured on the first start, 2026-10-14)
  (
    for fdp in /proc/self/fd/*; do
      fd="${fdp##*/}"
      (( fd > 2 )) && eval "exec $fd>&-" 2>/dev/null
    done
    exec setsid "${SSH_BIN:-ssh}" -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
      -o ControlMaster=no -o ControlPath=none \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -R "127.0.0.1:$port:127.0.0.1:22" "$dest" </dev/null >>"$dir/$box.log" 2>&1
  ) &
  echo "$!" >"$dir/$box.pid"
  for (( w = 0; w < ${REVERSE_TUNNEL_START_WAIT:-5}; w++ )); do
    sleep 1
    [[ -n "$(spl_rt_pid "$dir" "$box")" ]] || break
  done
  pid="$(spl_rt_pid "$dir" "$box")"
  if [[ -z "$pid" ]]; then
    local why; why="$(tail -n1 "$dir/$box.log" 2>/dev/null)"; rm -f "$dir/$box.pid"
    [[ "$why" == *"remote port forwarding failed"* ]] && { spl_rt_stuck "$dir" "$box" "$dest" "$port"; return 3; }
    do_log "FATAL tunnel to $box exited at once: $why"; return 1
  fi
  local was=""; [[ -f "$dir/$box.stuck" ]] && was=", recovered from stuck since $(sed -n 's/^since=//p' "$dir/$box.stuck")"
  rm -f "$dir/$box.stuck"
  do_log "OK tunnel to $box started (pid $pid)$was: its 127.0.0.1:$port reaches this box's sshd"
}

# spl_rt_stuck <dir> <box> <dest> <port> - the forward was refused: something
# already listens on the other box's 127.0.0.1:<port> (a dead session sshd
# never reaped, SPL-1802). Retrying alone never frees it, so it is recorded in
# <dir>/<box>.stuck (since, count, reported: the health check reads it) and
# reported as ONE WARN line at most every REVERSE_TUNNEL_STUCK_EVERY minutes
# (default 15); the minutes between stay quiet.
spl_rt_stuck() {
  local dir="$1" box="$2" dest="$3" port="$4" f="$1/$2.stuck" since count rep now every
  every="${REVERSE_TUNNEL_STUCK_EVERY:-15}"; [[ "$every" =~ ^[0-9]+$ ]] || every=15
  now="$(date -u +%s)"
  since="$(sed -n 's/^since=//p' "$f" 2>/dev/null)"; [[ -n "$since" ]] || since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  count="$(sed -n 's/^count=//p' "$f" 2>/dev/null)"; [[ "$count" =~ ^[0-9]+$ ]] || count=0
  rep="$(sed -n 's/^reported=//p' "$f" 2>/dev/null)"; [[ "$rep" =~ ^[0-9]+$ ]] || rep=0
  count=$((count + 1))
  if (( now - rep >= every * 60 )); then
    rep="$now"
    do_log "WARN STUCK tunnel to $box: $dest's 127.0.0.1:$port is held by another listener since $since ($count tries); on $box run REVERSE_TUNNEL_FROM_BOX=<this box> TUNNEL_LOGIN_USER=<tunnel login> DRY_RUN=0 ./run -a do_clear_reverse_tunnel_listener"
  else
    do_log "INFO tunnel to $box still stuck since $since ($count tries, reported at $(date -u -d "@$rep" +%H:%M:%SZ))"
  fi
  printf 'since=%s\ncount=%s\nreported=%s\ndest=%s\nport=%s\n' "$since" "$count" "$rep" "$dest" "$port" >"$f"
}
