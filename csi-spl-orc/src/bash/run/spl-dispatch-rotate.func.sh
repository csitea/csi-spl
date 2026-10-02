#!/bin/bash
#------------------------------------------------------------------------------
# @description The hourly dispatcher rotation (spec 060 section 4.3, owner
# @description 2026-10-02): CLE-002 (master) and then CLE-003 (failover) each
# @description get a FRESH session under the SAME id, so no dispatcher carries
# @description an ever larger context. The ids never swap roles (lease.conf is
# @description never written). Mechanical (FR-001): every step reads files,
# @description /proc, tmux or a run action, and nothing calls a model; one line
# @description per step in <spool root>/dispatch/rotate.log, the phase in
# @description rotate.dispatch.state / .ctx (resumable, FR-003). The shared
# @description pieces are spl-rotate-lib.func.sh (CLE-77939).
# @description   GATE     switch, lease.conf, this machine holds the dispatch
# @description            lease (FR-044), boot grace, the last rotation and
# @description            the master at least ROTATE_MIN_AGE old, no orch
# @description            rotation in flight (FR-051), not stalled (FR-022)
# @description   HEAL     a dispatcher with no live process is spawned by
# @description            do_spl_dispatch_setup, nothing else this run (FR-021)
# @description   HOLD     <dir>/rotate.hold names M: the lease loops skip M,
# @description            F takes the lease and acts (FR-023)
# @description   QUIESCE, HANDOFF, SPAWN (the old window renamed retiring, a
# @description            new session beside the old one, seeded with the
# @description            dispatcher brief + the rotation line; the handoff
# @description            also arrives as a task in its inbox, FR-026), ACK
# @description            (a result on dispatch-rotate-<rid> in its outbox,
# @description            FR-041), RETIRE (/exit-clean, TERM, KILL), CLOSE
# @description   RELEASE  the hold goes, M takes the lease back (FR-028)
# @description   REFRESH  the same for F, without a hold (FR-029)
# @description   DONE     rotate.dispatch.last, a result note to the orchestrator
# @description A new session that does not start or ack is closed, the OLD one
# @description keeps the role (the hold is removed), and an ask + an owner DM
# @description raise it (owner D2, FR-027, FR-075). Dry run unless DRY_RUN=0.
# @param ROTATE_CMD (optional) - auto (default), ack (the new session's ack, with ROTATE_ID), abort (FR-091), handoff (preview)
# @param ROTATE_ID (optional) - with ROTATE_CMD=ack: the rotation id from the seed
# @param ROTATE_FORCE (optional) - 1 skips the age and boot gates
# @param ROTATE_ACK_TIMEOUT (optional) - s, default 600 here (the orchestrator's is 900)
# @param ROTATE_PROMOTE_WAIT (optional) - s for the lease to move to F and back, default 240
# @param ROTATE_SETTLE (optional) - s the fresh master holds the lease before F is refreshed, default 120
# @param ROTATE_SEQ_WAIT (optional) - s to wait for an orch rotation in flight, default 600
# @param ROTATE_HOLD_MAX (optional) - s after which the lease loops ignore a hold, default 1800
# @param ROTATE_* (optional) - every other knob and switch of spl_rotate_conf (env > rotate.conf > default)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_dispatch_rotate
# @example DRY_RUN=0 ./run -a do_spl_dispatch_rotate
# @example ROTATE_CMD=abort DRY_RUN=0 ./run -a do_spl_dispatch_rotate
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_dispatch_rotate() {
  # the dispatchers' ack window is shorter than the orchestrator's (FR-027)
  ROTATE_ACK_TIMEOUT="${ROTATE_ACK_TIMEOUT:-600}"
  spl_rotate_conf || return 1
  : "${ROTATE_PROMOTE_WAIT:=240}" "${ROTATE_SETTLE:=120}" "${ROTATE_SEQ_WAIT:=600}"
  [[ "${LEASE_MASTER:-}" =~ ^[A-Z]{2,4}-[0-9]{1,9}$ && "${LEASE_FAILOVER:-}" =~ ^[A-Z]{2,4}-[0-9]{1,9}$ &&
     "$LEASE_MASTER" != "$LEASE_FAILOVER" ]] ||
    { spl_rotate_log - GATE SKIP "no master + failover pair in $LEASE_CONF"; return 0; }
  case "${ROTATE_CMD:-auto}" in
    auto)    spl_disp_rotate_auto ;;
    ack)     spl_rotate_ack_send "${ROTATE_ID##*-}" "$(spl_rotate_role_id "${ROTATE_ID##*-}")" ;;
    abort)   spl_disp_rotate_abort ;;
    handoff) ROTATE_QUIESCE="not run (preview)" spl_rotate_handoff master "$LEASE_MASTER" preview - ;;
    *) do_log "FATAL ROTATE_CMD must be auto, ack, abort or handoff, got: '${ROTATE_CMD:-}'"; return 1 ;;
  esac
}

# 0 unless ROTATE=0 or ROTATE_DISPATCH=0 (environment, else rotate.conf):
# the rollback switch (FR-090), also read by do_spl_dispatch_check.
spl_dispatch_rotate_on() {
  local k v
  for k in ROTATE ROTATE_DISPATCH; do
    v="${!k:-}"
    [[ -z "$v" ]] && v="$(sed -n "s/^$k=\([01]\)\$/\1/p" "${LEASE_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch}/rotate.conf" 2>/dev/null | tail -1)"
    [[ "$v" == 0 ]] && return 1
  done
  return 0
}

spl_disp_rotate_auto() {
  local m="$LEASE_MASTER" f="$LEASE_FAILOVER" rid last mpid fpid age pane why
  rid="$(spl_rotate_new_rid master)"
  exec 7>> "$LEASE_DIR/rotate.dispatch.lock"
  flock -n 7 || { spl_rotate_log "$rid" GATE SKIP "locked"; return 0; }
  if spl_rotate_ctx_load dispatch && spl_disp_in_flight "$ROTATE_PHASE"; then
    if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_rotate_log "$ROTATE_RID" RESUME PLAN "from $ROTATE_PHASE"; return 0; fi
    spl_disp_rotate_resume || return 1
    return 0
  fi
  spl_dispatch_rotate_on || { spl_rotate_log "$rid" GATE SKIP "disabled (ROTATE=$ROTATE ROTATE_DISPATCH=$ROTATE_DISPATCH)"; return 0; }
  # FR-044: only the machine that holds the dispatch lease rotates its pair
  spl_lease_read
  if spl_lease_remote; then spl_rotate_log "$rid" GATE SKIP "standby (dispatch lease: $LH)"; return 0; fi
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( $(spl_rotate_uptime) < ROTATE_BOOT_GRACE )); then
    spl_rotate_log "$rid" GATE SKIP "boot ($(spl_rotate_uptime)s < ${ROTATE_BOOT_GRACE}s)"; return 0
  fi
  last="$(cat "$LEASE_DIR/rotate.dispatch.last" 2>/dev/null || true)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( $(date +%s) - last < ROTATE_MIN_AGE )); then
    spl_rotate_log "$rid" GATE SKIP "young: the last rotation was $(( $(date +%s) - last ))s ago"; return 0
  fi
  spl_disp_wait_orch "$rid" || return 0

  local -a mp fp
  mapfile -t mp < <(spl_rotate_pids "$m"); mapfile -t fp < <(spl_rotate_pids "$f")
  # HEAL (FR-021): never zero dispatchers
  if (( ${#mp[@]} == 0 || ${#fp[@]} == 0 )); then
    spl_disp_heal "$rid" "${#mp[@]}" "${#fp[@]}"; return $?
  fi
  if (( ${#mp[@]} > 1 || ${#fp[@]} > 1 )); then
    spl_rotate_log "$rid" GATE SKIP "duplicate: $m pids ${mp[*]}, $f pids ${fp[*]}"
    spl_disp_once "dup.${mp[*]// /_}.${fp[*]// /_}" "ROTATION SKIP duplicate: $m pids ${mp[*]} / $f pids ${fp[*]} on $ROTATE_BOX; no rotation until one each is left"
    return 0
  fi
  mpid="${mp[0]}"; fpid="${fp[0]}"
  age="$(spl_rotate_age "$mpid")"; age="${age:-0}"
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( age < ROTATE_MIN_AGE )); then
    spl_rotate_log "$rid" GATE SKIP "young: $m pid $mpid is ${age}s old (< $ROTATE_MIN_AGE)"; return 0
  fi
  pane="$(spl_rotate_pane_of_pid "$mpid")"
  [[ -n "$pane" ]] || { spl_rotate_log "$rid" GATE SKIP "absent: $m pid $mpid is in no tmux pane"; return 0; }
  why="$(spl_rotate_stalled "$pane")"
  if [[ -n "$why" ]]; then
    spl_rotate_log "$rid" GATE SKIP "stalled $why"
    spl_disp_once "stall.$(tr -c 'a-z0-9' '_' <<<"${why,,}")" "ROTATION SKIP stalled: $m@$ROTATE_BOX pane shows '$why'; the lease has moved to $f and a new session would stall too"
    return 0
  fi

  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_disp_plan "$rid" "$m" "$mpid" "$pane" "$age" "$f" "$fpid"; return 0
  fi
  spl_disp_begin master "$rid" "$mpid" "$pane"
  spl_disp_step GATE OK "$m pid $mpid, ${age}s old, pane $pane; $f pid $fpid; lease $LH"
  spl_disp_hold || return 1
  spl_disp_run || return 1
  spl_disp_run_all
}

# ALERT ends a failed rotation (it follows FAIL) and is the last phase the
# orch .state shows: read as in flight, it held every dispatcher rotation off
# until the next orch rotation (20261002T1515Z GATE SKIP orch-busy)
spl_disp_in_flight() { [[ -n "$1" && "$1" != DONE && "$1" != FAIL && "$1" != ABORT && "$1" != ALERT ]]; }

# FR-051: an orch rotation of this machine in flight goes first.
spl_disp_wait_orch() {
  local t0=$SECONDS ph
  while :; do
    ph="$(cut -d' ' -f2 "$LEASE_DIR/rotate.orch.state" 2>/dev/null || true)"
    spl_disp_in_flight "$ph" && [[ "$ph" != GATE ]] || return 0
    (( SECONDS - t0 >= ROTATE_SEQ_WAIT )) && { spl_rotate_log "$1" GATE SKIP "orch-busy (orch rotation at $ph)"; return 1; }
    sleep "$ROTATE_POLL"
  done
}

# FR-021: do_spl_dispatch_setup spawns whichever dispatcher has no process.
spl_disp_heal() {
  local rid="$1" nm="$2" nf="$3" what="" id t0
  (( nm )) || what+="$LEASE_MASTER "
  (( nf )) || what+="$LEASE_FAILOVER "
  what="${what% }"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_rotate_log "$rid" HEAL PLAN "do_spl_dispatch_setup spawns: $what"; return 0; fi
  spl_rotate_log "$rid" HEAL WAIT "no live process: $what - do_spl_dispatch_setup, no rotation this run"
  if ! env ENV="${ENV:-${LEASE_ENV:-prd}}" DISPATCH_MASTER="$LEASE_MASTER" DISPATCH_FAILOVER="$LEASE_FAILOVER" DISPATCH_ORCH="$LEASE_ORCH" \
      DISPATCH_SUBSCRIBE=0 DISPATCH_SWEEP=0 DRY_RUN=0 timeout 600 "$ROTATE_RUN" -a do_spl_dispatch_setup \
      >> "$LEASE_DIR/rotate.out" 2>&1 7>&- 8>&- 9>&-; then
    spl_rotate_log "$rid" HEAL FAIL "do_spl_dispatch_setup failed (log $LEASE_DIR/rotate.out)"
    spl_rotate_alert master "$rid" HEAL "no live $what and do_spl_dispatch_setup failed"
    return 1
  fi
  t0=$SECONDS
  for id in $what; do
    while [[ -z "$(spl_rotate_pids "$id")" ]]; do
      if (( SECONDS - t0 >= ROTATE_START_WAIT )); then
        spl_rotate_log "$rid" HEAL FAIL "$id did not start in ${ROTATE_START_WAIT}s"
        spl_rotate_alert master "$rid" HEAL "$id did not start"; return 1
      fi
      sleep "$ROTATE_POLL"
    done
  done
  spl_rotate_log "$rid" HEAL OK "running again: $what"
}

# One note per distinct condition, to the orchestrator (FR-009, FR-073).
spl_disp_once() {
  local mark="$LEASE_DIR/rotate.dispatch.told.$1"
  [[ -e "$mark" ]] && return 0
  rm -f "$LEASE_DIR"/rotate.dispatch.told.* 2>/dev/null || true
  touch "$mark"
  spl_rotate_note "$LEASE_ORCH" dispatch-rotate "$2"
}

spl_disp_plan() {
  local rid="$1" m="$2" mpid="$3" pane="$4" age="$5" f="$6" fpid="$7"
  spl_rotate_log "$rid" GATE PLAN "pass: $m pid $mpid, ${age}s old, pane $pane; $f pid $fpid; lease $LH"
  spl_rotate_log "$rid" HOLD PLAN "$LEASE_DIR/rotate.hold = $m; the lease moves to $f (wait ${ROTATE_PROMOTE_WAIT}s)"
  spl_rotate_log "$rid" QUIESCE PLAN "wait ${ROTATE_IDLE_GRACE}s for idle, then Escape, ${ROTATE_ESC_WAIT}s; busy = rotate anyway"
  spl_rotate_log "$rid" HANDOFF PLAN "$ROTATE_HANDOFF_DIR/$rid-$m.md"
  spl_rotate_log "$rid" SPAWN PLAN "rename $pane -> $(ROTATE_RID="$rid" spl_rotate_retiring_name "$m"); $ROTATE_SPAWN claude $m <seed: brief + rotation line> (SPAWN_REUSE_ID=1); adopt; a task on $(spl_rotate_ack_task "$rid") in its inbox"
  spl_rotate_log "$rid" ACK PLAN "wait ${ROTATE_ACK_TIMEOUT}s for a result on $(spl_rotate_ack_task "$rid") in $SPOOL_ROOT/$m/outbox"
  spl_rotate_log "$rid" RETIRE PLAN "/exit-clean into $pane, TERM after ${ROTATE_EXIT_WAIT}s, KILL after ${ROTATE_TERM_WAIT}s more; close it"
  spl_rotate_log "$rid" RELEASE PLAN "remove the hold; $m takes the lease back, $f STANDBY"
  spl_rotate_log "${rid%-master}-failover" REFRESH PLAN "after ${ROTATE_SETTLE}s with $m holding: $f (pid $fpid, $(spl_rotate_age "$fpid")s old) the same way, no hold"
  spl_rotate_log "$rid" DONE PLAN "$LEASE_DIR/rotate.dispatch.last; a result note to $LEASE_ORCH"
  echo "---- DRY_RUN, nothing was touched. Re-run with DRY_RUN=0."
}

# The globals of one role's rotation (the lib reads them).
spl_disp_begin() {  # ROLE RID OLD_PID OLD_PANE
  local id; id="$(spl_rotate_role_id "$1")"
  ROTATE_RID="$2" ROTATE_OLD_PID="$3" ROTATE_OLD_PANE="$4" ROTATE_NEW_PID="" ROTATE_NEW_PANE="" ROTATE_QUIESCE=""
  # shellcheck disable=SC2034 # read by spl_rotate_restore (spl-rotate-lib)
  ROTATE_OLD_NAME="$(spl_rotate_tmux display-message -p -t "$4" '#{window_name}' 2>/dev/null || true)"
  ROTATE_HANDOFF="$ROTATE_HANDOFF_DIR/$2-$id.md"
}

# Record the phase (log + .state + ctx).
spl_disp_step() {
  ROTATE_PHASE="$1"
  spl_rotate_ctx_save dispatch
  spl_rotate_log "$ROTATE_RID" "$1" "$2" "${3:-}"
}

spl_disp_role() { echo "${ROTATE_RID##*-}"; }

# ---- the lease: HOLD and RELEASE (FR-023, FR-028) ------------------------------

# 0 once the dispatch lease names <id> (bare, or <id>@<this box>).
spl_disp_wait_holder() {
  local t0=$SECONDS
  while :; do
    spl_lease_read
    [[ "$LH" == "$1" || "$LH" == "$1@$ROTATE_BOX" ]] && return 0
    (( SECONDS - t0 >= ROTATE_PROMOTE_WAIT )) && return 1
    sleep "$ROTATE_POLL"
  done
}

spl_disp_lease_to() {
  spl_lease_write "$1"; touch "$LEASE_FILE.failover"
  spl_lease_log "ROTATE ${ROTATE_RID:-}: lease -> $1"
}

# HOLD: every process of M is off the lease from here; F acts. Local mode
# writes the lease (no loop tells anyone then, so F and M are told here);
# fleet mode waits for the fleet loop's CAS, which tells them.
spl_disp_hold() {
  local m="$LEASE_MASTER" f="$LEASE_FAILOVER"
  printf '%s %s %s\n' "$m" "$(date +%s)" "$ROTATE_RID" > "$LEASE_DIR/rotate.hold.tmp.$$" &&
    mv -f "$LEASE_DIR/rotate.hold.tmp.$$" "$LEASE_DIR/rotate.hold"
  spl_lease_log "ROTATE $ROTATE_RID: hold $m"
  if [[ -z "${LEASE_FLEET:-}" ]]; then
    spl_lease_locked spl_disp_lease_to "$f"
    spl_rotate_note "$f" dispatch-lease "DISPATCH LEASE: you are now ACTIVE (hourly rotation $ROTATE_RID: $m gets a fresh session). Dispatch, including $m's unread inbox (spool recv --as $m), until told STANDBY."
    spl_rotate_note "$m" dispatch-lease "DISPATCH LEASE: STANDBY - hourly rotation $ROTATE_RID, $f acts while a fresh $m session starts. Route, spawn and post nothing more."
  fi
  if ! spl_disp_wait_holder "$f"; then
    rm -f "$LEASE_DIR/rotate.hold"
    spl_disp_step FAIL FAIL "HOLD: the lease did not move to $f in ${ROTATE_PROMOTE_WAIT}s (it is $LH); $m keeps acting"
    spl_rotate_alert master "$ROTATE_RID" PROMOTE "the lease did not move to $f in ${ROTATE_PROMOTE_WAIT}s"
    return 1
  fi
  spl_disp_step HOLD OK "rotate.hold = $m; the lease is $LH"
}

# RELEASE: the hold goes and M renews; local mode writes it back at once and
# keeps the failover marker, so the watch's handback tells F STANDBY.
spl_disp_release() {
  local m="$LEASE_MASTER"
  rm -f "$LEASE_DIR/rotate.hold"
  spl_lease_log "ROTATE ${ROTATE_RID:-}: release $m"
  if [[ -z "${LEASE_FLEET:-}" && -n "$(spl_lease_agent_able "$m")" ]]; then spl_lease_locked spl_disp_lease_to "$m"; fi
  return 0
}

# ---- one role: QUIESCE .. CLOSE ------------------------------------------------

spl_disp_run() {
  local id seed
  id="$(spl_rotate_role_id "$(spl_disp_role)")"
  seed="$ROTATE_HANDOFF_DIR/$ROTATE_RID-$id.seed.md"
  ROTATE_QUIESCE="$(spl_rotate_quiesce "$ROTATE_OLD_PANE")"
  spl_disp_step QUIESCE "$([[ "$ROTATE_QUIESCE" == busy-rotated ]] && echo WAIT || echo OK)" "$ROTATE_QUIESCE"
  mkdir -p "$ROTATE_HANDOFF_DIR" 2>/dev/null || true
  spl_rotate_handoff_prune
  spl_rotate_handoff "$(spl_disp_role)" "$id" "$ROTATE_RID" "$ROTATE_HANDOFF"
  chmod 0640 "$ROTATE_HANDOFF" 2>/dev/null || true
  if ! spl_disp_seed "$id" > "$seed"; then
    spl_disp_fail SPAWN "no dispatcher brief for $id (run do_spl_dispatch_setup once)"; return 1
  fi
  chmod 0640 "$seed" 2>/dev/null || true
  spl_disp_step HANDOFF OK "$ROTATE_HANDOFF ($(wc -l < "$ROTATE_HANDOFF") lines)"
  if ! spl_rotate_spawn "$id" "$seed"; then
    spl_disp_fail SPAWN "$ROTATE_ERR"; return 1
  fi
  # FR-026: the handoff also arrives as a task in the inbox
  spl_rotate_note "$id" "$(spl_rotate_ack_task "$ROTATE_RID")" \
    "ROTATION $ROTATE_RID: you are the fresh $id@$ROTATE_BOX. Read $ROTATE_HANDOFF, then your inbox (spool recv --as $id; skip what $LEASE_FAILOVER's outbox shows handled since the hold), then run the ACK-COMMAND of your seed $seed." task
  spl_disp_step SPAWN OK "new pid $ROTATE_NEW_PID pane $ROTATE_NEW_PANE; old window $(spl_rotate_retiring_name "$id")"
  spl_disp_from_spawn
}

spl_disp_from_spawn() {
  local id rc=0
  id="$(spl_rotate_role_id "$(spl_disp_role)")"
  spl_disp_step ACK WAIT "up to ${ROTATE_ACK_TIMEOUT}s for $(spl_rotate_ack_task "$ROTATE_RID")"
  spl_rotate_ack_wait "$id" "$ROTATE_RID" "$ROTATE_ACK_TIMEOUT" || rc=$?
  case "$rc" in
    0) ;;
    2) spl_disp_fail ACK "the new session (pid $ROTATE_NEW_PID) ended before it acked"; return 1 ;;
    *) spl_disp_fail ACK "no ack within ${ROTATE_ACK_TIMEOUT}s"; return 1 ;;
  esac
  spl_disp_step ACK OK "acked by pid $ROTATE_NEW_PID"
  spl_disp_from_ack
}

spl_disp_from_ack() {
  local role
  role="$(spl_disp_role)"
  spl_disp_step RETIRE WAIT "/exit-clean into $ROTATE_OLD_PANE (pid $ROTATE_OLD_PID)"
  if ! spl_rotate_retire "$ROTATE_OLD_PANE" "$ROTATE_OLD_PID"; then
    # the hold stays: two processes on one id never take the lease
    spl_disp_step FAIL FAIL "RETIRE: pid $ROTATE_OLD_PID survived SIGKILL; the duplicate gate refuses until a human clears it"
    spl_rotate_alert "$role" "$ROTATE_RID" RETIRE "old pid $ROTATE_OLD_PID survived SIGKILL"
    return 1
  fi
  spl_disp_step RETIRE OK "pid $ROTATE_OLD_PID gone"
  spl_disp_close
}

# CLOSE (FR-017), then RELEASE for the master.
spl_disp_close() {
  local role id n mp warn=""
  role="$(spl_disp_role)"; id="$(spl_rotate_role_id "$role")"
  if spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{pane_id}' >/dev/null 2>&1; then
    spl_rotate_tmux kill-window -t "$ROTATE_OLD_PANE" 2>/dev/null || true
  fi
  n="$(spl_rotate_pids "$id" | grep -c . || true)"
  [[ "$n" == 1 ]] || warn+=" processes=$n"
  mp="$(spl_rotate_ai pane-of "$id" 2>/dev/null || true)"
  [[ "$mp" == "$ROTATE_NEW_PANE" ]] || warn+=" map=${mp:-none}"
  spl_disp_step CLOSE "$([[ -z "$warn" ]] && echo OK || echo WAIT)" "old window closed; checks:${warn:- one process, map -> $ROTATE_NEW_PANE}"
  spl_lease_log "ROTATE $role $id $ROTATE_RID: pid $ROTATE_OLD_PID -> $ROTATE_NEW_PID"
  [[ "$role" == master ]] || return 0
  spl_disp_release
  if ! spl_disp_wait_holder "$LEASE_MASTER"; then
    spl_disp_step RELEASE FAIL "the lease is still $LH ${ROTATE_PROMOTE_WAIT}s after the release; $LEASE_FAILOVER keeps acting"
    spl_rotate_alert master "$ROTATE_RID" RELEASE "the lease did not come back to $LEASE_MASTER"
    return 1
  fi
  spl_disp_step RELEASE OK "the lease is $LH"
}

# A failure before RETIRE (owner D2): the new session closed, the old one keeps
# the role (for the master: the hold goes, so it takes the lease back), ALERT;
# after an ack timeout the old pane is told where the handoff is (FR-014).
spl_disp_fail() {
  local phase="$1" reason="$2" role id
  role="$(spl_disp_role)"; id="$(spl_rotate_role_id "$role")"
  spl_rotate_restore "$id" "$ROTATE_OLD_PANE" "$ROTATE_NEW_PANE"
  if [[ "$role" == master ]]; then
    spl_disp_release
    spl_rotate_note "$id" dispatch-lease "DISPATCH LEASE: you are ACTIVE again - rotation $ROTATE_RID failed and you keep the master role."
  fi
  spl_disp_step FAIL FAIL "$phase: $reason; the old session (pid $ROTATE_OLD_PID) keeps the role"
  spl_rotate_alert "$role" "$ROTATE_RID" "$phase" "$reason"
  if [[ "$phase" == ACK ]] && spl_rotate_alive "$ROTATE_OLD_PID"; then
    spl_rotate_tmux send-keys -t "$ROTATE_OLD_PANE" -l \
      "Rotation $ROTATE_RID failed; you keep the role. Read $ROTATE_HANDOFF for anything you were interrupted on." 2>/dev/null || true
    sleep 1
    spl_rotate_tmux send-keys -t "$ROTATE_OLD_PANE" Enter 2>/dev/null || true
  fi
  return 0
}

# The seed (FR-040): the role's brief (do_spl_dispatch_setup renders it), the
# rotation line with the ack command, the standing rules.
spl_disp_seed() {
  local id="$1" brief="${DISPATCH_BRIEF_DIR:-$LEASE_DIR/briefs}/brief-dispatcher-$1.md" as="${SPOOL_BOX_USER:-$USER}" ack
  [[ -f "$brief" ]] || return 1
  ack="cd $PROJ_PATH && sudo -u $as env SPOOL_ROOT=$SPOOL_ROOT ROTATE_CMD=ack ROTATE_ID=$ROTATE_RID ./run -a do_spl_dispatch_rotate"
  cat "$brief"
  cat <<EOF

## Hourly rotation $ROTATE_RID (spec 060)

You are the new $id@$ROTATE_BOX, rotated at $ROTATE_RID: same id, same inbox,
same role. Read $ROTATE_HANDOFF, then your inbox (spool recv --as $id), then
run the ack below. Do not greet; post nothing about the rotation. Without the
ack in ${ROTATE_ACK_TIMEOUT}s you are closed and the previous session keeps
the role.
ACK-COMMAND: $ack

Standing rules: agents run as the agent user only; one agent = one small
task; never spawn Grok.
EOF
}

# ---- REFRESH F (FR-029) and DONE ------------------------------------------------

spl_disp_refresh() {
  local f="$LEASE_FAILOVER" rid fpid age pane t0=$SECONDS
  rid="${ROTATE_RID%-master}-failover"
  while (( SECONDS - t0 < ROTATE_SETTLE )); do sleep "$ROTATE_POLL"; done
  spl_lease_read
  if [[ "$LH" != "$LEASE_MASTER" && "$LH" != "$LEASE_MASTER@$ROTATE_BOX" ]]; then
    spl_rotate_log "$rid" REFRESH SKIP "the lease is $LH, not $LEASE_MASTER: $f stays"; return 0
  fi
  fpid="$(spl_rotate_pids "$f" | head -1)"
  [[ -n "$fpid" ]] || { spl_rotate_log "$rid" REFRESH SKIP "$f has no live process: the next run heals it"; return 0; }
  age="$(spl_rotate_age "$fpid")"; age="${age:-0}"
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( age < ROTATE_MIN_AGE )); then
    spl_rotate_log "$rid" REFRESH SKIP "young: $f pid $fpid is ${age}s old"; return 0
  fi
  pane="$(spl_rotate_pane_of_pid "$fpid")"
  [[ -n "$pane" ]] || { spl_rotate_log "$rid" REFRESH SKIP "absent: $f pid $fpid is in no tmux pane"; return 0; }
  spl_disp_begin failover "$rid" "$fpid" "$pane"
  spl_disp_step REFRESH OK "$f pid $fpid, ${age}s old, pane $pane"
  spl_disp_run
}

spl_disp_run_all() {
  local master_rid="$ROTATE_RID" rc=0
  date +%s > "$LEASE_DIR/rotate.dispatch.last"
  spl_disp_refresh || rc=1
  ROTATE_RID="$master_rid"
  # through the ctx too: a phase left at the failover's CLOSE reads as in
  # flight, and every later run only resumed it (2026-10-02 11:09Z..)
  spl_disp_step DONE "$( ((rc)) && echo WAIT || echo OK)" "fresh $LEASE_MASTER$( ((rc)) && echo "; the $LEASE_FAILOVER refresh failed (alerted)")"
  spl_rotate_note "$LEASE_ORCH" "$(spl_rotate_ack_task "$ROTATE_RID")" \
    "ROTATION DONE $ROTATE_RID on $ROTATE_BOX: a fresh $LEASE_MASTER holds the dispatch lease$( ((rc)) && echo "; the $LEASE_FAILOVER refresh FAILED, the old one kept"). Log: $LEASE_DIR/rotate.log" result
  return $rc
}

# ---- resume (FR-003) and abort (FR-091) ------------------------------------------

spl_disp_rotate_resume() {
  local old=0 new=0 role
  role="$(spl_disp_role)"
  spl_rotate_alive "$ROTATE_OLD_PID" && old=1
  [[ -n "$ROTATE_NEW_PID" ]] && spl_rotate_alive "$ROTATE_NEW_PID" && new=1
  spl_rotate_log "$ROTATE_RID" RESUME OK "from $ROTATE_PHASE (old alive=$old, new alive=$new)"
  case "$ROTATE_PHASE:$old$new" in
    SPAWN:11|ACK:11)  spl_disp_from_spawn || return 1 ;;
    RETIRE:11)        spl_disp_from_ack || return 1 ;;
    RETIRE:01|CLOSE:01|ACK:01|RELEASE:01|RELEASE:11) spl_disp_close || return 1 ;;
    *:10|GATE:*|HOLD:*|QUIESCE:*|HANDOFF:*|REFRESH:*)
      spl_disp_fail "$ROTATE_PHASE" "resumed with no live new session"; return 1 ;;
    *) [[ "$role" == master ]] && spl_disp_release
       spl_disp_step FAIL FAIL "resumed at $ROTATE_PHASE with neither session alive - the next run heals"
       spl_rotate_alert "$role" "$ROTATE_RID" "$ROTATE_PHASE" "neither session alive"; return 1 ;;
  esac
  if [[ "$role" == master ]]; then spl_disp_run_all; return $?; fi
  spl_disp_step DONE OK "resumed $ROTATE_RID to its end"
}

spl_disp_rotate_abort() {
  exec 7>> "$LEASE_DIR/rotate.dispatch.lock"
  if ! spl_rotate_ctx_load dispatch || ! spl_disp_in_flight "$ROTATE_PHASE"; then
    echo "no dispatch rotation in flight"; return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_rotate_log "$ROTATE_RID" ABORT PLAN "at $ROTATE_PHASE: restore the old session, close the new one, remove the hold"; return 0
  fi
  if [[ "$ROTATE_PHASE" == RETIRE || "$ROTATE_PHASE" == CLOSE || "$ROTATE_PHASE" == RELEASE ]]; then
    [[ "$(spl_disp_role)" == master ]] && spl_disp_release
    spl_rotate_log "$ROTATE_RID" ABORT FAIL "at $ROTATE_PHASE the old session is already being retired: hold removed, nothing to restore"
    return 1
  fi
  spl_rotate_restore "$(spl_rotate_role_id "$(spl_disp_role)")" "$ROTATE_OLD_PANE" "$ROTATE_NEW_PANE"
  [[ "$(spl_disp_role)" == master ]] && spl_disp_release
  spl_disp_step ABORT ABORT "at $ROTATE_PHASE by hand; the old session (pid $ROTATE_OLD_PID) keeps the role"
}
