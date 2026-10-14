#!/bin/bash
#------------------------------------------------------------------------------
# @description The GC (garbage collector) agent of a box (owner HUM-10, t1
# @description 91a36ace): every 30 min the box's cron starts ONE GC session,
# @description which walks every agent on this box once, judges it (working,
# @description stuck, done and idle), helps a stuck one, pokes it, restarts it
# @description on a later pass when the poke changed nothing, asks the
# @description orchestrator to close a finished one, sends one summary line and
# @description closes itself. The agent only judges: every step is this action.
# @description   start     - the cron's (gc-cron.sh): the slot's vendor from
# @description               cnf/gc/gc.conf (:00 claude, :30 grok), no overlap
# @description               (a live GC younger than GC_MAX_AGE = SKIP; an
# @description               older one is ended first), a window gc@<box>
# @description   scan      - the facts of every agent of this box, one block each
# @description   begin     - start the clock on AGENT_ID (GC_AGENT_CAP s, the
# @description               owner's 3 minutes), print its issue and last errors
# @description   poke      - GC_HINT as a spool note on task gc-<id> + the ring
# @description   restart   - only after a poke from an earlier pass (GC_POKE_WAIT)
# @description               with no heartbeat progress since: do_spl_agent_restart
# @description               CAUSE=gc, detached (its own guards: human, rotation,
# @description               held out, limits)
# @description   close-ask - GC_WHY to the orchestrator: close this finished lane
# @description   done      - GC_SUMMARY: one log line + one note to GC_REPORT_TO,
# @description               then the GC window is closed
# @description   status    - the current pass and the log tail
# @description Role seats (001..003) are scanned, never poked, restarted or
# @description closed (rotation and the watchdog own them); a human hold
# @description refuses every step. poke, restart and close-ask are refused
# @description past the cap of the agent begun last. Log: <dispatch>/gc/gc.log.
# @description Dry run unless DRY_RUN=0. Exit: 0 done, 3 nothing to do, 4 refused.
# @param GC_CMD - start | scan | begin | poke | restart | close-ask | done | status (default status)
# @param AGENT_ID - the agent of begin / poke / restart / close-ask
# @param GC_HINT / GC_WHY / GC_SUMMARY - the text of poke / close-ask / done
# @param GC_VENDOR (optional) - start: this vendor instead of the slot's
# @param GC_CONF (optional) - default <orc>/cnf/gc/gc.conf
# @param GC_STATE_DIR (optional) - default <spool root>/dispatch/gc
# @param GC_REPORT_TO (optional) - the summary's addressee, default role seat 001 (spl_role_seat 1; c-001 under claude)
# @param GC_NOW / GC_CLOSE_DELAY / GC_RESTART_CMD / GC_SEND / ROTATE_TMUX (optional) - seams for the tests
# @param DRY_RUN (optional) - 1 (default) or 0
# @example GC_CMD=start ./run -a do_spl_gc
# @example GC_CMD=scan ./run -a do_spl_gc
# @example GC_CMD=poke AGENT_ID=c-123 GC_HINT="the gate is red on lint: run do_check_pre_push_lint" DRY_RUN=0 ./run -a do_spl_gc
# @example GC_CMD=done GC_SUMMARY="12 agents: 9 working, 2 poked, 1 close asked" DRY_RUN=0 ./run -a do_spl_gc
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

SPL_GC_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPL_GC_KNOBS="GC_AGENT_CAP GC_MAX_AGE GC_POKE_WAIT GC_SILENT_AGE GC_CLOSE_ASK_EVERY"

do_spl_gc() {
  echo "DEBUG: do_spl_gc called with GC_CMD=$GC_CMD, DRY_RUN=${DRY_RUN:-1}"
  local cmd="${GC_CMD:-status}"
  case "$cmd" in start|scan|begin|poke|restart|close-ask|done|status) ;;
    *) do_log "FATAL GC_CMD must be start, scan, begin, poke, restart, close-ask, done or status, got: '$cmd'"; return 1 ;;
  esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  echo "DEBUG: DRY_RUN in do_spl_gc=${DRY_RUN:-1}"
  spl_gc_init || return 1
  case "$cmd" in
    start) spl_gc_start ;;
    scan) spl_gc_scan ;;
    status) spl_gc_status ;;
    done) spl_gc_done ;;
    *) spl_gc_step "$cmd" ;;
  esac
}

# ---- settings ----------------------------------------------------------------

spl_gc_init() {
  spl_rotate_conf || return 1
  GC_DIR="${GC_STATE_DIR:-$LEASE_DIR/gc}"
  GC_LOG="$GC_DIR/gc.log"
  GC_CONF="${GC_CONF:-$PROJ_PATH/cnf/gc/gc.conf}"
  [[ -r "$GC_CONF" ]] || { do_log "FATAL no GC config $GC_CONF"; return 1; }
  spl_gc_conf || return 1
  GC_NOW="${GC_NOW:-$(date +%s)}"
  GC_BOX="${SPOOL_BOX_TAG:-$ROTATE_BOX}"
  GC_WIN="gc@$GC_BOX"
  GC_FROM="${GC_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}"
  # Resolve the current dispatch lease holder at send time; fall back to the orchestrator lease holder if stale or missing.
  spl_gc_resolve_report_to() {
    echo "DEBUG: spl_gc_resolve_report_to called at $(date +%s)" >&2
    local lease_holder="none" lease_age=-1 lease_file="${GC_LEASE_FILE:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease}"
    echo "DEBUG: lease_file=$lease_file" >&2
    if [[ -s "$lease_file" ]]; then
      read -r lease_holder lease_age < "$lease_file" 2>/dev/null || true
      echo "DEBUG: lease_holder=$lease_holder, lease_age=$lease_age" >&2
      [[ "$lease_age" =~ ^[0-9]+$ ]] || lease_age=-1
      lease_age=$(( GC_NOW - lease_age ))
      echo "DEBUG: lease_age after calc=$lease_age" >&2
    fi
    if [[ "$lease_holder" == "none" || "$lease_age" -lt 0 || "$lease_age" -gt 180 ]]; then
      GC_REPORT_TO="$(spl_role_seat 1)"
      spl_gc_log "GC_REPORT_TO: dispatch lease stale/missing (holder=$lease_holder, age=${lease_age}s), fallback to orchestrator $GC_REPORT_TO"
    else
      GC_REPORT_TO="$lease_holder"
      spl_gc_log "GC_REPORT_TO: dispatch lease holder $GC_REPORT_TO (age=${lease_age}s)"
    fi
    echo "DEBUG: GC_REPORT_TO set to $GC_REPORT_TO" >&2
  }

  spl_gc_resolve_report_to
  echo "DEBUG: GC_REPORT_TO after spl_gc_resolve_report_to: $GC_REPORT_TO"
  GC_SEND="${GC_SEND:-$ROTATE_SEND}"
  GC_RUN="${GC_RUN:-$ROTATE_RUN}"
  GC_DRY="${DRY_RUN:-1}"
  echo "DEBUG: GC_DRY in spl_gc_init=$GC_DRY, DRY_RUN=${DRY_RUN:-1}"
  echo "DEBUG: GC_REPORT_TO after spl_gc_init: $GC_REPORT_TO"
  mkdir -p "$GC_DIR" || { do_log "FATAL cannot create $GC_DIR"; return 1; }
}

# spl_gc_conf: GC_SLOTS ("MM vendor" lines), GC_FALLBACK and the knobs: the
# environment wins, then gc.conf (read, never sourced).
spl_gc_conf() {
  local k v
  GC_SLOTS="$(awk '$1 == "slot" && $2 ~ /^[0-5][0-9]$/ && $3 ~ /^[a-z]+$/ {print $2, $3}' "$GC_CONF")"
  GC_FALLBACK="$(awk '$1 == "fallback" {v = $2} END {print v}' "$GC_CONF")"
  GC_FALLBACK="${GC_FALLBACK:-claude}"
  [[ -n "$GC_SLOTS" ]] || { do_log "FATAL $GC_CONF names no slot (slot <MM> <vendor>)"; return 1; }
  while IFS='=' read -r k v; do
    [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v"
  done < <(grep -E '^GC_[A-Z_]+=[0-9]+$' "$GC_CONF" || true)
  : "${GC_AGENT_CAP:=180}" "${GC_MAX_AGE:=1500}" "${GC_POKE_WAIT:=1200}" "${GC_SILENT_AGE:=900}" "${GC_CLOSE_ASK_EVERY:=86400}"
  for k in $SPL_GC_KNOBS; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
}

# The vendor of the slot this minute falls in: the last slot at or before it.
spl_gc_slot_vendor() {
  local m
  m="$(date -u -d "@$GC_NOW" +%M)"
  awk -v m="$((10#$m))" -v best=-1 -v last=-1 '{s = $1 + 0; if (s <= m && s > best) {best = s; v = $2}; if (s > last) {last = s; lv = $2}}
    END {print (v != "" ? v : lv)}' <<<"$GC_SLOTS"
}

spl_gc_log() { echo "$(date -u -d "@$GC_NOW" +%FT%TZ) $*" >> "$GC_LOG"; }

# tmux, bounded; ROTATE_TMUX replaces it in tests. Fd 7 (start.lock) closed:
# a call that starts the server would hand it the lock for good.
spl_gc_tmux() {
  spl_gc_tm
  timeout -k 1 5 "${GC_TM[@]}" "$@" 7>&-
}
spl_gc_tm() {
  if [[ -n "${ROTATE_TMUX:-}" ]]; then GC_TM=("$ROTATE_TMUX"); return 0; fi
  spool_tmux_argv
  GC_TM=("${SPOOL_TM[@]}")
}

# ---- start -------------------------------------------------------------------

# The pane of the live GC window of this box, or nothing.
spl_gc_live_pane() {
  local pane="$1"
  [[ -n "$pane" ]] || return 0
  spl_gc_tmux list-panes -a -F $'#{pane_id}\t#{window_name}' 2>/dev/null |
    awk -F'\t' -v p="$pane" -v w="$GC_WIN" '$1 == p && $2 == w {print $1; exit}' || true
}

spl_gc_start() {
  local t pane v r age vendor rid sess cmd
  exec 7>>"$GC_DIR/start.lock"
  flock -n 7 || { echo "SKIP another GC start runs"; return 0; }
  if read -r t pane v r _ 2>/dev/null < "$GC_DIR/run" && [[ -n "$(spl_gc_live_pane "$pane")" ]]; then
    age=$(( GC_NOW - t ))
    if (( age < GC_MAX_AGE )); then
      spl_gc_log "SKIP $r is alive ($pane, ${age}s, $v): one GC per box"
      echo "SKIP $r is alive ($pane, ${age}s old, $v)"; return 0
    fi
    spl_gc_log "END-STALE $r ($pane, ${age}s >= ${GC_MAX_AGE}s): ended before the next pass"
    [[ "$GC_DRY" == 0 ]] && { spl_gc_tmux kill-window -t "$pane" >/dev/null 2>&1 || true; }
  fi
  vendor="${GC_VENDOR:-$(spl_gc_slot_vendor)}"
  rid="$(date -u -d "@$GC_NOW" +%Y%m%dT%H%MZ)-gc-$GC_BOX"
  cmd="SPOOL_ROOT='$SPOOL_ROOT' bash '$SPL_GC_RUN_DIR/../features/gc/gc-session.sh' '$vendor' '$GC_FALLBACK' '$rid' '$(cd "$PROJ_PATH/.." && pwd)'"
  if [[ "$GC_DRY" == 1 ]]; then echo "PLAN start $rid vendor=$vendor window=$GC_WIN: $cmd"; return 0; fi
  sess="$(spl_gc_tmux list-sessions -F '#{session_attached} #{session_id}' 2>/dev/null | awk '$1 > 0 {print $2; exit}' || true)"
  [[ -n "$sess" ]] || sess="$(spl_gc_tmux list-sessions -F '#{session_id}' 2>/dev/null | head -1 || true)"
  [[ -n "$sess" ]] || { spl_gc_log "FAIL $rid: no tmux session on this box"; do_log "FATAL no tmux session to start the GC in"; return 1; }
  pane="$(spl_gc_tmux new-window -d -t "$sess:" -n "$GC_WIN" -P -F '#{pane_id}' "$cmd" 2>/dev/null | grep -m1 -E '^%[0-9]+$' || true)"
  [[ -n "$pane" ]] || { spl_gc_log "FAIL $rid: new-window printed no pane"; do_log "FATAL the GC window did not start"; return 1; }
  echo "$GC_NOW $pane $vendor $rid" > "$GC_DIR/run"
  rm -f "$GC_DIR/cur"
  spl_gc_log "START $rid $vendor $pane"
  echo "START $rid $vendor $pane"
}

# ---- scan --------------------------------------------------------------------

# "<id>\t<pane>" of every agent window of this box (the watchdog's rule: a
# window named <id>[@<this box>], a "<tag>: " prefix allowed).
spl_gc_agents() {
  local re='^[acgqm]-[0-9]{3}$'
  spl_gc_tmux list-panes -a -F $'#{pane_id}\t#{window_name}' 2>/dev/null |
    while IFS=$'\t' read -r pane name; do
      [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:\  ]] && name="${name#*: }"
      name="${name%% *}"
      local id="${name%%@*}" box=""
      [[ "$name" == *@* ]] && box="${name#*@}"
      [[ "$id" =~ $re ]] || continue
      [[ -z "$box" || "$box" == "$GC_BOX" || "$box" == "$ROTATE_BOX" ]] || continue
      printf '%s\t%s\n' "$id" "$pane"
    done | sort -u -k1,1 || true
}

spl_gc_pane_of() { spl_gc_agents | awk -F'\t' -v i="$1" '$1 == i {print $2; exit}'; }

# Epoch of an ISO time, or 0.
spl_gc_epoch() { date -u -d "${1:-x}" +%s 2>/dev/null || echo 0; }

spl_gc_scan() {
  local id pane n=0
  echo "GC SCAN box=$GC_BOX at=$(date -u -d "@$GC_NOW" +%FT%TZ) cap=${GC_AGENT_CAP}s silent>=${GC_SILENT_AGE}s"
  spl_gc_agents | while IFS=$'\t' read -r id pane; do
    [[ -n "$id" ]] || continue
    spl_gc_scan_one "$id" "$pane"
    n=$(( n + 1 ))
  done
  echo "GC SCAN END agents=$n"
}

spl_gc_scan_one() {
  local id="$1" pane="$2" d="$SPOOL_ROOT/$1" role=lane st prog tool err sil wt cm post pa acc hint
  spl_is_role_seat "$id" && role="role-seat (scan only)"
  [[ -n "$(spl_gc_human "$id")" ]] && role="$role, $(spl_gc_human "$id")"
  IFS=$'\t' read -r st prog tool err <<EOF
$(jq -r '[.state // "-", .progress_ts // "-", .tool // "-", (.api_error // "-" | tostring)] | @tsv' "$d/heartbeat.json" 2>/dev/null || printf -- '-\t-\t-\t-\n')
EOF
  sil=$(( GC_NOW - $(spl_gc_epoch "$prog") ))
  wt="$(awk -F'\t' -v i="$id" '$1 == i {w = $4} END {print w}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true)"
  cm="$( [[ -d "$wt" ]] && git -c safe.directory='*' -C "$wt" log -1 --format='%ct %h %s' 2>/dev/null || true)"
  post="$(ls -t "$d/outbox" 2>/dev/null | head -1 || true)"
  pa="-"; [[ -n "$post" ]] && pa="$(( GC_NOW - $(stat -c %Y "$d/outbox/$post" 2>/dev/null || echo "$GC_NOW") ))s"
  acc="$(grep -rlsE '"body": ?"ACCEPTED' "$d/inbox" "$d/archive" 2>/dev/null | head -1 || true)"
  hint=working
  (( sil >= GC_SILENT_AGE )) && hint=silent
  [[ -n "$acc" ]] && hint="accepted (done?)"
  echo "== $id pane=$pane $role hint=$hint"
  echo "   issue: $(cat "$d/lifetime/issue" 2>/dev/null || echo -)  brief: $(head -1 "$d/lifetime/brief.md" 2>/dev/null | cut -c1-120 || true)"
  echo "   heartbeat: state=$st silent=${sil}s tool=$tool api_error=$(cut -c1-120 <<<"$err")"
  echo "   last commit: $( [[ -n "$cm" ]] && echo "$(( GC_NOW - ${cm%% *} ))s ago ${cm#* }" | cut -c1-140 || echo -)  worktree: ${wt:--}"
  echo "   last post: ${post:--} ($pa ago)  inbox: $(ls "$d/inbox" 2>/dev/null | wc -l) unread"
  echo "   gc: $(spl_gc_poked_line "$id")"
  spl_gc_tmux capture-pane -p -t "$pane" -S -12 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 5 | cut -c1-160 | sed 's/^/   | /' || true
}

spl_gc_poked_line() {
  local t p r
  if read -r t p r 2>/dev/null < "$GC_DIR/$1.poked"; then echo "poked $(( GC_NOW - t ))s ago in $r (progress then: $p)"; else echo "not poked"; fi
}

# A human hold on <id>, or nothing.
spl_gc_human() {
  local h
  h="$(cat "$SPOOL_ROOT/$1/.human-hold" 2>/dev/null || true)"
  if [[ "$h" =~ ^[0-9]+$ ]] && (( h > GC_NOW )); then echo "human hold for $(( (h - GC_NOW + 59) / 60 )) min"; fi
  return 0
}

# ---- one agent ---------------------------------------------------------------

spl_gc_refuse() { spl_gc_log "REFUSED $1 $2: $3"; echo "REFUSED $1 $2: $3"; return 4; }

spl_gc_step() {
  local cmd="$1" id="${AGENT_ID:-}"
  id="${id%@*}"
  [[ "$id" =~ ^[acgqm]-[0-9]{3}$ ]] || { do_log "FATAL AGENT_ID must be an agent id (c-NNN), got: '${AGENT_ID:-}'"; return 1; }
  [[ -n "$(spl_gc_pane_of "$id")" ]] || { spl_gc_log "NONE $cmd $id: not an agent of this box"; echo "NONE $id: not an agent of this box"; return 3; }
  if [[ "$cmd" == begin ]]; then spl_gc_begin "$id"; return; fi
  spl_gc_cap "$cmd" "$id" || return
  if spl_is_role_seat "$id"; then spl_gc_refuse "$cmd" "$id" "a role seat: rotation and the watchdog own it"; return; fi
  local h; h="$(spl_gc_human "$id")"
  [[ -z "$h" ]] || { spl_gc_refuse "$cmd" "$id" "$h"; return; }
  case "$cmd" in
    poke) spl_gc_poke "$id" ;;
    restart) spl_gc_restart "$id" ;;
    close-ask) spl_gc_close_ask "$id" ;;
  esac
}

# The clock of the owner's cap: <gc>/cur "<id> <epoch>"; the agent before is
# closed with its time (OVER past the cap).
spl_gc_begin() {
  local id="$1" d="$SPOOL_ROOT/$1" f
  spl_gc_end_cur
  echo "$id $GC_NOW" > "$GC_DIR/cur"
  spl_gc_log "BEGIN $id"
  echo "BEGIN $id: ${GC_AGENT_CAP}s, until $(date -u -d "@$(( GC_NOW + GC_AGENT_CAP ))" +%TZ); then begin the next agent"
  echo "issue: $(cat "$d/lifetime/issue" 2>/dev/null || echo -)  brief: $d/lifetime/brief.md"
  echo "api_error: $(jq -c '.api_error' "$d/heartbeat.json" 2>/dev/null || echo -)"
  for f in heartbeat.log hook.err lifetime/handoff.err; do
    [[ -s "$d/$f" ]] && { echo "--- $f"; tail -n 3 "$d/$f" | cut -c1-200; }
  done
  echo "--- last posts"
  ls -t "$d/outbox" 2>/dev/null | sed -n 1,2p | while read -r f; do jq -r '"\(.ts) \(.kind) to \(.to) task \(.task_id): \(.body)"' "$d/outbox/$f" 2>/dev/null | cut -c1-300; done || true
  echo "--- pane"
  spl_gc_tmux capture-pane -p -t "$(spl_gc_pane_of "$id")" -S -30 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 15 | cut -c1-200 || true
}

spl_gc_end_cur() {
  local cid ct el
  read -r cid ct 2>/dev/null < "$GC_DIR/cur" || return 0
  [[ "$ct" =~ ^[0-9]+$ ]] || return 0
  el=$(( GC_NOW - ct ))
  if (( el > GC_AGENT_CAP )); then spl_gc_log "END $cid ${el}s OVER the ${GC_AGENT_CAP}s cap"; else spl_gc_log "END $cid ${el}s"; fi
  rm -f "$GC_DIR/cur"
}

spl_gc_cap() {
  local cmd="$1" id="$2" cid ct el
  read -r cid ct 2>/dev/null < "$GC_DIR/cur" || { spl_gc_refuse "$cmd" "$id" "begin it first (GC_CMD=begin)"; return; }
  [[ "$cid" == "$id" ]] || { spl_gc_refuse "$cmd" "$id" "the agent begun is $cid: begin $id first"; return; }
  el=$(( GC_NOW - ct ))
  (( el <= GC_AGENT_CAP )) || { spl_gc_refuse "$cmd" "$id" "CAP ${el}s > ${GC_AGENT_CAP}s on this agent: move on"; return; }
}

spl_gc_send() {  # TO TASK BODY
  if [[ "$GC_DRY" == 1 ]]; then echo "PLAN note to $1 on $2: $3"; return 0; fi
  local rc=0
  echo "DEBUG: spl_gc_send --from $GC_FROM --to $1 --kind note --task $2 --body $3" >&2
  bash "$GC_SEND" --from "$GC_FROM" --to "$1" --kind note --task "$2" --body "$3" >/dev/null 2>&1 7>&- || rc=$?
  (( rc < 10 && rc != 2 ))
}

spl_gc_rid() { local r; read -r _ _ _ r 2>/dev/null < "$GC_DIR/run" || true; echo "${r:-${GC_RUN_ID:-manual}}"; }

spl_gc_progress() { jq -r '.progress_ts // "-"' "$SPOOL_ROOT/$1/heartbeat.json" 2>/dev/null || echo -; }

spl_gc_poke() {
  local id="$1" rid t _p r
  [[ -n "${GC_HINT:-}" ]] || { do_log "FATAL GC_HINT is required: what the agent should try (its issue, its last error)"; return 1; }
  rid="$(spl_gc_rid)"
  if read -r t _p r 2>/dev/null < "$GC_DIR/$id.poked" && [[ "$r" == "$rid" ]]; then
    spl_gc_refuse poke "$id" "already poked in this pass"; return
  fi
  spl_gc_send "$id" "gc-$id" "GC ($GC_BOX, $rid): you look stuck. $GC_HINT -- If you are working, carry on; if not, act on this or reply on this task." ||
    { spl_gc_log "FAIL poke $id: not delivered"; echo "FAIL poke $id: not delivered"; return 1; }
  [[ "$GC_DRY" == 0 ]] && echo "$GC_NOW $(spl_gc_progress "$id") $rid" > "$GC_DIR/$id.poked"
  spl_gc_log "POKE $id: $(cut -c1-200 <<<"$GC_HINT")"
  echo "POKE $id"
}

spl_gc_restart() {
  local id="$1" t p r now_p ev
  read -r t p r 2>/dev/null < "$GC_DIR/$id.poked" || { spl_gc_refuse restart "$id" "never poked: poke first, restart on a later pass"; return; }
  (( GC_NOW - t >= GC_POKE_WAIT )) || { spl_gc_refuse restart "$id" "poked $(( GC_NOW - t ))s ago (< ${GC_POKE_WAIT}s): restart on a later pass"; return; }
  now_p="$(spl_gc_progress "$id")"
  if [[ "$now_p" != "$p" ]] && (( $(spl_gc_epoch "$now_p") > t )); then
    rm -f "$GC_DIR/$id.poked"
    spl_gc_log "MOVED $id: progress $now_p after the poke: no restart"
    echo "MOVED $id: progress since the poke ($now_p): no restart"; return 3
  fi
  ev="gc $(spl_gc_rid): poked in $r at $(date -u -d "@$t" +%FT%TZ), no heartbeat progress since ($now_p)"
  if [[ "$GC_DRY" == 1 ]]; then echo "PLAN restart $id CAUSE=gc: $ev"; return 0; fi
  # shellcheck disable=SC2086 # a command line, split on purpose
  ( ID="$id" CAUSE=gc WD_EVIDENCE="$ev" DRY_RUN=0 setsid ${GC_RESTART_CMD:-$GC_RUN -a do_spl_agent_restart} \
      >> "$GC_DIR/restart.$id.out" 2>&1 < /dev/null 7>&- & )
  rm -f "$GC_DIR/$id.poked"
  spl_gc_log "RESTART $id: $ev (do_spl_agent_restart, log $GC_DIR/restart.$id.out)"
  echo "RESTART $id (detached; log $GC_DIR/restart.$id.out)"
}

spl_gc_close_ask() {
  local id="$1" t
  [[ -n "${GC_WHY:-}" ]] || { do_log "FATAL GC_WHY is required: why $id looks done and idle"; return 1; }
  if read -r t 2>/dev/null < "$GC_DIR/$id.closeask" && [[ "$t" =~ ^[0-9]+$ ]] && (( GC_NOW - t < GC_CLOSE_ASK_EVERY )); then
    spl_gc_refuse close-ask "$id" "asked $(( GC_NOW - t ))s ago"; return
  fi
  echo "DEBUG: GC_REPORT_TO before resolve=$GC_REPORT_TO"
  echo "DEBUG: GC_NOW before resolve=$GC_NOW"
  echo "DEBUG: GC_LEASE_FILE before resolve=$GC_LEASE_FILE"
  echo "DEBUG: GC_DRY before resolve=$GC_DRY"
  spl_gc_resolve_report_to
  echo "DEBUG: GC_REPORT_TO after resolve=$GC_REPORT_TO"
  echo "DEBUG: GC_NOW after resolve=$GC_NOW"
  echo "DEBUG: GC_LEASE_FILE after resolve=$GC_LEASE_FILE"
  echo "DEBUG: GC_DRY after resolve=$GC_DRY"
  local cc=""
  if [[ "$GC_REPORT_TO" != "$(spl_role_seat 1)" ]]; then
    cc=" --cc $(spl_role_seat 1)"
  fi
  spl_gc_send "orchestrator$cc" "gc-$id" "GC ($GC_BOX, $(spl_gc_rid)): $id@$GC_BOX looks done and idle: $GC_WHY. Close it if you agree." ||
    { spl_gc_log "FAIL close-ask $id: not delivered"; echo "FAIL close-ask $id: not delivered"; return 1; }
  [[ "$GC_DRY" == 0 ]] && echo "$GC_NOW" > "$GC_DIR/$id.closeask"
  spl_gc_log "CLOSE-ASK $id: $(cut -c1-200 <<<"$GC_WHY")"
  echo "CLOSE-ASK $id"
}

# ---- end of the pass -------------------------------------------------------------

spl_gc_done() {
  local rid t pane v
  [[ -n "${GC_SUMMARY:-}" ]] || { do_log "FATAL GC_SUMMARY is required: one line for the orchestrator"; return 1; }
  rid="$(spl_gc_rid)"
  [[ "$GC_DRY" == 0 ]] && spl_gc_end_cur
  read -r t pane v _ 2>/dev/null < "$GC_DIR/run" || true
  echo "DEBUG: GC_REPORT_TO before resolve=$GC_REPORT_TO"
  echo "DEBUG: GC_NOW before resolve=$GC_NOW"
  echo "DEBUG: GC_LEASE_FILE before resolve=$GC_LEASE_FILE"
  echo "DEBUG: GC_DRY before resolve=$GC_DRY"
  echo "DEBUG: GC_REPORT_TO before spl_gc_resolve_report_to=$GC_REPORT_TO"
  spl_gc_resolve_report_to
  echo "DEBUG: GC_REPORT_TO after spl_gc_resolve_report_to=$GC_REPORT_TO"
  echo "DEBUG: GC_NOW after resolve=$GC_NOW"
  echo "DEBUG: GC_LEASE_FILE after resolve=$GC_LEASE_FILE"
  echo "DEBUG: GC_DRY after resolve=$GC_DRY"
  spl_gc_send "$GC_REPORT_TO" "gc-$GC_BOX" "GC $GC_BOX $rid (${v:-?}): $GC_SUMMARY" || spl_gc_log "FAIL summary to $GC_REPORT_TO: not delivered"
  [[ "$GC_DRY" == 1 ]] && { echo "PLAN close ${pane:-?} ($GC_WIN)"; return 0; }
  spl_gc_log "DONE $rid: $(cut -c1-300 <<<"$GC_SUMMARY")"
  echo "DONE $rid: the window closes"
  [[ -n "$(spl_gc_live_pane "${pane:-}")" ]] || return 0
  if [[ "${GC_CLOSE_DELAY:-5}" == 0 ]]; then
    spl_gc_tmux kill-window -t "$pane" >/dev/null 2>&1 || true
  else
    spl_gc_tm
    ( setsid bash -c 'sleep "$1"; shift; "$@" kill-window -t "$0"' "$pane" "${GC_CLOSE_DELAY:-5}" "${GC_TM[@]}" >/dev/null 2>&1 < /dev/null 7>&- & )
  fi
}

spl_gc_status() {
  local t pane v r
  if read -r t pane v r 2>/dev/null < "$GC_DIR/run"; then
    echo "last pass: $r $v $pane, $(( GC_NOW - t ))s ago, $( [[ -n "$(spl_gc_live_pane "$pane")" ]] && echo alive || echo closed)"
  else
    echo "no GC pass on this box yet"
  fi
  echo "slots: $(tr '\n' ';' <<<"$GC_SLOTS") fallback $GC_FALLBACK"
  tail -n 15 "$GC_LOG" 2>/dev/null || true
}
