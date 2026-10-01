#!/bin/bash
#------------------------------------------------------------------------------
# @description The dispatcher heartbeat lease (SPEC-spool-fleet-roles.md
# @description section 4): exactly one dispatcher holds the lease and
# @description dispatches. LEASE_CMD picks the verb:
# @description   show   - print "<holder> <age-seconds>"
# @description   renew  - loop: every LEASE_PERIOD s, while a live claude
# @description            process carries SPOOL_AGENT_ID=<master>, write
# @description            "<master> <epoch>". It follows the master BY ID,
# @description            so a relaunched master is picked up with no manual
# @description            step; no live master process = no renewal
# @description   watch  - loop: promote the failover once the lease is older
# @description            than LEASE_STALE s (never a failover with no live
# @description            process), keep it fresh in the failover's name, and
# @description            send STANDBY once the master renews again
# @description   ensure - start renew + watch when they are not running
# @description            (idempotent; the desk reconcile cron calls it every
# @description            tick, which is what brings them back after a reboot)
# @description   stop   - stop the loops this action started
# @description Every transition is written ONCE to <dir>/lease.log and sent
# @description as a spool note to the failover and the orchestrator.
# @description The ids come from LEASE_MASTER / LEASE_FAILOVER / LEASE_ORCH,
# @description else from <dir>/lease.conf (KEY=value lines, never sourced).
# @description ensure does nothing while lease.conf is absent: that file is
# @description the opt-in, so a box without dispatchers starts no loop.
# @param LEASE_CMD - required: show, renew, watch, ensure or stop
# @param SPOOL_ROOT (optional) - default /var/spool-hub; the lease dir is <root>/dispatch
# @param LEASE_MASTER (optional) - the master's agent id (else lease.conf)
# @param LEASE_FAILOVER (optional) - the failover's agent id (else lease.conf)
# @param LEASE_ORCH (optional) - the orchestrator told of every transition (else lease.conf)
# @param LEASE_PERIOD (optional) - seconds between ticks, default 60
# @param LEASE_STALE (optional) - seconds of silence before a failover, default 180
# @example LEASE_CMD=show ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=watch LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 ./run -a do_spl_dispatch_lease
#------------------------------------------------------------------------------
do_spl_dispatch_lease() {
  spl_lease_init || return 1
  case "${LEASE_CMD:-}" in
    show)   spl_lease_show ;;
    renew)  spl_lease_ids master || return 1; spl_lease_loop renew ;;
    watch)  spl_lease_ids master failover orch || return 1; spl_lease_loop watch ;;
    ensure) spl_lease_ensure ;;
    stop)   spl_lease_stop ;;
    *) do_log "FATAL LEASE_CMD must be show, renew, watch, ensure or stop, got: '${LEASE_CMD:-}'"; return 1 ;;
  esac
}

# The lease dir and its files ("ro": do not create the dir); LEASE_NOW (an epoch) and LEASE_PROC_ROOT (a
# fake /proc) exist for the tests only.
spl_lease_init() {
  LEASE_DIR="${SPOOL_ROOT:-/var/spool-hub}/dispatch"
  LEASE_FILE="$LEASE_DIR/lease"
  LEASE_LOG="$LEASE_DIR/lease.log"
  LEASE_CONF="$LEASE_DIR/lease.conf"
  LEASE_PERIOD="${LEASE_PERIOD:-60}"
  LEASE_STALE="${LEASE_STALE:-180}"
  [[ "$LEASE_PERIOD" =~ ^[1-9][0-9]*$ && "$LEASE_STALE" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL LEASE_PERIOD and LEASE_STALE must be positive integers"; return 1; }
  [[ "${1:-}" == ro ]] && return 0
  mkdir -p "$LEASE_DIR" || { do_log "FATAL cannot create $LEASE_DIR"; return 1; }
}

# The test workspaces nobody dispatches to or sweeps: ONE list, shared by
# do_spl_unanswered_sweep and the dispatch actions. The ids in
# SWEEP_SKIP_TENANTS (default e2e) plus <spool root>/dispatch/test-workspaces
# (one id per line, # comments), printed space-separated.
spl_test_workspaces() {
  local f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/test-workspaces"
  # shellcheck disable=SC2086 # a space-separated list, split on purpose
  { printf '%s\n' ${SWEEP_SKIP_TENANTS-e2e}; [[ -f "$f" ]] && sed 's/#.*//' "$f"; } |
    tr -s ' \t' '\n\n' | grep -E '^[A-Za-z0-9_-]+$' | sort -u | tr '\n' ' '
}

# 0 when workspace <id> is a test one: on that list, or its id matches
# SWEEP_SKIP_RE (the sweep's default).
spl_test_workspace() {
  local re="${SWEEP_SKIP_RE-(^|[-_ ])(e2e|test|proof)([-_ ]|$)}"
  [[ " $(spl_test_workspaces) " == *" $1 "* ]] && return 0
  [[ -n "$re" ]] && grep -qiE -- "$re" <<<"$1"
}

# KEY=value from lease.conf for the ids not already in the environment. Read,
# never sourced: the file sits in a dir every agent on the box may write.
spl_lease_conf() {
  local k v
  [[ -f "$LEASE_CONF" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      LEASE_MASTER|LEASE_FAILOVER|LEASE_ORCH)
        [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v" ;;
    esac
  done < <(grep -E '^LEASE_(MASTER|FAILOVER|ORCH)=[A-Za-z0-9_-]+$' "$LEASE_CONF")
  return 0
}

# Require the named ids (master failover orch); each must be a plain agent id.
spl_lease_ids() {
  spl_lease_conf
  local n var
  for n in "$@"; do
    var="LEASE_${n^^}"
    [[ "${!var:-}" =~ ^[A-Za-z0-9_-]+$ ]] ||
      { do_log "FATAL $var is not set (env or $LEASE_CONF)"; return 1; }
  done
}

spl_lease_now() { echo "${LEASE_NOW:-$(date +%s)}"; }

# Sets LH (holder) and LT (epoch); no lease reads as "none 0".
spl_lease_read() {
  LH=none LT=0
  [[ -s "$LEASE_FILE" ]] && read -r LH LT < "$LEASE_FILE"
  [[ "$LT" =~ ^[0-9]+$ ]] || LT=0
  return 0
}

spl_lease_write() {
  printf '%s %s\n' "$1" "$(spl_lease_now)" > "$LEASE_FILE.tmp.$$" && mv -f "$LEASE_FILE.tmp.$$" "$LEASE_FILE"
}

spl_lease_log() { echo "$(date -u +%FT%TZ) $*" >> "$LEASE_LOG"; }

# A spool note on task dispatch-lease. LEASE_SEND replaces the sender in tests.
spl_lease_tell() {
  local to="$1"; shift
  local send="${LEASE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$LEASE_ORCH" --to "$to" \
    --kind note --task dispatch-lease --body "$*" >/dev/null 2>&1 8>&- ||
    spl_lease_log "WARN could not tell $to"
}

# The pid of a live claude process whose environment carries
# SPOOL_AGENT_ID=<id>; empty when there is none. The lowest pid wins, so two
# reads in a row agree.
spl_lease_agent_pid() {
  local id="$1" root="${LEASE_PROC_ROOT:-/proc}" d pid comm
  for d in "$root"/[0-9]*; do
    pid="${d##*/}"
    # `read`, not $(cat): a builtin, so the walk forks only for the few
    # claude processes (measured 2026-10-01: one fork per pid made a tick 26 s)
    comm=""; { read -r comm < "$d/comm"; } 2>/dev/null
    [[ "$comm" == claude ]] || continue
    grep -qzx "SPOOL_AGENT_ID=$id" "$d/environ" 2>/dev/null || continue
    echo "$pid"
  done | sort -n | head -1
}

# The SPOOL_AGENT_ID of every live process on this box that carries one,
# one per line - any agent kind (an agy or grok agent is not a claude process).
# For the dead-subscription REPORT; the lease itself keeps the claude-only rule.
# mapfile, not tr/grep: a builtin, so the walk does not fork per process.
spl_lease_live_ids() {
  local root="${LEASE_PROC_ROOT:-/proc}" d e
  local -a env
  for d in "$root"/[0-9]*; do
    env=()
    { mapfile -d '' -t env < "$d/environ"; } 2>/dev/null || continue
    for e in "${env[@]}"; do
      [[ "$e" == SPOOL_AGENT_ID=* ]] && { echo "${e#SPOOL_AGENT_ID=}"; break; }
    done
  done | sort -u
}

# One renew tick. The bound pid lives in renew.<id>.pid so a rebind or a loss
# is logged once, not every tick.
spl_lease_renew_tick() {
  local id="$LEASE_MASTER" state="$LEASE_DIR/renew.$LEASE_MASTER.pid" pid last=""
  [[ -f "$state" ]] && last="$(cat "$state")"
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -n "$pid" ]]; then
    spl_lease_locked spl_lease_write "$id"
    [[ "$pid" != "$last" ]] && { echo "$pid" > "$state"; spl_lease_log "renew bind $id pid=$pid"; }
  elif [[ "$last" != gone ]]; then
    echo gone > "$state"; spl_lease_log "renew stop $id (no live process)"
  fi
  return 0
}

# Runs "$@" holding the lease lock, so the watcher's read-then-refresh of the
# failover's lease can never overwrite a master renewal that lands between.
spl_lease_locked() {
  ( flock -w 10 9 || exit 1; "$@" ) 9> "$LEASE_DIR/lease.lock"
}

# One watch tick. Markers: lease.failover (the failover holds it, a handback
# is due when the master renews) and lease.nofailover (the master is silent and
# the failover has no live process either; logged once).
spl_lease_watch_tick() {
  local m="$LEASE_MASTER" f="$LEASE_FAILOVER" age fpid
  spl_lease_read
  age=$(( $(spl_lease_now) - LT ))
  # a fresh lease ends a "nobody dispatches" episode, so the next one is logged
  (( age <= LEASE_STALE )) && rm -f "$LEASE_FILE.nofailover"
  if [[ "$LH" == "$m" ]]; then
    if [[ -f "$LEASE_FILE.failover" ]]; then
      rm -f "$LEASE_FILE.failover"; spl_lease_log "handback to $m"
      spl_lease_tell "$f" "DISPATCH LEASE: STANDBY - master $m is back and holds the lease. Finish the message in hand, then stop dispatching."
      spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: master $m is back; $f is standby."
    fi
  fi
  if [[ "$LH" != "$f" && "$age" -gt "$LEASE_STALE" ]]; then
    fpid="$(spl_lease_agent_pid "$f")"
    if [[ -n "$fpid" ]]; then
      spl_lease_locked spl_lease_promote "$m" "$f" "$age" || return 0
      rm -f "$LEASE_FILE.nofailover"
    elif [[ ! -f "$LEASE_FILE.nofailover" ]]; then
      touch "$LEASE_FILE.nofailover"
      spl_lease_log "NO-FAILOVER: $LH silent ${age}s and $f has no live process"
      spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: nobody dispatches - master $m silent ${age}s and failover $f has no live process."
    fi
  elif [[ "$LH" == "$f" ]]; then
    # keep it fresh while the failover lives; a dead failover lets it go stale
    [[ -n "$(spl_lease_agent_pid "$f")" ]] && spl_lease_locked spl_lease_refresh "$f"
  fi
  return 0
}

# Under the lock: re-read, and promote only if the lease is still stale.
spl_lease_promote() {
  local m="$1" f="$2" age
  spl_lease_read
  age=$(( $(spl_lease_now) - LT ))
  [[ "$LH" != "$f" && "$age" -gt "$LEASE_STALE" ]] || return 1
  spl_lease_write "$f"; touch "$LEASE_FILE.failover"
  spl_lease_log "FAILOVER: $LH silent ${age}s -> $f active"
  spl_lease_tell "$f" "DISPATCH LEASE: you are now ACTIVE (master $m silent ${age}s). Dispatch, including $m's unread inbox (spool recv --as $m), until told STANDBY."
  spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: failover $f took over; master $m silent ${age}s."
}

# Under the lock: refresh only while the failover still holds it.
spl_lease_refresh() {
  spl_lease_read
  [[ "$LH" == "$1" ]] && spl_lease_write "$1"
  return 0
}

spl_lease_show() {
  spl_lease_read
  local age=$(( $(spl_lease_now) - LT ))
  [[ "$LH" == none ]] && age=-1
  echo "$LH $age"
}

# The loop holds <verb>.run with flock for its whole life: that lock IS the
# "is it running" answer ensure reads, so a stale pid file cannot lie and a
# second copy exits at once. <verb>.ver records the code it runs, so ensure
# can replace a loop whose code trunk has since changed.
spl_lease_loop() {
  local verb="$1"
  exec 8> "$LEASE_DIR/$verb.run"
  # -w, not -n: a "is it running?" probe (spl_lease_running) holds the lock
  # for an instant, and a loop starting in that instant must not give up
  flock -w 2 8 || { do_log "INFO a $verb loop already runs - nothing to do"; return 0; }
  echo "$$" > "$LEASE_DIR/$verb.pid"
  spl_lease_code_ver > "$LEASE_DIR/$verb.ver"
  spl_lease_log "$verb start master=$LEASE_MASTER${LEASE_FAILOVER:+ failover=$LEASE_FAILOVER} pid=$$"
  while :; do
    "spl_lease_${verb}_tick"
    [[ -n "${LEASE_TICKS:-}" ]] && { LEASE_TICKS=$((LEASE_TICKS - 1)); (( LEASE_TICKS > 0 )) || break; }
    sleep "$LEASE_PERIOD"
  done
}

# This file, as the loops run it; its hash is the code version.
SPL_LEASE_SRC="${BASH_SOURCE[0]}"
spl_lease_code_ver() { sha1sum < "$SPL_LEASE_SRC" | cut -c1-12; }

# 0 when a <verb> loop holds its run lock.
spl_lease_running() {
  [[ -f "$LEASE_DIR/$1.run" ]] || return 1
  ! flock -n "$LEASE_DIR/$1.run" true
}

# Refuse to start loops from a tree whose lease code is not trunk's: a stale
# checkout would otherwise run old code for as long as nobody looks (the desk
# cron's checkout ran 27 commits behind for ~18 h on 2026-09-30). A tree that
# is not a git checkout, or has no LEASE_TRUNK_REF, is not judged.
# LEASE_ALLOW_STALE=1 overrides, for a deliberate test of unmerged code.
spl_lease_trunk_check() {
  local ref="${LEASE_TRUNK_REF:-origin/master}" dir rel mine theirs
  [[ "${LEASE_ALLOW_STALE:-0}" == 1 ]] && return 0
  dir="$(cd "$(dirname "$SPL_LEASE_SRC")" && pwd)"
  git -C "$dir" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 0
  rel="$(git -C "$dir" ls-files --full-name -- "$(basename "$SPL_LEASE_SRC")" 2>/dev/null)"
  [[ -n "$rel" ]] || return 0
  mine="$(git hash-object "$SPL_LEASE_SRC")"
  theirs="$(git -C "$dir" rev-parse -q --verify "$ref:$rel" 2>/dev/null)"
  [[ "$mine" == "$theirs" ]] && return 0
  do_log "FATAL $SPL_LEASE_SRC is not $ref's version - this tree is stale or edited; update it (or LEASE_ALLOW_STALE=1 for a deliberate test)"
  spl_lease_log "REFUSED ensure from a stale tree ($SPL_LEASE_SRC != $ref)"
  return 1
}

# Start "$@" fully detached: its own session, stdin/stdout/stderr to the log,
# and EVERY other inherited fd closed. Without the closing, a caller that
# pipes this action (`... | grep`) never sees EOF: run.sh's output tee holds
# the pipe and the loop holds the tee's input through a process-substitution fd.
spl_lease_detach() {
  local out="$1"; shift
  (
    for fd in /proc/$BASHPID/fd/*; do
      fd="${fd##*/}"
      [[ "$fd" =~ ^[0-9]+$ ]] && (( fd > 2 )) && eval "exec $fd>&-" 2>/dev/null
    done
    exec setsid nohup "$@" >> "$out" 2>&1 < /dev/null
  ) >> "$out" 2>&1 < /dev/null &
}

spl_lease_ensure() {
  [[ -f "$LEASE_CONF" ]] || { do_log "INFO no $LEASE_CONF - this box runs no dispatch lease"; return 0; }
  spl_lease_ids master failover orch || return 1
  spl_lease_trunk_check || return 1
  local verb out ver
  ver="$(spl_lease_code_ver)"
  for verb in renew watch; do
    if spl_lease_running "$verb"; then
      # a loop that took its lock a moment ago writes its version just after
      [[ "$(cat "$LEASE_DIR/$verb.ver" 2>/dev/null)" == "$ver" ]] || sleep 1
      if [[ "$(cat "$LEASE_DIR/$verb.ver" 2>/dev/null)" == "$ver" ]]; then
        do_log "INFO lease $verb loop running (pid $(cat "$LEASE_DIR/$verb.pid" 2>/dev/null))"
        continue
      fi
      # an old loop: replace it. The lease survives a few seconds without a
      # renewal or a watcher, so this leaves no gap.
      spl_lease_log "ensure replaces $verb (code $(cat "$LEASE_DIR/$verb.ver" 2>/dev/null || echo unknown) -> $ver)"
      spl_lease_stop_one "$verb" || return 1
    fi
    out="$LEASE_DIR/$verb.out"
    LEASE_CMD="$verb" LEASE_MASTER="$LEASE_MASTER" LEASE_FAILOVER="$LEASE_FAILOVER" LEASE_ORCH="$LEASE_ORCH" \
      spl_lease_detach "$out" "${LEASE_RUN:-$PROJ_PATH/run}" -a do_spl_dispatch_lease
    do_log "INFO lease $verb loop started (log $out)"
    spl_lease_log "ensure started $verb"
  done
  return 0
}

# Stop one loop by its pid file (never by a command-line pattern: `pkill -f`
# also matches the shell that runs it) and wait for its lock to free.
spl_lease_stop_one() {
  local verb="$1" pid i
  spl_lease_running "$verb" || return 0
  pid="$(cat "$LEASE_DIR/$verb.pid" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { do_log "FATAL $verb runs but $LEASE_DIR/$verb.pid holds no pid"; return 1; }
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
  for i in $(seq 1 50); do spl_lease_running "$verb" || break; sleep 0.1; done
  spl_lease_running "$verb" && { do_log "FATAL $verb loop pid $pid did not stop"; return 1; }
  spl_lease_log "stop $verb pid=$pid"
}

spl_lease_stop() {
  spl_lease_stop_one renew && spl_lease_stop_one watch
}
