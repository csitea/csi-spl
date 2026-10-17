#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 05 (rel-05, SPL-2369, Refs: SPL-2364):
# @description the liveness of the box's tmux server. Every agent session runs
# @description on one tmux server; when it freezes, the whole fleet stops
# @description silently. This guard probes its socket and alerts.
# @description
# @description The probe runs AS THE SOCKET OWNER (the socket dir is mode 700):
# @description   timeout -k 1 <TMUX_HEALTH_TIMEOUT> tmux -S <socket> list-sessions
# @description and prints one line:
# @description   tmux-health <OK|HUNG|DOWN|ERROR> socket=<path> sessions=<n> ms=<n>
# @description   OK    the server answered (exit 0)
# @description   HUNG  no answer within the timeout: the server is frozen
# @description   DOWN  no socket, or no server behind it
# @description   ERROR any other failure of the probe (its message is shown)
# @description The probe's output goes to a temp file, never a pipe: the tmux
# @description client passes its stdout to the server, so a frozen server would
# @description hold a pipe open and hang the guard past its timeout.
# @description A socket owned by another user, or hidden in a socket dir this
# @description user cannot enter, is not probed: the guard prints NOT_OWNER
# @description with the command to run instead and exits 2 (never DOWN).
# @description
# @description ALERT OR REPORT ONLY: it never kills, restarts or signals the
# @description server. A HUNG / DOWN / ERROR state sends ONE spool note to the
# @description orchestrator, only with DRY_RUN=0 (default 1 prints the plan),
# @description throttled by a state stamp: again when the state changes or
# @description after TMUX_HEALTH_THROTTLE_S. OK clears the stamp. The note is
# @description sent with --no-poke and under a timeout, as a frozen server
# @description would hang a pane poke. Every alert goes through
# @description TMUX_HEALTH_SEND_CMD when set (tests stub it); only the real run
# @description resolves spool-send.sh, relative to the repo.
# @description Exit 0 OK, 1 HUNG / DOWN / ERROR, 2 NOT_OWNER or a usage error.
# @param TMUX_HEALTH_SOCKET (optional) - default the fleet socket SPOOL_TMUX_SOCKET,
# @param   else ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default
# @param TMUX_HEALTH_TIMEOUT (optional) - probe seconds 1..4, default 3; with the
# @param   1 s kill grace a frozen server is flagged in at most 5 s
# @param TMUX_HEALTH_TMUX_BIN (optional) - default tmux
# @param TMUX_HEALTH_STATE_DIR (optional) - default <SPL_STATE_DIR or
# @param   $HOME/.local/state/csi-spl>/tmux-health
# @param TMUX_HEALTH_THROTTLE_S (optional) - default 1800
# @param TMUX_HEALTH_SEND_CMD (optional) - the sender, called with
# @param   --from <id> --to <id> --kind note --task <task> --no-poke --body <text>;
# @param   default bash <repo>/csi-spl-orc/.../spawn-agents/scripts/spool-send.sh
# @param TMUX_HEALTH_SEND_TIMEOUT (optional) - seconds for the sender, default 20
# @param TMUX_HEALTH_ALERT_TO / _FROM / _TASK (optional) - default orchestrator /
# @param   $SPOOL_AGENT_ID or tmux-health-guard@<box> / tmux-health
# @param DRY_RUN (optional) - 1 (default) plans the alert; 0 sends it
# @example ./run -a do_fleet_tmux_health_guard
# @example TMUX_HEALTH_SOCKET=/tmp/tmux-1000/default DRY_RUN=0 ./run -a do_fleet_tmux_health_guard
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_fleet_tmux_health_guard() {
  local uid sock tmo="${TMUX_HEALTH_TIMEOUT:-3}" dry="${DRY_RUN:-1}"
  local tmux_bin="${TMUX_HEALTH_TMUX_BIN:-tmux}" owner="" state out outf rc t0 ms n=0 detail=""
  local -a lines=()
  uid="$(id -u)"
  sock="${TMUX_HEALTH_SOCKET:-${SPOOL_TMUX_SOCKET:-${TMUX_TMPDIR:-/tmp}/tmux-$uid/default}}"
  [[ "$tmo" =~ ^[1-4]$ ]] || { do_log "FATAL TMUX_HEALTH_TIMEOUT must be 1..4 seconds (flag a freeze in <= 5 s), got: '$tmo'"; return 2; }
  command -v timeout >/dev/null 2>&1 || { do_log "FATAL timeout (coreutils) is not on PATH"; return 2; }
  command -v "$tmux_bin" >/dev/null 2>&1 || { do_log "FATAL $tmux_bin is not on PATH"; return 2; }

  # The socket dir is mode 700: to anyone but its owner the socket looks
  # absent, which must read NOT_OWNER, never DOWN.
  if [[ ! -e "$sock" && -d "${sock%/*}" && ! -x "${sock%/*}" ]]; then
    owner="$(stat -c %u "${sock%/*}" 2>/dev/null)"
  elif [[ -S "$sock" ]]; then
    owner="$(stat -c %u "$sock" 2>/dev/null)"
  fi
  if [[ -n "$owner" && "$owner" != "$uid" ]]; then
    do_log "WARN tmux-health NOT_OWNER socket=$sock owner_uid=$owner my_uid=$uid: run it as the socket owner, sudo -u '#$owner' ./run -a do_fleet_tmux_health_guard"
    return 2
  fi

  t0="$(tmux_health_ms)"
  if [[ ! -S "$sock" ]]; then
    state=DOWN detail="no socket at $sock"
  else
    # Into a file, never a pipe: the tmux client hands its stdin/stdout to the
    # server over the socket, so a frozen server keeps a $(...) pipe open and
    # the caller blocks long after timeout killed the client.
    outf="$(mktemp "${TMPDIR:-/tmp}/tmux-health.XXXXXX")" || { do_log "FATAL mktemp failed"; return 2; }
    timeout -k 1 "$tmo" "$tmux_bin" -S "$sock" list-sessions </dev/null >"$outf" 2>&1
    rc=$?
    out="$(<"$outf")"
    rm -f "$outf"
    if ((rc == 0)); then
      state=OK
      [[ -n "$out" ]] && mapfile -t lines <<<"$out"
      n=${#lines[@]}
    elif ((rc == 124 || rc == 137)); then
      state=HUNG detail="list-sessions gave no answer in ${tmo}s"
    elif [[ "$out" == *"no server running"* || "$out" == *"error connecting"* || "$out" == *"Connection refused"* ]]; then
      state=DOWN detail="${out//$'\n'/ }"
    else
      state=ERROR detail="exit $rc: ${out//$'\n'/ }"
    fi
  fi
  ms=$(($(tmux_health_ms) - t0))

  do_log "INFO tmux-health $state socket=$sock sessions=$n ms=$ms${detail:+ ($detail)}"
  if [[ "$state" == OK ]]; then
    tmux_health_clear "$sock" "$dry"
    return 0
  fi
  tmux_health_alert "$sock" "$state" "$detail" "$dry"
  return 1
}

# do_tmux_health_guard - the filename's own action name (same guard)
do_tmux_health_guard() { do_fleet_tmux_health_guard "$@"; }

# tmux_health_stamp <socket> - the throttle stamp path of a socket
tmux_health_stamp() {
  local key="${1//\//_}"
  echo "${TMUX_HEALTH_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/tmux-health}/${key#_}.stamp"
}

# tmux_health_clear <socket> <dry> - an OK server forgets its last alert (real run only)
tmux_health_clear() {
  local stamp; stamp="$(tmux_health_stamp "$1")"
  [[ "$2" == 0 && -f "$stamp" ]] && rm -f "$stamp"
  return 0
}

# tmux_health_alert <socket> <state> <detail> <dry> - one throttled note
tmux_health_alert() {
  local sock="$1" state="$2" detail="$3" dry="$4" stamp prev="" at=0 now box body from
  local to="${TMUX_HEALTH_ALERT_TO:-orchestrator}" task="${TMUX_HEALTH_ALERT_TASK:-tmux-health}"
  local throttle="${TMUX_HEALTH_THROTTLE_S:-1800}" send_tmo="${TMUX_HEALTH_SEND_TIMEOUT:-20}"
  local -a send
  box="$(hostname -s 2>/dev/null)"
  from="${TMUX_HEALTH_ALERT_FROM:-${SPOOL_AGENT_ID:-tmux-health-guard@$box}}"
  stamp="$(tmux_health_stamp "$sock")"
  now="${EPOCHSECONDS:-$(date +%s)}"
  [[ -f "$stamp" ]] && read -r prev at <"$stamp"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  if [[ "$prev" == "$state" ]] && ((now - at < throttle)); then
    do_log "INFO tmux-health $state alert throttled by $stamp"
    return 0
  fi
  body="tmux-health $state on $box: the tmux server at $sock ($detail). Every agent pane of this box runs on it. Nothing was restarted: check the server by hand (as its owner: tmux -S $sock list-sessions)."
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  read -ra send <<<"${TMUX_HEALTH_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: alert not sent"; return 0; }
  fi
  if timeout -k 2 "$send_tmo" "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$state $now" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run alerts again"
    do_log "INFO tmux-health $state note sent to $to"
  else
    do_log "WARN tmux-health: the note to $to failed"
  fi
  return 0
}

# tmux_health_ms - a millisecond wall clock (no fork)
tmux_health_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

# The file name gives do_tmux_health_guard; the plan's action name is
# do_fleet_tmux_health_guard, registered here when run.sh sources the file.
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_fleet_tmux_health_guard"]="${BASH_SOURCE[0]}"
fi
