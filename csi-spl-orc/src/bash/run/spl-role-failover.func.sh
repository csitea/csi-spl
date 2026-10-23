#!/bin/bash
#------------------------------------------------------------------------------
# @description Switch a role seat that cannot act to the next vendor IN PLACE
# @description (SPL-2544; owner HUM-10 t1 b3e90079: "there was login on the
# @description claude and ... grok should have been able to take over the
# @description orchestration, but it did not"; msg dfe76b16: "the order is
# @description claude -> grok -> agy"). The fleet lease launches it
# @description (spl_fleet_switch_tick) when no seat of the role on this
# @description machine passes its able + stuck test and the holder has been
# @description silent past the next vendor's wait (LEASE_STALE +
# @description LEASE_FALLBACK_WAIT per vendor step). One seat, one process: no
# @description standby seat (SPL-2532 is retired). The seat keeps ONE spool dir,
# @description inbox, handoff and lease key (SPL-1685, SPEC-spool-fleet-roles.md 4.4):
# @description   1. the role's rotation lock (rotate.orch.lock /
# @description      rotate.dispatch.lock, flock -n): never inside an hourly
# @description      rotation; a rotation left in flight = SKIP; then the id lock
# @description   2. the seat is checked again: able now = SKIP
# @description   3. the next vendor after the seat's (LEASE_*_FALLBACK, else
# @description      LEASE_VENDOR_ORDER) that passes its guards (grok:
# @description      spl_rotate_grok_why; agy: lane-mix + the lease counting
# @description      it), whose wait has run (ROLE_FAILOVER_SILENT) and that is
# @description      not backed off; none = SKIP
# @description   4. role-seat-switch.sh OLD NEW (the dir moves, every other
# @description      letter links to it), then NEW must be its own real dir:
# @description      a switch never writes another seat's lifetime/prompt.txt
# @description   5. the vendor starts in the seat (spl_rotate_spawn: the old
# @description      window renamed -retiring, SPAWN_REUSE_ID=1, the start
# @description      check, the identity map) with a seed naming the role and a
# @description      handoff; ROLE_FAILOVER_SETTLE s later the lease's own able
# @description      test (spl_fleet_try) judges it, and then a proof of WORK
# @description      (SPL-2609): the switch sent the seat a probe task on the
# @description      spool, in its inbox, carrying the rotation's ACK command
# @description      (spl_rotate_ack_send, as do_spl_orch_rotate's ack; here
# @description      ROLE_FAILOVER_CMD=ack); the seat is able only once that
# @description      ack is in its outbox within ROLE_FAILOVER_ACK_WAIT s. The
# @description      lease's test alone passes for a session that started and
# @description      sits at an idle prompt (its stuck check fires only on an
# @description      unread inbox older than LEASE_UNREAD_MAX, 600 s)
# @description   6. able: lease.conf LEASE_ORCH / LEASE_MASTER = NEW, the old
# @description      process ended (/exit, TERM, KILL), its window closed, the
# @description      seat recorded in role-failover/seat.<NNN> (the rotation
# @description      hands it back once claude can act: spl_rotate_failover_vendor)
# @description   7. any failure in 4-6: the new session closed, the dirs
# @description      switched back, the links the switch made for the seat's
# @description      other letters removed and the seat's lifetime/prompt.txt
# @description      put back (SPL-2865: 2026-10-22 a failed grok switch left
# @description      g-001 -> c-001 and the grok seed in c-001's prompt),
# @description      lease.conf untouched (or put back), that
# @description      vendor backed off ROLE_FAILOVER_BACKOFF s, the next one tried
# @description The seat is checked again after a vendor's guards, right before
# @description its switch: able = SKIP (SPL-2865: the guards take minutes, and a
# @description seat refused on a fresh watchdog HIT was able by then).
# @description One line per step in <spool root>/dispatch/rotate.log (rid
# @description <ts>-failover-<role>) and role-failover.log. Dry run unless DRY_RUN=0.
# @param ROLE_FAILOVER_ROLE (required) - orch | dispatch
# @param ROLE_FAILOVER_SEAT (optional) - the seat id the lease saw; checked against lease.conf
# @param ROLE_FAILOVER_SILENT (optional) - s the holder has been silent (from the lease); a vendor whose wait has not run is skipped; empty = no wait check (a hand run)
# @param ROLE_FAILOVER_SETTLE (optional) - s between the start and the able test, default 30
# @param ROLE_FAILOVER_ACK_WAIT (optional) - s the new seat gets, after the able test, to run the probe's ack, default 300 (grok role sessions acked 12-17 s after their start in the rotations of 2026-10-18/19, n=7)
# @param ROLE_FAILOVER_CMD (optional) - switch (default) | ack: run BY the new seat, with ROTATE_ID=<the probe's id>, as its probe task states
# @param ROLE_FAILOVER_BACKOFF (optional) - s a vendor that failed for a seat is not tried again, default 1800
# @param ROLE_FAILOVER_EXIT_WAIT (optional) - s the old session gets after /exit before TERM, default 30
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ROLE_FAILOVER_ROLE=orch ./run -a do_spl_role_failover
# @example ROLE_FAILOVER_ROLE=dispatch DRY_RUN=0 ./run -a do_spl_role_failover
# @example ROLE_FAILOVER_CMD=ack ROLE_FAILOVER_ROLE=orch ROTATE_ID=20261019T2000Z-failover-g-001 ./run -a do_spl_role_failover
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"
# the dispatcher brief a dispatch seat's seed starts with (spl_disp_seed_brief)
declare -F spl_disp_seed_brief >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-rotate.func.sh"

do_spl_role_failover() {
  spl_rotate_conf || return 1
  local role="${ROLE_FAILOVER_ROLE:-}" fam key seat old rid v n=0
  case "$role" in
    orch) fam=orch key=LEASE_ORCH ;;
    dispatch) fam=dispatch key=LEASE_MASTER ;;
    *) do_log "FATAL ROLE_FAILOVER_ROLE must be orch or dispatch, got: '$role'"; return 1 ;;
  esac
  [[ "${ROLE_FAILOVER_SETTLE:=30}" =~ ^[0-9]+$ && "${ROLE_FAILOVER_BACKOFF:=1800}" =~ ^[0-9]+$ && "${ROLE_FAILOVER_EXIT_WAIT:=30}" =~ ^[0-9]+$ && "${ROLE_FAILOVER_ACK_WAIT:=300}" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL ROLE_FAILOVER_SETTLE, ROLE_FAILOVER_BACKOFF, ROLE_FAILOVER_EXIT_WAIT and ROLE_FAILOVER_ACK_WAIT must be whole seconds"; return 1; }
  RF_DIR="$LEASE_DIR/role-failover" RF_LOG="$LEASE_DIR/role-failover.log"
  case "${ROLE_FAILOVER_CMD:-switch}" in
    switch) ;;
    ack) spl_role_failover_ack "$role"; return $? ;;
    *) do_log "FATAL ROLE_FAILOVER_CMD must be switch or ack, got: '$ROLE_FAILOVER_CMD'"; return 1 ;;
  esac
  rid="$(spl_rotate_new_rid "failover-$role")"
  # the old and the new session are different vendors (spl_rotate_cli reads it)
  # shellcheck disable=SC2034
  ROTATE_CLI_KINDS="claude grok agy mistral"
  old="${!key:-}"
  [[ "$old" =~ ^${SPL_ROLE_SEAT_RX}$ ]] || { spl_role_failover_say "$rid" SKIP "$key='$old' in $LEASE_CONF is no role seat id"; return 0; }
  seat="$(spl_fleet_seat_id "$old")"
  [[ -z "${ROLE_FAILOVER_SEAT:-}" || "$ROLE_FAILOVER_SEAT" == "$seat" || "$ROLE_FAILOVER_SEAT" == "$old" ]] ||
    { spl_role_failover_say "$rid" SKIP "the lease saw seat $ROLE_FAILOVER_SEAT, lease.conf has $key=$old ($seat): moved meanwhile"; return 0; }
  if [[ "${DRY_RUN:-1}" == 0 ]]; then
    mkdir -p "$RF_DIR" || { do_log "FATAL cannot create $RF_DIR"; return 1; }
    exec 7>> "$LEASE_DIR/rotate.$fam.lock"
    flock -n 7 || { spl_role_failover_say "$rid" SKIP "an hourly rotation holds rotate.$fam.lock"; return 0; }
  fi
  local ph
  ph="$(ROTATE_STATE_DIR="" spl_rotate_ctx_load "$fam" && echo "$ROTATE_RID $ROTATE_PHASE" || true)"
  # this run's own .state / .ctx: <lease dir>/role-failover/rotate.failover-<role>.*
  # (per role: an orch and a dispatch switch at once keep their own probe ctx)
  # shellcheck disable=SC2034 # read by spl_rotate_log / spl_rotate_spawn
  ROTATE_FAMILY="failover-$role" ROTATE_STATE_DIR="$RF_DIR"
  if [[ -n "$ph" ]] && spl_disp_in_flight "${ph#* }"; then
    spl_role_failover_say "$rid" SKIP "rotation ${ph% *} is in flight at ${ph#* } (rotate.$fam.ctx): it resumes first"; return 0
  fi
  if spl_fleet_try "$seat" >/dev/null; then
    spl_role_failover_say "$rid" SKIP "$seat can act again: nothing to switch"; return 0
  fi
  for v in $(spl_fleet_fallback "$role"); do
    (( $(spl_fleet_vtier "$v") > $(spl_fleet_vtier "$(spl_fleet_seat_vendor "$seat")") )) || continue
    n=$((n + 1))
    spl_role_failover_vendor "$rid" "$role" "$key" "$old" "$seat" "$v" && return 0
  done
  (( n )) || spl_role_failover_say "$rid" SKIP "$seat ($(spl_fleet_vendor "$seat")) cannot act and no vendor is left after it (fallback: '$(spl_fleet_fallback "$role")')"
  return 0
}

# spl_role_failover_say RID RESULT DETAIL: a rotate.log line (spl_rotate_log)
# and the same in role-failover.log (not in a dry run, not for PLAN).
spl_role_failover_say() {
  spl_rotate_log "$1" SWITCH "$2" "$3"
  [[ "${DRY_RUN:-1}" == 1 || "$2" == PLAN ]] && return 0
  echo "$(date -u +%FT%TZ) $ROTATE_BOX $1 $2 $3" >> "$RF_LOG"
}

# spl_role_failover_vendor RID ROLE KEY OLD SEAT VENDOR: one vendor tried.
# 0 = the seat runs VENDOR now (or a dry run planned it); 1 = try the next.
spl_role_failover_vendor() {
  local rid="$1" role="$2" key="$3" old="$4" seat="$5" v="$6" new why wait bo t=""
  new="$(spl_role_seat_id "${v%2}" "$(spl_role_seat_num "$seat")")" ||
    { spl_role_failover_say "$rid" SKIP "no $v id for seat $seat"; return 1; }
  wait=$(( LEASE_STALE + $(spl_fleet_vtier "$v") * ${LEASE_FALLBACK_WAIT:-60} ))
  if [[ "${ROLE_FAILOVER_SILENT:-}" =~ ^[0-9]+$ ]] && (( ROLE_FAILOVER_SILENT <= wait )); then
    spl_role_failover_say "$rid" SKIP "$v not yet: the holder is silent ${ROLE_FAILOVER_SILENT}s, $v takes a seat past ${wait}s"; return 1
  fi
  bo="$RF_DIR/refused.$(spl_role_seat_num "$seat").$v"
  read -r t why 2>/dev/null < "$bo" || t=""
  if [[ "$t" =~ ^[0-9]+$ ]] && (( $(date +%s) - t < ROLE_FAILOVER_BACKOFF )); then
    spl_role_failover_say "$rid" SKIP "$v backed off for seat $seat: failed $(( ($(date +%s) - t) / 60 )) min ago ($why)"; return 1
  fi
  why="$(spl_role_failover_guard "$v")"
  [[ -z "$why" ]] || { spl_role_failover_say "$rid" SKIP "$v cannot take seat $seat: $why"; return 1; }
  # the guards take minutes (lane-mix): the seat may act again by now
  if spl_fleet_try "$seat" >/dev/null; then
    spl_role_failover_say "$rid" SKIP "$seat can act again (checked after the $v guards): nothing to switch"; return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_role_failover_say "$rid" PLAN "$seat ($(spl_fleet_vendor "$seat")) cannot act ($(spl_role_failover_able "$seat")): $seat -> $new in place (role-seat-switch.sh), start $v $new@$ROTATE_BOX in the seat (spawn-window.sh SPAWN_REUSE_ID=1), able ${ROLE_FAILOVER_SETTLE}s later = lease.conf $key=$new and the old session ended"
    echo "OK DRY_RUN nothing was switched. Re-run with DRY_RUN=0."
    return 0
  fi
  local idl=0
  spl_agent_id_lock "$seat" do_spl_role_failover "$rid" || idl=$?
  (( idl == 0 )) || { spl_role_failover_say "$rid" SKIP "id lock: $SPL_ID_LOCK_WHY"; return 0; }
  if spl_role_failover_run "$rid" "$role" "$key" "$old" "$seat" "$v" "$new"; then
    rm -f "$bo"; spl_agent_id_unlock "$seat"; return 0
  fi
  printf '%s %s\n' "$(date +%s)" "$(tr '\n' ' ' <<<"$ROTATE_ERR" | cut -c1-200)" > "$bo"
  spl_agent_id_unlock "$seat"
  return 1
}

# spl_role_failover_guard VENDOR: why VENDOR cannot take a role seat, nothing
# when it can. grok: the rotation's guard (spl_rotate_grok_why); agy: lane-mix
# with an agy=100 row (CLI, sign-in, limit) and a lease that counts agy.
spl_role_failover_guard() {
  local out pick why
  case "$1" in
    grok) spl_rotate_grok_why ;;
    agy)
      out="$(env LANE_MIX_KIND=orchestration LANE_MIX_SPLIT_KIND="claude=0 grok=0 agy=100 qwen=0 mistral=0 backup=claude" \
        timeout "${ROTATE_SRC_TIMEOUT:-120}" "$ROTATE_RUN" -a do_spl_lane_mix 2>&1 7>&- 8>&- 9>&-)" || true
      pick="$(grep -m1 -oE '^pick=[a-z]+' <<<"$out" | cut -d= -f2 || true)"
      if [[ "$pick" != agy ]]; then
        why="$(sed -nE 's/^agy .* skip \((.*)\); share to .*/\1/p' <<<"$out")"; why="${why%%$'\n'*}"
        echo "${why:-lane-mix gave '${pick:-no pick}'}"; return 0
      fi
      spl_rotate_lease_sees agy || echo "the fleet lease does not count an agy process as the holder" ;;
    claude2) spl_role_failover_claude2_why ;;
    *) echo "$1 is no role vendor here (grok, agy, claude2)" ;;
  esac
  return 0
}

# The second login's config folder (SPL-2943): CLAUDE2_CONFIG_DIR, else
# <agent home>/.claude-2. The one setting; the owner logs in there once.
spl_role_failover_claude2_dir() { echo "${CLAUDE2_CONFIG_DIR:-${ROTATE_AGENT_HOME:-$HOME}/.claude-2}"; }

# Why claude under the second login cannot take a seat; nothing when it can:
# the agent user's claude, run with CLAUDE_CONFIG_DIR=<that folder>, says
# `auth status` loggedIn true. No login there yet = the step is dormant.
# Reads the status only, never a credential file.
spl_role_failover_claude2_why() {
  local dir bin st
  dir="$(spl_role_failover_claude2_dir)"
  bin="${ROTATE_CLAUDE_BIN:-${CLAUDE_BIN:-${ROTATE_AGENT_HOME:-$HOME}/.local/bin/claude}}"
  spl_rotate_as_agent test -d "$dir" 2>/dev/null || { echo "no second login: the folder CLAUDE2_CONFIG_DIR does not exist (dormant)"; return 0; }
  st="$(spl_rotate_as_agent env CLAUDE_CONFIG_DIR="$dir" timeout "${ROTATE_SRC_TIMEOUT:-120}" "$bin" auth status 2>/dev/null |
    jq -r '.loggedIn // false' 2>/dev/null || true)"
  [[ "$st" == true ]] || echo "no second login: claude auth status in CLAUDE2_CONFIG_DIR is not loggedIn (dormant)"
  return 0
}

# Why the lease's test refused ID, one line.
spl_role_failover_able() { cat "$LEASE_DIR/able.$1" 2>/dev/null | tr '\n' ' ' | cut -c1-160; }

# spl_role_failover_own ID: 0 when <spool root>/ID is a real dir of its own
# (no link, not resolving to another id): the only dir a start may write.
spl_role_failover_own() {
  [[ -d "$SPOOL_ROOT/$1" && ! -L "$SPOOL_ROOT/$1" ]] &&
    [[ "$(readlink -f "$SPOOL_ROOT/$1")" == "$(readlink -f "$SPOOL_ROOT")/$1" ]]
}

# spl_role_failover_run RID ROLE KEY OLD SEAT VENDOR NEW: steps 4-7. Non-zero =
# failed and put back, ROTATE_ERR says why.
spl_role_failover_run() {
  local rid="$1" role="$2" key="$3" old="$4" seat="$5" v="$6" new="$7" opid opane seed rec ack arc
  # claude2 (SPL-2943): claude, started with CLAUDE_CONFIG_DIR = the second login
  # shellcheck disable=SC2034 # spl_rotate_spawn reads it
  ROTATE_CLAUDE_CONFIG_DIR="$(if [[ "$v" == claude2 ]]; then spl_role_failover_claude2_dir; fi)"
  # shellcheck disable=SC2034 # the rotation globals spl_rotate_spawn / _restore / _end read
  ROTATE_RID="$rid" ROTATE_KIND="${v%2}" \
    ROTATE_NEW_PID="" ROTATE_NEW_PANE="" ROTATE_NEW_DIALOG="" ROTATE_SWITCH_FROM="$seat" ROTATE_SWITCH_TO="$new" \
    ROTATE_LANE_SCOPE="role $new $role (vendor failover from $seat)" ROTATE_ERR=""
  opid="$(spl_lease_agent_pid "$seat")"
  opane=""; [[ -n "$opid" ]] && opane="$(spl_rotate_pane_of_pid "$opid")"
  # shellcheck disable=SC2034 # read by spl_rotate_spawn / spl_rotate_restore
  ROTATE_OLD_PID="$opid" ROTATE_OLD_PANE="$opane"
  # shellcheck disable=SC2034
  ROTATE_OLD_NAME="$([[ -n "$opane" ]] && spl_rotate_tmux display-message -p -t "$opane" '#{window_name}' 2>/dev/null || true)"
  spl_role_failover_say "$rid" WAIT "$seat ($(spl_fleet_vendor "$seat"), pid ${opid:-none}, pane ${opane:-none}) cannot act ($(spl_role_failover_able "$seat")): switching it to $v as $new"
  ROTATE_HANDOFF="$ROTATE_HANDOFF_DIR/$rid-$seat.md"
  mkdir -p "$ROTATE_HANDOFF_DIR" 2>/dev/null || true
  ROTATE_QUIESCE="not run (vendor failover: the seat cannot act)" ROTATE_ASKS_ROLE="$role" spl_rotate_handoff "$role" "$seat" "$rid" "$ROTATE_HANDOFF"
  chmod 0640 "$ROTATE_HANDOFF" 2>/dev/null || true
  seed="$ROTATE_HANDOFF_DIR/$rid-$new.seed.md"
  spl_role_failover_seed "$role" "$seat" "$new" > "$seed" && chmod 0644 "$seed" 2>/dev/null ||
    { ROTATE_ERR="cannot write the seed $seed"; spl_role_failover_say "$rid" FAIL "$ROTATE_ERR"; return 1; }
  spl_role_failover_snap "$rid" "$seat" "$new"
  # a claude seat to claude2 keeps its id: a restart in place, no dir switch
  if [[ "$new" != "$seat" ]] && ! spl_rotate_seat_switch "$seat" "$new"; then
    spl_role_failover_say "$rid" FAIL "$ROTATE_ERR; nothing started"; return 1
  fi
  if ! spl_role_failover_own "$new"; then
    ROTATE_ERR="after the switch $SPOOL_ROOT/$new is not a dir of its own ($(readlink -f "$SPOOL_ROOT/$new" 2>/dev/null || echo missing)): a start there would write another seat's prompt"
    spl_role_failover_back "$rid" "$seat" "$new" "$opane"; return 1
  fi
  if ! spl_rotate_spawn "$new" "$seed"; then
    spl_role_failover_back "$rid" "$seat" "$new" "$opane"; return 1
  fi
  # a restart in place (claude2 on a claude seat): the old session cannot
  # act and shares the id, so every able test would read it (the lowest
  # pid): it ends now, not after the new one is judged
  if [[ "$new" == "$seat" && -n "$opid" ]]; then
    spl_rotate_end "${opane:-none}" "$opid" /exit "$ROLE_FAILOVER_EXIT_WAIT" "$ROTATE_TERM_WAIT" || true
    [[ -n "$opane" ]] && { spl_rotate_tmux kill-window -t "$opane" 2>/dev/null || true; }
    spl_role_failover_say "$rid" OK "the old session (pid $opid) of $seat ended before the able test (restart in place)"
    opid="" opane=""
  fi
  ack="${rid%%-*}-failover-$new"
  spl_role_failover_probe "$rid" "$role" "$new" "$ack"
  sleep "$ROLE_FAILOVER_SETTLE"
  if ! spl_fleet_try "$new" >/dev/null; then
    ROTATE_ERR="$v $new (pid $ROTATE_NEW_PID) not able ${ROLE_FAILOVER_SETTLE}s after the start: $(spl_role_failover_able "$new")"
    spl_role_failover_back "$rid" "$seat" "$new" "$opane"; return 1
  fi
  spl_role_failover_say "$rid" WAIT "$new is up and not stuck; up to ${ROLE_FAILOVER_ACK_WAIT}s for its ack of the probe $ack (proof of work)"
  arc=0; spl_rotate_ack_wait "$new" "$ack" "$ROLE_FAILOVER_ACK_WAIT" || arc=$?
  if (( arc )); then
    ROTATE_ERR="$v $new (pid $ROTATE_NEW_PID) not able: $( ((arc == 2)) && echo "it ended before it acked the probe $ack" || echo "no ack of the probe $ack within ${ROLE_FAILOVER_ACK_WAIT}s (up, but it did no work)")"
    printf '%s\n' "$ROTATE_ERR" > "$LEASE_DIR/able.$new" 2>/dev/null || true
    spl_role_failover_back "$rid" "$seat" "$new" "$opane"; return 1
  fi
  spl_role_failover_say "$rid" OK "$new acked the probe $ack: it read its inbox and ran the command"
  if [[ "$old" != "$new" ]] && ! spl_rotate_conf_flip "$key" "$old" "$new"; then
    spl_role_failover_back "$rid" "$seat" "$new" "$opane"; return 1
  fi
  spl_role_failover_say "$rid" OK "$new ($v, pid $ROTATE_NEW_PID, pane $ROTATE_NEW_PANE) runs the $role seat; lease.conf $key=$new"
  [[ "${RF_PROMPT:-}" == "$RF_DIR/"* ]] && rm -f "$RF_PROMPT"
  rec="$seat $new $v $rid $(date +%s)"
  # the first claude id the seat left stays the one it goes back to
  [[ -s "$RF_DIR/seat.$(spl_role_seat_num "$new")" ]] && rec="$(cut -d' ' -f1 "$RF_DIR/seat.$(spl_role_seat_num "$new")") $new $v $rid $(date +%s)"
  echo "$rec" > "$RF_DIR/seat.$(spl_role_seat_num "$new")"
  if [[ -n "$opid" ]]; then
    if spl_rotate_end "${opane:-none}" "$opid" /exit "$ROLE_FAILOVER_EXIT_WAIT" "$ROTATE_TERM_WAIT"; then
      [[ -n "$opane" ]] && { spl_rotate_tmux kill-window -t "$opane" 2>/dev/null || true; }
      spl_role_failover_say "$rid" OK "the old session (pid $opid) ended"
    else
      spl_role_failover_say "$rid" FAIL "the old session (pid $opid) survived SIGKILL: two processes on seat $(spl_role_seat_num "$new")"
      spl_rotate_alert "$([[ "$role" == orch ]] && echo orch || echo master)" "$rid" SWITCH "old pid $opid of $seat survived SIGKILL after the switch to $new"
    fi
  fi
  [[ "$seat" != "$new" && -e "$SPOOL_ROOT/agents/$seat.json" ]] && { spl_rotate_ai retire "$seat" "$rid" >/dev/null 2>&1 || true; }
  spl_rotate_note "$new" "$(spl_rotate_ack_task "$rid")" \
    "VENDOR FAILOVER $rid on $ROTATE_BOX: seat $seat ($(spl_fleet_vendor "$seat")) could not act; $new ($v, pid $ROTATE_NEW_PID) runs the $role seat now, same inbox. The lease names it at its next tick; the hourly rotation hands it back once claude can act. Log: $ROTATE_LOG" result
  return 0
}

# spl_role_failover_probe RID ROLE NEW ACK: the proof-of-work probe
# (SPL-2609). ACK is RID's time + failover + NEW: one per seat and vendor
# tried, in the form spl_rotate_ack_send takes. The run's ctx is saved under
# it at phase ACK, so the ack sender accepts it only from the new pid. A task
# on the spool to NEW (its inbox, poked) carries the ACK command; the ack
# lands as a result in NEW's outbox (spl_rotate_ack_seen). The command is in
# the inbox only, never in the seed or the first prompt: a seat that does
# not read its inbox never acks.
spl_role_failover_probe() {
  local rid="$1" role="$2" new="$3" ack="$4" cmd rid0="$ROTATE_RID"
  # shellcheck disable=SC2034 # saved in the ctx the ack sender loads
  ROTATE_PHASE=ACK ROTATE_RID="$ack"
  spl_rotate_ctx_save "$ROTATE_FAMILY"
  ROTATE_RID="$rid0"
  cmd="cd $PROJ_PATH && sudo -u ${SPOOL_BOX_USER:-$USER} env SPOOL_ROOT=$SPOOL_ROOT ROLE_FAILOVER_CMD=ack ROLE_FAILOVER_ROLE=$role ROTATE_ID=$ack ./run -a do_spl_role_failover"
  spl_rotate_note "$new" "$(spl_rotate_ack_task "$ack")" \
    "PROBE $ack: you are $new@$ROTATE_BOX, the $role seat after a vendor failover. Run this ack now, exactly, before anything else: ACK-COMMAND: $cmd ; without it within ${ROLE_FAILOVER_ACK_WAIT}s of your start check this seat is not able and the switch is rolled back." task
  spl_role_failover_say "$rid" WAIT "probe $ack sent to $new's inbox (task $(spl_rotate_ack_task "$ack"))"
}

# spl_role_failover_ack ROLE: ROLE_FAILOVER_CMD=ack, run by the new seat:
# the rotation's ack sender (spl_rotate_ack_send: the probe in flight at
# phase ACK, the caller the new pid) on the failover's own ctx.
spl_role_failover_ack() {
  # shellcheck disable=SC2034 # read by spl_rotate_family / spl_rotate_log / spl_rotate_ctx_*
  local ROTATE_FAMILY="failover-$1" ROTATE_STATE_DIR="$RF_DIR" ROTATE_CMD=ack
  if ! spl_rotate_ctx_load "$ROTATE_FAMILY" || [[ -z "$ROTATE_SWITCH_TO" ]]; then
    do_log "FATAL no vendor failover of the $1 seat waits for an ack ($RF_DIR/rotate.$ROTATE_FAMILY.ctx)"; return 3
  fi
  spl_rotate_ack_send "$1" "$ROTATE_SWITCH_TO"
}

# spl_role_failover_snap RID SEAT NEW: what a switch back must undo, taken
# before the switch: the ids of the seat with no entry in the spool root
# (RF_MADE; the switch links each to NEW) and the seat's lifetime/prompt.txt
# (RF_PROMPT, a copy in RF_DIR; empty = the seat had none).
spl_role_failover_snap() {
  local id p="$SPOOL_ROOT/$2/lifetime/prompt.txt"
  RF_MADE="" RF_PROMPT="$RF_DIR/$1-$2.prompt.txt"
  for id in $(spl_role_seat_ids "$3"); do
    [[ -e "$SPOOL_ROOT/$id" || -L "$SPOOL_ROOT/$id" ]] || RF_MADE+="$id "
  done
  if [[ -f "$p" ]]; then cp -p "$p" "$RF_PROMPT" 2>/dev/null || RF_PROMPT="?"
  else RF_PROMPT=""; fi
}

# spl_role_failover_undo SEAT: after the switch back, the links the switch
# made (RF_MADE, still a link to SEAT) removed and SEAT's lifetime/prompt.txt
# (the new vendor's seed now) put back from RF_PROMPT. Prints what it did.
spl_role_failover_undo() {
  local seat="$1" id gone="" p="$SPOOL_ROOT/$1/lifetime/prompt.txt"
  for id in ${RF_MADE:-}; do
    [[ -L "$SPOOL_ROOT/$id" && "$(readlink "$SPOOL_ROOT/$id")" == "$seat" ]] && rm -f "$SPOOL_ROOT/$id" && gone+="$id "
  done
  [[ -n "$gone" ]] && printf '; links removed: %s' "${gone% }"
  case "${RF_PROMPT:-}" in
    "?") printf '; prompt.txt NOT put back (no copy taken)' ;;
    "") rm -f "$p" && printf '; the seed in prompt.txt removed (it had none)' ;;
    *) if cp "$RF_PROMPT" "$p" 2>/dev/null; then rm -f "$RF_PROMPT"; printf '; prompt.txt put back'
       else printf '; prompt.txt NOT put back (copy in %s)' "$RF_PROMPT"; fi ;;
  esac
}

# spl_role_failover_back RID SEAT NEW OLD_PANE: a failed switch put back: the
# new session closed, the dirs back to SEAT, the links the switch made and
# SEAT's prompt.txt undone, the old window's name back; lease.conf was not
# written yet.
spl_role_failover_back() {
  local rid="$1" seat="$2" new="$3" back=""
  spl_rotate_restore "$seat" "$4" "${ROTATE_NEW_PANE:-}"
  if [[ "$new" == "$seat" ]]; then back="; $seat restarted in place, no dir switch to undo"
  elif spl_rotate_seat_switch "$new" "$seat"; then back="; seat switch back $new -> $seat$(spl_role_failover_undo "$seat")"
  else back="; the seat switch back FAILED ($ROTATE_ERR), $seat links to $new"; fi
  spl_role_failover_say "$rid" FAIL "$ROTATE_ERR$back; lease.conf untouched"
}

# The seed of the switched seat (a brief file for spawn-window.sh).
spl_role_failover_seed() {
  local role="$1" seat="$2" new="$3" as="${SPOOL_BOX_USER:-$USER}" brief=""
  [[ "$role" == dispatch ]] && brief="$(spl_disp_seed_brief "$new" 2>/dev/null || true)"
  if [[ -n "$brief" ]]; then printf '%s\n\n' "$brief"
  else echo "# Brief: you are the $role seat $new@$ROTATE_BOX"; echo; fi
  cat <<EOF
## Vendor failover $ROTATE_RID (SPL-2544)

You are $new@$ROTATE_BOX, the $role seat. The previous $seat session could
not act (the fleet lease's able test: $(spl_role_failover_able "$seat")), so
this seat switched vendor in place: same seat, same inbox (every letter of
the seat links to $SPOOL_ROOT/$new), same lease key. Read $ROTATE_HANDOFF,
then your inbox (spool recv --as $new): its PROBE task carries an
ACK-COMMAND, run it first; without that ack within ${ROLE_FAILOVER_ACK_WAIT}s this switch
is rolled back. Then act in your role:
$ROTATE_SPEC section 1 ($role), 4.1 (fleet lease), 4.3 (asks).
Do not greet; post nothing about the switch.

The fleet lease names you at its next tick and tells you ACTIVE; until then
read and stay ready. Check it with:
cd $PROJ_PATH && sudo -u $as env SPOOL_ROOT=$SPOOL_ROOT LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease
The hourly rotation hands the seat back to claude once claude can act.
Never run /exit-clean and never close this window.
EOF
}
