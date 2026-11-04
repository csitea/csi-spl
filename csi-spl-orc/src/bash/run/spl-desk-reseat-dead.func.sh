#!/bin/bash
#------------------------------------------------------------------------------
# @description Re-seat, while the desk reconcile is PAUSED
# @description (<spool root>/.desk-reconcile.<env>.pause, specs/058 6.5), every
# @description desk of this machine whose hub-run sidecar died with the box: its
# @description hub-run.pid was written before the current boot and names no
# @description live hub-run (SPL-4772). A pause holds moves and re-homing only:
# @description on sat 2026-11-01 the box rebooted at 02:39:12Z under a fresh
# @description desk-move pause, every tick logged "no seat step", 11 of 12 prd
# @description sidecars stayed dead ~5 min, the relay to the other box refused sends
# @description (rc 3) and every workspace seat was deaf until a hand re-seat.
# @description Per dead desk it restarts the sidecar through do_spl_desk_up for
# @description the desk's first agent, as the desk's CURRENT user (the owner of
# @description its dir under spl_desk_dir's roots, spec 069 8.3.1), only when
# @description that user is the caller and the desk is pinned there: no move,
# @description no rebox, no keygen, no pin. A live sidecar, a desk retired by
# @description do_spl_desk_rebox, a desk moved to another user, a desk that is
# @description not pinned and a sidecar that died AFTER the boot are left
# @description alone, one line each. A moved desk's dir belongs to its new user,
# @description so the owner check leaves it to that user (no spl_desk_moved_to
# @description call: on the caller's own pinned copy it never names a move).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param DESK_BOOT_TIME (optional) - the boot time, epoch seconds; default
# @param   btime of /proc/stat
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_desk_reseat_dead
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_desk_reseat_dead
#------------------------------------------------------------------------------
do_spl_desk_reseat_dead() {
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local e t b u d me agent boot rc=0 n=0 r=0
  me="$(id -un)"
  boot="$(spl_desk_boot_epoch)" || { do_log "FATAL no boot time (DESK_BOOT_TIME or btime of /proc/stat)"; return 1; }
  while IFS=$'\t' read -r e t b u d; do
    n=$((n + 1))
    if (( $(stat -c %Y "$d/spool/.hub/hub-run.pid" 2>/dev/null || echo "$boot") >= boot )); then
      do_log "INFO dead desk $b of $t ($e, $u): its sidecar died after the boot, left to the reconcile once the pause ends"; continue
    fi
    [[ "$u" == "$me" ]] || { do_log "INFO dead desk $b of $t ($e) belongs to $u: re-seated by $u's tick, not as $me"; continue; }
    [[ -s "$d/pinned" ]] || { do_log "WARN dead desk $b of $t ($e, $u) is not pinned: no re-seat while paused (no keygen, no pin)"; continue; }
    agent="$(spl_desk_box_agents "$d" | sed -n 1p)"
    [[ -n "$agent" ]] || { do_log "INFO dead desk $b of $t ($e, $u) has no agent dir: its sidecar would announce nobody"; continue; }
    if (( dry )); then
      do_log "INFO DRY_RUN would: re-seat dead desk $b of $t ($e) as $u by seating $agent (paused: no move, no keygen)"; continue
    fi
    if ROOT_KEY_JSON="" SPOOL_JOIN_TOKEN="" spl_desk_box_restart "$d" "$t" "$b" "$agent"; then
      r=$((r + 1)); do_log "INFO re-seated dead desk $b of $t ($e) as $u for $agent (paused: no move, no keygen)"
    else
      rc=1; do_log "FAIL dead desk $b of $t ($e, $u): the re-seat for $agent failed: see $d/spool/.hub/hub-run.log"
    fi
  done < <(spl_desk_dead_list "$ENV")
  do_log "OK $n dead desk(s) in $ENV, $r re-seated$( (( dry )) && echo ' (DRY_RUN: nothing was touched)')"
  return "$rc"
}

# spl_desk_boot_epoch: the boot time in epoch seconds (DESK_BOOT_TIME, else
# btime of /proc/stat).
spl_desk_boot_epoch() {
  local b="${DESK_BOOT_TIME:-$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)}"
  [[ "$b" =~ ^[0-9]+$ ]] && printf '%s' "$b"
}

# spl_desk_dead_list <env>: "<env>\t<tenant>\t<box>\t<user>\t<desk dir>" per
# desk of env, in the roots the caller can enter, whose sidecar should run (a
# hub-run.pid: do_spl_desk_down removes it) and is not live. Left out: box-wui
# and a desk retired by do_spl_desk_rebox. <user> owns the desk dir.
spl_desk_dead_list() {
  local e="$1" d t b
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    b="${d##*/}"; t="${d%/*}"; t="${t##*/}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$b" != box-wui ]] || continue
    [[ -e "$d/rebox-seated.txt" || -d "$d/rebox-retired" ]] && continue
    [[ -e "$d/spool/.hub/hub-run.pid" ]] || continue
    spl_desk_alive "$d/spool/.hub/hub-run.pid" && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$e" "$t" "$b" "$(stat -c %U "$d" 2>/dev/null || echo '?')" "$d"
  done < <(spl_desk_glob "*/*" "$e")
}
