#!/bin/bash
#------------------------------------------------------------------------------
# @description A live drill of the role vendor failover (SPL-2562, follow-up
# @description of SPL-2544; owner HUM-10 t1 b3e90079: "grok should have been
# @description able to take over the orchestration, but it did not"; "the order
# @description is claude -> grok -> agy"). A hand run of do_spl_role_failover on
# @description a healthy seat switches nothing (its step 2: the seat can act),
# @description and a bare stop of the seat races the watchdog, whose S3
# @description takeover restarts it long before the lease launches the
# @description failover (LEASE_STALE + LEASE_FALLBACK_WAIT). This action:
# @description   1. refuses inside an hourly rotation (the role's
# @description      rotate.orch.lock / rotate.dispatch.lock held), when
# @description      ROLE_FAILOVER_SEAT is not lease.conf's holder of the role
# @description      (LEASE_ORCH / LEASE_MASTER) and when that seat has no live
# @description      process on this box
# @description   then (DRY_RUN=0) the drill starts itself again detached
# @description      (setsid, its own session and process group, output in
# @description      <dispatch>/role-failover/<rid>.drill.log) and the caller
# @description      returns: the caller is often the seat itself, whose pid
# @description      step 3 ends; the detached run does 1 again and goes on
# @description   2. holds the watchdog off THAT seat: <wd dir>/<seat>.heldout
# @description      (the takeover gate, spl_wd_gate; it lapses by itself after
# @description      an hour), released on every exit path (EXIT / INT / TERM
# @description      trap) and before any restore; a hold that stood before is
# @description      put back as it was
# @description   3. ends the seat's own pid (spl_lease_agent_pid): /exit, then
# @description      TERM, then KILL (spl_rotate_end); never a pattern kill
# @description   4. runs do_spl_role_failover at once with ROLE_FAILOVER_SEAT
# @description   5. prints the failover's rotate.log lines and what it
# @description      PROVED (lease.conf's new holder, which the failover wrote
# @description      only after its own able test passed; its live pid; the
# @description      old pid gone) and, in one line, what it did NOT prove (that
# @description      the new seat works the role: that able test passes for a
# @description      session that started and sits idle)
# @description   6. lease.conf still names the seat and no process carries it:
# @description      the hold released, the seat restarted by the normal restore
# @description      path (do_spl_agent_restart CAUSE=S3), so the role is never
# @description      left without a process
# @description Lines "<ts> <rid> DRILL <PHASE> <RESULT> <detail>" in rotate.log
# @description (rid <ts>-drill-<role>). Dry run unless DRY_RUN=0: the plan only.
# @param ROLE_FAILOVER_ROLE (required) - orch | dispatch
# @param ROLE_FAILOVER_SEAT (optional) - the seat to drill; must be lease.conf's holder of the role; default that holder
# @param ROLE_FAILOVER_EXIT_WAIT (optional) - s the seat gets after /exit before TERM, default 30
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ROLE_FAILOVER_ROLE=orch ./run -a do_spl_role_failover_drill
# @example ROLE_FAILOVER_ROLE=dispatch DRY_RUN=0 ./run -a do_spl_role_failover_drill
#------------------------------------------------------------------------------
declare -F do_spl_role_failover >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-role-failover.func.sh"

do_spl_role_failover_drill() {
  spl_rotate_conf || return 1
  local role="${ROLE_FAILOVER_ROLE:-}" fam key seat pid pane lfd n0 rc=0
  # spl_rotate_end's lines and the failover's own ROTATE_FAMILY stay in this
  # call: no rotate.<fam>.state of the hourly rotation is written
  # shellcheck disable=SC2034 # read by spl_rotate_log
  local ROTATE_FAMILY=drill ROTATE_STATE_DIR="$LEASE_DIR/role-failover"
  case "$role" in
    orch) fam=orch key=LEASE_ORCH ;;
    dispatch) fam=dispatch key=LEASE_MASTER ;;
    *) do_log "FATAL ROLE_FAILOVER_ROLE must be orch or dispatch, got: '$role'"; return 1 ;;
  esac
  [[ "${ROLE_FAILOVER_EXIT_WAIT:=30}" =~ ^[0-9]+$ ]] || { do_log "FATAL ROLE_FAILOVER_EXIT_WAIT must be whole seconds"; return 1; }
  # the detached run keeps its caller's rid (spl_rfd_detach)
  [[ "${RFD_DETACHED:-0}" == 1 && -n "${RFD_RID:-}" ]] || RFD_RID="$(spl_rotate_new_rid "drill-$role")"
  RFD_HELD=""
  # shellcheck disable=SC2034 # read by spl_rotate_end's log lines
  ROTATE_RID="$RFD_RID"
  seat="${!key:-}"
  [[ "$seat" =~ ^${SPL_ROLE_SEAT_RX}$ ]] || { spl_rfd_say REFUSED "$key='$seat' in $LEASE_CONF is no role seat id"; return 1; }
  if [[ -n "${ROLE_FAILOVER_SEAT:-}" && "$ROLE_FAILOVER_SEAT" != "$seat" ]]; then
    spl_rfd_say REFUSED "$ROLE_FAILOVER_SEAT is not the $role holder: lease.conf has $key=$seat"; return 1
  fi
  exec {lfd}>> "$LEASE_DIR/rotate.$fam.lock"
  if ! flock -n "$lfd"; then
    exec {lfd}>&-
    spl_rfd_say REFUSED "an hourly rotation holds rotate.$fam.lock: drill after it"; return 1
  fi
  # the failover takes this lock itself (flock -n): never hold it across
  exec {lfd}>&-
  pid="$(spl_lease_agent_pid "$seat")"
  [[ -n "$pid" ]] || { spl_rfd_say REFUSED "$seat has no live process on this box: nothing to drill (the lease's own failover acts)"; return 1; }
  pane="$(spl_rotate_pane_of_pid "$pid")"
  RFD_WD_DIR="${WD_STATE_DIR:-$LEASE_DIR/wd}" RFD_SEAT="$seat" RFD_PRIOR=""
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_rfd_say PLAN "$role holder $seat (pid $pid, pane ${pane:-none}): hold $RFD_WD_DIR/$seat.heldout, end pid $pid (/exit, TERM, KILL), ROLE_FAILOVER_SEAT=$seat DRY_RUN=0 do_spl_role_failover, print the new $key; nothing switched = release the hold and restart $seat (do_spl_agent_restart CAUSE=S3)"
    echo "OK DRY_RUN nothing was stopped. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_rfd_detach "$seat" && return 0
  mkdir -p "$ROTATE_STATE_DIR" 2>/dev/null || true
  trap 'spl_rfd_release' EXIT
  trap 'spl_rfd_release; exit 130' INT
  trap 'spl_rfd_release; exit 143' TERM
  spl_rfd_hold || { spl_rfd_say HOLD FAIL "cannot write $RFD_WD_DIR/$seat.heldout: nothing stopped"; spl_rfd_untrap; return 1; }
  spl_rfd_say STOP WAIT "$seat pid $pid pane ${pane:-none}: /exit, then TERM, then KILL"
  if ! spl_rotate_end "${pane:-none}" "$pid" /exit "$ROLE_FAILOVER_EXIT_WAIT" "$ROTATE_TERM_WAIT"; then
    spl_rfd_say STOP FAIL "pid $pid of $seat survived SIGKILL: no failover"
    spl_rfd_release; spl_rfd_untrap; return 1
  fi
  spl_rfd_say STOP OK "pid $pid of $seat ended"
  n0="$(wc -l 2>/dev/null < "$ROTATE_LOG" || echo 0)"
  ROLE_FAILOVER_ROLE="$role" ROLE_FAILOVER_SEAT="$seat" ROLE_FAILOVER_SILENT="" DRY_RUN=0 do_spl_role_failover || rc=$?
  # the failover's rotation lock (its fd 7) goes with it, before any restart
  exec 7>&-
  spl_rfd_say FAILOVER "$( ((rc)) && echo FAIL || echo OK)" "do_spl_role_failover returned $rc; its lines:"
  tail -n "+$((n0 + 1))" "$ROTATE_LOG" 2>/dev/null | grep -E "^[^ ]+ [0-9TZ]+-failover-$role " || true
  spl_rfd_release
  spl_rfd_untrap
  spl_rfd_after "$key" "$seat" "$pid"
}

# spl_rfd_detach SEAT: 0 = the drill was started again, detached (setsid: its
# own session and process group, no terminal, stdin /dev/null), its output in
# <dispatch>/role-failover/<rid>.drill.log; the caller only prints where. The
# caller is often the seat itself (the orch drills its own seat from its
# pane): step 3 ends that pid and the pane's process group with it, so the
# drill must not be a child of that pane. 1 = this IS the detached run.
spl_rfd_detach() {
  [[ "${RFD_DETACHED:-0}" == 1 ]] && return 1
  local log="$LEASE_DIR/role-failover/$RFD_RID.drill.log"
  mkdir -p "${log%/*}" 2>/dev/null || true
  ( RFD_DETACHED=1 RFD_RID="$RFD_RID" ROLE_FAILOVER_ROLE="$ROLE_FAILOVER_ROLE" ROLE_FAILOVER_SEAT="$1" DRY_RUN=0 \
      setsid "$ROTATE_RUN" -a do_spl_role_failover_drill > "$log" 2>&1 < /dev/null 7>&- 8>&- 9>&- & )
  spl_rfd_say DETACH OK "the drill of $1 runs detached (setsid); follow it: tail -f $log"
  return 0
}

# spl_rfd_say PHASE [RESULT] DETAIL: "<ts> <rid> DRILL <PHASE> [RESULT] <detail>"
# on stdout and, not in a dry run, in rotate.log. No rotate.<fam>.state is
# written: a drill is no rotation.
spl_rfd_say() {
  local line
  line="$(date -u +%FT%TZ) $RFD_RID DRILL $*"
  printf '%s\n' "$line"
  [[ "${DRY_RUN:-1}" == 1 ]] && return 0
  echo "$line" >> "$ROTATE_LOG" 2>/dev/null || true
}

# spl_rfd_hold: <wd dir>/<seat>.heldout = now (spl_wd_gate refuses the
# takeover for an hour); what stood there before is kept in RFD_PRIOR.
spl_rfd_hold() {
  local f="$RFD_WD_DIR/$RFD_SEAT.heldout"
  mkdir -p "$RFD_WD_DIR" 2>/dev/null || true
  if [[ -e "$f" ]]; then RFD_PRIOR="$(cat "$f" 2>/dev/null || true)"; RFD_HELD=prior; fi
  date +%s > "$f" 2>/dev/null || return 1
  [[ -n "$RFD_HELD" ]] || RFD_HELD=drill
  spl_rfd_say HOLD OK "$f: the watchdog keeps off $RFD_SEAT until the drill ends"
}

# spl_rfd_release: the hold off again (once): the prior one put back, else removed.
spl_rfd_release() {
  local f="$RFD_WD_DIR/$RFD_SEAT.heldout"
  case "${RFD_HELD:-}" in
    prior) printf '%s\n' "$RFD_PRIOR" > "$f" 2>/dev/null || true ;;
    drill) rm -f "$f" ;;
    *) return 0 ;;
  esac
  RFD_HELD=""
  spl_rfd_say HOLD OK "$f released"
}

spl_rfd_untrap() { trap - EXIT INT TERM; }

# spl_rfd_after KEY SEAT OLD_PID: what the drill proved, and what it did not.
# lease.conf names another id: the failover's OK came only after its own able
# test (spl_fleet_try, ROLE_FAILOVER_SETTLE s after the start) passed for it;
# the new id's live pid and the old pid's end are checked here. Still SEAT
# and nothing carries SEAT: the seat is restarted (do_spl_agent_restart).
spl_rfd_after() {
  local key="$1" seat="$2" opid="$3" now npid gone=yes out rc=0
  now="$(sed -n "s/^$key=//p" "$LEASE_CONF" 2>/dev/null | tail -n 1)"
  if [[ "$now" != "$seat" ]]; then
    npid="$(spl_lease_agent_pid "$now")"
    [[ -d "${LEASE_PROC_ROOT:-/proc}/$opid" ]] && gone="NO, pid $opid still runs"
    spl_rfd_say RESULT OK "PROVED: lease.conf $key=$now (was $seat); the failover's own able test (spl_fleet_try, ${ROLE_FAILOVER_SETTLE:-30}s after the start) passed for $now; $now has live pid ${npid:-NONE NOW}; the old $seat pid $opid gone: $gone"
    spl_rfd_say RESULT NOTE "NOT PROVED: that $now works the $ROLE_FAILOVER_ROLE role (acks its seed, reads the asks book, answers its inbox): that able test passes for a session that started and sits idle, check $now's pane and outbox"
    return 0
  fi
  if [[ -n "$(spl_lease_agent_pid "$seat")" ]]; then
    spl_rfd_say RESULT FAIL "lease.conf $key=$seat: nothing switched; $seat runs again"; return 1
  fi
  spl_rfd_say RESTORE WAIT "lease.conf $key=$seat and no process carries it: ID=$seat CAUSE=S3 do_spl_agent_restart"
  out="$LEASE_DIR/role-failover/$RFD_RID.restart.out"
  mkdir -p "${out%/*}" 2>/dev/null || true
  env ID="$seat" CAUSE=S3 REASON=drill DRY_RUN=0 "$ROTATE_RUN" -a do_spl_agent_restart > "$out" 2>&1 < /dev/null 8>&- 9>&- || rc=$?
  tail -n 5 "$out" 2>/dev/null || true
  spl_rfd_say RESTORE "$( ((rc)) && echo FAIL || echo OK)" "do_spl_agent_restart returned $rc ($out)"
  spl_rfd_say RESULT FAIL "lease.conf $key=$seat: nothing switched"
  return 1
}
