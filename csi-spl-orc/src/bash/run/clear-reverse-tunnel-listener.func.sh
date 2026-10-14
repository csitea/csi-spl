#!/bin/bash
#------------------------------------------------------------------------------
# @description On the box that RECEIVES a reverse tunnel of
# @description do_setup_reverse_tunnel (SPL-1802): free its 127.0.0.1:<port>
# @description when a stale session holds it, so the tunnel box's cron can
# @description forward again (its log says "remote port forwarding failed" and
# @description its status says stuck). It frees the port ONLY when all hold:
# @description   1. one listener on 127.0.0.1:<port> (ss), its pid an
# @description      sshd-session running as TUNNEL_LOGIN_USER
# @description   2. the tunnel does not answer: `ssh <from box>-tunnel ping`
# @description      as TUNNEL_PING_AS fails REVERSE_TUNNEL_PING_TRIES times
# @description Then that ONE pid gets SIGTERM (never a pattern kill) and the
# @description port must be free within 5 s. Nothing listening, a listener of
# @description another process or user, or a tunnel that answers = nothing
# @description killed. Dry run unless DRY_RUN=0.
# @param REVERSE_TUNNEL_FROM_BOX (required) - the box the tunnel comes from (its BOX_TAG); the ping goes to Host <box>-tunnel
# @param TUNNEL_LOGIN_USER (required) - the user the tunnel logs in as on this box
# @param REVERSE_TUNNEL_PORT (optional) - default 2222
# @param TUNNEL_PING_AS (optional) - the user whose ~/.ssh/config has the Host block, default AGENT_USER of SATELLITE_ENV_FILE, else this user
# @param SATELLITE_ENV_FILE (optional) - default /etc/csi-spl-satellite.env
# @param REVERSE_TUNNEL_PING_TRIES (optional) - default 2
# @param SSH_BIN (optional) - default ssh
# @param RT_SUDO (optional) - the privilege prefix, default "sudo -n" ("" as root)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example REVERSE_TUNNEL_FROM_BOX=<box> TUNNEL_LOGIN_USER=<tunnel login> ./run -a do_clear_reverse_tunnel_listener
# @example REVERSE_TUNNEL_FROM_BOX=<box> TUNNEL_LOGIN_USER=<tunnel login> DRY_RUN=0 ./run -a do_clear_reverse_tunnel_listener
#------------------------------------------------------------------------------
do_clear_reverse_tunnel_listener() {
  local from="${REVERSE_TUNNEL_FROM_BOX:-}" user="${TUNNEL_LOGIN_USER:-}" port="${REVERSE_TUNNEL_PORT:-2222}"
  local tries="${REVERSE_TUNNEL_PING_TRIES:-2}" envf="${SATELLITE_ENV_FILE:-/etc/csi-spl-satellite.env}"
  local dry=1 me as pid owner comm i
  local -a su=()
  [[ "$from" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL REVERSE_TUNNEL_FROM_BOX must be the box id the tunnel comes from, got: '$from'"; return 1; }
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL TUNNEL_LOGIN_USER must be a login name (the user the tunnel logs in as), got: '$user'"; return 1; }
  if ! [[ "$port" =~ ^[0-9]{4,5}$ ]] || (( port < 1024 || port > 65535 )); then
    do_log "FATAL REVERSE_TUNNEL_PORT must be 1024..65535, got: '$port'"; return 1
  fi
  [[ "$tries" =~ ^[1-9]$ ]] || { do_log "FATAL REVERSE_TUNNEL_PING_TRIES must be 1..9, got: '$tries'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if [[ -n "${RT_SUDO+x}" ]]; then read -ra su <<<"$RT_SUDO"; elif (( EUID != 0 )); then su=(sudo -n); fi
  me="$(id -un)"
  as="${TUNNEL_PING_AS:-$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' "$envf" 2>/dev/null | tail -n1)}"
  as="${as:-$me}"
  [[ "$as" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL TUNNEL_PING_AS must be a login name, got: '$as'"; return 1; }

  pid="$(spl_rtl_holder "$port" "${su[@]}")"
  [[ -n "$pid" ]] || { do_log "OK nothing listens on 127.0.0.1:$port: nothing to clear"; return 0; }
  read -r owner comm < <(ps -o user=,comm= -p "$pid" 2>/dev/null)
  if [[ "$owner" != "$user" || ( "$comm" != sshd-session && "$comm" != sshd ) ]]; then
    do_log "FATAL 127.0.0.1:$port is held by pid $pid ($comm, user ${owner:-?}), not an sshd session of $user: not touched"; return 1
  fi
  for (( i = 1; i <= tries; i++ )); do
    if spl_rtl_ping "$from" "$as" "$me"; then
      do_log "OK the tunnel from $from answers (pid $pid, $user): nothing cleared"; return 0
    fi
    (( i < tries )) && sleep "${REVERSE_TUNNEL_PING_GAP:-5}"
  done
  if (( dry )); then
    do_log "INFO DRY_RUN would: kill -TERM $pid (sshd-session of $user holding 127.0.0.1:$port; ssh $from-tunnel ping failed $tries times)"
    do_log "OK DRY_RUN nothing was killed. Re-run with DRY_RUN=0 to clear."
    return 0
  fi
  "${su[@]}" kill -TERM "$pid" || { do_log "FATAL kill -TERM $pid failed"; return 1; }
  for (( i = 0; i < 10; i++ )); do
    [[ -z "$(spl_rtl_holder "$port" "${su[@]}")" ]] && {
      do_log "OK freed 127.0.0.1:$port (stale sshd-session $pid of $user): the tunnel box's cron forwards it again within a minute"; return 0; }
    sleep 0.5
  done
  do_log "FATAL 127.0.0.1:$port still held after kill -TERM $pid"; return 1
}

# spl_rtl_holder <port> [sudo...] -> the pid listening on 127.0.0.1:<port>, or nothing
spl_rtl_holder() {
  local port="$1"; shift
  "$@" ss -ltnpH "sport = :$port" 2>/dev/null |
    awk -v a="127.0.0.1:$port" '$4 == a && !p && match($0, /pid=[0-9]+/) { p = substr($0, RSTART + 4, RLENGTH - 4) } END { if (p) print p }'
}

# spl_rtl_ping <from box> <as user> <me> - the tunnel answers its gate's ping
spl_rtl_ping() {
  local -a cmd=("${SSH_BIN:-ssh}" -o BatchMode=yes -o ConnectTimeout=15 "$1-tunnel" ping)
  [[ "$2" == "$3" ]] || cmd=(sudo -n -u "$2" -H "${cmd[@]}")
  timeout 30 "${cmd[@]}" </dev/null 2>/dev/null | grep '^pong ' >/dev/null
}
