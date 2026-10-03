#!/bin/bash
#------------------------------------------------------------------------------
# @description Restart a LANE fresh instead of compacting it (spec 063 R-L1 /
# @description R-L2, sections 6, 7.2, 7.3). The lane keeps its id, worktree and
# @description branch; only the claude process is new:
# @description   GATE    - the lane has a live claude in a pane, its worktree has
# @description             no tracked change and no commit missing from
# @description             origin/master (it lands what is green first), and
# @description             the task has had fewer than lane_restarts_before_split
# @description             restarts; at that count it refuses and notes the
# @description             orchestrator "split this task" (R-L2, exit 3)
# @description   DISTIL  - the lane distil (section 6: header + brief path, 1b
# @description             NOTES tail, 1c tried and failed (required), 2 git
# @description             and spool state, outbox / inbox, session tail; no
# @description             pane scrape) to <hold>/<task>/<ID>.md, mode 0640;
# @description             the raw pane capture only as <ID>.pane.txt beside it
# @description   SPAWN   - respawn-pane -k in the SAME window, as the agent user,
# @description             never --resume, seeded "Read <distil>, then continue
# @description             the task"; the identity map adopts the new pid
# @description   HUMAN   - no claude process of the human's login user (the box
# @description             user) may exist
# @description   A failed SPAWN follows seat_fail_action (7.3): compact (default)
# @description   types /compact into the old pane, respawn kills the pane's
# @description   process and respawns once more from the distil; either way a
# @description   note to the orchestrator. A lane running this on itself is detached
# @description   first (setsid), since respawn-pane -k ends its own process.
# @description One line per step to stdout and <spool root>/dispatch/lane-restart.log;
# @description one do_spl_lifecycle_event per step when that action exists
# @description (LIFECYCLE_EVENTS=0 turns it off). Dry run unless DRY_RUN=0.
# @param ID (required) - the lane id, e.g. c-050
# @param DRY_RUN (optional) - 1 (default) prints the plan and the distil, touches nothing
# @param LANE_TASK (optional) - the task (hold dir name); default the brief file's name without .md
# @param LANE_BRIEF (optional) - the brief path; default the one the lane's seed names
# @param LANE_RESTART_REASON (optional) - size (default) | manual
# @param LANE_RESTARTS_BEFORE_SPLIT (optional) - 1..5; default the lifecycle config, else 2
# @param SEAT_FAIL_ACTION (optional) - compact | respawn; default the lifecycle config, else compact
# @param LANE_START_WAIT (optional) - seconds for the new claude to appear, default 120
# @param ROTATE_HOLD_DIR (optional) - default /var/tmp/CLE-parent-level/dispatch/hold
# @example ID=c-050 ./run -a do_spl_lane_restart
# @example ID=c-050 DRY_RUN=0 ./run -a do_spl_lane_restart
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_lane_restart() {
  spl_rotate_conf || return 1
  spl_is_agent_id "${ID:-}" || { do_log "FATAL ID must be a lane id like c-050, got '${ID:-}'"; return 1; }
  : "${LANE_START_WAIT:=120}"
  [[ "$LANE_START_WAIT" =~ ^[0-9]+$ ]] || { do_log "FATAL LANE_START_WAIT must be a whole number"; return 1; }
  [[ "${LANE_RESTART_REASON:=size}" =~ ^(size|manual)$ ]] || { do_log "FATAL LANE_RESTART_REASON must be size or manual"; return 1; }
  LANE_RESTART_LOG="$LEASE_DIR/lane-restart.log"
  [[ -z "${SEAT_FAIL_ACTION:-}" || "$SEAT_FAIL_ACTION" =~ ^(compact|respawn)$ ]] ||
    { do_log "FATAL SEAT_FAIL_ACTION must be compact or respawn"; return 1; }
  # the detached second half of a lane restarting itself
  if [[ "${LANE_RESTART_PHASE:-}" == spawn ]]; then spl_lane_restart_spawn; return; fi
  local rid id="$ID" wt pid pane task brief split n tr ctx
  rid="$(date -u +%Y%m%dT%H%M%SZ)-$id"
  pid="$(spl_rotate_pids "$id" | head -1)"
  [[ -n "$pid" ]] || { spl_lane_restart_log "$rid" GATE FAIL "no live claude carries $id"; return 1; }
  pane="$(spl_rotate_pane_of_pid "$pid")"
  [[ -n "$pane" ]] || { spl_lane_restart_log "$rid" GATE FAIL "$id pid $pid sits in no tmux pane"; return 1; }
  ROTATE_OLD_PID="$pid"
  wt="$(spl_rotate_workdir "$id")"
  [[ -d "$wt" && "$wt" != "$HOME" ]] || { spl_lane_restart_log "$rid" GATE FAIL "no worktree for $id"; return 1; }
  if ! spl_lane_restart_clean "$wt"; then
    spl_lane_restart_log "$rid" GATE FAIL "$wt: $LANE_DIRTY; land what is green (commit, rebase, push) first"
    return 1
  fi
  tr="$(spl_rotate_transcript "$id")"
  brief="${LANE_BRIEF:-$(spl_lane_restart_brief "$tr")}"
  task="${LANE_TASK:-$(basename "${brief:-x}" .md)}"
  [[ -n "${LANE_TASK:-$brief}" && "$task" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] ||
    { spl_lane_restart_log "$rid" GATE FAIL "no task: set LANE_TASK (the seed names no brief file)"; return 1; }
  LANE_RESTART_TASK="$task"
  split="$(spl_lane_restart_split_at)"
  n="$(spl_lane_restart_count "$task")"
  if (( n >= split )); then
    spl_lane_restart_log "$rid" GATE FAIL "task $task restarted $n time(s), lane_restarts_before_split=$split: split this task"
    if [[ "${DRY_RUN:-1}" == 0 ]]; then
      spl_rotate_note "${LEASE_ORCH:-orchestrator}" "$task" \
        "split this task: lane $id@$ROTATE_BOX hit $n restarts of $task (lane_restarts_before_split=$split, spec 063 R-L2); not restarted again. Hold: $ROTATE_HOLD_DIR/$task/" note
      spl_lane_restart_event "$rid" split fail "restarts $n >= $split"
    fi
    return 3
  fi
  LANE_DISTIL="$ROTATE_HOLD_DIR/$task/$id.md"
  ctx="$(spl_lane_restart_ctx_k "$tr")"
  spl_lane_restart_log "$rid" GATE OK "$id pid $pid, pane $pane, $wt clean, task $task restart $((n + 1)) of $split, ctx ${ctx:-?}k"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_lane_restart_log "$rid" DISTIL PLAN "-> $LANE_DISTIL (0640)"
    spl_lane_restart_log "$rid" SPAWN PLAN "respawn-pane -k -t $pane as ${SPOOL_AGENT_USER:-?}, never --resume: $(spl_lane_restart_seed)"
    spl_lane_restart_log "$rid" HUMAN PLAN "no claude of ${SPOOL_BOX_USER:-?}"
    ROTATE_OLD_PANE="$pane" spl_lane_restart_distil "$id" "$rid" "$task" "$brief" "$wt" "$tr" "$ctx" -
    return 0
  fi
  if ! { [[ -d "$ROTATE_HOLD_DIR/$task" ]] || mkdir -p "$ROTATE_HOLD_DIR/$task"; }; then
    spl_lane_restart_log "$rid" DISTIL FAIL "cannot create $ROTATE_HOLD_DIR/$task"; return 1
  fi
  if ! ( umask 0027; ROTATE_OLD_PANE="$pane" spl_lane_restart_distil "$id" "$rid" "$task" "$brief" "$wt" "$tr" "$ctx" "$LANE_DISTIL.tmp.$$" ) ||
     ! chmod 0640 "$LANE_DISTIL.tmp.$$" || ! mv -f "$LANE_DISTIL.tmp.$$" "$LANE_DISTIL"; then
    spl_lane_restart_log "$rid" DISTIL FAIL "cannot write $LANE_DISTIL"; return 1
  fi
  # the raw screen, for a human debugging only: the seed never names it
  ( umask 0027; spl_rotate_tmux capture-pane -p -J -S -300 -t "$pane" > "$ROTATE_HOLD_DIR/$task/$id.pane.txt" 2>/dev/null ) || true
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$id" "$rid" "${ctx:-}" >> "$ROTATE_HOLD_DIR/$task/restarts.tsv"
  spl_lane_restart_log "$rid" DISTIL OK "$LANE_DISTIL $(wc -l < "$LANE_DISTIL") lines"
  spl_lane_restart_event "$rid" handoff ok "$(wc -l < "$LANE_DISTIL") lines" "$ctx"
  export LANE_RESTART_PHASE=spawn LANE_RESTART_RID="$rid" LANE_RESTART_PID="$pid" LANE_RESTART_PANE="$pane" \
    LANE_RESTART_WT="$wt" LANE_RESTART_TASK="$task" LANE_RESTART_CTX="$ctx" LANE_DISTIL ID="$id"
  # respawn-pane -k ends every process of the pane: a lane restarting itself
  # would kill this script with it, so its second half runs detached
  if [[ "$(spl_rotate_claude_ancestor)" == "$pid" ]]; then
    spl_lane_restart_log "$rid" SPAWN OK "self-restart: detached, follow $LANE_RESTART_LOG"
    setsid -f env DRY_RUN=0 timeout $((LANE_START_WAIT + 300)) "$ROTATE_RUN" -a do_spl_lane_restart \
      >> "$LANE_RESTART_LOG.out" 2>&1 < /dev/null 7>&- 8>&- 9>&- || true
    return 0
  fi
  spl_lane_restart_spawn
}

# ---- SPAWN, HUMAN, the 7.3 fallback ---------------------------------------------

spl_lane_restart_spawn() {
  local rid="$LANE_RESTART_RID" id="$ID" pane="$LANE_RESTART_PANE" user stray action
  if ! spl_lane_restart_respawn "$rid" "$pane"; then
    action="$(spl_lane_restart_fail_action)"
    spl_lane_restart_fallback "$rid" "$pane" "$LANE_SPAWN_ERR" "$action" || return 1
  fi
  user="$(spl_rotate_user "$LANE_NEW_PID")"
  if [[ -n "${SPOOL_AGENT_USER:-}" && "$user" != "$SPOOL_AGENT_USER" ]]; then
    spl_lane_restart_log "$rid" SPAWN FAIL "new pid $LANE_NEW_PID runs as '$user', not the agent user $SPOOL_AGENT_USER"
    spl_lane_restart_event "$rid" restart fail "wrong user $user"
    return 1
  fi
  spl_rotate_ai adopt "$id" "$LANE_NEW_PID" >/dev/null 2>&1 || true
  spl_lane_restart_log "$rid" SPAWN OK "$id pid $LANE_NEW_PID in $pane as $user (old pid $LANE_RESTART_PID)"
  spl_lane_restart_event "$rid" restart ok "pid $LANE_NEW_PID" "${LANE_RESTART_CTX:-}"
  stray="$(spl_lane_restart_human_claude)"
  if [[ -n "$stray" ]]; then
    spl_lane_restart_log "$rid" HUMAN FAIL "claude of the human's login ${SPOOL_BOX_USER:-?}: $(tr '\n' ' ' <<<"$stray" | cut -c1-200)"
    spl_rotate_note "${LEASE_ORCH:-orchestrator}" "$LANE_RESTART_TASK" \
      "lane restart $rid: a claude runs as the human's login ${SPOOL_BOX_USER:-?} (pids: $(awk '{print $1}' <<<"$stray" | paste -sd' ')); restart it as the agent user" note
    return 1
  fi
  spl_lane_restart_log "$rid" HUMAN OK "no claude of ${SPOOL_BOX_USER:-?}"
  spl_lane_restart_log "$rid" DONE OK "$id restarted from $LANE_DISTIL"
  return 0
}

# spl_lane_restart_respawn RID PANE: respawn-pane -k, then wait for a claude
# carrying the id in that pane (not the old pid). Sets LANE_NEW_PID; non-zero
# with the reason in LANE_SPAWN_ERR.
spl_lane_restart_respawn() {
  local rid="$1" pane="$2" t0 p
  LANE_NEW_PID="" LANE_SPAWN_ERR=""
  if ! spl_rotate_tmux respawn-pane -k -t "$pane" -c "$LANE_RESTART_WT" "$(spl_lane_restart_pane_cmd)" 2>/dev/null; then
    LANE_SPAWN_ERR="tmux refused respawn-pane on $pane"
    spl_lane_restart_log "$rid" SPAWN FAIL "$LANE_SPAWN_ERR"
    return 1
  fi
  t0=$SECONDS
  while (( SECONDS - t0 < LANE_START_WAIT )); do
    for p in $(spl_rotate_pids "$ID"); do
      [[ "$p" != "$LANE_RESTART_PID" && "$(spl_rotate_pane_of_pid "$p")" == "$pane" ]] && { LANE_NEW_PID="$p"; return 0; }
    done
    sleep "$ROTATE_POLL"
  done
  LANE_SPAWN_ERR="no claude carrying $ID started in $pane within ${LANE_START_WAIT}s"
  spl_lane_restart_log "$rid" SPAWN FAIL "$LANE_SPAWN_ERR"
  return 1
}

# seat_fail_action (spec 063 section 11): env, else the lifecycle config when
# that action exists, else compact.
spl_lane_restart_fail_action() {
  local v="${SEAT_FAIL_ACTION:-}"
  if [[ -z "$v" ]] && { declare -F do_spl_lifecycle_config >/dev/null || [[ -f "$SPL_ROTATE_LIB_DIR/spl-lifecycle-config.func.sh" ]]; }; then
    v="$(spl_rotate_json -a do_spl_lifecycle_config | jq -r '.seat_fail_action // empty' 2>/dev/null || true)"
  fi
  [[ "$v" =~ ^(compact|respawn)$ ]] || v=compact
  echo "$v"
}

# 7.3, after a failed SPAWN: compact types /compact into the old pane while its
# process lives; respawn kills the pane's process and respawns once more from
# the distil (0 when that worked: the caller goes on with LANE_NEW_PID). What
# is left to do goes to the orchestrator in a note.
spl_lane_restart_fallback() {
  local rid="$1" pane="$2" why="$3" action="$4" how rc=1
  if [[ "$action" == respawn ]]; then
    if spl_rotate_alive "$LANE_RESTART_PID"; then
      ${ROTATE_KILL:-sudo -n kill} -TERM "$LANE_RESTART_PID" 2>/dev/null || true
    fi
    if spl_lane_restart_respawn "$rid" "$pane"; then
      how="seat_fail_action=respawn: the pane's process killed, respawned from the distil (pid $LANE_NEW_PID)"; rc=0
    else
      how="seat_fail_action=respawn: the second respawn failed too ($LANE_SPAWN_ERR): close the lane and respawn it from the hold dir"
      spl_lane_restart_event "$rid" restart fail "$why; respawn: $LANE_SPAWN_ERR"
    fi
  elif spl_rotate_alive "$LANE_RESTART_PID" && spl_rotate_type "$pane" /compact; then
    spl_rotate_tmux send-keys -t "$pane" Enter 2>/dev/null || true
    how="seat_fail_action=compact: /compact typed into $pane"
    spl_lane_restart_event "$rid" compact ok "fallback: $why"
  else
    how="seat_fail_action=compact, but the old process is gone or its box reads '$(printf '%s' "${ROTATE_INPUT_READ:-}" | tr '\n' '|' | cut -c1-80)': close the lane and respawn it from the hold dir"
    spl_lane_restart_event "$rid" restart fail "$why"
  fi
  spl_lane_restart_log "$rid" FALLBACK "$( (( rc == 0 )) && echo OK || echo DONE)" "$how"
  spl_rotate_note "${LEASE_ORCH:-orchestrator}" "$LANE_RESTART_TASK" \
    "lane restart $rid of $ID@$ROTATE_BOX: SPAWN failed ($why); $how. Distil: $LANE_DISTIL" note
  return "$rc"
}

# The pane's command, run by the tmux server (the box user): it hops to the
# agent user with spool_agent_exec and starts claude through spool-harness, as
# spawn-core does. The launch line travels base64-encoded, so no quote of the
# seed is parsed twice.
spl_lane_restart_pane_cmd() {
  local bin flags esc launch b64
  bin="${ROTATE_CLAUDE_BIN:-${CLAUDE_BIN:-}}"
  [[ -z "$bin" && -x "$ROTATE_AGENT_HOME/.local/bin/claude" ]] && bin="$ROTATE_AGENT_HOME/.local/bin/claude"
  if declare -F spool_claude_perm_flags >/dev/null; then flags="$(spool_claude_perm_flags)"; else flags="--permission-mode auto"; fi
  spool_dq_escape esc "$(spl_lane_restart_seed)"
  launch="export SPOOL_ROOT='$SPOOL_ROOT' SPOOL_AGENT_ID='$ID' CLE_TMUX_PANE='$LANE_RESTART_PANE'; cd '$LANE_RESTART_WT' && exec bash '$ROTATE_FEAT/scripts/spool-harness.sh' --as '$ID' --mirror -- '${bin:-claude}' --name '$(spool_decorate "$ID")' $flags \"$esc\""
  b64="$(printf '%s' "$launch" | base64 | tr -d '\n')"
  printf "env SPOOL_ROOT='%s' SPOOL_AGENT_USER='%s' SPOOL_BOX_USER='%s' SPOOL_AGENT_PTY=1 bash -c 'source \"%s/lib/spool-env.inc.sh\"; SPOOL_ENV_NO_BINS=1 spool_env_resolve; spool_agent_exec \"\$(printf %%s %s | base64 -d)\"; exec bash'" \
    "$SPOOL_ROOT" "${SPOOL_AGENT_USER:-}" "${SPOOL_BOX_USER:-}" "$ROTATE_FEAT" "$b64"
}

spl_lane_restart_seed() { printf 'Read %s, then continue the task' "${LANE_DISTIL:-<distil>}"; }

# The standing check: a claude binary run by the human's login user (the box
# user) prints its line; nothing when none, or when agents run as that user.
spl_lane_restart_human_claude() {
  [[ -n "${SPOOL_BOX_USER:-}" && "${SPOOL_BOX_USER}" != "${SPOOL_AGENT_USER:-}" ]] || return 0
  ${LANE_PS:-ps} -u "$SPOOL_BOX_USER" -o pid=,args= 2>/dev/null | awk '$2 ~ /(^|\/)claude$/ {sub(/^ +/, ""); print}' || true
}

# ---- GATE helpers ----------------------------------------------------------------

# 0 when WT has no tracked change and no commit missing from origin/master;
# else the reason in LANE_DIRTY. Untracked files do not count.
spl_lane_restart_clean() {
  local g=(git -c safe.directory='*' -C "$1") dirty ahead
  dirty="$("${g[@]}" status --porcelain --untracked-files=no 2>/dev/null | wc -l)"
  ahead="$("${g[@]}" rev-list --count origin/master..HEAD 2>/dev/null || echo '?')"
  LANE_DIRTY=""
  (( dirty == 0 )) || LANE_DIRTY="$dirty uncommitted tracked change(s)"
  [[ "$ahead" == 0 ]] || LANE_DIRTY="${LANE_DIRTY:+$LANE_DIRTY, }$ahead commit(s) not on origin/master"
  [[ -z "$LANE_DIRTY" ]]
}

# The brief path the lane's seed (its transcript's first user line) names.
spl_lane_restart_brief() {
  [[ -n "$1" ]] || return 0
  spl_rotate_as_agent head -n 50 "$1" 2>/dev/null | jq -r 'select(.type == "user") | .message.content | strings' 2>/dev/null |
    grep -oE -m1 'task brief at [^ ]+' | head -1 | sed -E 's/^task brief at //; s/[.,;]$//' || true
}

# The lane's last context in thousands: input + cache_read + cache_creation of
# the transcript's last assistant usage; empty when unreadable.
spl_lane_restart_ctx_k() {
  [[ -n "$1" ]] || return 0
  spl_rotate_as_agent tail -n 200 "$1" 2>/dev/null | jq -r 'select(.type == "assistant") | .message.usage // empty |
      ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) / 1000 | floor' 2>/dev/null |
    tail -1 || true
}

spl_lane_restart_count() {
  local f="$ROTATE_HOLD_DIR/$1/restarts.tsv"
  if [[ -f "$f" ]]; then grep -c . "$f" || true; else echo 0; fi
}

# lane_restarts_before_split: env, else the lifecycle config (brief 03) when
# that action exists, else 2 (spec 063 section 11).
spl_lane_restart_split_at() {
  local v="${LANE_RESTARTS_BEFORE_SPLIT:-}"
  if [[ -z "$v" ]] && { declare -F do_spl_lifecycle_config >/dev/null || [[ -f "$SPL_ROTATE_LIB_DIR/spl-lifecycle-config.func.sh" ]]; }; then
    v="$(spl_rotate_json -a do_spl_lifecycle_config | jq -r '.lane_restarts_before_split // empty' 2>/dev/null || true)"
  fi
  [[ "$v" =~ ^[1-5]$ ]] || v=2
  echo "$v"
}

# ---- the log and the events --------------------------------------------------------

spl_lane_restart_log() {
  local line
  line="$(date -u +%FT%TZ) $1 $2 $3 ${4:-}"
  printf '%s\n' "$line"
  [[ "$3" == PLAN || "${DRY_RUN:-1}" == 1 ]] && return 0
  echo "$line" >> "$LANE_RESTART_LOG" 2>/dev/null || true
}

# spl_lane_restart_event RID EVENT OUTCOME DETAIL [CTX_K]: one row for the
# agent_lifecycle_events table through do_spl_lifecycle_event (brief 03), fire
# and forget, when that action exists; never in a dry run, never with
# LIFECYCLE_EVENTS=0. Without it the step's log line is the record.
spl_lane_restart_event() {
  [[ "${LIFECYCLE_EVENTS:-1}" != 0 && "${DRY_RUN:-1}" == 0 ]] || return 0
  declare -F do_spl_lifecycle_event >/dev/null || [[ -f "$SPL_ROTATE_LIB_DIR/spl-lifecycle-event.func.sh" ]] || return 0
  ( env LIFECYCLE_EVENT="$2" LIFECYCLE_ROLE=lane LIFECYCLE_AGENT="$ID" LIFECYCLE_REASON="${LANE_RESTART_REASON:-size}" \
      LIFECYCLE_RID="$1" LIFECYCLE_OUTCOME="$3" LIFECYCLE_DETAIL="${4:0:200}" LIFECYCLE_CTX_BEFORE_K="${5:-}" \
      timeout 60 "$ROTATE_RUN" -a do_spl_lifecycle_event >/dev/null 2>&1 7>&- 8>&- 9>&- & ) || true
  return 0
}

# ---- the distil (spec 063 section 6, the lane form) ----------------------------------

# spl_lane_restart_distil ID RID TASK BRIEF WT TRANSCRIPT CTX_K OUT ("-" prints)
spl_lane_restart_distil() {
  if [[ "$8" == - ]]; then spl_lane_restart_distil_body "$@"; else spl_lane_restart_distil_body "$@" > "$8"; fi
}

spl_lane_restart_distil_body() {
  local id="$1" rid="$2" task="$3" brief="$4" wt="$5" tr="$6" ctx="$7" age notes branch tried
  age="$(spl_rotate_age "${ROTATE_OLD_PID:-0}")"
  notes="$SPOOL_ROOT/$id/NOTES.md"
  branch="$(git -c safe.directory='*' -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  echo "# $id@$ROTATE_BOX lane distil, restart $rid"
  echo
  echo "Written by do_spl_lane_restart from files, /proc and tmux (spec 063 section 6); no model wrote it."
  echo "- task: $task; brief: ${brief:-UNAVAILABLE: the seed names no brief file}"
  echo "- old session: pid ${ROTATE_OLD_PID:-?}, $(( ${age:-0} / 60 )) min old, pane ${ROTATE_OLD_PANE:-?}, context ${ctx:-?}k"
  echo "- reason: ${LANE_RESTART_REASON:-size}; worktree $wt"
  echo "- transcript: ${tr:-UNAVAILABLE: no session id in the identity map}"
  echo "- you keep the id $id, the worktree and the branch: re-read the brief, then go on from section 1b"
  echo
  echo "## 1b. NOTES (the last ${NOTES_TAIL_LINES:-40} lines of $notes)"
  if [[ -r "$notes" ]]; then tail -n "${NOTES_TAIL_LINES:-40}" "$notes" | cut -c1-300; else echo "none"; fi
  echo
  echo "## 1c. Tried and failed (every tried / failed line of $notes): do not repeat these"
  tried="$(grep -E '^[^ ]+ (tried|failed) ' "$notes" 2>/dev/null | tail -n 30 | cut -c1-300 || true)"
  printf '%s\n' "${tried:-none recorded}"
  echo
  echo "## 2. In flight: git and spool state"
  echo "- branch: $branch"
  echo "- git status --short (tracked):"
  git -c safe.directory='*' -C "$wt" status --short --untracked-files=no 2>/dev/null | head -n 15 | sed 's/^/    /' | grep . || echo "    clean"
  echo "- commits not on origin/master:"
  git -c safe.directory='*' -C "$wt" log --oneline -10 origin/master..HEAD 2>/dev/null | sed 's/^/    /' | grep . || echo "    none (all pushed)"
  echo "- last spool message sent: $(spl_lane_restart_last_msg "$SPOOL_ROOT/$id/outbox" to)"
  echo "- last spool message received: $(spl_lane_restart_last_msg "$SPOOL_ROOT/$id/inbox" "$SPOOL_ROOT/$id/archive")"
  echo
  echo "## 4. Sent by the old session in its last hour (its outbox)"
  spl_rotate_msgs "$SPOOL_ROOT/$id/outbox" to 60 40 160
  echo
  echo "## 5. Unread inbox: $(find "$SPOOL_ROOT/$id/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) message(s), the 20 newest"
  spl_rotate_msgs "$SPOOL_ROOT/$id/inbox" from "" 20 120
  echo
  echo "## 8. Session tail (the old transcript: last 10 user lines, last 10 assistant texts)"
  spl_rotate_transcript_tail "$tr"
  echo
  return 0
}

# spl_lane_restart_last_msg DIR... : the newest spool message in those dirs,
# its header and the first 160 chars of its body; "none" when there is none.
# A first argument "to" (after the dir) shows the recipient instead of the sender.
spl_lane_restart_last_msg() {
  local who=from f
  local -a dirs=()
  for f in "$@"; do if [[ "$f" == to ]]; then who=to; else dirs+=("$f"); fi; done
  f="$(find "${dirs[@]}" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [[ -n "$f" ]] || { echo none; return 0; }
  jq -r --arg who "$who" '"\(.ts // "?") \(if $who == "to" then "-> " + (.to // "?") else "<- " + (.from // "?") end) \(.kind // "?") [\(.task_id // "" | .[0:12])] \((.body // "") | gsub("\\s+"; " ") | .[0:160])"' "$f" 2>/dev/null || echo "UNAVAILABLE: $f unreadable"
}
