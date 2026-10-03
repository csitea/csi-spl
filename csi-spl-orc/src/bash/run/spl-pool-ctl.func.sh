#!/bin/bash
#------------------------------------------------------------------------------
# @description Start, stop and report every server-side runtime of this box
# @description with ONE action (spec 071 section 4; owner HUM-10 2026-10-03:
# @description "The whole thing on the server side should be possible to start
# @description with one shell action"). It owns no runtime itself: every row
# @description goes through the action that already owns it (spec 071 3.1):
# @description   desk:<tenant>/<box> - the `spool hub-run` sidecars:
# @description       do_spl_desk_up_all / _tenants / _boxes, do_spl_desk_down
# @description   lease      - LEASE_CMD=ensure|stop do_spl_dispatch_lease
# @description   peer:<id>  - do_spl_peer_ensure, spl_peer_stop
# @description   pool-serve - do_spl_pool_serve (spec 070 L3) when the installed
# @description       spool binary has `pool serve`; else the row reads
# @description       "not built yet (spec 070 L3)" and nothing fails
# @description   cron:<tag> - status only: each `# csi-spl:<tag>` crontab line
# @description POOL_CMD picks the verb:
# @description   status  - one row per runtime: running | stopped | missing.
# @description             Read-only, always
# @description   start   - drop the env's reconcile pause marker, then start
# @description             every row (each step is idempotent)
# @description   ensure  - start, unless the env is paused: then nothing
# @description   stop    - write the pause marker <spool root>/.desk-reconcile.
# @description             <env>.pause (the reconcile then leaves the desks
# @description             alone for DESK_PAUSE_MAX_SECS), stop every row in
# @description             reverse order. A stopped row is skipped: twice is a
# @description             no-op
# @description   restart - stop, then start
# @description Rows have a scope. env rows (desk, pool-serve) belong to ENV; box
# @description rows (lease, peer) to the box env, LEASE_ENV in lease.conf
# @description (default prd), and a start/stop touches them only when ENV is
# @description that env: ENV=dev never stops the prd lease.
# @description SAFETY: it kills only through a pid file or lock its own action
# @description wrote, never by a command-line pattern, never a tmux window. The
# @description pool-serve pid is refused when it, or an ancestor, is a tmux
# @description pane's process, or its cmdline is not `spool pool serve`.
# @description Dry run unless DRY_RUN=0 (prints each call it would make).
# @param ENV - required: dev or prd
# @param POOL_CMD (optional) - status (default) | start | stop | restart | ensure
# @param POOL_TENANT (optional) - the tenant start seats live agents in;
# @param   default LEASE_TENANT in lease.conf, else t1
# @param DESK_MUTE (optional) - as do_spl_desk_up_all; default the DESK_MUTE of
# @param   this env's installed desk-reconcile cron line, so a start keeps a
# @param   deliberate mute
# @param POOL_SERVE_PID (optional) - default <spool root>/pool/serve.pid
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param SPOOL_TMUX_SOCKET (optional) - the tmux socket whose panes are protected
# @param DRY_RUN (optional) - 1 (default) or 0; status ignores it
# @example ENV=prd ./run -a do_spl_pool_ctl
# @example ENV=dev POOL_CMD=start ./run -a do_spl_pool_ctl
# @example ENV=dev POOL_CMD=stop DRY_RUN=0 ./run -a do_spl_pool_ctl
#------------------------------------------------------------------------------
declare -F spl_lease_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"
declare -F spl_peer_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-poll.func.sh"
declare -F spl_peer_stop >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-ensure.func.sh"
declare -F spl_desk_alive >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-up.func.sh"

do_spl_pool_ctl() {
  local cmd="${POOL_CMD:-status}" dry="${DRY_RUN:-1}"
  case "${ENV:-}" in dev|prd) ;; *) do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1 ;; esac
  case "$cmd" in status|start|stop|restart|ensure) ;; *) do_log "FATAL POOL_CMD must be status, start, stop, restart or ensure, got: '$cmd'"; return 1 ;; esac
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  pool_ctl_init || return 1
  case "$cmd" in
    status)  pool_ctl_status ;;
    start)   pool_ctl_start start ;;
    ensure)  pool_ctl_start ensure ;;
    stop)    pool_ctl_stop ;;
    restart) local rc=0; pool_ctl_stop || rc=1; pool_ctl_start start || rc=1; return "$rc" ;;
  esac
}

# The paths and the box env; SPL_STATE_DIR comes from the cloud cnf unless set.
pool_ctl_init() {
  POOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  POOL_PAUSE="$POOL_ROOT/.desk-reconcile.$ENV.pause"
  POOL_SERVE_PIDF="${POOL_SERVE_PID:-$POOL_ROOT/pool/serve.pid}"
  POOL_STATE="${SPL_STATE_DIR:-$HOME/.local/share/${SPL_ORG_APP:-csi-spl}/cloud/$ENV}"
  POOL_BOX_ENV="$(pool_ctl_conf LEASE_ENV)"; POOL_BOX_ENV="${POOL_BOX_ENV:-prd}"
  POOL_TENANT_ID="${POOL_TENANT:-$(pool_ctl_conf LEASE_TENANT)}"; POOL_TENANT_ID="${POOL_TENANT_ID:-t1}"
  POOL_RC=0
  spl_lease_init ro || return 1
  spl_peer_init ro || return 1
}

# pool_ctl_conf <KEY> - its value in lease.conf (KEY=value lines, never sourced)
pool_ctl_conf() {
  sed -n "s/^$1=\([A-Za-z0-9_.-]*\)\$/\1/p" "$POOL_ROOT/dispatch/lease.conf" 2>/dev/null | tail -1
}

pool_ctl_row() { printf '%-30s %-8s %s\n' "$1" "$2" "$3"; }

# pool_ctl_call <row> [-u NAME | NAME=value]... <fn> [args] - PLAN in a dry
# run, else call the action in a subshell with those variables set (so they
# never leak into the next row) and note a failure in POOL_RC
pool_ctl_call() {
  local row="$1"; shift
  if [[ "$dry" == 1 ]]; then echo "PLAN $row: $*"; return 0; fi
  echo "DO   $row: $*"
  if (
    while (( $# )); do
      if [[ "$1" == -u ]]; then unset "$2"; shift 2
      elif [[ "$1" =~ ^[A-Z_][A-Z0-9_]*= ]]; then export "${1?}"; shift
      else break; fi
    done
    "$@"
  ); then return 0; fi
  echo "FAIL $row: $*"; POOL_RC=1; return 1
}

# ---- the rows --------------------------------------------------------------

# The desk dirs: <state>/desk/<tenant>/<box>, one line "<tenant> <box>"
pool_ctl_desks() {
  local d t b
  for d in "$POOL_STATE"/desk/*/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"; b="${d##*/}"; t="${d%/*}"; t="${t##*/}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]*$ && "$b" =~ ^[a-z0-9][a-z0-9-]*$ ]] && echo "$t $b"
  done
}
pool_ctl_desk_pidf() { echo "$POOL_STATE/desk/$1/$2/spool/.hub/hub-run.pid"; }

# The lease verbs this box runs: fleet with LEASE_FLEET, else renew + watch
pool_ctl_lease_verbs() { [[ -n "$(pool_ctl_conf LEASE_FLEET)" ]] && echo fleet || echo "renew watch"; }

# pool-serve: "built" when the installed binary knows `pool serve` AND the
# action that runs it has landed; else why not (one line)
pool_ctl_serve_built() {
  local bin="$POOL_STATE/bin/spool" out
  [[ -x "$bin" ]] || { echo "no spool binary at $bin"; return 1; }
  out="$("$bin" pool serve -h 2>&1)"
  [[ "$out" == *"unknown command"* ]] && { echo "not built yet (spec 070 L3)"; return 1; }
  declare -F do_spl_pool_serve >/dev/null || { echo "not built yet (spec 070 L3): the binary has it, do_spl_pool_serve has not landed"; return 1; }
  return 0
}

# 0 when the pid file names a live `spool pool serve`
pool_ctl_serve_alive() {
  local pid
  pid="$(cat "$POOL_SERVE_PIDF" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q ' pool serve'
}

# pool_ctl_in_pane <pid> - 0 when <pid> or one of its ancestors is the process
# of a tmux pane: an interactive window this action must never kill
pool_ctl_in_pane() {
  local pid="$1" panes ppid n=0
  panes=" $(tmux ${SPOOL_TMUX_SOCKET:+-S "$SPOOL_TMUX_SOCKET"} list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ') "
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && $n -lt 64 ]]; do
    [[ "$panes" == *" $pid "* ]] && return 0
    ppid="$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $2}')"
    pid="$ppid"; n=$((n + 1))
  done
  return 1
}

# ---- status ----------------------------------------------------------------

pool_ctl_status() {
  local t b v up line tag any=0 why seat
  echo "pool-ctl status: env=$ENV box-env=$POOL_BOX_ENV state=$POOL_STATE root=$POOL_ROOT"
  [[ -e "$POOL_PAUSE" ]] && echo "PAUSED $POOL_PAUSE: $(head -c 200 "$POOL_PAUSE" 2>/dev/null)"
  while read -r t b; do
    [[ -n "$t" ]] || continue; any=1
    if spl_desk_alive "$(pool_ctl_desk_pidf "$t" "$b")"; then
      pool_ctl_row "desk:$t/$b" running "hub-run pid $(cat "$(pool_ctl_desk_pidf "$t" "$b")")"
    else
      pool_ctl_row "desk:$t/$b" stopped "no live hub-run"
    fi
  done < <(pool_ctl_desks)
  (( any )) || pool_ctl_row desk missing "no desk under $POOL_STATE/desk"

  if [[ ! -f "$LEASE_CONF" ]]; then
    pool_ctl_row lease missing "no $LEASE_CONF"
  else
    up=""; for v in $(pool_ctl_lease_verbs); do spl_lease_running "$v" && up+=" $v"; done
    if [[ "$up" == " $(pool_ctl_lease_verbs)" ]]; then pool_ctl_row lease running "${up# } (env $POOL_BOX_ENV)"
    else pool_ctl_row lease stopped "running:${up:- none} of $(pool_ctl_lease_verbs) (env $POOL_BOX_ENV)"; fi
  fi

  if [[ -z "$(spl_peer_seats)" ]]; then
    pool_ctl_row peer missing "no seat in $PEER_SEATS"
  else
    while read -r seat _; do
      if spl_peer_running "$seat"; then pool_ctl_row "peer:$seat" running "poll pid $(cat "$PEER_DIR/$seat/poll.pid" 2>/dev/null)"
      else pool_ctl_row "peer:$seat" stopped "no poll loop"; fi
    done < <(spl_peer_seats)
  fi

  if why="$(pool_ctl_serve_built)"; then
    if pool_ctl_serve_alive; then pool_ctl_row pool-serve running "pid $(cat "$POOL_SERVE_PIDF")"
    else pool_ctl_row pool-serve stopped "no live pid in $POOL_SERVE_PIDF"; fi
  else
    pool_ctl_row pool-serve missing "$why"
  fi

  while IFS= read -r line; do
    [[ "$line" =~ \#\ csi-spl:([a-z0-9:-]+)$ ]] || continue
    tag="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^[[:space:]]*# ]] && { pool_ctl_row "cron:$tag" stopped "commented out"; continue; }
    pool_ctl_row "cron:$tag" running "installed"
  done < <(crontab -l 2>/dev/null)
  return 0
}

# ---- start / ensure --------------------------------------------------------

# The DESK_MUTE baked into this env's desk-reconcile cron line, if any
pool_ctl_cron_mute() {
  crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep "ENV=$ENV " | grep 'desk-reconcile-cron.sh' |
    sed -n "s/.*DESK_MUTE=['\"]\{0,1\}\([A-Za-z0-9 _-]*\)['\"]\{0,1\} .*/\1/p" | head -1
}

pool_ctl_paused() {
  local age
  [[ -e "$POOL_PAUSE" ]] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$POOL_PAUSE" 2>/dev/null || date +%s) ))
  [[ "$age" -le "${DESK_PAUSE_MAX_SECS:-1800}" ]]
}

pool_ctl_start() {
  local verb="$1" mute seat why box_rows=0
  [[ "$ENV" == "$POOL_BOX_ENV" ]] && box_rows=1
  if [[ "$verb" == ensure ]] && pool_ctl_paused; then
    do_log "INFO env $ENV is paused by $POOL_PAUSE: ensure leaves every row alone"; return 0
  fi
  if [[ "$verb" == start && -e "$POOL_PAUSE" ]]; then
    if [[ "$dry" == 1 ]]; then echo "PLAN pause: rm $POOL_PAUSE"; else rm -f "$POOL_PAUSE"; echo "DO   pause: removed $POOL_PAUSE"; fi
  fi
  mute="${DESK_MUTE-$(pool_ctl_cron_mute)}"
  pool_ctl_call desk ENV="$ENV" TENANT_ID="$POOL_TENANT_ID" DESK_MUTE="$mute" DRY_RUN=0 do_spl_desk_up_all
  pool_ctl_call desk -u TENANT_ID ENV="$ENV" DESK_SKIP_TENANTS="$POOL_TENANT_ID" DESK_MUTE="$mute" DRY_RUN=0 do_spl_desk_up_tenants
  pool_ctl_call desk -u TENANT_ID ENV="$ENV" DRY_RUN=0 do_spl_desk_up_boxes
  if (( box_rows )); then
    if [[ -f "$LEASE_CONF" ]]; then pool_ctl_call lease LEASE_CMD=ensure do_spl_dispatch_lease
    else echo "SKIP lease: no $LEASE_CONF"; fi
    if [[ -n "$(spl_peer_seats)" ]]; then pool_ctl_call peer do_spl_peer_ensure
    else echo "SKIP peer: no seat in $PEER_SEATS"; fi
  else
    echo "SKIP lease, peer: box rows of env $POOL_BOX_ENV, not $ENV"
  fi
  if why="$(pool_ctl_serve_built)"; then
    pool_ctl_call pool-serve ENV="$ENV" do_spl_pool_serve
  else
    echo "SKIP pool-serve: $why"
  fi
  pool_ctl_done "$verb"
}

# ---- stop ------------------------------------------------------------------

pool_ctl_stop() {
  local t b seat v up box_rows=0
  [[ "$ENV" == "$POOL_BOX_ENV" ]] && box_rows=1
  if [[ "$dry" == 1 ]]; then echo "PLAN pause: write $POOL_PAUSE"
  else
    if ! { mkdir -p "$POOL_ROOT" && printf 'pool-ctl stop %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-$(id -un)}" >"$POOL_PAUSE"; }; then
      do_log "FATAL cannot write $POOL_PAUSE - nothing stopped (the reconcile would restart it)"; return 1
    fi
    echo "DO   pause: wrote $POOL_PAUSE"
  fi
  if pool_ctl_serve_alive; then pool_ctl_serve_stop
  elif [[ -s "$POOL_SERVE_PIDF" ]]; then pool_ctl_serve_refuse_note
  fi
  if (( box_rows )); then
    while read -r seat _; do
      [[ -n "$seat" ]] && spl_peer_running "$seat" && pool_ctl_call "peer:$seat" spl_peer_stop "$seat"
    done < <(spl_peer_seats)
    up=""; for v in renew watch fleet; do spl_lease_running "$v" && up+=" $v"; done
    [[ -n "$up" ]] && pool_ctl_call lease LEASE_CMD=stop do_spl_dispatch_lease
  else
    echo "SKIP lease, peer: box rows of env $POOL_BOX_ENV, not $ENV"
  fi
  while read -r t b; do
    [[ -n "$t" ]] || continue
    spl_desk_alive "$(pool_ctl_desk_pidf "$t" "$b")" || continue
    pool_ctl_call "desk:$t/$b" ENV="$ENV" TENANT_ID="$t" DESK_BOX="$b" DESK_ALL=1 DRY_RUN=0 do_spl_desk_down
  done < <(pool_ctl_desks)
  pool_ctl_done stop
}

# pool-serve has no stop action yet (spec 070 L3 brings do_spl_pool_serve):
# stop it by its pid file, after the pane and cmdline guards
pool_ctl_serve_stop() {
  local pid i
  pid="$(cat "$POOL_SERVE_PIDF")"
  if pool_ctl_in_pane "$pid"; then
    echo "REFUSE pool-serve: pid $pid runs in a tmux pane - not killed"; POOL_RC=1; return 1
  fi
  if [[ "$dry" == 1 ]]; then echo "PLAN pool-serve: kill $pid ($POOL_SERVE_PIDF)"; return 0; fi
  echo "DO   pool-serve: kill $pid"
  kill "$pid" 2>/dev/null || true
  for ((i = 0; i < 75; i++)); do pool_ctl_serve_alive || break; sleep 0.2; done
  pool_ctl_serve_alive && { echo "FAIL pool-serve: pid $pid will not stop"; POOL_RC=1; return 1; }
  rm -f "$POOL_SERVE_PIDF"
}

# A pid file that names something other than a live `spool pool serve`: say
# so and touch nothing (the pid may have been reused by anything, a pane too)
pool_ctl_serve_refuse_note() {
  local pid
  pid="$(cat "$POOL_SERVE_PIDF" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
    echo "REFUSE pool-serve: $POOL_SERVE_PIDF names pid $pid, which is not 'spool pool serve' - not killed"
}

pool_ctl_done() {
  if [[ "$dry" == 1 ]]; then do_log "OK DRY_RUN $1: nothing was touched. Re-run with DRY_RUN=0."
  elif (( POOL_RC )); then do_log "FATAL $1: a row failed (named above)"
  else do_log "OK $1 done: ENV=$ENV POOL_CMD=status ./run -a do_spl_pool_ctl"; fi
  return "$POOL_RC"
}
