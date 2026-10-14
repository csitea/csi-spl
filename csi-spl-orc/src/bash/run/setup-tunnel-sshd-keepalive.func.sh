#!/bin/bash
#------------------------------------------------------------------------------
# @description On the box that RECEIVES a reverse tunnel of
# @description do_setup_reverse_tunnel (SPL-1802): make its sshd drop a dead
# @description tunnel session by itself, for the tunnel login only. One drop-in
# @description <SSHD_CONF_D>/65-spl-reverse-tunnel.conf:
# @description   Match User <TUNNEL_LOGIN_USER>
# @description     ClientAliveInterval <interval>
# @description     ClientAliveCountMax <count>
# @description   Match all
# @description (`Match all` ends the block, so nothing the main sshd_config
# @description says after its Include falls into it). Checked with sshd -t
# @description before the reload (a bad file is removed again, sshd keeps its
# @description old config), then proved with sshd -T for that user. The client
# @description side is the tunnel's own ssh (ServerAliveInterval). Idempotent:
# @description the same file again = unchanged, no reload. Dry run unless DRY_RUN=0.
# @param TUNNEL_LOGIN_USER (required) - the user the tunnel logs in as on this box
# @param TUNNEL_CLIENT_ALIVE_INTERVAL (optional) - seconds, default 15
# @param TUNNEL_CLIENT_ALIVE_COUNT (optional) - unanswered probes before the drop, default 4
# @param SSHD_CONF_D (optional) - default /etc/ssh/sshd_config.d
# @param SSHD_BIN (optional) - default sshd
# @param SSHD_RELOAD_CMD (optional) - default "systemctl reload ssh"
# @param RT_SUDO (optional) - the privilege prefix, default "sudo -n" ("" as root)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TUNNEL_LOGIN_USER=<tunnel login> ./run -a do_setup_tunnel_sshd_keepalive
# @example TUNNEL_LOGIN_USER=<tunnel login> DRY_RUN=0 ./run -a do_setup_tunnel_sshd_keepalive
#------------------------------------------------------------------------------
do_setup_tunnel_sshd_keepalive() {
  local user="${TUNNEL_LOGIN_USER:-}" iv="${TUNNEL_CLIENT_ALIVE_INTERVAL:-15}" cnt="${TUNNEL_CLIENT_ALIVE_COUNT:-4}"
  local d="${SSHD_CONF_D:-/etc/ssh/sshd_config.d}" sshd="${SSHD_BIN:-sshd}" reload="${SSHD_RELOAD_CMD:-systemctl reload ssh}"
  local dry=1 f new got
  local -a su=()
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL TUNNEL_LOGIN_USER must be a login name (the user the tunnel logs in as), got: '$user'"; return 1; }
  [[ "$iv" =~ ^[0-9]{1,3}$ && "$iv" -ge 5 ]] || { do_log "FATAL TUNNEL_CLIENT_ALIVE_INTERVAL must be 5..999 s, got: '$iv'"; return 1; }
  [[ "$cnt" =~ ^[0-9]{1,2}$ && "$cnt" -ge 1 ]] || { do_log "FATAL TUNNEL_CLIENT_ALIVE_COUNT must be 1..99, got: '$cnt'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if [[ -n "${RT_SUDO+x}" ]]; then read -ra su <<<"$RT_SUDO"; elif (( EUID != 0 )); then su=(sudo -n); fi
  f="$d/65-spl-reverse-tunnel.conf"
  new="$(printf '# written by do_setup_tunnel_sshd_keepalive (SPL-1802): a dead reverse tunnel\n# session is dropped after %s s of unanswered keep-alives; do not edit\nMatch User %s\n  ClientAliveInterval %s\n  ClientAliveCountMax %s\nMatch all\n' \
    "$((iv * cnt))" "$user" "$iv" "$cnt")"
  if [[ "$("${su[@]}" cat "$f" 2>/dev/null)" == "$new" ]]; then
    do_log "OK $f is already in place (user $user, ${iv}s x $cnt): unchanged"; return 0
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: write $f (Match User $user: ClientAliveInterval $iv, ClientAliveCountMax $cnt), check it with $sshd -t, then $reload"
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to install."
    return 0
  fi
  printf '%s\n' "$new" | "${su[@]}" tee "$f" >/dev/null || { do_log "FATAL cannot write $f"; return 1; }
  if ! "${su[@]}" "$sshd" -t 2>&1; then
    "${su[@]}" rm -f "$f"; do_log "FATAL $sshd -t refused the new $f: removed again, sshd keeps its old config"; return 1
  fi
  # shellcheck disable=SC2086 # the reload command is a command line
  "${su[@]}" $reload || { do_log "FATAL '$reload' failed: $f is written, sshd not reloaded"; return 1; }
  got="$("${su[@]}" "$sshd" -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null | sed -n 's/^clientaliveinterval //p')"
  [[ "$got" == "$iv" ]] || { do_log "FATAL sshd -T for $user says clientaliveinterval '$got', want $iv"; return 1; }
  do_log "OK $f installed and sshd reloaded: a dead $user session drops after $((iv * cnt)) s (new sessions)"
}
