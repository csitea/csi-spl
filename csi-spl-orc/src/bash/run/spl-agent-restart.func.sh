#!/bin/bash
#------------------------------------------------------------------------------
# @description The one restart path of spec 102 section 4.1: end a session of
# @description <id> (planned or not) and start the next one under the same id,
# @description same harness, same worktree. The watchdog is its only automatic
# @description caller (spl_wd_takeover); a seat may request it (exit 3 when
# @description nothing hits). Built from the takeover's phases
# @description (spl-wd-takeover.func.sh), with its own order per kind:
# @description LANE (stop first: two sessions never share one worktree)
# @description   GATE     - a restart slot (peer/restart.slot.<n>, RESTART_SLOTS,
# @description              lanes 1..n), the id lock (4.2), done / retired =
# @description              refused (exit 3), the 6.2 guards (not the human
# @description              ones at hard-end, R3), held out = refused (the hold
# @description              never expires), the limits of 6 (ONE counter
# @description              lifetime/restarts, RESTART_MAX_PER_HOUR; the task
# @description              caps REBIRTH_MAX / TASK_RESTART_MAX), and for a
# @description              crash or a rebirth the situation re-run
# @description   RETIRE   - TERM, KILL after ROTATE_TERM_WAIT (nothing when the
# @description              agent already exited: rebirth, S3)
# @description   CLEANUP  - a stale .git/index.lock (no git process in the
# @description              worktree) removed; a rebase or merge noted
# @description   WIP      - do_spl_lane_wip_push from the quiet tree
# @description   HANDOFF  - do_spl_agent_handoff and its snapshot
# @description              <id>/handoff/<rid>.md (+ `## watchdog` for a crash);
# @description              the rebirth marker consumed (lifetime/last-rebirth)
# @description   SEED     - lifetime text + counts + the brief + the handoff;
# @description              a new lifetime/session.json
# @description   SPAWN    - SPAWN_REUSE_ID=1; not started in WD_START_WAIT:
# @description              nothing runs, the watchdog's episode flag is
# @description              cleared so the next tick retries; a claude
# @description              parked on a known dialog (Settings Warning,
# @description              trust, login, usage limit, auto-mode offer;
# @description              ROTATE_START_CHECK_WAIT, 45 s) fails at once,
# @description              named, and is alerted (ask + owner DM)
# @description   REPORT   - crash: one blocker wd-<id>-<ts> to the peers;
# @description              planned: ONE line to the orchestrator,
# @description              `REBORN <id>@<box> #<n> cause=<c> handoff=<path>`;
# @description              one that does not leave (no relay yet) is
# @description              journaled in <wd>/report.queue and resent until
# @description              it does (RS-REPORT QUEUED, then OK);
# @description              an id with an open FAIL alert also gets its asks
# @description              closed and ONE "recovered at <ts> by <action>, now
# @description              pid <pid>" line to the owner (spl_rotate_recovered)
# @description   LOG      - rotate.log phases RS-*, the last DONE; one
# @description              agent_lifecycle_events row when that action exists
# @description SEAT (start first, slot 0): GATE, rotate.hold (role ids), the
# @description poll loop stopped, HANDOFF, SEED, SPAWN, the ack (a result on
# @description task restart-<rid> in its outbox within ROTATE_ACK_TIMEOUT),
# @description RETIRE the old session, REPORT, LOG. A failed start or ack
# @description keeps the old session; at hard-end it is retired anyway (R2).
# @description Past RESTART_MAX_PER_HOUR or a task cap the id is held out
# @description (lifetime/heldout, until the admin clears it) and the admin
# @description gets ONE message. Dry run unless DRY_RUN=0.
# @description Exit: 0 done (or planned), 1 failed, 3 nothing to restart (no hit, done, retired), 4 refused by a guard, a lock or a limit.
# @param ID - required: the agent id (<id>@<this box> accepted)
# @param CAUSE - required: rebirth | hard-end | S1 | S3 | S4 | S5 | S7 | S9 | reboot | box-down | login-reset
# @param DRY_RUN (optional) - 1 (default): PLAN lines, nothing touched; 0: act
# @param WD_EVIDENCE (optional) - the watchdog's evidence line (set by do_spl_watchdog)
# @param RESTART_SLOTS (optional) - lane restarts at once on this box, default 4
# @param RESTART_MAX_PER_HOUR (optional) - restarts of one id per rolling hour, default 3 (env until T011)
# @param REBIRTH_MAX / TASK_RESTART_MAX (optional) - per task, default 7 / 12 (env until T011)
# @param HARD_END (optional) - seconds of session age for CAUSE=hard-end, default 7200
# @param WD_START_WAIT (optional) - seconds for the new session to start, default 120
# @param ARS_REPORT_RETRY (optional) - seconds between resends of a journaled report, default 30; 0: only the next report resends it
# @param ARS_REPORT_TTL (optional) - seconds a journaled report is resent before it is dropped (RS-REPORT FAIL), default 21600
# @param ARS_REPORT_QUEUE (optional) - 1 (default): journal a report that did not leave; 0: log RS-REPORT FAIL and lose it (the old way)
# @param ROTATE_SPAWN / ROTATE_TMUX / ROTATE_KILL / WD_SEND / LEASE_PROC_ROOT (optional) - the seams (tests)
# @example ID=c-007 CAUSE=rebirth ./run -a do_spl_agent_restart
# @example ID=c-007 CAUSE=S3 DRY_RUN=0 ./run -a do_spl_agent_restart
#------------------------------------------------------------------------------
declare -F spl_wdt_gate >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-takeover.func.sh"
declare -F do_spl_agent_handoff >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-agent-handoff.func.sh"
declare -F do_spl_lane_wip_push >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-wip-push.func.sh"

ARS_CAUSES="rebirth hard-end S1 S3 S4 S5 S7 S9 reboot box-down login-reset"

do_spl_agent_restart() {
  local id="${ID:-}" cause="${CAUSE:-}" req="${REQ_FROM:-${SPOOL_AGENT_ID:-}}" box=""
  if [[ "$id" == *@* ]]; then box="${id#*@}"; id="${id%@*}"; fi
  [[ "$id" =~ ^[acgq]-[0-9]{3}$ ]] || { do_log "FATAL ID must be an agent id (c-NNN), got: '${ID:-}'"; return 1; }
  [[ " $ARS_CAUSES " == *" $cause "* ]] || { do_log "FATAL CAUSE must be one of: $ARS_CAUSES; got: '$cause'"; return 1; }
  spl_wd_init || return 1
  spl_peer_init ro || return 1
  if [[ -n "$box" && "$box" != "$ROTATE_BOX" && "$box" != "${SPOOL_BOX_TAG:-}" ]]; then
    do_log "FATAL $id@$box is not on this box ($ROTATE_BOX): a restart runs on the agent's own box"; return 1
  fi
  : "${WD_START_WAIT:=120}" "${RESTART_SLOTS:=4}" "${RESTART_MAX_PER_HOUR:=3}" "${REBIRTH_MAX:=7}" "${TASK_RESTART_MAX:=12}" "${HARD_END:=7200}"
  local k
  for k in WD_START_WAIT RESTART_SLOTS RESTART_MAX_PER_HOUR REBIRTH_MAX TASK_RESTART_MAX HARD_END; do
    [[ "${!k}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $k must be a positive integer, got: '${!k}'"; return 1; }
  done
  # 6.3: a lane may not request a restart, nobody may request its own
  if [[ -n "$req" && -z "${WD_EVIDENCE:-}" ]]; then
    if [[ "${req%@*}" == "$id" ]]; then spl_ars_refuse "$id" 4 "$req may not request a restart of itself"; return; fi
    if [[ ! "${req%@*}" =~ -00[1-4]$ ]]; then spl_ars_refuse "$id" 4 "$req is a lane: a lane reports a stuck peer --to peers, it requests no restart"; return; fi
  fi
  local now ts rid rc=0
  now="$(spl_lease_now)"
  ts="$(date -u -d "@$now" +%Y%m%dT%H%MZ)"
  rid="$ts-rs-$id"
  ARS_SEAT="" ARS_CONSUMED=""
  if spl_ars_is_seat "$id"; then ARS_SEAT=1; fi
  mkdir -p "$PEER_DIR" || { do_log "FATAL cannot create $PEER_DIR"; return 1; }
  spl_ars_slot "$id" || return
  spl_agent_id_lock "$id" do_spl_agent_restart "$rid" || rc=$?
  (( rc == 0 )) || { spl_ars_refuse "$id" "$rc" "id lock (spec 102 4.2): $SPL_ID_LOCK_WHY"; return; }
  spl_ars_gate "$id" "$cause" "$now" || return
  spl_ars_run "$id" "$rid" "$ts" "$now"
}

# A refusal by a guard, a lock or a slot (exit 4) of the watchdog's own call
# is not a restart done: its episode flag goes, so the next tick retries once
# the guard is gone (2026-10-07: a rotate.hold refusal read "takeover
# done" for ever). A refusal never counts in lifetime/restarts.
spl_ars_refuse() {
  if [[ "$2" == 4 && -n "${WD_EVIDENCE:-}" && -n "${WD_DIR:-}" ]]; then rm -f "${WD_DIR:?}/${1:?}".ep.S*.takeover; fi
  spl_wd_log "WD-RESTART REFUSED $1: $3"
  echo "REFUSED $1: $3"
  return "$2"
}

# A seat (spec 102 section 2): ids 001..004, a peer seat, an expected seat.
spl_ars_is_seat() {
  [[ "$1" =~ -00[1-4]$ ]] && return 0
  spl_peer_seated "$1" && return 0
  grep -qx -- "$1" <<<"$(spl_wd_expected)"
}

# spl_ars_slot ID: one of the slot locks peer/restart.slot.<n> (4.2) on fd 6
# for the whole run: a lane any of 1..RESTART_SLOTS, a seat slot 0. The
# children that outlive the run close it (spawn, detach). None free = exit 4.
spl_ars_slot() {
  local n first=1 last="$RESTART_SLOTS"
  if [[ -n "$ARS_SEAT" ]]; then first=0; last=0; fi
  for (( n = first; n <= last; n++ )); do
    exec 6>> "$PEER_DIR/restart.slot.$n" || continue
    if flock -n 6; then ARS_SLOT="$n"; return 0; fi
    exec 6>&-
  done
  spl_ars_refuse "$1" 4 "no free restart slot (peer/restart.slot.$first..$last are held)"
}

# ---- GATE --------------------------------------------------------------------

# spl_ars_gate ID CAUSE NOW: 0 when the restart may run; sets ARS_PID,
# ARS_PANE, ARS_CAUSE, ARS_CODE, ARS_EV, ARS_WT and the WDT_* names the
# takeover's helpers read. Non-zero is the exit code.
spl_ars_gate() {
  local id="$1" cause="$2" now="$3" tick ctx row why hits="" hid lt age start
  local -a pids
  tick="$WD_DIR/restart.$id.tick" ctx="$WD_DIR/restart.$id.ctx"
  lt="$SPOOL_ROOT/$id/lifetime"
  rm -rf "${tick:?}" "${ctx:?}" && mkdir -p "$tick" "$ctx"
  if spl_ars_retired "$id"; then spl_ars_refuse "$id" 3 "retired (registry.retired.tsv, no open registry row): never restarted"; return; fi
  spl_wd_ps > "$tick/ps"
  spl_wd_tmux_lists "$tick"
  spl_wd_agents "$tick" > "$tick/agents"
  row="$(awk -F'\t' -v i="$id" '$1 == i {print; exit}' "$tick/agents")"
  [[ -n "$row" ]] || { spl_ars_refuse "$id" 3 "not an agent of this box (no window, no process carries it)"; return; }
  IFS=$'\t' read -r _ ARS_PID ARS_PANE <<<"$row"
  [[ "$ARS_PID" == - ]] && ARS_PID=""
  [[ "$ARS_PANE" == - ]] && ARS_PANE=""
  spl_wd_gather "$id" "$ARS_PID" "$ARS_PANE" "$now" "$tick" "$ctx"
  # 4.3: done is never restarted
  if [[ -e "$ctx/rundir_gone" ]]; then spl_ars_refuse "$id" 3 "done: its workdir $(cat "$ctx/rundir_gone") is gone"; return; fi
  start="$(cat "$ctx/session_start" 2>/dev/null || true)"
  [[ "$start" =~ ^[0-9]+$ ]] || start=0
  if [[ -s "$ctx/done" ]] && (( $(cat "$ctx/done") >= start )); then
    spl_ars_refuse "$id" 3 "done: lifetime/done is newer than the session start"; return
  fi
  if [[ -e "$lt/heldout" ]]; then spl_ars_refuse "$id" 4 "held out until the admin clears it: $(head -c 200 "$lt/heldout")"; return; fi
  why="$(spl_wd_skip "$id" "$ARS_PID" "$now" "$tick" "$ctx")"
  [[ -z "$why" ]] || { spl_ars_refuse "$id" 4 "$why"; return; }
  # R3: at the hard end a human is not honoured
  why="$(DRY_RUN=0 WD_BOX_BUSY="" WD_GATE_NO_HUMAN="$([[ "$cause" == hard-end ]] && echo 1)" spl_wd_gate "$id" "$now" "$ctx")"
  [[ -z "$why" ]] || { spl_ars_refuse "$id" 4 "$why"; return; }
  if [[ -s "$LEASE_DIR/rotate.hold" ]]; then
    read -r hid _ < "$LEASE_DIR/rotate.hold" || true
    [[ "$hid" == "$id" ]] || { spl_ars_refuse "$id" 4 "rotate.hold names ${hid:-?}: a rotation runs on this box"; return; }
  fi
  mapfile -t pids < <(spl_peer_pids "$id")
  (( ${#pids[@]} <= 1 )) || { spl_ars_refuse "$id" 4 "duplicate: ${#pids[@]} live processes carry $id (pids ${pids[*]})"; return; }
  ARS_CAUSE="$cause" ARS_CODE="" ARS_EV="${WD_EVIDENCE:-}"
  case "$cause" in
    rebirth|S1|S3|S4|S5|S7|S9)
      spl_wd_run_scripts "$id" "$ARS_PID" "$ARS_PANE" "$ctx"
      hits="$(cat "$ctx"/out.s* 2>/dev/null | grep -E '^HIT S[0-9]+( |$)' || true)"
      if ! spl_ars_pick "$cause" "$hits"; then
        spl_ars_refuse "$id" 3 "no $cause hit; hits: $(tr '\n' ';' <<<"${hits:-none}" | cut -c1-200) heartbeat: $(jq -c '{ts, event, state, progress_ts}' "$ctx/heartbeat" 2>/dev/null || echo none)"
        return
      fi ;;
    hard-end)
      age="$(spl_ars_session_age "$ctx" "$now")"
      (( age >= HARD_END )) || { spl_ars_refuse "$id" 3 "session ${age}s old, the hard end is at ${HARD_END}s"; return; }
      ARS_CODE=hard-end ARS_EV="session ${age}s old" ;;
    *) ARS_CODE="$cause" ARS_EV="${ARS_EV:-requested ($cause), no situation re-run}" ;;
  esac
  ARS_WT="$(spl_rotate_workdir "$id")"
  # shellcheck disable=SC2034 # read by the takeover helpers (spl_wdt_section, spl_wdt_spawn)
  WDT_CODE="$ARS_CODE" WDT_EV="$ARS_EV" WDT_CTX="$ctx" WDT_PID="$ARS_PID" WDT_PANE="$ARS_PANE" WDT_SEAT=""
  if spl_peer_seated "$id"; then WDT_SEAT=1; else PEER_HARNESS="$(spl_wd_harness "$id")"; fi
  [[ "$PEER_HARNESS" =~ ^(claude|grok|agy|qwen)$ ]] || PEER_HARNESS=claude
  WDT_BOXENV=""
  if [[ -n "$ARS_SEAT" && -z "$ARS_PID$ARS_PANE" ]]; then
    WDT_BOXENV="$(spl_wdt_box_env)" ||
      { spl_ars_refuse "$id" 4 "a windowless seat starts only as the agent user its box config names: none"; return; }
  fi
  spl_ars_limits "$id" "$now" || return
  return 0
}

# A retired id: a row in registry.retired.tsv and none in registry.tsv
# (agent-id-retire.sh moves the row; a reused id has a new live row).
spl_ars_retired() {
  awk -F'\t' -v i="$1" '{k = $1; sub(/@.*/, "", k)} k == i {f = 1} END {exit !f}' "$SPOOL_ROOT/registry.retired.tsv" 2>/dev/null || return 1
  ! awk -F'\t' -v i="$1" '{k = $1; sub(/@.*/, "", k)} k == i {f = 1} END {exit !f}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null
}

# spl_ars_pick CAUSE HITS: the hit that proves CAUSE (ARS_CODE, ARS_EV). An
# S3 hit carrying the rebirth marker is a rebirth; a rebirth needs one.
spl_ars_pick() {
  local cause="$1" hits="$2" line
  case "$cause" in
    rebirth) line="$(grep -m1 -E '^HIT S3 rebirth:' <<<"$hits" || true)" ;;
    S7) line="$(grep -m1 -E '^HIT S7 modal=2 ' <<<"$hits" || true)" ;;
    *) line="$(grep -m1 -E "^HIT $cause( |\$)" <<<"$hits" || true)" ;;
  esac
  [[ -n "$line" ]] || return 1
  if [[ "$line" == "HIT S3 rebirth:"* ]]; then ARS_CAUSE=rebirth; fi
  ARS_CODE="$(cut -d' ' -f2 <<<"$line")"
  [[ -n "${WD_EVIDENCE:-}" ]] || ARS_EV="$(cut -d' ' -f3- <<<"$line" | cut -c1-300)"
  return 0
}

# Session age in s: session.json's start, the process age the cross-check,
# the older wins (spec 102 section 2).
spl_ars_session_age() {
  local ctx="$1" now="$2" s p a=0
  s="$(cat "$ctx/session_start" 2>/dev/null || true)"
  p="$(cat "$ctx/proc_age" 2>/dev/null || true)"
  if [[ "$s" =~ ^[0-9]+$ ]]; then a=$(( now - s )); fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > a )); then a="$p"; fi
  echo "$a"
}

# spl_ars_limits ID NOW: section 6. RESTART_MAX_PER_HOUR on lifetime/restarts
# (the ONE counter; the watchdog reads it too), then the task caps of a
# lane. Past one: held out (spl_wd_hold_out), ONE admin message, exit 4. A
# pass counts this restart (a failed start counts too: 6.1).
spl_ars_limits() {
  local id="$1" now="$2" n f="$SPOOL_ROOT/$1/lifetime/restarts" sj="$SPOOL_ROOT/$1/lifetime/session.json" cap=""
  n="$(spl_wd_restarts_n "$id" "$now")"
  if (( n >= RESTART_MAX_PER_HOUR )); then
    spl_ars_hold "$id" "$now" "$n restarts in the last hour (restart_max_per_hour $RESTART_MAX_PER_HOUR), then $ARS_CODE again ($ARS_EV)"
    return
  fi
  ARS_N=1 ARS_REBIRTHS=0 ARS_RESTARTS=0 ARS_BRIEF=""
  if [[ -f "$sj" ]] && [[ "$(jq -r '.spawned // ""' "$sj" 2>/dev/null || true)" == "$(spl_ars_spawned "$id")" ]]; then
    ARS_N="$(jq -r '(.n // 0) + 1' "$sj" 2>/dev/null || echo 1)"
    ARS_REBIRTHS="$(jq -r '.rebirths // 0' "$sj" 2>/dev/null || echo 0)"
    ARS_RESTARTS="$(jq -r '.restarts // 0' "$sj" 2>/dev/null || echo 0)"
    ARS_BRIEF="$(jq -r '.brief // ""' "$sj" 2>/dev/null || true)"
  fi
  if [[ -z "$ARS_SEAT" ]]; then
    if [[ "$ARS_CAUSE" == rebirth ]] && (( ARS_REBIRTHS >= REBIRTH_MAX )); then cap="rebirth_max $ARS_REBIRTHS"
    elif (( ARS_RESTARTS >= TASK_RESTART_MAX )); then cap="task_restart_max $ARS_RESTARTS"; fi
    if [[ -n "$cap" ]]; then spl_ars_task_cap "$id" "$now" "$cap"; return; fi
  fi
  if [[ "${DRY_RUN:-1}" != 1 ]]; then
    mkdir -p "${f%/*}" && echo "$now $ARS_CAUSE" >> "$f"
  fi
  return 0
}

# The spawn time of the id's open registry row: it tells this task from the
# previous one under a reused id.
spl_ars_spawned() { awk -F'\t' -v i="$1" '$1 == i {s = $5} END {print s}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true; }

spl_ars_hold() {
  local id="$1" now="$2" why="$3"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_ars_refuse "$id" 4 "would hold out: $why"; return; fi
  spl_wd_hold_out "$id" "$now" "$why"
  spl_wdt_alert "$id" "$(date -u -d "@$now" +%Y%m%dT%H%MZ)-rs-$id" RS-LIMIT \
    "$id@$ROTATE_BOX is held out of the watchdog until the admin clears it: $why. Handoff: $SPOOL_ROOT/$id/handoff.md"
  spl_ars_refuse "$id" 4 "held out: $why"
}

# 6.2 at a task cap: the wip ref pushed, the orchestrator told
# `TASK CAP <id> <cap> <n> wip=<sha>`, the id held out, no new session.
spl_ars_task_cap() {
  local id="$1" now="$2" cap="$3" sha="" rc=0
  if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_ars_refuse "$id" 4 "would stop at the task cap: $cap"; return; fi
  ( ID="$id" WIP_WORKTREE="$ARS_WT" DRY_RUN=0 do_spl_lane_wip_push ) >/dev/null 2>&1 6>&- || rc=$?
  if (( rc == 0 )); then sha="$(spl_ars_wip_sha)"; fi
  spl_ars_send orchestrator note "restart-$id" "TASK CAP $id $cap wip=${sha:-none}" --no-ask || true
  spl_ars_hold "$id" "$now" "task cap ${cap% *} reached (${cap##* })"
}

spl_ars_wip_sha() {
  local b
  b="$(git -c safe.directory='*' -C "$ARS_WT" symbolic-ref -q --short HEAD 2>/dev/null)" || return 0
  git -c safe.directory='*' -C "$ARS_WT" ls-remote "${WIP_REMOTE:-origin}" "refs/heads/wip/$b" 2>/dev/null | awk '{print substr($1, 1, 12); exit}' || true
}

# ---- the restart ------------------------------------------------------------------

spl_ars_run() {
  local id="$1" rid="$2" ts="$3" now="$4" d hand seed name="" rc=0 role=""
  d="$SPOOL_ROOT/$id/handoff"
  hand="$d/$rid.md" seed="$d/$rid.seed.md"
  if [[ "$id" =~ -00[1-3]$ ]]; then role=1; fi
  if [[ -n "$ARS_PANE" ]]; then name="$(spl_rotate_tmux display-message -p -t "$ARS_PANE" '#{window_name}' 2>/dev/null || true)"; fi
  # shellcheck disable=SC2034 # read by spl_peer_restart_spawn and the rotate lib
  ROTATE_RID="$rid" ROTATE_OLD_PID="$ARS_PID" ROTATE_OLD_PANE="$ARS_PANE" ROTATE_OLD_NAME="$name" ROTATE_NEW_PID="" ROTATE_NEW_PANE="" ROTATE_ERR=""
  # shellcheck disable=SC2034 # read by spl_rotate_handoff and spl_peer_with_lib
  ROTATE_QUIESCE="not run (restart $ARS_CAUSE)" PEER_RESTART_ID="$id"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_ars_plan "$id" "$rid" "$ts" "$hand" "$seed" "$name" "$role"
    echo "---- DRY_RUN: nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_peer_rlog "$rid" RS-GATE OK "$id ($PEER_HARNESS${ARS_SEAT:+, seat}) cause=$ARS_CAUSE $ARS_CODE $ARS_EV; slot $ARS_SLOT; ${ARS_PID:+pid $ARS_PID }pane ${ARS_PANE:-none}"
  if [[ -n "$role" ]]; then
    printf '%s %s %s\n' "$id" "$now" "$rid" > "$LEASE_DIR/rotate.hold.tmp.$$" && mv -f "$LEASE_DIR/rotate.hold.tmp.$$" "$LEASE_DIR/rotate.hold"
    spl_peer_rlog "$rid" RS-HOLD OK "rotate.hold = $id"
  fi
  if [[ -n "$ARS_SEAT" ]]; then spl_ars_seat "$id" "$rid" "$ts" "$hand" "$seed" || rc=$?
  else spl_ars_lane "$id" "$rid" "$ts" "$hand" "$seed" || rc=$?; fi
  if [[ -n "$role" ]]; then
    rm -f "${LEASE_DIR:?}/rotate.hold"
    spl_peer_rlog "$rid" RS-HOLD OK "rotate.hold removed"
  fi
  if (( rc == 0 )); then
    spl_peer_rlog "$rid" DONE OK "$id@$ROTATE_BOX restarted ($ARS_CAUSE): session #$ARS_N pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"
    spl_peer_with_lib spl_rotate_recovered "$id" "$rid" "do_spl_agent_restart $rid ($ARS_CAUSE)" "$ROTATE_NEW_PID"
    spl_ars_event "$id" "$rid" ok
  else
    spl_peer_rlog "$rid" DONE FAIL "$id@$ROTATE_BOX not restarted ($ARS_CAUSE): ${ROTATE_ERR:-see above}"
    spl_ars_event "$id" "$rid" fail
  fi
  return "$rc"
}

spl_ars_plan() {
  local id="$1" rid="$2" ts="$3" hand="$4" seed="$5" name="$6" role="$7" eat=""
  if [[ "$ARS_CAUSE" == rebirth ]]; then eat="; the rebirth marker consumed"; fi
  spl_peer_rlog "$rid" RS-GATE PLAN "$id ($PEER_HARNESS${ARS_SEAT:+, seat}) cause=$ARS_CAUSE $ARS_CODE $ARS_EV; ${ARS_PID:+pid $ARS_PID }pane ${ARS_PANE:-none} '$name'"
  if [[ -n "$role" ]]; then spl_peer_rlog "$rid" RS-HOLD PLAN "$LEASE_DIR/rotate.hold = $id while the restart runs"; fi
  if [[ -z "$ARS_SEAT" ]]; then
    if [[ -n "$ARS_PID" ]]; then spl_peer_rlog "$rid" RS-RETIRE PLAN "TERM pid $ARS_PID, KILL after ${ROTATE_TERM_WAIT}s"; fi
    spl_peer_rlog "$rid" RS-CLEANUP PLAN "a stale .git/index.lock in $ARS_WT"
    spl_peer_rlog "$rid" RS-WIP PLAN "do_spl_lane_wip_push ID=$id WIP_WORKTREE=$ARS_WT"
  fi
  spl_peer_rlog "$rid" RS-HANDOFF PLAN "do_spl_agent_handoff ID=$id; snapshot $hand$eat"
  spl_peer_rlog "$rid" RS-SEED PLAN "$seed; session #$ARS_N"
  spl_peer_rlog "$rid" RS-SPAWN PLAN "$ROTATE_SPAWN $PEER_HARNESS $id $ARS_WT <seed> (SPAWN_REUSE_ID=1); wait ${WD_START_WAIT}s"
  if [[ -n "$ARS_SEAT" ]]; then spl_peer_rlog "$rid" RS-ACK PLAN "a result on task restart-$rid within ${ROTATE_ACK_TIMEOUT}s, then RETIRE the old session"; fi
  if spl_ars_planned; then spl_peer_rlog "$rid" RS-REPORT PLAN "one REBORN line to the orchestrator"
  else spl_peer_rlog "$rid" RS-REPORT PLAN "one blocker to the peers on task wd-$id-$ts"; fi
}

# A planned end (no investigation): rebirth, hard end, reboot, box down, login reset.
spl_ars_planned() { [[ ! "$ARS_CAUSE" =~ ^S[0-9]+$ ]]; }

# LANE: stop first.
spl_ars_lane() {
  local id="$1" rid="$2" ts="$3" hand="$4" seed="$5"
  if [[ -n "$ARS_PID" ]]; then
    if ! spl_wdt_kill "$ARS_PID"; then
      ROTATE_ERR="pid $ARS_PID survived SIGKILL"; spl_peer_rlog "$rid" RS-RETIRE FAIL "$ROTATE_ERR: no new session in its worktree"
      spl_wdt_alert "$id" "$rid" RS-RETIRE "$ROTATE_ERR"
      return 1
    fi
    spl_peer_rlog "$rid" RS-RETIRE OK "pid $ARS_PID gone (TERM, no /exit-clean)"
  else
    spl_peer_rlog "$rid" RS-RETIRE SKIP "no process: the session already ended"
  fi
  if [[ -n "$ROTATE_OLD_PANE" ]] && ! spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{pane_id}' >/dev/null 2>&1; then ROTATE_OLD_PANE=""; fi
  spl_ars_cleanup "$rid"
  spl_ars_wip "$id" "$rid"
  spl_ars_handoff "$id" "$rid" "$hand" || return 1
  spl_ars_seed "$id" "$rid" "$ts" "$hand" "$seed" || return 1
  if ! spl_ars_spawn lane "$id" "$seed"; then
    spl_peer_with_lib spl_rotate_restore "$id" "$ROTATE_OLD_PANE" "$ROTATE_NEW_PANE"
    if [[ -n "$ROTATE_NEW_PID" ]] && spl_peer_alive "$ROTATE_NEW_PID"; then spl_wdt_kill "$ROTATE_NEW_PID" || true; fi
    spl_ars_unconsume "$id"
    rm -f "${WD_DIR:?}/${id:?}".ep.S*.takeover
    spl_peer_rlog "$rid" RS-SPAWN FAIL "$ROTATE_ERR; nothing runs, the next tick retries (counted)"
    if [[ -n "$ROTATE_NEW_DIALOG" ]]; then spl_wdt_alert "$id" "$rid" RS-SPAWN "$ROTATE_ERR"; fi
    return 1
  fi
  spl_peer_rlog "$rid" RS-SPAWN OK "new pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"
  if [[ -n "$ROTATE_OLD_PANE" ]]; then spl_rotate_tmux kill-window -t "$ROTATE_OLD_PANE" 2>/dev/null || true; fi
  spl_ars_report "$id" "$rid" "$ts" "$hand"
}

# SEAT: start first; the old session goes only after the new one acked.
spl_ars_seat() {
  local id="$1" rid="$2" ts="$3" hand="$4" seed="$5" ack=1
  if [[ -n "$WDT_SEAT" ]]; then
    spl_peer_stop "$id" >/dev/null || { ROTATE_ERR="the $id poll loop did not stop"; spl_peer_rlog "$rid" RS-LOOP FAIL "$ROTATE_ERR"; return 1; }
    spl_peer_rlog "$rid" RS-LOOP OK "the $id poll loop is stopped"
  fi
  if ! spl_ars_handoff "$id" "$rid" "$hand" || ! spl_ars_seed "$id" "$rid" "$ts" "$hand" "$seed"; then
    if [[ -n "$WDT_SEAT" ]]; then spl_peer_loop_start "$id" "$rid"; fi
    return 1
  fi
  if ! spl_ars_spawn seat "$id" "$seed"; then
    spl_peer_rlog "$rid" RS-SPAWN FAIL "$ROTATE_ERR"
    if [[ -n "$ROTATE_NEW_DIALOG" ]]; then spl_wdt_alert "$id" "$rid" RS-SPAWN "$ROTATE_ERR"; fi
  else
    spl_peer_rlog "$rid" RS-SPAWN OK "new pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"
    ack=0; spl_ars_ack_wait "$id" "restart-$rid" || ack=$?
    if (( ack == 0 )); then spl_peer_rlog "$rid" RS-ACK OK "a result on task restart-$rid from $id"
    else ROTATE_ERR="no ack on task restart-$rid within ${ROTATE_ACK_TIMEOUT}s"; spl_peer_rlog "$rid" RS-ACK FAIL "$ROTATE_ERR"; fi
  fi
  if (( ack != 0 )); then
    spl_peer_with_lib spl_rotate_restore "$id" "$ARS_PANE" "$ROTATE_NEW_PANE"
    if [[ -n "$ROTATE_NEW_PID" ]] && spl_peer_alive "$ROTATE_NEW_PID"; then spl_wdt_kill "$ROTATE_NEW_PID" || true; fi
    if [[ "$ARS_CAUSE" == hard-end && -n "$ARS_PID" ]] && spl_wdt_kill "$ARS_PID"; then
      spl_peer_rlog "$rid" RS-RETIRE OK "hard end: pid $ARS_PID retired anyway (R2); the next tick starts a fresh one"
    else
      spl_peer_rlog "$rid" RS-RETIRE SKIP "the old session${ARS_PID:+ (pid $ARS_PID)} keeps the seat (060 D2)"
    fi
    if [[ -n "$WDT_SEAT" ]]; then spl_peer_loop_start "$id" "$rid"; fi
    spl_ars_unconsume "$id"
    return 1
  fi
  if [[ -n "$ARS_PID" ]]; then
    if spl_wdt_kill "$ARS_PID"; then spl_peer_rlog "$rid" RS-RETIRE OK "pid $ARS_PID gone after the ack"
    else
      spl_peer_rlog "$rid" RS-RETIRE FAIL "pid $ARS_PID survived SIGKILL: two sessions carry $id until a human clears it"
      spl_wdt_alert "$id" "$rid" RS-RETIRE "old pid $ARS_PID survived SIGKILL"
    fi
  fi
  if [[ -n "$ARS_PANE" ]]; then spl_rotate_tmux kill-window -t "$ARS_PANE" 2>/dev/null || true; fi
  if [[ -n "$WDT_SEAT" ]]; then spl_peer_loop_start "$id" "$rid"; fi
  spl_ars_report "$id" "$rid" "$ts" "$hand"
}

# spl_ars_spawn lane|seat ID SEED: the start (spl_peer_restart_spawn, a seat
# through spl_wdt_spawn), then for claude the dialog check of
# start-check.inc.sh on the new pane, up to ROTATE_START_CHECK_WAIT (45 s): a
# known dialog = 1 at once, ROTATE_ERR and ROTATE_NEW_DIALOG naming it (the
# restore then signals the session and types nothing into the dialog); no
# input box and no known dialog = one WAIT line, the start stands.
# spawn-window's own check is off (SPAWN_START_CHECK=0): it runs here.
spl_ars_spawn() {
  local how="$1" out rc=0
  local -x SPAWN_START_CHECK=0
  shift
  ROTATE_NEW_DIALOG=""
  if [[ "$how" == seat ]]; then PEER_START_WAIT="$WD_START_WAIT" spl_wdt_spawn "$@" || return 1
  else PEER_START_WAIT="$WD_START_WAIT" spl_peer_restart_spawn "$@" || return 1; fi
  [[ "$PEER_HARNESS" == claude ]] || return 0
  out="$(spool_start_check "$ROTATE_NEW_PANE" "${ROTATE_START_CHECK_WAIT:-45}" spl_rotate_capture_e)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) ROTATE_NEW_DIALOG="$out"
       ROTATE_ERR="the new session in $ROTATE_NEW_PANE is stopped on a '$out' dialog (not answered: fix its cause$(spool_start_hint "$out"))"
       return 1 ;;
  esac
  spl_peer_rlog "$ROTATE_RID" RS-SPAWN WAIT "$ROTATE_NEW_PANE: $out and no known dialog"
  return 0
}

# spl_ars_ack_wait ID TASK: 0 once <ID>/outbox holds its result on TASK; 2
# when the new session dies first; 1 after ROTATE_ACK_TIMEOUT.
spl_ars_ack_wait() {
  local t0=$SECONDS
  while :; do
    spl_rotate_ack_seen "$1" "$2" && return 0
    if [[ -n "$ROTATE_NEW_PID" ]] && ! spl_peer_alive "$ROTATE_NEW_PID"; then return 2; fi
    (( SECONDS - t0 < ROTATE_ACK_TIMEOUT )) || return 1
    sleep "$ROTATE_POLL"
  done
}

# CLEANUP: a stale index.lock (no git process with its cwd in the worktree)
# goes; a rebase or merge in progress is noted (WIP pushes ORIG_HEAD then).
spl_ars_cleanup() {
  local rid="$1" wt="$ARS_WT" gd p cwd busy="" note=""
  if ! gd="$(git -c safe.directory='*' -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"; then
    spl_peer_rlog "$rid" RS-CLEANUP SKIP "no git worktree at $wt"; return 0
  fi
  if [[ -e "$gd/index.lock" ]]; then
    for p in "${LEASE_PROC_ROOT:-/proc}"/[0-9]*; do
      [[ "$(cat "$p/comm" 2>/dev/null || true)" == git ]] || continue
      cwd="$(readlink "$p/cwd" 2>/dev/null || true)"
      if [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]]; then busy="${p##*/}"; break; fi
    done
    if [[ -n "$busy" ]]; then note="index.lock kept: git pid $busy runs in $wt"
    else rm -f "${gd:?}/index.lock"; note="a stale index.lock removed"; fi
  fi
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then note+="${note:+; }a rebase is in progress"; fi
  if [[ -f "$gd/MERGE_HEAD" ]]; then note+="${note:+; }a merge is in progress"; fi
  spl_peer_rlog "$rid" RS-CLEANUP OK "${note:-clean}"
}

spl_ars_wip() {
  local id="$1" rid="$2" out rc=0
  out="$( ( ID="$id" WIP_WORKTREE="$ARS_WT" DRY_RUN=0 do_spl_lane_wip_push ) 2>&1 6>&- )" || rc=$?
  out="$(grep -E 'OK WIP|SKIP WIP|FATAL' <<<"$out" | tail -1 | cut -c1-200 || true)"
  if (( rc == 0 )); then spl_peer_rlog "$rid" RS-WIP OK "${out:-pushed}"
  else spl_peer_rlog "$rid" RS-WIP FAIL "${out:-exit $rc}; the tree stays in $ARS_WT"; fi
  return 0
}

# HANDOFF: the final compose, its snapshot <id>/handoff/<rid>.md (+ the
# `## watchdog` section of a crash), the rebirth marker consumed. A snapshot
# that is not written fails the restart: never logged OK unwritten.
spl_ars_handoff() {
  local id="$1" rid="$2" hand="$3" d lt="$SPOOL_ROOT/$1/lifetime" out rc=0 hk=""
  d="$(dirname "$hand")"
  { mkdir -p "$d" && chmod g+ws "$d"; } 2>/dev/null || true
  if [[ "$ARS_CAUSE" == hard-end ]]; then hk=1; fi
  out="$( ( ID="$id" HANDOFF_WORKDIR="$ARS_WT" HANDOFF_HARD_KILLED="$hk" do_spl_agent_handoff ) 2>&1 6>&- )" || rc=$?
  if ! spl_ars_handoff_body "$id" "$rid" "$rc" 2>/dev/null > "$hand" || [[ ! -s "$hand" ]]; then
    ROTATE_ERR="cannot write the handoff $hand"; spl_peer_rlog "$rid" RS-HANDOFF FAIL "$ROTATE_ERR"
    return 1
  fi
  chmod 0640 "$hand" 2>/dev/null || true
  if (( rc != 0 )); then spl_peer_rlog "$rid" RS-HANDOFF WARN "the compose failed ($(tail -1 <<<"$out" | cut -c1-120)); the 060 handoff instead"; fi
  if [[ -e "$lt/rebirth" ]] && mv -f "$lt/rebirth" "$lt/last-rebirth"; then ARS_CONSUMED=1; fi
  spl_peer_rlog "$rid" RS-HANDOFF OK "$hand ($(wc -l < "$hand") lines)${ARS_CONSUMED:+; the rebirth marker consumed}"
}

spl_ars_handoff_body() {
  local id="$1" rid="$2" rc="$3" src="$SPOOL_ROOT/$1/handoff.md"
  if (( rc == 0 )) && [[ -s "$src" ]]; then cat "$src"; else spl_rotate_handoff watchdog "$id" "$rid" -; fi
  if ! spl_ars_planned; then echo; spl_wdt_section "$id"; fi
  return 0
}

# A failed start puts a consumed rebirth marker back: the retry is a rebirth still.
spl_ars_unconsume() {
  local lt="$SPOOL_ROOT/$1/lifetime"
  if [[ -n "$ARS_CONSUMED" && -e "$lt/last-rebirth" && ! -e "$lt/rebirth" ]]; then mv -f "$lt/last-rebirth" "$lt/rebirth" || true; fi
  return 0
}

# SEED: the seed file and the next lifetime/session.json.
spl_ars_seed() {
  local id="$1" rid="$2" ts="$3" hand="$4" seed="$5" lt="$SPOOL_ROOT/$1/lifetime" brief rb rs
  brief="$(spl_ars_brief "$id")"
  rb="$ARS_REBIRTHS"; rs=$(( ARS_RESTARTS + 1 ))
  if [[ "$ARS_CAUSE" == rebirth ]]; then rb=$(( rb + 1 )); fi
  if ! spl_ars_seed_text "$id" "$rid" "$ts" "$hand" "$brief" "$rb" "$rs" 2>/dev/null > "$seed" || [[ ! -s "$seed" ]]; then
    ROTATE_ERR="cannot write the seed $seed"; spl_peer_rlog "$rid" RS-SEED FAIL "$ROTATE_ERR"; return 1
  fi
  chmod 0640 "$seed" 2>/dev/null || true
  if ! jq -n --arg id "$id" --argjson n "$ARS_N" --arg st "$(date -u -d "@$(spl_lease_now)" +%FT%TZ)" --arg c "$ARS_CAUSE" \
        --arg rid "$rid" --argjson rb "$rb" --argjson rs "$rs" --arg b "$brief" --arg sp "$(spl_ars_spawned "$id")" --arg box "$ROTATE_BOX" \
        '{v: 1, id: $id, n: $n, started: $st, cause: $c, rid: $rid, rebirths: $rb, restarts: $rs, brief: $b, spawned: $sp, box: $box}' \
        2>/dev/null > "$lt/session.json.tmp.$$" || ! mv -f "$lt/session.json.tmp.$$" "$lt/session.json"; then
    rm -f "${lt:?}/session.json.tmp.$$"
    ROTATE_ERR="cannot write $lt/session.json"; spl_peer_rlog "$rid" RS-SEED FAIL "$ROTATE_ERR"; return 1
  fi
  ARS_REBIRTHS="$rb" ARS_RESTARTS="$rs"
  spl_peer_rlog "$rid" RS-SEED OK "$seed; session #$ARS_N, rebirths $rb, restarts $rs"
}

# The brief's path: session.json .brief, else lifetime/brief.md, else the
# old session's first prompt, saved there once (a restart seed is never
# taken for a brief: after a restart the first prompt is the seed).
spl_ars_brief() {
  local id="$1" f="$SPOOL_ROOT/$1/lifetime/brief.md" tr first=""
  if [[ -n "$ARS_BRIEF" && -r "$ARS_BRIEF" ]]; then echo "$ARS_BRIEF"; return 0; fi
  if [[ -s "$f" ]]; then echo "$f"; return 0; fi
  [[ -z "${WDT_BOXENV:-}" ]] || return 0
  tr="$(spl_rotate_transcript "$id" || true)"
  if [[ -n "$tr" ]]; then
    first="$(spl_rotate_as_agent head -n 200 "$tr" 2>/dev/null | jq -Rr 'fromjson? // empty
      | select(.type == "user" and (.message.content | type) == "string") | .message.content' 2>/dev/null | head -c 6000 || true)"
  fi
  [[ -n "$first" && "$first" != "# Brief: you are $id"* ]] || return 0
  if printf '%s\n' "$first" 2>/dev/null > "$f"; then echo "$f"; fi
  return 0
}

spl_ars_seed_text() {
  local id="$1" rid="$2" ts="$3" hand="$4" brief="$5" rb="$6" rs="$7"
  echo "# Brief: you are $id@$ROTATE_BOX, restarted by the watchdog ($rid)"
  echo
  if spl_ars_planned; then
    echo "Your previous session ended as planned (cause $ARS_CAUSE): this is session #$ARS_N of the same task."
  else
    echo "Your previous session stopped working (cause $ARS_CAUSE: $ARS_EV); a peer investigates it on"
    echo "task wd-$id-$ts, not you. This is session #$ARS_N of the same task."
  fi
  echo "Same id, same inbox, same workdir and branch. Do not greet; post nothing about the restart."
  echo "Rebirths of this task: $rb (cap $REBIRTH_MAX); restarts: $rs (cap $TASK_RESTART_MAX)."
  echo
  echo "Your session lives at most 2 h: at 1 h you are asked to hand over and exit; at 1 h 50 you take"
  echo "no new work; at 2 h you are stopped. After every step write your next step with"
  echo "\`./run -a do_spl_agent_handoff_note SECTION=next TEXT=...\`."
  echo
  if [[ -n "$ARS_SEAT" ]]; then
    echo "FIRST, before anything else, acknowledge the restart (the old session waits for it):"
    echo "  SPOOL_ROOT=$SPOOL_ROOT bash $ROTATE_SEND --from $id --to $id --kind result --task restart-$rid --no-ask --no-poke --body \"ACK restart $rid\""
    echo
  fi
  echo "1. Section A is your brief: continue it. 2. Section B is the handoff. 3. Then drain your inbox:"
  echo "   SPOOL_ROOT=$SPOOL_ROOT spool recv --as $id"
  echo
  if [[ -n "${WDT_BOXENV:-}" ]]; then spl_wdt_seat_section "$id"
  elif [[ -n "$brief" ]]; then echo "## A. Your brief ($brief)"; echo; head -c 6000 "$brief"; echo
  else echo "## A. Your brief: UNAVAILABLE (no brief file, no transcript); read section B and your inbox"; fi
  echo
  echo "## B. The handoff"
  echo
  cat "$hand"
}

# REPORT: a crash -> one blocker for the peers to investigate (093 8.2); a
# planned end -> ONE line to the orchestrator, nothing in topics (W5).
# A report that does not leave is journaled, never lost: the 2026-10-08
# reboot drill (n=3 seat restarts, one boot) sent all three while the orch
# lease named a seat on another box and this box's hub-run sidecar was not
# up yet, so the relay refused them (spool-send exit 13): each logged FAIL.
# A local recipient never reaches the relay (spool-send writes its inbox).
spl_ars_report() {
  local id="$1" rid="$2" ts="$3" hand="$4" body
  spl_ars_report_flush
  if spl_ars_planned; then
    body="REBORN $id@$ROTATE_BOX #$ARS_N cause=$ARS_CAUSE handoff=$hand"
    spl_ars_report_send "$rid" "the REBORN line" "$body" orchestrator note "restart-$id" "$body" --no-ask
    return 0
  fi
  body="WATCHDOG RESTART (102 4.1): $id@$ROTATE_BOX was restarted: $ARS_CODE $ARS_EV. The new session is pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE. Handoff: $hand. Investigate (093 8.3): read the handoff and the old transcript, post one paragraph here (what it was doing, why it stopped, whether its job was finished), then close this job; a new cause or a code defect opens a lane."
  spl_ars_report_send "$rid" "the blocker" "blocker on task wd-$id-$ts to the peers" orchestrator blocker "wd-$id-$ts" "$body"
  return 0
}

# spl_ars_report_send RID WHAT OKTEXT TO KIND TASK BODY [FLAG]: sent = OK;
# not sent = journaled in <wd>/report.queue/<rid>.json (QUEUED) and a resend
# loop started; a usage error (exit 2) or ARS_REPORT_QUEUE=0 = FAIL.
spl_ars_report_send() {
  local rid="$1" what="$2" ok="$3" q f
  shift 3
  if spl_ars_send "$@"; then spl_peer_rlog "$rid" RS-REPORT OK "$ok"; return 0; fi
  q="${WD_DIR:?}/report.queue" f="${WD_DIR}/report.queue/$rid.json"
  if [[ "${ARS_REPORT_QUEUE:-1}" == 0 || "$ARS_SEND_RC" == 2 ]] || ! mkdir -p "$q" ||
     ! jq -n -c --arg rid "$rid" --arg what "$what" --arg ok "$ok" --arg to "$1" --arg k "$2" --arg t "$3" \
         --arg b "$4" --arg fl "${5:-}" --argjson at "$(spl_lease_now)" \
         '{v: 1, rid: $rid, what: $what, ok: $ok, to: $to, kind: $k, task: $t, body: $b, flag: $fl, queued: $at}' \
         2>/dev/null > "$q/.$rid.tmp" || ! mv -f "$q/.$rid.tmp" "$f"; then
    rm -f "$q/.$rid.tmp" 2>/dev/null
    spl_peer_rlog "$rid" RS-REPORT FAIL "$what was not delivered (spool-send exit $ARS_SEND_RC)"
    return 0
  fi
  spl_peer_rlog "$rid" RS-REPORT QUEUED "$what was not delivered (spool-send exit $ARS_SEND_RC): journaled in $f, resent until it leaves"
  spl_ars_report_retry_bg
}

# The resend loop, detached: every ARS_REPORT_RETRY s a flush, until the queue
# is empty. No lock fd of the run goes with it (the slot is fd 6).
spl_ars_report_retry_bg() {
  [[ "${ARS_REPORT_RETRY:-30}" =~ ^[1-9][0-9]*$ ]] || return 0
  ( trap - ERR; set +e
    while compgen -G "$WD_DIR/report.queue/*.json" >/dev/null; do
      sleep "$ARS_REPORT_RETRY"; spl_ars_report_flush
    done ) </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- &
  disown 2>/dev/null || true
  return 0
}

# Resend every journaled report, oldest first (a rid starts with its time).
# Each one is claimed by a rename, so two flushes never send it twice; a
# claim whose flush died goes back. Past ARS_REPORT_TTL it is dropped (FAIL).
spl_ars_report_flush() {
  local q="${WD_DIR:-}/report.queue" f c pid now age
  local -a a
  [[ -n "${WD_DIR:-}" && -d "$q" && "${DRY_RUN:-1}" != 1 ]] || return 0
  for c in "$q"/*.json.sending.*; do
    [[ -e "$c" ]] || continue
    pid="${c##*.}"
    if [[ ! -d "/proc/$pid" ]]; then mv -f "$c" "${c%.sending.*}" 2>/dev/null || true; fi
  done
  now="$(spl_lease_now)"
  for f in "$q"/*.json; do
    [[ -e "$f" ]] || continue
    c="$f.sending.$BASHPID"
    mv "$f" "$c" 2>/dev/null || continue
    a=()
    mapfile -d '' -t a < <(jq -j '[.rid, .what, .ok, .to, .kind, .task, .body, .flag, .queued] | map(tostring + "\u0000") | add' "$c" 2>/dev/null)
    if (( ${#a[@]} != 9 )) || [[ ! "${a[8]}" =~ ^[0-9]+$ ]]; then mv -f "$c" "$f.bad" 2>/dev/null || true; continue; fi
    age=$(( now - a[8] ))
    if spl_ars_send "${a[3]}" "${a[4]}" "${a[5]}" "${a[6]}" ${a[7]:+"${a[7]}"}; then
      rm -f "$c"; spl_peer_rlog "${a[0]}" RS-REPORT OK "${a[2]} (journaled ${age}s)"
    elif (( age > ${ARS_REPORT_TTL:-21600} )); then
      rm -f "$c"; spl_peer_rlog "${a[0]}" RS-REPORT FAIL "${a[1]} was not delivered in ${age}s: dropped (spool-send exit $ARS_SEND_RC)"
    else
      mv -f "$c" "$f" 2>/dev/null || true
    fi
  done
  return 0
}

# spl_ars_send TO KIND TASK BODY [FLAG]: spool-send.sh exit 1-9 = delivered
# (exit 2 = usage: not sent); ARS_SEND_RC is its exit.
spl_ars_send() {
  local rc=0
  SPOOL_ROOT="$SPOOL_ROOT" bash "$WD_SEND" --from "$WD_FROM" --to "$1" --kind "$2" --task "$3" ${5:+"$5"} --body "$4" \
    >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- || rc=$?
  ARS_SEND_RC="$rc"
  (( rc < 10 && rc != 2 ))
}

# LOG: one agent_lifecycle_events row (063 section 12) through
# do_spl_lifecycle_event when that action exists; fire and forget.
spl_ars_event() {
  [[ "${LIFECYCLE_EVENTS:-1}" != 0 ]] || return 0
  declare -F do_spl_lifecycle_event >/dev/null || [[ -f "$SPL_ROTATE_LIB_DIR/spl-lifecycle-event.func.sh" ]] || return 0
  ( env LIFECYCLE_EVENT=restart LIFECYCLE_ROLE="$([[ -n "$ARS_SEAT" ]] && echo seat || echo lane)" LIFECYCLE_AGENT="$1" \
      LIFECYCLE_REASON="$ARS_CAUSE" LIFECYCLE_RID="$2" LIFECYCLE_OUTCOME="$3" LIFECYCLE_DETAIL="${ARS_EV:0:200}" \
      timeout 60 "$ROTATE_RUN" -a do_spl_lifecycle_event >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- & ) || true
  return 0
}
