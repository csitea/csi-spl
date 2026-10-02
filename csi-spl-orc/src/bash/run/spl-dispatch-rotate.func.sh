#!/bin/bash
#------------------------------------------------------------------------------
# @description Rotate this machine's dispatchers every hour (owner 2026-10-02,
# @description SPEC-spool-fleet-roles.md 4.4, specs/060): a long-running
# @description dispatcher carries an ever larger context, burns usage and
# @description stalls, so each role gets a FRESH session under the SAME id -
# @description the master M first while the failover F acts for it, then F.
# @description The ids stay bound to their roles (spec 058 3.0: CLE-002
# @description master, CLE-003 failover), so text sent to CLE-002 always
# @description reaches the master. Mechanical: no model decides or writes
# @description anything here; one line per step in <dir>/rotate.log.
# @description   1 precheck  lease.conf present, the last rotation old enough
# @description   2 heal      F has no live process: spawn what is missing, stop
# @description   3 handoff   <dir>/handoff/<stamp>-<M>.md, assembled by script:
# @description               lease, M's unread inbox, M's last-hour outbox, M's
# @description               last terminal lines (redacted), open asks, lane map
# @description   4 hold      <dir>/rotate.hold names M: the lease loops treat M
# @description               as not able to act, F takes the lease (local:
# @description               written here; fleet: the fleet loop) and acts.
# @description               A busy M is rotated anyway (owner decision 1)
# @description   5 replace   the fresh M starts BESIDE the old one, seeded with
# @description               its brief + the handoff + the ack command; ack =
# @description               a message on task dispatch-rotate-<stamp> in M's
# @description               outbox. No start / no ack -> the fresh one is
# @description               killed, the OLD session keeps the role, and an
# @description               ask + an owner DM raise it (owner decision 2).
# @description               Ack -> /exit-clean no-close in the old pane, force-
# @description               killed after ROTATE_EXIT_WAIT s (decision 4), old
# @description               window closed
# @description   6 release   the hold goes: M renews, the handback tells F STANDBY
# @description   7 refresh   once M has held the lease ROTATE_SETTLE s, F is
# @description               replaced the same way (when older than
# @description               ROTATE_REFRESH_MIN minutes)
# @description Never zero dispatchers (the old session lives until the new one
# @description acks) and never two masters (the hold keeps every M process off
# @description the lease while two run). One run at a time (flock rotate.lock).
# @description Dry run unless DRY_RUN=0: PLAN lines, nothing touched, no wait.
# @param DISPATCH_ROTATE_MIN (optional) - minutes between rotations, default 60
# @param ROTATE_FORCE (optional) - 1 rotates even when the last rotation is recent
# @param ROTATE_IDLE_WAIT (optional) - s to wait for an idle pane before rotating anyway, default 60
# @param ROTATE_SPAWN_WAIT (optional) - s to wait for the fresh process, default 180
# @param ROTATE_ACK_WAIT (optional) - s to wait for the fresh session's ack, default 600
# @param ROTATE_EXIT_WAIT (optional) - s after /exit-clean before SIGTERM, default 300
# @param ROTATE_LEASE_WAIT (optional) - s to wait for the lease to move, default 180
# @param ROTATE_SETTLE (optional) - s the fresh master holds the lease before F is refreshed, default 120
# @param ROTATE_REFRESH_MIN (optional) - F older than this (minutes) is refreshed, default 50
# @param ROTATE_HOLD_MAX (optional) - s after which the lease loops ignore a hold, default 1800
# @param ROTATE_REPO (optional) - the checkout the dispatcher worktrees branch off, default the main checkout of this tree
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_dispatch_rotate
# @example DRY_RUN=0 ./run -a do_spl_dispatch_rotate
# @example DRY_RUN=0 ROTATE_FORCE=1 ./run -a do_spl_dispatch_rotate
#------------------------------------------------------------------------------
# the lease helpers (ids, lock, pid walk, hold), also when sourced on its own
declare -F spl_lease_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"
# classify_screen, for the short idle wait
# shellcheck source=../features/spawn-agents/lib/agent-state.inc.sh
. "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/agent-state.inc.sh" 2>/dev/null || true

do_spl_dispatch_rotate() {
  spl_lease_init || return 1
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  ROT_DRY=1; [[ "${DRY_RUN:-1}" == 0 ]] && ROT_DRY=0
  [[ -f "$LEASE_CONF" ]] || { spl_rot_say precheck "SKIP no $LEASE_CONF - this box runs no dispatchers"; return 0; }
  local rc
  exec 7> "$LEASE_DIR/rotate.lock"
  flock -n 7 || { spl_rot_say precheck "SKIP another rotation runs"; return 0; }
  spl_rot_run; rc=$?
  exec 7>&-
  return $rc
}

spl_rot_run() {
  # lease.conf is the ONE source of the roles, never the caller's environment
  unset LEASE_MASTER LEASE_FAILOVER
  spl_lease_ids master failover orch || return 1
  local m="$LEASE_MASTER" f="$LEASE_FAILOVER" min="${DISPATCH_ROTATE_MIN:-60}" now last mpid fpid
  [[ "$m" != "$f" ]] || { spl_rot_say precheck "FATAL lease.conf names $m as master AND failover"; return 1; }
  [[ "$min" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL DISPATCH_ROTATE_MIN must be minutes, got '$min'"; return 1; }
  now="$(spl_lease_now)"
  last="$(cat "$LEASE_DIR/rotate.last" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  # 5 min of slack: an hourly cron must not skip a turn over a few seconds
  if [[ "${ROTATE_FORCE:-0}" != 1 ]] && (( now - last < min * 60 - 300 )); then
    spl_rot_say precheck "SKIP last rotation $(( (now - last) / 60 )) min ago (< $min)"; return 0
  fi
  ROT_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  mpid="$(spl_lease_agent_pid "$m")"; fpid="$(spl_lease_agent_pid "$f")"
  spl_rot_say precheck "master=$m pid=${mpid:-none} failover=$f pid=${fpid:-none}"

  # 2. heal: with no live failover nobody could act while M is replaced
  if [[ -z "$fpid" ]]; then
    spl_rot_say heal "failover $f has no live process: spawn it fresh, no rotation this run"
    spl_rot_replace "$f" failover "" || return 1
    return 0
  fi

  # 3. handoff
  local handoff="$LEASE_DIR/handoff/$ROT_STAMP-$m.md"
  if (( ROT_DRY )); then
    spl_rot_say handoff "PLAN write $handoff"
  else
    mkdir -p "$LEASE_DIR/handoff" && spl_rot_handoff "$m" "$f" > "$handoff" ||
      { spl_rot_say handoff "FATAL could not write $handoff"; return 1; }
    spl_rot_say handoff "$handoff ($(wc -l < "$handoff") lines)"
  fi

  # 4. hold: F acts for M from here until the release
  spl_rot_hold "$m" "$f" "$handoff" || return 1

  # 5. replace M; on failure the old M keeps the role
  if ! spl_rot_replace "$m" master "$handoff"; then
    spl_rot_release "$m"
    [[ -n "$mpid" ]] && spl_rot_send "$m" note dispatch-lease "DISPATCH LEASE: you are ACTIVE again - the rotation failed and you keep the master role." >/dev/null
    spl_rot_alert "dispatch rotation FAILED on $(spl_rot_machine): no fresh $m - the old session keeps the master role. Log: $LEASE_DIR/rotate.log"
    return 1
  fi

  # 6. release
  spl_rot_release "$m"
  spl_rot_wait_holder "$m" || spl_rot_say release "WARN the lease did not come back to $m in ${ROTATE_LEASE_WAIT:-180}s"

  # 7. refresh the failover too
  spl_rot_refresh_failover "$m" "$f"

  if (( ROT_DRY )); then
    do_log "OK DRY_RUN nothing was touched - re-run with DRY_RUN=0 to rotate"
  else
    spl_lease_now > "$LEASE_DIR/rotate.last"
    spl_rot_say "done" "fresh master $m (handoff $handoff)"
    spl_rot_send "$LEASE_ORCH" note dispatch-rotate "dispatch rotation done on $(spl_rot_machine): a fresh $m holds the lease; handoff $handoff; log $LEASE_DIR/rotate.log" >/dev/null
  fi
  return 0
}

# One line per step, to stdout and rotate.log (a dry run logs nothing).
spl_rot_say() {
  echo "STEP $1 $2"
  (( ${ROT_DRY:-1} )) || echo "$(date -u +%FT%TZ) $1 $2" >> "$LEASE_DIR/rotate.log"
}

spl_rot_machine() { echo "${LEASE_MACHINE:-$(spl_desk_box_default)}"; }

# Owner decision 2: an ask in the ask book (a blocker to the orchestrator is
# one) AND a DM to the owner (lease.conf ASKS_OWNER).
spl_rot_alert() {
  local owner
  spl_rot_say alert "$1"
  (( ROT_DRY )) && return 0
  spl_rot_send "$LEASE_ORCH" blocker dispatch-rotate "BLOCKER (dispatch rotation): $1" ask >/dev/null
  owner="$(sed -n 's/^ASKS_OWNER=\(HUM-[0-9]*\)$/\1/p' "$LEASE_CONF" 2>/dev/null | tail -1)"
  if [[ -n "${ROTATE_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $ROTATE_OWNER_CMD <<<"$1"
  elif [[ -n "$owner" && -n "${LEASE_TENANT:-}" && -n "${LEASE_ENV:-}" ]]; then
    ( ENV="$LEASE_ENV" TENANT_ID="$LEASE_TENANT" DESK_BOX="${LEASE_DESK_BOX:-$(spl_desk_box_default)}" \
        DESK_AGENT="$LEASE_ORCH" DESK_TO="$owner" DESK_TASK="$(cat /proc/sys/kernel/random/uuid)" \
        DESK_KIND=blocker DESK_BODY="BLOCKER (dispatch rotation): $1" DRY_RUN=0 "$PROJ_PATH/run" -a do_spl_desk_reply ) \
      >> "$LEASE_DIR/rotate.out" 2>&1 || spl_rot_say alert "WARN the owner DM failed (log $LEASE_DIR/rotate.out)"
  else
    spl_rot_say alert "WARN no owner DM: lease.conf has no ASKS_OWNER / LEASE_TENANT / LEASE_ENV"
  fi
  return 0
}

# tmux as the box user (ROTATE_TMUX replaces it in the tests).
spl_rot_tm() {
  if [[ -n "${ROTATE_TMUX:-}" ]]; then "$ROTATE_TMUX" "$@"; return; fi
  if [[ -z "${SPOOL_TM+x}" ]]; then
    # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" && spool_env_resolve && spool_tmux_argv || return 1
  fi
  "${SPOOL_TM[@]}" "$@"
}

# The pane of <id>: its newest registry row, accepted only while that pane's
# window still carries the id (a reused pane number is someone else's).
spl_rot_pane() {
  local id="$1" pane name
  pane="$(awk -F'\t' -v id="$id" '$1 == id {p = $3} END {print p}' "${SPOOL_ROOT:-/var/spool-hub}/registry.tsv" 2>/dev/null)"
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
  name="$(spl_rot_tm display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"
  [[ "$name" == *"$id"* ]] && echo "$pane"
  return 0
}

# Every live claude pid carrying SPOOL_AGENT_ID=<id>, one per line (the lease
# picks the lowest; here the old and the fresh session run side by side).
spl_rot_pids() {
  local id="$1" root="${LEASE_PROC_ROOT:-/proc}" d comm
  local -a other=()
  {
    for d in "$root"/[0-9]*; do
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null
      [[ "$comm" == claude ]] || continue
      if [[ -r "$d/environ" ]]; then
        grep -qzx "SPOOL_AGENT_ID=$id" "$d/environ" 2>/dev/null && echo "${d##*/}"
      else
        other+=("${d##*/}")
      fi
    done
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" | awk -v id="$id" '$2 == id {print $1}'
    fi
  } | sort -n
}

# Wait up to ROTATE_IDLE_WAIT s for an idle pane; busy is logged, never a stop.
spl_rot_wait_idle() {
  local id="$1" pane="$2" waited=0 wait="${ROTATE_IDLE_WAIT:-60}" scr prev=""
  (( ROT_DRY )) && { spl_rot_say idle "PLAN wait up to ${wait}s for $id (${pane:-no pane}) to be idle, then go on anyway"; return 0; }
  [[ -n "$pane" ]] && declare -F classify_screen >/dev/null || return 0
  while (( waited < wait )); do
    scr="$(spl_rot_tm capture-pane -p -t "$pane" 2>/dev/null)"
    [[ "$(classify_screen "$scr")" == idle && "$scr" == "$prev" ]] && { spl_rot_say idle "$id ($pane) idle"; return 0; }
    prev="$scr"
    spl_rot_sleep "${ROTATE_IDLE_POLL:-10}"; waited=$((waited + ${ROTATE_IDLE_POLL:-10} + 1))
  done
  spl_rot_say idle "$id ($pane) busy after ${wait}s - rotating anyway (owner decision 1)"
}

spl_rot_sleep() { (( $1 > 0 )) && sleep "$1"; return 0; }

# The handoff, assembled from files and actions only.
spl_rot_handoff() {
  local m="$1" f="$2" root="${SPOOL_ROOT:-/var/spool-hub}" n=0 x pane
  printf '# Dispatcher handoff: %s, rotated %s\n\n' "$m" "$ROT_STAMP"
  printf -- '- written by do_spl_dispatch_rotate on %s - assembled by script, no model wrote it\n' "$(spl_rot_machine)"
  printf -- '- %s acts for %s until the fresh session acks\n' "$f" "$m"
  printf -- '- dispatch lease: %s; orch lease: %s\n\n' "$(cat "$LEASE_FILE" 2>/dev/null || echo none)" "$(cat "$LEASE_FILE.orch" 2>/dev/null || echo none)"
  printf '## Unread in the %s inbox (`spool recv --as %s`)\n\n' "$m" "$m"
  for x in "$root/$m/inbox"/*.json; do
    [[ -f "$x" ]] || continue
    n=$((n + 1)); spl_rot_msg_line "$x"
  done
  (( n )) || echo "none"
  printf '\n## %s outbox, last hour (newest last, at most %s)\n\n' "$m" "${ROTATE_HANDOFF_OUT:-25}"
  n=0
  while IFS= read -r x; do
    n=$((n + 1)); spl_rot_msg_line "$x"
  done < <(find "$root/$m/outbox" -maxdepth 1 -name '*.json' -mmin -60 2>/dev/null | sort | tail -n "${ROTATE_HANDOFF_OUT:-25}")
  (( n )) || echo "none"
  printf '\n## The old session'"'"'s last terminal lines (redacted)\n\n'
  pane="$(spl_rot_pane "$m")"
  if [[ -n "$pane" ]]; then
    echo '```'
    spl_rot_tm capture-pane -p -J -S -200 -t "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' |
      tail -n "${ROTATE_HANDOFF_TERM:-40}" | spl_rot_redact
    echo '```'
  else
    echo "no pane"
  fi
  printf '\n## Open asks to the orchestrator\n\n'
  spl_rot_cmd_out "${ROTATE_ASKS_CMD:-$PROJ_PATH/run -a do_spl_asks_open}"
  printf '\n## Lane map\n\n'
  spl_rot_cmd_out "${ROTATE_LANES_CMD:-bash $PROJ_PATH/src/bash/features/spawn-agents/scripts/lane-map.sh}"
}

# The box's one redaction pass; without it the lines are left out, not leaked.
spl_rot_redact() {
  local py="$PROJ_PATH/src/bash/features/spawn-agents/lib/spool_redact.py"
  if [[ -f "$py" ]]; then python3 "$py" 2>/dev/null; else cat > /dev/null; echo "(no spool_redact.py - lines left out)"; fi
}

# "- <ts> <from> -> <to> [<kind>, task <t>] <id8>: <first 200 chars>"
spl_rot_msg_line() {
  jq -r '"- \(.ts // "?") \(.from // "?") -> \(.to // "?") [\(.kind // "?"), task \(.task_id // "-")] \(.msg_id // "" | .[0:8]): \(.body // "" | gsub("\n"; " ") | .[0:200])"' "$1" 2>/dev/null ||
    echo "- (unreadable) ${1##*/}"
}

# A command's output in a fence, capped; a failure is a line, never a stop.
spl_rot_cmd_out() {
  local out rc
  # shellcheck disable=SC2086 # a command line, split on purpose
  out="$(timeout "${ROTATE_CMD_TIMEOUT:-60}" $1 2>&1)"; rc=$?
  echo '```'
  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -vE '\[(DEBUG|INFO)\]' | head -n "${ROTATE_HANDOFF_LINES:-60}"
  echo '```'
  (( rc )) && echo "(exit $rc)"
  return 0
}

# Write the hold and move the lease to F. Local mode writes the lease here
# (under its lock) with the failover marker, so M's first renewal after the
# release is the ordinary handback; fleet mode waits for the fleet loop.
spl_rot_hold() {
  local m="$1" f="$2" handoff="$3" me
  if (( ROT_DRY )); then
    spl_rot_say hold "PLAN $LEASE_DIR/rotate.hold = $m; lease -> $f; $f ACTIVE, $m STANDBY"; return 0
  fi
  printf '%s %s\n' "$m" "$(spl_lease_now)" > "$LEASE_DIR/rotate.hold.tmp.$$" &&
    mv -f "$LEASE_DIR/rotate.hold.tmp.$$" "$LEASE_DIR/rotate.hold" ||
    { spl_rot_say hold "FATAL cannot write $LEASE_DIR/rotate.hold"; return 1; }
  spl_lease_log "ROTATE hold $m (do_spl_dispatch_rotate)"
  spl_rot_say hold "rotate.hold = $m"
  spl_lease_conf
  me="$(spl_rot_machine)"
  if [[ -z "${LEASE_FLEET:-}" ]]; then
    spl_lease_locked spl_rot_lease_to "$f"
    spl_rot_say hold "lease -> $f"
  else
    spl_lease_read
    if [[ "$LH" == "$m@$me" ]]; then
      spl_rot_wait_holder "$f" || {
        spl_rot_release "$m"
        spl_rot_alert "dispatch rotation stopped on $me: the fleet lease did not move to $f@$me in ${ROTATE_LEASE_WAIT:-180}s - $m keeps the role"
        return 1
      }
    else
      spl_rot_say hold "the fleet dispatch lease is $LH, not $m@$me - nothing to move"
    fi
  fi
  spl_rot_send "$f" note dispatch-lease "DISPATCH LEASE: you are now ACTIVE (hourly rotation: $m gets a fresh session). Dispatch, including $m's unread inbox (spool recv --as $m), until told STANDBY. Handoff: $handoff" >/dev/null
  spl_rot_send "$m" note dispatch-lease "DISPATCH LEASE: STANDBY - hourly rotation, a fresh $m session takes over from you in a moment and $f acts meanwhile. Finish the line you are typing, then route, spawn and post nothing more." >/dev/null
  return 0
}

spl_rot_lease_to() {
  spl_lease_write "$1"; touch "$LEASE_FILE.failover"
  spl_lease_log "ROTATE: lease -> $1"
}

spl_rot_release() {
  (( ROT_DRY )) && { spl_rot_say release "PLAN remove $LEASE_DIR/rotate.hold"; return 0; }
  rm -f "$LEASE_DIR/rotate.hold"
  spl_lease_log "ROTATE release $1"
  spl_rot_say release "rotate.hold removed - $1 renews"
  # local mode: the lease names M at once (the renew loop would within a
  # tick); the failover marker stays, so the watch's handback tells F STANDBY
  spl_lease_conf
  [[ -z "${LEASE_FLEET:-}" && -n "$(spl_lease_agent_able "$1")" ]] && spl_lease_locked spl_rot_lease_to "$1"
  return 0
}

# 0 once the lease names <id> (bare, or <id>@<this machine> in fleet mode).
spl_rot_wait_holder() {
  local id="$1" waited=0 me
  (( ROT_DRY )) && return 0
  me="$(spl_rot_machine)"
  while :; do
    spl_lease_read
    [[ "$LH" == "$id" || "$LH" == "$id@$me" ]] && { spl_rot_say lease "holder $LH"; return 0; }
    (( waited >= ${ROTATE_LEASE_WAIT:-180} )) && return 1
    spl_rot_sleep "${ROTATE_LEASE_POLL:-5}"; waited=$((waited + ${ROTATE_LEASE_POLL:-5} + 1))
  done
}

# spool-send on <task> (5th arg "ask": an ask in the ask book); prints the
# msg_id (empty when nothing was delivered).
spl_rot_send() {
  local to="$1" kind="$2" task="$3" body="$4" out rc
  local send="${ROTATE_SEND:-${LEASE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}}"
  local -a ask=(--no-ask)
  [[ "${5:-}" == ask ]] && ask=(--ask "$kind")
  out="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$LEASE_ORCH" --to "$to" \
    --kind "$kind" --task "$task" "${ask[@]}" --body "$body" 2>/dev/null 7>&- 8>&-)"; rc=$?
  # spool-send.sh: 1-9 = delivered, only the poke did not ring
  (( rc >= 10 || rc == 2 )) && { spl_rot_say send "WARN could not tell $to (spool-send exit $rc)"; return 0; }
  sed -n 's/.*"msg_id": *"\([^"]*\)".*/\1/p' <<<"$out" | head -1
}

# Replace <id> (role master|failover) by a fresh session beside the old one.
# 0 = the fresh one acked and the old one is gone; 1 = the old one (if any)
# still holds the role and the fresh one was killed.
spl_rot_replace() {
  local id="$1" role="$2" handoff="$3" old oldpane task brief new waited=0
  task="dispatch-rotate-$ROT_STAMP-$id"
  old="$(spl_rot_pids "$id" | tr '\n' ' ')"; old="${old% }"
  oldpane="$(spl_rot_pane "$id")"
  [[ -n "$old" ]] && spl_rot_wait_idle "$id" "$oldpane"
  brief="$LEASE_DIR/handoff/$ROT_STAMP-$id.brief.md"
  if (( ROT_DRY )); then
    spl_rot_say replace "PLAN spawn a fresh $id ($role) beside pid ${old:-none}, seeded with $brief; wait ${ROTATE_ACK_WAIT:-600}s for a message on $task in its outbox; then /exit-clean no-close in ${oldpane:-<no pane>}, SIGTERM after ${ROTATE_EXIT_WAIT:-300}s"
    return 0
  fi
  mkdir -p "$LEASE_DIR/handoff" && spl_rot_brief "$id" "$role" "$handoff" "$task" > "$brief" ||
    { spl_rot_say replace "FATAL no brief for $id (run do_spl_dispatch_setup once)"; return 1; }
  spl_rot_spawn "$id" "$role" "$brief" || { spl_rot_say replace "FAIL the spawn of $id failed (log $LEASE_DIR/rotate.out)"; return 1; }
  while :; do
    new="$(spl_rot_pids "$id" | grep -vxF -f <(tr ' ' '\n' <<<"${old:-none}") | tail -1)"
    [[ -n "$new" ]] && break
    (( waited >= ${ROTATE_SPAWN_WAIT:-180} )) && { spl_rot_say replace "FAIL the fresh $id did not start in ${ROTATE_SPAWN_WAIT:-180}s"; return 1; }
    spl_rot_sleep "${ROTATE_SPAWN_POLL:-5}"; waited=$((waited + ${ROTATE_SPAWN_POLL:-5} + 1))
  done
  spl_rot_say replace "fresh $id pid=$new beside ${old:-none}"
  if ! spl_rot_wait_ack "$id" "$task"; then
    spl_rot_kill_pids "$id" "$new"
    return 1
  fi
  if [[ -n "$old" ]]; then
    spl_rot_retire "$id" "$oldpane" "$old" "$new"
  fi
  return 0
}

# The role's brief (rendered by do_spl_dispatch_setup) + this rotation's part.
spl_rot_brief() {
  local id="$1" role="$2" handoff="$3" task="$4" base="${DISPATCH_BRIEF_DIR:-$LEASE_DIR/briefs}/brief-dispatcher-$1.md"
  [[ -f "$base" ]] || return 1
  cat "$base"
  printf '\n## Hourly rotation (%s)\n\n' "$ROT_STAMP"
  printf 'You are a FRESH %s session for %s; the previous one is retired once you ack.\n\n' "$role" "$id"
  if [[ -n "$handoff" ]]; then
    printf '1. Read the handoff %s and take over every routing, owed answer and unread message it lists.\n' "$handoff"
  else
    printf '1. Read nothing more: confirm the lease (do_spl_dispatch_lease LEASE_CMD=show) and stay as your role says.\n'
  fi
  printf '2. Ack, exactly once, before anything else is sent:\n\n'
  printf '   bash %s/src/bash/features/spawn-agents/scripts/spool-send.sh --from %s --to %s --kind note --task %s --body "%s fresh session up"\n\n' \
    "$PROJ_PATH" "$id" "$LEASE_ORCH" "$task" "$id"
  printf 'No ack in %s s and this session is stopped, the old one keeps the role.\n' "${ROTATE_ACK_WAIT:-600}"
}

# A fresh session for <id> in a NEW window (spawn-window.sh: auto mode, the
# mirror on, as the agent user, the same mailbox: SPAWN_REUSE_ID=1).
spl_rot_spawn() {
  local id="$1" role="$2" brief="$3" repo common
  if [[ -n "${ROTATE_SPAWN:-}" ]]; then "$ROTATE_SPAWN" "$id" "$role" "$brief" >> "$LEASE_DIR/rotate.out" 2>&1; return; fi
  repo="${ROTATE_REPO:-}"
  if [[ -z "$repo" ]]; then
    common="$(git -C "$PROJ_PATH/.." rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ "$common" == */.git ]]; then repo="${common%/.git}"; else repo="$(cd "$PROJ_PATH/.." && pwd)"; fi
  fi
  env SPAWN_REUSE_ID=1 bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh" \
    claude "$id" "$repo" "$brief" "dispatcher-$role" >> "$LEASE_DIR/rotate.out" 2>&1
}

# 0 once <id>'s outbox holds a message on <task>.
spl_rot_wait_ack() {
  local id="$1" task="$2" waited=0 wait="${ROTATE_ACK_WAIT:-600}"
  while :; do
    if grep -lqE "\"task_id\": *\"$task\"" "${SPOOL_ROOT:-/var/spool-hub}/$id/outbox"/*.json 2>/dev/null; then
      spl_rot_say ack "$id acked $task after ~${waited}s"; return 0
    fi
    (( waited >= wait )) && { spl_rot_say ack "FAIL $id did not ack $task in ${wait}s"; return 1; }
    spl_rot_sleep "${ROTATE_ACK_POLL:-10}"; waited=$((waited + ${ROTATE_ACK_POLL:-10} + 1))
  done
}

# Owner decision 4: /exit-clean (no-close: the window close by id would find
# the fresh session's window) in the OLD pane, force-killed after
# ROTATE_EXIT_WAIT s; then the old window is closed - never the fresh one's.
spl_rot_retire() {
  local id="$1" pane="$2" old="$3" new="$4" waited=0 wait="${ROTATE_EXIT_WAIT:-300}" p alive newpane
  newpane="$(spl_rot_pane "$id")"
  if [[ -n "$pane" && "$pane" != "$newpane" ]]; then
    spl_rot_tm send-keys -t "$pane" -l '/exit-clean no-close' && spl_rot_tm send-keys -t "$pane" Enter
    spl_rot_say retire "/exit-clean no-close typed in $pane (pid $old)"
  fi
  while (( waited < wait )); do
    alive=""; for p in $old; do [[ -d "${LEASE_PROC_ROOT:-/proc}/$p" ]] && alive+=" $p"; done
    [[ -z "$alive" ]] && break
    spl_rot_sleep "${ROTATE_EXIT_POLL:-5}"; waited=$((waited + ${ROTATE_EXIT_POLL:-5} + 1))
  done
  spl_rot_kill_pids "$id" "$old"
  if [[ -n "$pane" && "$pane" != "$newpane" && "$(spl_rot_tm display-message -p -t "$pane" '#{window_name}' 2>/dev/null)" == *"$id"* ]]; then
    spl_rot_tm kill-window -t "$pane" 2>/dev/null && spl_rot_say retire "closed the old window of $id ($pane)"
  fi
  return 0
}

# TERM, then KILL, the given pids of <id>; logs what is left.
spl_rot_kill_pids() {
  local id="$1" pids="$2" sig p left
  for sig in TERM KILL; do
    left=""; for p in $pids; do [[ -d "${LEASE_PROC_ROOT:-/proc}/$p" ]] && left+=" $p"; done
    [[ -z "$left" ]] && { spl_rot_say retire "$id pid(s) $pids gone"; return 0; }
    for p in $left; do spl_rot_kill "$sig" "$p"; done
    spl_rot_say retire "SIG$sig $id pid(s)$left"
    spl_rot_sleep "${ROTATE_KILL_GRACE:-10}"
  done
  left=""; for p in $pids; do [[ -d "${LEASE_PROC_ROOT:-/proc}/$p" ]] && left+=" $p"; done
  [[ -z "$left" ]] && { spl_rot_say retire "$id pid(s) $pids gone"; return 0; }
  spl_rot_say retire "FAIL $id pid(s)$left still run after SIGKILL"
  return 1
}

# Signal as the process owner: the box user cannot signal the agent user's.
spl_rot_kill() {
  local sig="$1" pid="$2" owner
  if [[ -n "${ROTATE_KILL:-}" ]]; then "$ROTATE_KILL" "$sig" "$pid"; return; fi
  owner="$(stat -c %U "/proc/$pid" 2>/dev/null)"
  if [[ -z "$owner" || "$owner" == "$(id -un)" ]]; then kill -s "$sig" "$pid" 2>/dev/null
  else sudo -n -u "$owner" kill -s "$sig" "$pid" 2>/dev/null; fi
}

# Seconds since <pid> started (its /proc dir's mtime; the fake one in tests).
spl_rot_age() {
  local start
  start="$(stat -c %Y "${LEASE_PROC_ROOT:-/proc}/$1" 2>/dev/null)" || { echo 0; return; }
  echo $(( $(spl_lease_now) - start ))
}

# Step 7: the failover is replaced too, once the fresh master has held the
# lease ROTATE_SETTLE s; a failure there leaves the old F in its role.
spl_rot_refresh_failover() {
  local m="$1" f="$2" fpid age
  if (( ROT_DRY )); then
    spl_rot_say refresh "PLAN after ${ROTATE_SETTLE:-120}s with $m holding the lease: $f older than ${ROTATE_REFRESH_MIN:-50} min gets a fresh session"
    spl_rot_replace "$f" failover ""
    return 0
  fi
  spl_rot_sleep "${ROTATE_SETTLE:-120}"
  spl_lease_read
  [[ "$LH" == "$m" || "$LH" == "$m@$(spl_rot_machine)" || "$LH" == *@* && "${LH##*@}" != "$(spl_rot_machine)" ]] ||
    { spl_rot_say refresh "SKIP the lease is $LH, not $m - $f stays as it is"; return 0; }
  fpid="$(spl_lease_agent_pid "$f")"
  if [[ -n "$fpid" ]]; then
    age="$(spl_rot_age "$fpid")"
    (( age >= ${ROTATE_REFRESH_MIN:-50} * 60 )) || { spl_rot_say refresh "SKIP $f is $((age / 60)) min old"; return 0; }
  fi
  spl_rot_replace "$f" failover "" ||
    spl_rot_alert "failover refresh FAILED on $(spl_rot_machine): no fresh $f - the old session keeps the failover role"
  return 0
}
