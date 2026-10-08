#!/bin/bash
#------------------------------------------------------------------------------
# @description Rotate the orchestrator to a fresh session every hour (spec 060
# @description section 4.2, CLE-77939). The orchestrator re-reads its whole
# @description context on every turn and runs all day, so at :05 (cron, FR-050)
# @description a NEW claude session takes the role over under the SAME id
# @description (same inbox, same asks, same lease) and the old one ends.
# @description Mechanical (FR-001): no step calls a model; the new session only
# @description reads its handoff and runs the ack command. ROTATE_CMD picks:
# @description   auto    - the gates (FR-010: the id lock of spec 102 4.2,
# @description             held = exit 4; switch, LEASE_ORCH, this machine
# @description             holds the orch lease, boot grace, exactly ONE live
# @description             process, older than ROTATE_MIN_AGE, not stalled),
# @description             then QUIESCE (idle grace, Escape: a busy session is
# @description             rotated anyway, owner D1) -> HANDOFF -> SPAWN (old
# @description             window -> <ID>-<hhmm>Z-retiring, the map adopts the
# @description             new pid) -> ACK (the new session's result in
# @description             <ID>/outbox) -> RETIRE (/exit-clean, TERM, KILL) ->
# @description             CLOSE -> DONE. A failure keeps the old session in the
# @description             role and ALERTS (an ask + an owner DM, owner D2). A
# @description             re-run resumes a rotation left mid-way (FR-003).
# @description   ack     - run BY the new session: ROTATE_ID=<rid> from its seed
# @description   abort   - run the current phase's failure path (FR-091)
# @description   handoff - print the handoff a rotation would write now
# @description One line per step in <spool root>/dispatch/rotate.log. Dry run
# @description unless DRY_RUN=0: PLAN lines, nothing touched (FR-005).
# @param ROTATE_CMD (optional) - auto (default) | ack | abort | handoff
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ROTATE_ID (ack) - the rotation id named in the new session's seed
# @param ROTATE / ROTATE_ORCH (optional) - 0 turns rotation off (also <spool root>/dispatch/rotate.conf, FR-090)
# @param ROTATE_MIN_AGE (optional) - seconds, default 3300 (FR-008)
# @param ROTATE_FORCE (optional) - 1 skips the age and boot gates (never the one-process, lease or stall gates)
# @param ROTATE_IDLE_GRACE / ROTATE_ESC_WAIT / ROTATE_START_WAIT / ROTATE_ACK_TIMEOUT / ROTATE_EXIT_WAIT / ROTATE_TERM_WAIT (optional) - seconds, default 60 / 30 / 120 / 900 / 300 / 30
# @param ROTATE_HANDOFF_DIR (optional) - default <spool root>/dispatch/handoff
# @param ROTATE_HOLD_DIR (optional) - the hold notes, default /var/tmp/CLE-parent-level/dispatch/hold
# @example ./run -a do_spl_orch_rotate
# @example DRY_RUN=0 ./run -a do_spl_orch_rotate
# @example ROTATE_CMD=ack ROTATE_ID=20261002T0505Z-orch ./run -a do_spl_orch_rotate
# @example ROTATE_CMD=abort DRY_RUN=0 ./run -a do_spl_orch_rotate
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_orch_rotate() {
  spl_rotate_conf || return 1
  spl_is_agent_id "${LEASE_ORCH:-}" || { spl_rotate_log - GATE SKIP "no LEASE_ORCH in $LEASE_CONF"; return 0; }
  case "${ROTATE_CMD:-auto}" in
    auto)    spl_orch_rotate_auto ;;
    ack)     spl_rotate_ack_send orch "$LEASE_ORCH" ;;
    abort)   spl_orch_rotate_abort ;;
    handoff) ROTATE_QUIESCE="not run (preview)" spl_rotate_handoff orch "$LEASE_ORCH" preview - ;;
    *) do_log "FATAL ROTATE_CMD must be auto, ack, abort or handoff, got: '${ROTATE_CMD:-}'"; return 1 ;;
  esac
}

spl_orch_rotate_auto() {
  local id="$LEASE_ORCH" rid pid age pane why holder new
  # spec 061 L6 (owner 2026-10-02 21:37Z: the role switch is the rotation's,
  # not a command for him): LEASE_ORCH still a legacy id with a row in the
  # alias table = this rotation switches it (spl_orch_rotate_switch).
  new="$(spl_orch_rotate_new_id "$id")"
  rid="$(spl_rotate_new_rid orch)"
  exec 7>> "$LEASE_DIR/rotate.orch.lock"
  flock -n 7 || { spl_rotate_log "$rid" GATE SKIP "locked"; return 0; }
  # spec 102 4.2: the id lock, so no takeover, lane restart or restore acts
  # on the orchestrator while it rotates (the ack and abort take none: they
  # run inside a rotation)
  local idl=0
  spl_agent_id_lock "$id" do_spl_orch_rotate "$rid" || idl=$?
  (( idl == 0 )) || { spl_rotate_log "$rid" GATE SKIP "id lock: $SPL_ID_LOCK_WHY"; return "$idl"; }
  # a rotation left mid-way is resumed or failed first (FR-003)
  if spl_rotate_ctx_load orch && [[ -n "$ROTATE_PHASE" && "$ROTATE_PHASE" != DONE && "$ROTATE_PHASE" != FAIL && "$ROTATE_PHASE" != ABORT ]]; then
    if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_rotate_log "$ROTATE_RID" RESUME PLAN "from $ROTATE_PHASE"; return 0; fi
    spl_orch_rotate_resume || return 1
    return 0
  fi
  [[ "$ROTATE" != 0 && "$ROTATE_ORCH" != 0 ]] || { spl_rotate_log "$rid" GATE SKIP "disabled (ROTATE=$ROTATE ROTATE_ORCH=$ROTATE_ORCH)"; return 0; }
  if [[ -n "${LEASE_FLEET:-}" ]]; then
    holder="$(spl_orch_rotate_holder)"
    # the hub writes the holder under the NEW id once the alias exists
    # (c-001@box-desk while lease.conf says CLE-001: every rotation skipped);
    # a standby with a switch pending switches too, so both boxes move
    if [[ "$holder" != "$id@$ROTATE_BOX" && ( -z "$new" || "$holder" != "$new@$ROTATE_BOX" ) ]]; then
      [[ -n "$new" ]] || { spl_rotate_log "$rid" GATE SKIP "standby (orch lease: ${holder:-none})"; return 0; }
      spl_rotate_log "$rid" GATE OK "standby (orch lease: ${holder:-none}), but $id -> $new is pending: switching this machine's session"
    fi
  fi
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( $(spl_rotate_uptime) < ROTATE_BOOT_GRACE )); then
    spl_rotate_log "$rid" GATE SKIP "boot ($(spl_rotate_uptime)s < ${ROTATE_BOOT_GRACE}s)"; return 0
  fi
  local -a pids
  mapfile -t pids < <(spl_rotate_pids "$id")
  (( ${#pids[@]} > 0 )) || { spl_rotate_log "$rid" GATE SKIP "absent: no live claude carries $id"; return 0; }
  if (( ${#pids[@]} > 1 )); then
    spl_rotate_log "$rid" GATE SKIP "duplicate: ${#pids[@]} live processes carry $id (pids ${pids[*]})"
    spl_orch_rotate_once "dup.${pids[*]// /_}" "$id" "ROTATION SKIP duplicate: ${#pids[@]} live processes carry $id@$ROTATE_BOX (pids ${pids[*]}); no rotation until one is left"
    return 0
  fi
  pid="${pids[0]}"
  age="$(spl_rotate_age "$pid")"; age="${age:-0}"
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( age < ROTATE_MIN_AGE )); then
    spl_rotate_log "$rid" GATE SKIP "young: pid $pid is ${age}s old (< $ROTATE_MIN_AGE)"; return 0
  fi
  pane="$(spl_rotate_pane_of_pid "$pid")"
  [[ -n "$pane" ]] || { spl_rotate_log "$rid" GATE SKIP "absent: pid $pid is in no tmux pane"; return 0; }
  why="$(spl_rotate_stalled "$pane")"
  if [[ -n "$why" ]]; then
    spl_rotate_log "$rid" GATE SKIP "stalled $why"
    spl_orch_rotate_once "stall.$(tr -c 'a-z0-9' '_' <<<"${why,,}")" "$id" "ROTATION SKIP stalled: $id@$ROTATE_BOX pane shows '$why'; a new session would stall too"
    return 0
  fi

  ROTATE_RID="$rid" ROTATE_OLD_PID="$pid" ROTATE_OLD_PANE="$pane" ROTATE_NEW_PID="" ROTATE_NEW_PANE="" ROTATE_QUIESCE=""
  ROTATE_OLD_NAME="$(spl_rotate_tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null || true)"
  ROTATE_HANDOFF="$ROTATE_HANDOFF_DIR/$rid-$id.md"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_rotate_log "$rid" GATE PLAN "pass: $id pid $pid, ${age}s old, pane $pane '$ROTATE_OLD_NAME'"
    spl_rotate_log "$rid" QUIESCE PLAN "wait ${ROTATE_IDLE_GRACE}s for idle, then Escape, ${ROTATE_ESC_WAIT}s; busy = rotate anyway"
    spl_rotate_log "$rid" HANDOFF PLAN "$ROTATE_HANDOFF"
    [[ -n "$new" ]] && spl_rotate_log "$rid" SWITCH PLAN "$id -> $new: role rename (spool dir, registry, identity, window, dev+prd desks), lease.conf LEASE_ORCH=$new; the successor starts as $new"
    spl_rotate_log "$rid" SPAWN PLAN "rename $pane -> $(spl_rotate_retiring_name "$id"); $ROTATE_SPAWN claude $id $(spl_rotate_workdir "$id") <seed> (SPAWN_REUSE_ID=1); adopt the new pid"
    spl_rotate_log "$rid" ACK PLAN "wait ${ROTATE_ACK_TIMEOUT}s for a result on $(spl_rotate_ack_task "$rid") in $SPOOL_ROOT/$id/outbox"
    spl_rotate_log "$rid" RETIRE PLAN "/exit-clean into $pane, TERM after ${ROTATE_EXIT_WAIT}s, KILL after ${ROTATE_TERM_WAIT}s more"
    spl_rotate_log "$rid" CLOSE PLAN "close $pane by pane id; check one process, the lease, the map"
    echo "---- handoff preview ----"
    ROTATE_QUIESCE="not run (dry run)" spl_rotate_handoff orch "$id" "$rid" -
    echo "---- end of preview: DRY_RUN, nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_orch_rotate_step GATE OK "pid $pid, ${age}s old, pane $pane"
  spl_orch_rotate_run || return 1
}

# The new id of a legacy LEASE_ORCH (spec 061 L6), from this machine's alias
# table; nothing when it is already a new id or has no row.
spl_orch_rotate_new_id() {
  [[ "$1" =~ ^(CLE|GRK|AGY|QWN)-[0-9]+$ ]] || return 0
  awk -F'\t' -v id="$1" '$1 == id && $2 ~ /^[acgmq]-[0-9]{3}$/ {print $2; exit}' "$SPOOL_ROOT/agent-id-aliases.tsv" 2>/dev/null
}

# spl_orch_rotate_switch OLD: the role switch of do_spl_role_id_switch, done
# by the rotation (owner, 2026-10-02 21:37Z): agent-id-rename --roles (spool
# dir, registry, identity, the window, the dev+prd desks), then lease.conf
# LEASE_ORCH=<new>. Sets LEASE_ORCH and ROTATE_SWITCH_FROM; ROTATE_RENAME
# replaces the rename in tests. Non-zero = nothing in lease.conf changed.
spl_orch_rotate_switch() {
  local old="$1" new out
  new="$(spl_orch_rotate_new_id "$old")"
  out="$(${ROTATE_RENAME:-bash "$ROTATE_FEAT/scripts/agent-id-rename.sh"} --apply --roles --desk-envs "${ROTATE_SWITCH_DESK_ENVS-dev prd}" "$old" 2>&1)" ||
    { ROTATE_ERR="the rename $old -> $new failed: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"; return 1; }
  cp -p "$LEASE_CONF" "$LEASE_CONF.bak-$ROTATE_RID" 2>/dev/null || true
  sed -i "s/^LEASE_ORCH=$old\$/LEASE_ORCH=$new/" "$LEASE_CONF" && grep -qx "LEASE_ORCH=$new" "$LEASE_CONF" ||
    { ROTATE_ERR="lease.conf did not take LEASE_ORCH=$new"; return 1; }
  ROTATE_SWITCH_FROM="$old" LEASE_ORCH="$new"
  spl_orch_rotate_step SWITCH OK "$old -> $new: $(grep -c '^DO ' <<<"$out") rename step(s), lease.conf LEASE_ORCH=$new"
}

# The orch fleet lease holder as this machine mirrors it, when fresh.
spl_orch_rotate_holder() {
  local h t
  [[ -s "$LEASE_FILE.orch" ]] || return 0
  read -r h t < "$LEASE_FILE.orch"
  [[ "$t" =~ ^[0-9]+$ ]] && (( $(date +%s) - t <= ${LEASE_STALE:-180} )) && echo "$h"
  return 0
}

# One note per distinct condition (FR-009, FR-010), to the orchestrator.
spl_orch_rotate_once() {
  local mark="$LEASE_DIR/rotate.orch.told.$1"
  [[ -e "$mark" ]] && return 0
  rm -f "$LEASE_DIR"/rotate.orch.told.* 2>/dev/null || true
  touch "$mark"
  spl_rotate_note "$2" orch-rotate "$3"
}

# Record the phase (log + .state + ctx).
spl_orch_rotate_step() {
  ROTATE_PHASE="$1"
  spl_rotate_ctx_save orch
  spl_rotate_log "$ROTATE_RID" "$1" "$2" "${3:-}"
}

# QUIESCE -> HANDOFF -> SPAWN, then on.
spl_orch_rotate_run() {
  local id="$LEASE_ORCH" seed
  ROTATE_QUIESCE="$(spl_rotate_quiesce "$ROTATE_OLD_PANE")"
  spl_orch_rotate_step QUIESCE "$([[ "$ROTATE_QUIESCE" == busy-rotated ]] && echo WAIT || echo OK)" "$ROTATE_QUIESCE"

  mkdir -p "$ROTATE_HANDOFF_DIR" 2>/dev/null || true
  spl_rotate_handoff_prune
  spl_rotate_handoff orch "$id" "$ROTATE_RID" "$ROTATE_HANDOFF"
  chmod 0640 "$ROTATE_HANDOFF" 2>/dev/null || true
  seed="$ROTATE_HANDOFF_DIR/$ROTATE_RID-$id.seed.md"
  spl_orch_rotate_seed "$seed"
  chmod 0640 "$seed" 2>/dev/null || true
  spl_orch_rotate_step HANDOFF OK "$ROTATE_HANDOFF ($(wc -l < "$ROTATE_HANDOFF") lines)"

  ROTATE_SWITCH_FROM=""
  if [[ -n "$(spl_orch_rotate_new_id "$id")" ]]; then
    spl_orch_rotate_switch "$id" || { spl_orch_rotate_fail SWITCH "$ROTATE_ERR"; return 1; }
    id="$LEASE_ORCH"
    sed -i "s/\b$ROTATE_SWITCH_FROM\b/$id/g" "$seed" 2>/dev/null || true
  fi
  if ! spl_rotate_spawn "$id" "$seed"; then
    spl_orch_rotate_fail SPAWN "$ROTATE_ERR"; return 1
  fi
  spl_orch_rotate_step SPAWN OK "new pid $ROTATE_NEW_PID pane $ROTATE_NEW_PANE; old window $(spl_rotate_retiring_name "$id")"
  spl_orch_rotate_from_spawn || return 1
}

spl_orch_rotate_from_spawn() {
  local rc=0
  spl_orch_rotate_step ACK WAIT "up to ${ROTATE_ACK_TIMEOUT}s for $(spl_rotate_ack_task "$ROTATE_RID")"
  spl_rotate_ack_wait "$LEASE_ORCH" "$ROTATE_RID" "$ROTATE_ACK_TIMEOUT" || rc=$?
  case "$rc" in
    0) ;;
    2) spl_orch_rotate_fail ACK "the new session (pid $ROTATE_NEW_PID) ended before it acked"; return 1 ;;
    *) spl_orch_rotate_fail ACK "no ack within ${ROTATE_ACK_TIMEOUT}s"; return 1 ;;
  esac
  spl_orch_rotate_step ACK OK "acked by pid $ROTATE_NEW_PID"
  spl_orch_rotate_from_ack || return 1
}

spl_orch_rotate_from_ack() {
  spl_orch_rotate_step RETIRE WAIT "/exit-clean into $ROTATE_OLD_PANE (pid $ROTATE_OLD_PID)"
  if ! spl_rotate_retire "$ROTATE_OLD_PANE" "$ROTATE_OLD_PID"; then
    spl_orch_rotate_step RETIRE FAIL "pid $ROTATE_OLD_PID survived SIGKILL; the duplicate gate refuses until a human clears it"
    spl_rotate_alert orch "$ROTATE_RID" RETIRE "old pid $ROTATE_OLD_PID survived SIGKILL"
    return 1
  fi
  spl_orch_rotate_step RETIRE OK "pid $ROTATE_OLD_PID gone"
  spl_orch_rotate_close
}

# CLOSE (FR-017): the retiring window by pane id when /exit-clean's own
# close has not run, then the three checks, then DONE + a result note.
spl_orch_rotate_close() {
  local id="$LEASE_ORCH" n lp mp holder warn=""
  if spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{pane_id}' >/dev/null 2>&1; then
    spl_rotate_tmux kill-window -t "$ROTATE_OLD_PANE" 2>/dev/null || true
  fi
  n="$(spl_rotate_pids "$id" | grep -c . || true)"
  [[ "$n" == 1 ]] || warn+=" processes=$n"
  lp="$(spl_lease_agent_pid "$id")"
  [[ "$lp" == "$ROTATE_NEW_PID" ]] || warn+=" lease-pid=${lp:-none}"
  if [[ -n "${LEASE_FLEET:-}" ]]; then
    holder="$(spl_orch_rotate_holder)"
    [[ "$holder" == "$id@$ROTATE_BOX" ]] || warn+=" lease-moved(${holder:-none})"
  fi
  mp="$(spl_rotate_ai pane-of "$id" 2>/dev/null || true)"
  [[ "$mp" == "$ROTATE_NEW_PANE" ]] || warn+=" map=${mp:-none}"
  spl_orch_rotate_step CLOSE "$([[ -z "$warn" ]] && echo OK || echo WAIT)" "old window closed; checks:${warn:- one process, lease follows pid $ROTATE_NEW_PID, map -> $ROTATE_NEW_PANE}"
  spl_lease_log "ROTATE orch $id $ROTATE_RID: pid $ROTATE_OLD_PID -> $ROTATE_NEW_PID"
  spl_orch_rotate_step DONE OK "$id@$ROTATE_BOX is pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"
  spl_rotate_note "$id" "$(spl_rotate_ack_task "$ROTATE_RID")" \
    "ROTATION DONE $ROTATE_RID: you are $id@$ROTATE_BOX (pid $ROTATE_NEW_PID); old pid $ROTATE_OLD_PID retired; quiesce $ROTATE_QUIESCE; handoff $ROTATE_HANDOFF ($(wc -l < "$ROTATE_HANDOFF" 2>/dev/null || echo 0) lines); $(find "$SPOOL_ROOT/$id/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) unread in the inbox." result
  return 0
}

# A failure before RETIRE (owner D2): the old session keeps the role, the
# new one is closed, ALERT; after an ack timeout the old pane is told where
# the handoff is (FR-014). Returns 0; the caller returns 1.
spl_orch_rotate_fail() {
  local phase="$1" reason="$2"
  if [[ -n "${ROTATE_SWITCH_FROM:-}" ]]; then
    sed -i "s/^LEASE_ORCH=$LEASE_ORCH\$/LEASE_ORCH=$ROTATE_SWITCH_FROM/" "$LEASE_CONF" 2>/dev/null || true
    reason+="; lease.conf LEASE_ORCH back to $ROTATE_SWITCH_FROM (the renamed dirs stay, the old id links to them)"
    LEASE_ORCH="$ROTATE_SWITCH_FROM"
  fi
  spl_rotate_restore "$LEASE_ORCH" "$ROTATE_OLD_PANE" "$ROTATE_NEW_PANE"
  spl_orch_rotate_step FAIL FAIL "$phase: $reason; the old session (pid $ROTATE_OLD_PID) keeps the role"
  spl_rotate_alert orch "$ROTATE_RID" "$phase" "$reason"
  if [[ "$phase" == ACK ]] && spl_rotate_alive "$ROTATE_OLD_PID"; then
    spl_rotate_tmux send-keys -t "$ROTATE_OLD_PANE" -l \
      "Rotation $ROTATE_RID failed; you keep the role. Read $ROTATE_HANDOFF for anything you were interrupted on." 2>/dev/null || true
    sleep 1
    spl_rotate_tmux send-keys -t "$ROTATE_OLD_PANE" Enter 2>/dev/null || true
  fi
  return 0
}

# A rotation left mid-way (FR-003): continue from what can be checked.
spl_orch_rotate_resume() {
  local old=0 new=0 why
  # a reboot cut it off: no FAIL blocker, a switched lease.conf goes back,
  # the ctx goes, the next run gates afresh (as spl_disp_rotate_resume)
  if why="$(spl_rotate_booted_after "$ROTATE_RID")"; then
    if [[ -n "${ROTATE_SWITCH_FROM:-}" ]]; then
      sed -i "s/^LEASE_ORCH=$LEASE_ORCH\$/LEASE_ORCH=$ROTATE_SWITCH_FROM/" "$LEASE_CONF" 2>/dev/null || true
      why+="; lease.conf LEASE_ORCH back to $ROTATE_SWITCH_FROM"
    fi
    spl_rotate_log "$ROTATE_RID" ABORT BOOT "interrupted by boot at $ROTATE_PHASE: $why; ctx removed, no alert"
    rm -f "$LEASE_DIR/rotate.orch.ctx"
    return 0
  fi
  spl_rotate_alive "$ROTATE_OLD_PID" && old=1
  [[ -n "$ROTATE_NEW_PID" ]] && spl_rotate_alive "$ROTATE_NEW_PID" && new=1
  spl_rotate_log "$ROTATE_RID" RESUME OK "from $ROTATE_PHASE (old alive=$old, new alive=$new)"
  case "$ROTATE_PHASE:$old$new" in
    SPAWN:11|ACK:11)    spl_orch_rotate_from_spawn || return 1 ;;
    RETIRE:11)          spl_orch_rotate_from_ack || return 1 ;;
    RETIRE:01|CLOSE:01|ACK:01) spl_orch_rotate_close ;;
    *:10|GATE:*|QUIESCE:*|HANDOFF:*) spl_orch_rotate_fail "$ROTATE_PHASE" "resumed with no live new session"; return 1 ;;
    *) spl_orch_rotate_step FAIL FAIL "resumed at $ROTATE_PHASE with neither session alive - nothing acts as $LEASE_ORCH here"
       spl_rotate_alert orch "$ROTATE_RID" "$ROTATE_PHASE" "neither session alive"; return 1 ;;
  esac
}

# ROTATE_CMD=abort (FR-091): the current phase's failure path.
spl_orch_rotate_abort() {
  exec 7>> "$LEASE_DIR/rotate.orch.lock"
  if ! spl_rotate_ctx_load orch || [[ -z "$ROTATE_PHASE" || "$ROTATE_PHASE" == DONE || "$ROTATE_PHASE" == FAIL || "$ROTATE_PHASE" == ABORT ]]; then
    echo "no orch rotation in flight"; return 0
  fi
  [[ "${DRY_RUN:-1}" == 1 ]] && { spl_rotate_log "$ROTATE_RID" ABORT PLAN "at $ROTATE_PHASE: restore the old session, close the new one"; return 0; }
  if [[ "$ROTATE_PHASE" == RETIRE || "$ROTATE_PHASE" == CLOSE ]]; then
    spl_rotate_log "$ROTATE_RID" ABORT FAIL "at $ROTATE_PHASE the old session is already being retired: nothing to restore"; return 1
  fi
  spl_rotate_restore "$LEASE_ORCH" "$ROTATE_OLD_PANE" "$ROTATE_NEW_PANE"
  spl_orch_rotate_step ABORT ABORT "at $ROTATE_PHASE by hand; the old session (pid $ROTATE_OLD_PID) keeps the role"
}

# The seed (FR-040): the role, the rotation line, the standing rules.
spl_orch_rotate_seed() {
  local id="$LEASE_ORCH" as="${SPOOL_BOX_USER:-$USER}" inbox ack
  inbox="cd $PROJ_PATH && sudo -u $as env SPOOL_ROOT=$SPOOL_ROOT ./run -a do_spl_orch_inbox"
  ack="cd $PROJ_PATH && sudo -u $as env SPOOL_ROOT=$SPOOL_ROOT ROTATE_CMD=ack ROTATE_ID=$ROTATE_RID ./run -a do_spl_orch_rotate"
  cat > "$1" <<EOF
# Brief: you are the orchestrator $id@$ROTATE_BOX (rotation $ROTATE_RID)

You are the new $id@$ROTATE_BOX, rotated at $ROTATE_RID. Read $ROTATE_HANDOFF, then run \`$inbox\`, then run \`$ack\`. Do not greet; post nothing about the rotation.

This is not a coding task and it has no end. The hourly rotation (spec 060)
replaced the previous $id session with you: same id, same inbox, same asks,
same lease. The previous session is closed right after your ack; without the
ack you are closed instead and it keeps the role.

1. Your role: $ROTATE_SPEC section 1 (orchestrator), 1.2 (rotation),
   4.1 (fleet lease) and 4.3 (asks).
2. The handoff: $ROTATE_HANDOFF - what the previous session was doing when
   it was stopped (its screen, open asks, last hour of outbox, unread inbox,
   lanes, hold notes, the tail of its transcript). Pick up what it left.
3. The inbox: $inbox
4. The ack, exactly:
ACK-COMMAND: $ack
5. Standing rules: agents run as the agent user only; one agent = one small
   task; the memory files named in the handoff section 9.
EOF
}
