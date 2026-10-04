#!/bin/bash
#------------------------------------------------------------------------------
# @description Keep the sidecar of EVERY other seated desk box on this machine
# @description up and on the current spool binary - box-rsp, box-ci and the
# @description like, the boxes that are not this machine's default desk box
# @description (DESK_BOX, which do_spl_desk_up_all and do_spl_desk_up_tenants
# @description reconcile). Their agents (RSP-01, OPS-01) have no tmux window,
# @description so the live-window reconcile never sees them: on prd
# @description 2026-10-02 all 6 box-rsp sidecars ran a DELETED spool binary
# @description from 2026-10-01 that predated the c-NNN ids, and every RSP-01
# @description relay to a c-NNN agent was moved to .hub/rejected until they
# @description were restarted by hand.
# @description A box is in the reconcile set when its dir under
# @description $SPL_STATE_DIR/desk/<tenant>/ holds a sidecar pid file (a
# @description sidecar was started and not stopped: do_spl_desk_down removes
# @description that file) and at least one agent dir. Left out: DESK_BOX,
# @description box-wui, and a box moved away by do_spl_desk_rebox (it holds
# @description rebox-seated.txt or rebox-retired/: the retired box-desk dirs).
# @description Per box: a live sidecar on the current binary is left alone; a
# @description live one on a rebuilt (deleted) binary, or a dead one, is
# @description restarted through do_spl_desk_up for its first agent, keeping
# @description that agent's hand mute (.no-poke) and the live sidecar's
# @description SPOOL_POKE / SPOOL_NOTIFY_CMD. Never seats a new agent.
# @description Prints one line per box. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param DESK_BOX (optional) - the default desk box, left out; default
# @param   spl_desk_box_default
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_desk_up_boxes
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_desk_up_boxes
#------------------------------------------------------------------------------
do_spl_desk_up_boxes() {
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local main="${DESK_BOX:-$(spl_desk_box_default)}" tdir bdir t b d rc=0 n=0 r=0 why agent
  for tdir in "$SPL_STATE_DIR"/desk/*/; do
    t="${tdir%/}"; t="${t##*/}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
    for bdir in "$tdir"*/; do
      d="${bdir%/}"; b="${d##*/}"
      [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$b" != box-wui && "$b" != "$main" ]] || continue
      [[ -e "$d/rebox-seated.txt" || -d "$d/rebox-retired" ]] && continue
      [[ -e "$d/spool/.hub/hub-run.pid" ]] || continue
      agent="$(spl_desk_box_agents "$d" | sed -n 1p)"
      [[ -n "$agent" ]] || continue
      n=$((n + 1))
      why="$(spl_desk_box_state "$d")"
      if [[ "$why" == up ]]; then
        do_log "INFO desk box $b of $t: in the reconcile set, sidecar up on the current binary"
        continue
      fi
      if (( dry )); then
        do_log "INFO DRY_RUN would: restart the sidecar of desk box $b of $t ($why) by seating $agent"
        continue
      fi
      if spl_desk_box_restart "$d" "$t" "$b" "$agent"; then
        r=$((r + 1)); do_log "INFO desk box $b of $t: restarted ($why) for $agent"
      else
        rc=1; do_log "FAIL desk box $b of $t: the restart ($why) for $agent failed: see $d/spool/.hub/hub-run.log"
      fi
    done
  done
  if (( dry )); then
    do_log "OK DRY_RUN $n desk box(es) other than $main in the reconcile set; nothing was touched"
  else
    do_log "OK reconciled $n desk box(es) other than $main, $r restarted"
  fi
  return "$rc"
}

# spl_desk_box_agents <desk dir>: the agent dirs under its spool root, sorted;
# what the box announces from (hubclient scanAgents).
spl_desk_box_agents() {
  local e a
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for e in "$1"/spool/*/; do
    a="${e%/}"; a="${a##*/}"
    [[ "$a" =~ ^${SPOOL_PARTICIPANT_RX}$ && "${a%%-*}" != BOX ]] && printf '%s\n' "$a"
  done | sort
}

# spl_desk_box_state <desk dir>: up | stale-binary | sidecar-dead.
spl_desk_box_state() {
  local pidf="$1/spool/.hub/hub-run.pid"
  spl_desk_alive "$pidf" || { echo sidecar-dead; return 0; }
  if spl_desk_sidecar_stale "$(cat "$pidf")"; then echo stale-binary; else echo up; fi
}

# spl_desk_box_restart <desk dir> <tenant> <box> <agent>: re-seat AGENT, which
# restarts a dead or stale sidecar (spl_desk_sidecar). Holds the desk's
# up-all.lock so it never races a hand-run do_spl_desk_up_all on that box.
spl_desk_box_restart() {
  local d="$1" t="$2" b="$3" a="$4" pid poke=1 boxpoke=1 notify="" v rc=0
  [[ -e "$d/spool/$a/.no-poke" ]] && poke=0
  pid="$(cat "$d/spool/.hub/hub-run.pid" 2>/dev/null)"
  if spl_desk_alive "$d/spool/.hub/hub-run.pid"; then
    v="$(spl_desk_sidecar_poke "$pid")"; [[ -n "$v" ]] && boxpoke="$v"
    [[ -r "/proc/$pid/environ" ]] &&
      notify="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SPOOL_NOTIFY_CMD=//p' | tail -n 1)"
  fi
  exec 7>"$d/up-all.lock" || { do_log "FATAL cannot open $d/up-all.lock"; return 1; }
  if ! flock -n 7; then
    do_log "OK another reconcile holds $d/up-all.lock: leaving desk box $b of $t to it"
    exec 7>&-; return 0
  fi
  if [[ -n "$notify" ]]; then
    TENANT_ID="$t" DESK_BOX="$b" DESK_AGENT="$a" DESK_POKE="$poke" DESK_BOX_POKE="$boxpoke" \
      DESK_NOTIFY_CMD="$notify" DESK_WAIT_SECS="${DESK_WAIT_SECS:-30}" DRY_RUN=0 do_spl_desk_up || rc=1
  else
    TENANT_ID="$t" DESK_BOX="$b" DESK_AGENT="$a" DESK_POKE="$poke" DESK_BOX_POKE="$boxpoke" \
      DESK_WAIT_SECS="${DESK_WAIT_SECS:-30}" DRY_RUN=0 do_spl_desk_up || rc=1
  fi
  flock -u 7; exec 7>&-
  return "$rc"
}
