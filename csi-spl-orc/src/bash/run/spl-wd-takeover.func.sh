#!/bin/bash
#------------------------------------------------------------------------------
# @description The takeover of spec 093 section 8: stop a broken session and
# @description start a fresh one under the same id from a handoff. It is the
# @description seat restart's path (spl_peer_restart_seat, spec 060's
# @description functions) with another trigger and shorter waits:
# @description   GATE    - the 6.2 guards (human hold or activity, rotation,
# @description             grace, held out), one takeover per box at a time
# @description             (peer/restart.lock), the id lock of spec 102 4.2
# @description             (<spool root>/<id>/lifetime/restart.lock, held by
# @description             another actor = exit 4), no duplicate sessions, the
# @description             6.3 limit (WD_TAKEOVER_MAX per id per hour: past
# @description             it the id is held out and the owner gets ONE DM),
# @description             and the situations RE-RUN: no S1/S3/S4/S5 hit =
# @description             refused, exit 3, quoting the heartbeat
# @description   HOLD    - a role id (001..003) is named in rotate.hold while
# @description             the takeover runs, so the lease skips it
# @description   LOOP    - a seat's poll loop is stopped (its locks stay)
# @description   HANDOFF - the 060 handoff + a `## watchdog` section (code,
# @description             evidence, heartbeat.json, heartbeat.log tail, the
# @description             transcript's last entry types and error texts)
# @description   SEED    - the old session's first prompt (its brief) + the
# @description             handoff; no distill (a stuck session writes none)
# @description   SPAWN   - same id, same harness, same workdir (SPAWN_REUSE_ID=1)
# @description   RETIRE  - no /exit-clean: TERM at once, KILL after
# @description             ROTATE_TERM_WAIT (S3: nothing to retire)
# @description   BLOCKER - one blocker on task wd-<id>-<ts> to the peers (the
# @description             orchestrator while no seat exists): the
# @description             investigation is an agent's (8.2, 8.3)
# @description A windowless seat (an expected seat of spl_wd_expected: no
# @description pane, no process) is started FRESH on this box (SPAWN_BOX=local,
# @description a seed, never --resume) as the agent user the box config names.
# @description A failed start restores the old window, holds the id out and
# @description alerts (ask + one owner DM). rotate.log phases are WD-*, the
# @description last line DONE. An id on another box (ID=<id>@<box>) is relayed
# @description as a spool task to that box (section 10). Dry run unless DRY_RUN=0.
# @description Exit: 0 done (or planned), 1 failed, 3 no situation hits, 4 refused by a guard or a limit.
# @param ID - required: the agent id; <id>@<box> for an agent on another box
# @param REASON - required: a situation code (S1, S3, S4, S5, S7 modal=2) or a short text
# @param DRY_RUN (optional) - 1 (default): PLAN lines, nothing touched; 0: act
# @param WD_EVIDENCE (optional) - the watchdog's evidence line (set by do_spl_watchdog)
# @param WD_START_WAIT (optional) - seconds for the fresh session to start, default 120
# @param WD_RELAY_TO (optional) - who runs a relayed request on the other box, default c-001
# @param REQ_FROM (optional) - the requesting agent id, default SPOOL_AGENT_ID
# @example ID=c-007 REASON=S3 ./run -a do_spl_wd_takeover
# @example ID=c-007 REASON=S3 DRY_RUN=0 ./run -a do_spl_wd_takeover
# @example ID=c-007@sat REASON="no progress for 10 min" DRY_RUN=0 ./run -a do_spl_wd_takeover
#------------------------------------------------------------------------------
declare -F spl_wd_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-watchdog.func.sh"
declare -F spl_peer_restart_spawn >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-restart.func.sh"

# The codes a takeover repairs, in pick order (8.1: S2 never reaches it, no
# restart fixes a login). S7 only as the default-mode offer (modal=2, owner
# t1 4a1966d8): a fresh session with --dangerously-skip-permissions.
WDT_CODES="S3 S4 S5 S1 S7"

do_spl_wd_takeover() {
  local id="${ID:-}" reason="${REASON:-}" box="" req="${REQ_FROM:-${SPOOL_AGENT_ID:-}}"
  [[ -n "$reason" ]] || { do_log "FATAL REASON is required: a situation code (S1, S3, S4, S5) or a short text"; return 1; }
  if [[ "$id" == *@* ]]; then box="${id#*@}"; id="${id%@*}"; fi
  [[ "$id" =~ ^[acgqm]-[0-9]{3}$ ]] || { do_log "FATAL ID must be an agent id (c-NNN, optionally @<box>), got: '${ID:-}'"; return 1; }
  spl_wd_init || return 1
  spl_peer_init ro || return 1
  : "${WD_START_WAIT:=120}" "${WD_RELAY_TO:=c-001}"
  [[ "$WD_START_WAIT" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL WD_START_WAIT must be a positive integer"; return 1; }
  if [[ -n "$box" && "$box" != "$ROTATE_BOX" && "$box" != "${SPOOL_BOX_TAG:-}" ]]; then
    spl_wdt_relay "$id" "$box" "$reason" "$req"
    return
  fi
  # 6.3: a lane may not request a takeover, nobody may request its own
  if [[ -n "$req" && -z "${WD_EVIDENCE:-}" ]]; then
    if [[ "${req%@*}" == "$id" ]]; then spl_wdt_refuse "$id" 4 "$req may not request a takeover of itself"; return; fi
    if [[ ! "${req%@*}" =~ -00[1-4]$ ]]; then
      spl_wdt_refuse "$id" 4 "$req is a lane: a lane reports a stuck peer --to peers, it requests no takeover"; return
    fi
  fi
  local now ts
  now="$(spl_lease_now)"
  ts="$(date -u -d "@$now" +%Y%m%dT%H%MZ)"
  mkdir -p "$PEER_DIR" || { do_log "FATAL cannot create $PEER_DIR"; return 1; }
  exec 6>> "$PEER_DIR/restart.lock"
  flock -n 6 || { spl_wdt_refuse "$id" 4 "another restart or takeover runs on this box (peer/restart.lock)"; return; }
  local idl=0
  spl_agent_id_lock "$id" do_spl_wd_takeover "$ts-wd-$id" || idl=$?
  (( idl == 0 )) || { spl_wdt_refuse "$id" "$idl" "id lock (spec 102 4.2): $SPL_ID_LOCK_WHY"; return; }
  spl_wdt_gate "$id" "$reason" "$now" || return
  spl_wdt_run "$id" "$ts-wd-$id" "$ts" "$now"
}

# ---- GATE --------------------------------------------------------------------

# spl_wdt_refuse ID RC WHY: one wd.log line, the reason on stdout, return RC.
spl_wdt_refuse() {
  spl_wd_log "WD-TAKEOVER REFUSED $1: $3"
  echo "REFUSED $1: $3"
  return "$2"
}

# spl_wdt_gate ID REASON NOW: 0 when the takeover may run; sets WDT_PID,
# WDT_PANE, WDT_CODE, WDT_EV, WDT_CTX, WDT_SEAT and PEER_HARNESS. Non-zero
# is the exit code: 3 no hit, 4 a guard or a limit.
spl_wdt_gate() {
  local id="$1" reason="$2" now="$3" tick ctx row why code hits hb hid
  local -a pids
  tick="$WD_DIR/takeover.$id.tick"
  ctx="$WD_DIR/takeover.$id.ctx"
  rm -rf "$tick" "$ctx" && mkdir -p "$tick" "$ctx"
  spl_wd_ps > "$tick/ps"
  spl_wd_tmux_lists "$tick"
  spl_wd_agents "$tick" > "$tick/agents"
  row="$(awk -F'\t' -v i="$id" '$1 == i {print; exit}' "$tick/agents")"
  [[ -n "$row" ]] || { spl_wdt_refuse "$id" 3 "not an agent of this box (no window, no process carries it)"; return; }
  IFS=$'\t' read -r _ WDT_PID WDT_PANE <<<"$row"
  [[ "$WDT_PID" == - ]] && WDT_PID=""
  [[ "$WDT_PANE" == - ]] && WDT_PANE=""
  spl_wd_gather "$id" "$WDT_PID" "$WDT_PANE" "$now" "$tick" "$ctx"
  why="$(spl_wd_skip "$id" "$WDT_PID" "$now" "$tick" "$ctx")"
  [[ -z "$why" ]] || { spl_wdt_refuse "$id" 4 "$why"; return; }
  why="$(DRY_RUN=0 WD_BOX_BUSY="" spl_wd_gate "$id" "$now" "$ctx")"
  [[ -z "$why" ]] || { spl_wdt_refuse "$id" 4 "$why"; return; }
  if [[ -s "$LEASE_DIR/rotate.hold" ]]; then
    read -r hid _ < "$LEASE_DIR/rotate.hold" || true
    [[ "$hid" == "$id" ]] || { spl_wdt_refuse "$id" 4 "rotate.hold names ${hid:-?}: a rotation runs on this box"; return; }
  fi
  mapfile -t pids < <(spl_peer_pids "$id")
  (( ${#pids[@]} <= 1 )) || { spl_wdt_refuse "$id" 4 "duplicate: ${#pids[@]} live processes carry $id (pids ${pids[*]})"; return; }
  # the situations again: the takeover runs only on a hit it can repair
  spl_wd_run_scripts "$id" "$WDT_PID" "$WDT_PANE" "$ctx"
  hits="$(cat "$ctx"/out.s* 2>/dev/null | grep -E '^HIT S[0-9]+( |$)' || true)"
  WDT_CODE=""
  for code in $WDT_CODES; do
    [[ "$reason" =~ ^S[0-9]+$ && "$reason" != "$code" ]] && continue
    if [[ "$code" == S7 ]]; then
      if grep -qE "^HIT S7 modal=2 " <<<"$hits"; then WDT_CODE=S7; break; fi
    elif grep -qE "^HIT $code( |$)" <<<"$hits"; then WDT_CODE="$code"; break; fi
  done
  if [[ -z "$WDT_CODE" ]]; then
    hb="$(jq -c '{ts, event, state, progress_ts, tool, api_error}' "$ctx/heartbeat" 2>/dev/null || echo 'none')"
    spl_wdt_refuse "$id" 3 "no takeover situation hits ($reason); hits: $(tr '\n' ';' <<<"${hits:-none}" | cut -c1-200) heartbeat: $hb"
    return
  fi
  WDT_EV="$(grep -m1 -E "^HIT $WDT_CODE( |$)" <<<"$hits" | cut -d' ' -f3- | cut -c1-300)"
  WDT_CTX="$ctx"
  WDT_SEAT=""
  if spl_peer_seated "$id"; then
    WDT_SEAT=1
  else
    PEER_HARNESS="$(spl_wd_harness "$id")"
    [[ "$PEER_HARNESS" =~ ^(claude|grok|agy|qwen|mistral)$ ]] || PEER_HARNESS=claude
  fi
  WDT_BOXENV=""
  if [[ -z "$WDT_PID$WDT_PANE" ]]; then
    WDT_BOXENV="$(spl_wdt_box_env)" ||
      { spl_wdt_refuse "$id" 4 "a windowless seat starts only as the agent user its box config names (SPOOL_AGENT_USER in ${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}): none"; return; }
  fi
  spl_wdt_limit "$id" "$now" || return
  return 0
}

# spl_wdt_box_env: the box config's spawn identity for a windowless seat, as
# KEY=value lines (box user, agent user, run-as mode, tmux socket), resolved
# from <spool root>/box.env and the spool root's owner with the caller's own
# values dropped: c-001@sat's manual restart of 2026-10-07 ran, from a shell
# with no box env, as the box user and with no window. Non-zero when the box
# config names no agent user: a seat never falls back to the box user.
spl_wdt_box_env() {
  (
    unset SPOOL_BOX_USER SPOOL_AGENT_USER SPOOL_RUN_AS_AGENT SPOOL_TMUX_SOCKET
    _spool_box_env_load
    [[ -n "${SPOOL_AGENT_USER:-}" ]] || exit 1
    SPOOL_ENV_NO_BINS=1 spool_env_resolve
    printf '%s\n' "SPOOL_BOX_USER=$SPOOL_BOX_USER" "SPOOL_AGENT_USER=$SPOOL_AGENT_USER" \
      "SPOOL_RUN_AS_AGENT=$SPOOL_RUN_AS_AGENT" "SPOOL_TMUX_SOCKET=$SPOOL_TMUX_SOCKET"
  )
}

# spl_wdt_spawn ID SEED: spl_peer_restart_spawn. A windowless seat
# (WDT_BOXENV set) starts on THIS box (SPAWN_BOX=local: a remote spawn
# forwards no SPAWN_REUSE_ID) under the box config's identity.
spl_wdt_spawn() {
  if [[ -z "${WDT_BOXENV:-}" ]]; then spl_peer_restart_spawn "$@"; return; fi
  local -x SPAWN_BOX=local SPOOL_BOX_USER="" SPOOL_AGENT_USER="" SPOOL_RUN_AS_AGENT="" SPOOL_TMUX_SOCKET=""
  local k v
  while IFS='=' read -r k v; do
    case "$k" in SPOOL_BOX_USER|SPOOL_AGENT_USER|SPOOL_RUN_AS_AGENT|SPOOL_TMUX_SOCKET) printf -v "$k" '%s' "$v" ;; esac
  done <<<"$WDT_BOXENV"
  spl_peer_restart_spawn "$@"
}

# spl_wdt_limit ID NOW: WD_TAKEOVER_MAX per id per rolling hour (6.3). The
# watchdog counted its own call already (it sets WD_EVIDENCE); a seat's
# request is counted here. Past the limit: held out for an hour, ONE owner
# DM (the ask + DM of spl_rotate_alert), exit 4.
spl_wdt_limit() {
  local id="$1" now="$2" f n self=0
  f="$WD_DIR/$id.takeovers"
  touch "$f"
  awk -v n="$now" '$1 + 3600 > n' "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  n="$(grep -c . "$f" || true)"
  [[ -n "${WD_EVIDENCE:-}" ]] && self=1
  if (( n - self >= WD_TAKEOVER_MAX )); then
    if [[ "${DRY_RUN:-1}" == 1 ]]; then spl_wdt_refuse "$id" 4 "would hold out: $((n - self)) takeovers in the last hour"; return; fi
    echo "$now" > "$WD_DIR/$id.heldout"
    spl_wdt_alert "$id" "$(date -u -d "@$now" +%Y%m%dT%H%MZ)-wd-$id" WD-LIMIT \
      "$id was taken over $((n - self)) times in the last hour and hit $WDT_CODE again ($WDT_EV); held out of the watchdog for an hour"
    spl_wdt_refuse "$id" 4 "held out: $((n - self)) takeovers in the last hour"
    return
  fi
  if (( ! self )) && [[ "${DRY_RUN:-1}" != 1 ]]; then echo "$now" >> "$f"; fi
  return 0
}

# ---- the takeover --------------------------------------------------------------

spl_wdt_run() {
  local id="$1" rid="$2" ts="$3" now="$4" d hand seed name="" rc=0 role=""
  d="$SPOOL_ROOT/$id/handoff"
  hand="$d/$rid.md" seed="$d/$rid.seed.md"
  [[ "$id" =~ -00[1-3]$ ]] && role=1
  [[ -n "$WDT_PANE" ]] && name="$(spl_rotate_tmux display-message -p -t "$WDT_PANE" '#{window_name}' 2>/dev/null || true)"
  # shellcheck disable=SC2034 # read by spl_peer_restart_spawn and the rotate lib
  ROTATE_RID="$rid" ROTATE_OLD_PID="$WDT_PID" ROTATE_OLD_PANE="$WDT_PANE" ROTATE_OLD_NAME="$name" ROTATE_NEW_PID="" ROTATE_NEW_PANE=""
  # shellcheck disable=SC2034 # read by spl_rotate_handoff (spl-rotate-lib.func.sh)
  ROTATE_QUIESCE="not run (watchdog takeover $WDT_CODE)"
  # shellcheck disable=SC2034 # read by spl_peer_with_lib (spl-peer-restart.func.sh)
  PEER_RESTART_ID="$id"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_peer_rlog "$rid" WD-GATE PLAN "$id ($PEER_HARNESS${WDT_SEAT:+, seat}): $WDT_CODE $WDT_EV; ${WDT_PID:+pid $WDT_PID }pane ${WDT_PANE:-none} '$name'"
    [[ -n "$role" ]] && spl_peer_rlog "$rid" WD-HOLD PLAN "$LEASE_DIR/rotate.hold = $id while the takeover runs"
    [[ -n "$WDT_SEAT" ]] && spl_peer_rlog "$rid" WD-LOOP PLAN "stop the $id poll loop (its locks stay on the hub)"
    spl_peer_rlog "$rid" WD-HANDOFF PLAN "$hand (the 060 handoff + ## watchdog)"
    local a="the old first prompt"; [[ -n "$WDT_BOXENV" ]] && a="the fresh seat section"
    spl_peer_rlog "$rid" WD-SEED PLAN "$seed: $a + the handoff"
    spl_peer_rlog "$rid" WD-SPAWN PLAN "$ROTATE_SPAWN $PEER_HARNESS $id $(spl_rotate_workdir "$id") <seed> (SPAWN_REUSE_ID=1); wait ${WD_START_WAIT}s"
    [[ -n "$WDT_BOXENV" ]] && spl_peer_rlog "$rid" WD-SPAWN PLAN "windowless seat: a fresh session, no --resume; SPAWN_BOX=local $(tr '\n' ' ' <<<"$WDT_BOXENV")"
    [[ -n "$WDT_PID" ]] && spl_peer_rlog "$rid" WD-RETIRE PLAN "TERM pid $WDT_PID, KILL after ${ROTATE_TERM_WAIT}s"
    spl_peer_rlog "$rid" WD-BLOCKER PLAN "one blocker to the peers on task wd-$id-$ts"
    echo "---- DRY_RUN: nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ -n "$role" ]]; then
    printf '%s %s %s\n' "$id" "$now" "$rid" > "$LEASE_DIR/rotate.hold.tmp.$$" && mv -f "$LEASE_DIR/rotate.hold.tmp.$$" "$LEASE_DIR/rotate.hold"
    spl_peer_rlog "$rid" WD-HOLD OK "rotate.hold = $id"
  fi
  spl_wdt_steps "$id" "$rid" "$ts" "$hand" "$seed" || rc=$?
  if [[ -n "$role" ]]; then
    rm -f "$LEASE_DIR/rotate.hold"
    spl_peer_rlog "$rid" WD-HOLD OK "rotate.hold removed"
  fi
  if (( rc == 0 )); then
    spl_peer_rlog "$rid" DONE OK "$id@$ROTATE_BOX taken over ($WDT_CODE): pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"
  else
    spl_peer_rlog "$rid" DONE FAIL "$id@$ROTATE_BOX not taken over ($WDT_CODE): ${ROTATE_ERR:-see above}"
  fi
  return "$rc"
}

spl_wdt_steps() {
  local id="$1" rid="$2" ts="$3" hand="$4" seed="$5" d
  d="$(dirname "$hand")"
  spl_peer_rlog "$rid" WD-GATE OK "$WDT_CODE $WDT_EV; ${WDT_PID:+pid $WDT_PID }pane ${WDT_PANE:-none}"
  if [[ -n "$WDT_SEAT" ]]; then
    spl_peer_stop "$id" >/dev/null || { ROTATE_ERR="the $id poll loop did not stop"; spl_peer_rlog "$rid" WD-LOOP FAIL "$ROTATE_ERR"; return 1; }
    spl_peer_rlog "$rid" WD-LOOP OK "the $id poll loop is stopped"
  fi
  { mkdir -p "$d" && chmod g+ws "$d"; } 2>/dev/null || true
  if [[ ! -d "$d" ]]; then
    ROTATE_ERR="cannot create $d"; spl_peer_rlog "$rid" WD-HANDOFF FAIL "$ROTATE_ERR"
    if [[ -n "$WDT_SEAT" ]]; then spl_peer_loop_start "$id" "$rid"; fi
    return 1
  fi
  { spl_rotate_handoff watchdog "$id" "$rid" -; spl_wdt_section "$id"; } > "$hand" 2>/dev/null || true
  chmod 0640 "$hand" 2>/dev/null || true
  spl_peer_rlog "$rid" WD-HANDOFF OK "$hand ($(wc -l < "$hand") lines)"
  spl_wdt_seed "$id" "$rid" "$ts" "$hand" > "$seed"
  chmod 0640 "$seed" 2>/dev/null || true
  spl_peer_rlog "$rid" WD-SEED OK "$seed"
  if ! PEER_START_WAIT="$WD_START_WAIT" spl_wdt_spawn "$id" "$seed"; then
    spl_peer_with_lib spl_rotate_restore "$id" "$WDT_PANE" "$ROTATE_NEW_PANE"
    spl_peer_rlog "$rid" WD-SPAWN FAIL "$ROTATE_ERR; ${WDT_PID:+the old session (pid $WDT_PID) is kept}${WDT_PID:-no session carries $id}"
    spl_lease_now > "$WD_DIR/$id.heldout"
    spl_wdt_alert "$id" "$rid" WD-SPAWN "$ROTATE_ERR; $id is held out of the watchdog for an hour"
    if [[ -n "$WDT_SEAT" ]]; then spl_peer_loop_start "$id" "$rid"; fi
    return 1
  fi
  spl_peer_rlog "$rid" WD-SPAWN OK "new pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE"
  if [[ -n "$WDT_PID" ]]; then
    if spl_wdt_kill "$WDT_PID"; then
      spl_peer_rlog "$rid" WD-RETIRE OK "pid $WDT_PID gone (TERM, no /exit-clean)"
    else
      spl_peer_rlog "$rid" WD-RETIRE FAIL "pid $WDT_PID survived SIGKILL: two sessions carry $id until a human clears it"
      spl_wdt_alert "$id" "$rid" WD-RETIRE "old pid $WDT_PID survived SIGKILL"
    fi
  fi
  if [[ -n "$WDT_PANE" ]]; then spl_rotate_tmux kill-window -t "$WDT_PANE" 2>/dev/null || true; fi
  if [[ -n "$WDT_SEAT" ]]; then spl_peer_loop_start "$id" "$rid"; fi
  spl_wdt_blocker "$id" "$rid" "$ts" "$hand"
  return 0
}

# spl_wdt_kill PID: TERM at once, KILL after ROTATE_TERM_WAIT (8.1 RETIRE: a
# stuck model runs no /exit-clean). 0 once gone.
spl_wdt_kill() {
  local pid="$1" t0
  spl_peer_alive "$pid" || return 0
  ${ROTATE_KILL:-sudo -n kill} -TERM "$pid" 2>/dev/null || true
  t0=$SECONDS; while (( SECONDS - t0 < ROTATE_TERM_WAIT )); do spl_peer_alive "$pid" || return 0; sleep 1; done
  ${ROTATE_KILL:-sudo -n kill} -KILL "$pid" 2>/dev/null || true
  t0=$SECONDS; while (( SECONDS - t0 < 5 )); do spl_peer_alive "$pid" || return 0; sleep 1; done
  return 1
}

# spl_wdt_alert ID RID PHASE REASON: an ask + one owner DM (spl_rotate_alert).
spl_wdt_alert() { PEER_RESTART_ID="$1" spl_peer_with_lib spl_rotate_alert watchdog "$2" "$3" "$4"; }

# ---- HANDOFF + SEED ---------------------------------------------------------------

# The `## watchdog` section of the handoff (8.1).
spl_wdt_section() {
  local id="$1" tr
  echo "## watchdog (spec 093 section 8)"
  echo
  echo "- situation: $WDT_CODE"
  echo "- evidence: ${WD_EVIDENCE:-$WDT_EV}"
  echo "- requested by: ${REQ_FROM:-${SPOOL_AGENT_ID:-the box watchdog}}; reason: ${REASON:-}"
  echo
  echo "### heartbeat.json"
  echo '```json'
  jq . "$SPOOL_ROOT/$id/heartbeat.json" 2>/dev/null || echo "UNAVAILABLE: no $SPOOL_ROOT/$id/heartbeat.json"
  echo '```'
  echo
  echo "### heartbeat.log, last 40 lines"
  echo '```text'
  tail -n 40 "$SPOOL_ROOT/$id/heartbeat.log" 2>/dev/null || echo "UNAVAILABLE: no heartbeat.log"
  echo '```'
  echo
  echo "### transcript, last 20 entries (type, error text)"
  tr="$WDT_CTX/transcript"
  [[ -s "$tr" ]] || tr="$(spl_rotate_transcript "$id")"
  if [[ -n "$tr" ]] && spl_rotate_as_agent test -s "$tr" 2>/dev/null; then
    spl_rotate_as_agent tail -n 400 "$tr" 2>/dev/null | jq -Rr 'fromjson? // empty | select(type == "object")
      | "- \(.timestamp // "-") \(.type // "?")\(if .isApiErrorMessage == true then " API ERROR: " + ([.message.content[]? | select(type == "object") | .text // empty] | join(" ") | .[0:120]) else "" end)"' \
      2>/dev/null | tail -n 20 || true
  else
    echo "UNAVAILABLE: no transcript"
  fi
  return 0
}

# The fresh session's brief: why, its original brief (the old session's
# first prompt), the handoff. Section 8.4: a lane continues its brief.
spl_wdt_seed() {
  local id="$1" rid="$2" ts="$3" hand="$4" tr first=""
  tr="$(spl_rotate_transcript "$id")"
  # a windowless seat: its last session's first prompt may be a rotation
  # seed with an ack long expired; the seat section replaces it
  [[ -n "${WDT_BOXENV:-}" ]] && tr=""
  if [[ -n "$tr" ]]; then
    first="$(spl_rotate_as_agent head -n 200 "$tr" 2>/dev/null | jq -Rr 'fromjson? // empty
      | select(.type == "user" and (.message.content | type) == "string") | .message.content' 2>/dev/null | head -c 6000 || true)"
  fi
  echo "# Brief: you are $id@$ROTATE_BOX, restarted by the watchdog ($rid)"
  echo
  echo "Your previous session stopped working and the box watchdog took it over"
  echo "(spec 093 section 8): situation $WDT_CODE, $WDT_EV."
  echo "Same id, same inbox, same workdir and branch. Do not greet; post nothing about"
  echo "the takeover: a peer investigates it on task wd-$id-$ts, not you."
  echo
  if [[ -n "${WDT_BOXENV:-}" ]]; then echo "1. Section A is your seat: take it back."
  else echo "1. Section A is the brief your previous session ran under: continue it."; fi
  echo "2. Section B is the mechanical handoff: what was in flight, and why it stopped."
  echo "3. Then drain your inbox: SPOOL_ROOT=$SPOOL_ROOT spool recv --as $id"
  echo
  if [[ -n "${WDT_BOXENV:-}" ]]; then
    spl_wdt_seat_section "$id"
  elif [[ -n "$first" ]]; then
    echo "## A. Your brief (the previous session's first prompt, verbatim)"
    echo
    printf '%s\n' "$first"
  else
    echo "## A. Your brief: UNAVAILABLE (no transcript); read section B and your inbox"
  fi
  echo
  echo "## B. The mechanical handoff"
  echo
  cat "$hand"
}

# Section A of a windowless seat's seed: no session carried the seat any
# more, so this is a fresh start of the seat, not a resume.
spl_wdt_seat_section() {
  local id="$1" role="seat (peer/seats)"
  case "$id" in
    "${LEASE_ORCH:-}") role="orchestrator (lease.conf LEASE_ORCH)" ;;
    "${LEASE_MASTER:-}") role="dispatcher (lease.conf LEASE_MASTER)" ;;
    "${LEASE_FAILOVER:-}") role="failover dispatcher (lease.conf LEASE_FAILOVER)" ;;
  esac
  echo "## A. Your seat: $id@$ROTATE_BOX, the $role"
  echo
  echo "No session carried $id on this box any more (no window, no process): you are a"
  echo "FRESH start of the seat, not a resume. Your role: $ROTATE_SPEC. Take the role"
  echo "back from the lease and the asks; the previous session's own brief is not"
  echo "repeated here (it may carry a rotation ack long expired)."
}

# ---- BLOCKER + RELAY ---------------------------------------------------------------

# One job for the peers (8.2): kind blocker, task wd-<id>-<ts>. --to
# orchestrator is the peers when this box has seats (spool-send.sh, 068 L4).
spl_wdt_blocker() {
  local id="$1" rid="$2" ts="$3" hand="$4" rc=0
  SPOOL_ROOT="$SPOOL_ROOT" bash "$WD_SEND" --from "$WD_FROM" --to orchestrator --kind blocker --task "wd-$id-$ts" --body \
    "WATCHDOG TAKEOVER (093 8.2): $id@$ROTATE_BOX was taken over: $WDT_CODE $WDT_EV. The fresh session is pid $ROTATE_NEW_PID in $ROTATE_NEW_PANE. Handoff: $hand. Investigate (8.3): read the handoff and the old transcript, post one paragraph here (what it was doing, why it stopped, whether its job was finished), then close this job; a new cause or a code defect opens a lane." \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  if (( rc < 10 && rc != 2 )); then spl_peer_rlog "$rid" WD-BLOCKER OK "task wd-$id-$ts to the peers"
  else spl_peer_rlog "$rid" WD-BLOCKER FAIL "spool-send exit $rc"; fi
  return 0
}

# A takeover of an agent on another box (section 10): a spool task to that
# box, run there by WD_RELAY_TO (the box's role id: `wd` is not a spool id
# under SPOOL_ID_RE), answered with the verdict on the same task.
spl_wdt_relay() {
  local id="$1" box="$2" reason="$3" req="$4" task rc=0 from
  task="wd-$id-req-$(date -u -d "@$(spl_lease_now)" +%Y%m%dT%H%MZ)"
  from="${req:-$WD_FROM}"; from="${from%@*}"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    echo "PLAN relay to $WD_RELAY_TO@$box on task $task: ID=$id REASON=$reason"
    return 0
  fi
  SPOOL_ROOT="$SPOOL_ROOT" bash "$WD_SEND" --from "$from" --to "$WD_RELAY_TO@$box" --kind task --task "$task" --body \
    "WATCHDOG TAKEOVER REQUEST (093 6.3, section 10) from $from: on $box run \`ID=$id REASON=\"$reason\" REQ_FROM=$from DRY_RUN=0 ./run -a do_spl_wd_takeover\` and answer its verdict (exit code and last line) on this task. Exit 3 = no situation hits, 4 = a guard refused." \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  if (( rc < 10 && rc != 2 )); then
    spl_wd_log "WD-TAKEOVER RELAY $id@$box ($reason) to $WD_RELAY_TO@$box task $task"
    echo "RELAYED $id@$box to $WD_RELAY_TO@$box on task $task"
    return 0
  fi
  do_log "FATAL the relay to $WD_RELAY_TO@$box failed (spool-send exit $rc)"
  return 1
}
