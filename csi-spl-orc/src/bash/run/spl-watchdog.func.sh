#!/bin/bash
#------------------------------------------------------------------------------
# @description The box watchdog of spec 093 section 6: one loop per box, no
# @description model call. Every WD_TICK s it walks every local agent (a tmux
# @description window named <id>[@<this box>], or a process carrying
# @description SPOOL_AGENT_ID), fills its context dir once, runs each
# @description situation script features/watchdog/situations/s[1-8].sh under
# @description `timeout WD_SCRIPT_TIMEOUT` (a hung script costs one script one
# @description tick, never the tick: FR-014), debounces the hits (6.1), applies
# @description the guards of 6.2 and the limits of 6.3, writes the verdict
# @description <spool root>/dispatch/wd.<id> ("HIT <code> <epoch>" or "OK <epoch>")
# @description for the able check, prints one verdict line per agent and
# @description acts: S1 rings at 120 s and takes over at 240 s, S2 never
# @description restarts (a login: ONE blocker to the orchestrator), S3 takes
# @description over, S4 Escape then takeover, S5 Escape + note then takeover,
# @description S6 clears a poke-shaped box and re-pokes, S7 Escape once (the
# @description default-mode offer: bypass settings re-asserted + takeover,
# @description "No, keep bypass permissions" as the fallback), S8 reports the
# @description hook GAP once. A takeover is do_spl_wd_takeover
# @description (T005); until it exists the wish is logged. DRY_RUN=1 (the
# @description default) writes the verdicts and only prints the actions.
# @param WD_TICKS (optional) - ticks to run, default 0 = forever (the loop); 1 = one proof tick
# @param WD_TICK (optional) - seconds per tick, default 30
# @param DRY_RUN (optional) - 1 (default): no key, ring, note or takeover; 0: act
# @param WD_SCRIPT_TIMEOUT (optional) - seconds per situation script, default 5
# @param WD_START_GRACE (optional) - seconds after a session start or a box resume with no situation, default 180
# @param WD_TAKEOVER_MAX (optional) - takeovers per id per rolling hour, default 2
# @param WD_JOBS (optional) - agents checked at once, default 8
# @param WD_SITUATIONS (optional) - the situation scripts dir (tests)
# @param WD_ONLY (optional) - space-separated ids: check only these (a drill on scratch ids next to the live loop)
# @param WD_STATE_DIR (optional) - the state dir (lock, debounces, ctx), default <spool root>/dispatch/wd; another one runs beside the live loop
# @param WD_PS_CMD / WD_SEND / WD_TAKEOVER_CMD / ROTATE_TMUX (optional) - seams for the tests: ps, spool-send.sh, the takeover, tmux
# @example WD_TICKS=1 ./run -a do_spl_watchdog
# @example DRY_RUN=0 ./run -a do_spl_watchdog
# @example WD_ONLY="c-981 c-982" WD_STATE_DIR=/var/tmp/wd-drill DRY_RUN=0 WD_TICKS=20 ./run -a do_spl_watchdog
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"
declare -F spl_wd_log_rotate >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-ensure.func.sh"

SPL_WD_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

do_spl_watchdog() {
  spl_wd_init || return 1
  local n=0 t0 left
  exec 7>>"$WD_DIR/run.lock"
  if ! flock -w "$(( WD_TICKS > 0 ? WD_TICK : 0 ))" 7; then
    do_log "INFO a watchdog already runs on this box ($WD_DIR/run.lock)"
    return 0
  fi
  echo "$$" > "$WD_DIR/run.pid"
  while :; do
    t0="$(date +%s)"
    spl_wd_tick
    n=$((n + 1))
    if (( WD_TICKS > 0 && n >= WD_TICKS )); then break; fi
    left=$(( WD_TICK - ($(date +%s) - t0) ))
    if (( left > 0 )); then sleep "$left"; fi
  done
  return 0
}

spl_wd_init() {
  spl_rotate_conf || return 1
  WD_DIR="${WD_STATE_DIR:-$LEASE_DIR/wd}"
  WD_LOG="$LEASE_DIR/wd.log"
  WD_SITUATIONS="${WD_SITUATIONS:-$SPL_WD_RUN_DIR/../features/watchdog/situations}"
  : "${WD_TICKS:=0}" "${WD_TICK:=30}" "${WD_SCRIPT_TIMEOUT:=5}" "${WD_START_GRACE:=180}"
  : "${WD_TAKEOVER_MAX:=2}" "${WD_JOBS:=8}" "${WD_JOB_WAIT:=120}" "${WD_LOOP_N:=5}"
  local k
  for k in WD_TICKS WD_TICK WD_SCRIPT_TIMEOUT WD_START_GRACE WD_TAKEOVER_MAX WD_JOBS WD_JOB_WAIT WD_LOOP_N; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  (( WD_TICK > 0 && WD_JOBS > 0 && WD_SCRIPT_TIMEOUT > 0 )) ||
    { do_log "FATAL WD_TICK, WD_JOBS and WD_SCRIPT_TIMEOUT must be at least 1"; return 1; }
  [[ -d "$WD_SITUATIONS" ]] || { do_log "FATAL no situation scripts in $WD_SITUATIONS"; return 1; }
  WD_FROM="${WD_FROM:-${LEASE_ORCH:-c-001}}"
  WD_SEND="${WD_SEND:-$ROTATE_SEND}"
  WD_BOX="${ROTATE_BOX:-}"
  export WD_JOB_WAIT WD_LOOP_N WD_BOX
  mkdir -p "$WD_DIR/ctx" || { do_log "FATAL cannot create $WD_DIR"; return 1; }
  return 0
}

# ---- one tick ------------------------------------------------------------------

spl_wd_tick() {
  local now last tick="$WD_DIR/tick" id pid pane
  now="$(spl_lease_now)"
  last="$(cat "$WD_DIR/last.tick" 2>/dev/null || true)"
  # a box back from suspend or power loss: every age looks huge (6.2)
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last > 3 * WD_TICK )); then
    rm -f "$WD_DIR"/*.hits
    echo "$now" > "$WD_DIR/resume"
    spl_wd_log "RESUME tick gap $((now - last))s: debounces and graces reset"
  fi
  echo "$now" > "$WD_DIR/last.tick"
  rm -rf "$tick" && mkdir -p "$tick"
  spl_wd_ps > "$tick/ps"
  spl_wd_tmux list-panes -a -F '#{pane_id}	#{pane_pid}	#{session_id}	#{window_name}	#{pane_current_command}' \
    > "$tick/panes" 2>/dev/null || true
  spl_wd_tmux list-clients -F '#{session_id} #{client_activity}' > "$tick/clients" 2>/dev/null || true
  WD_BOX_BUSY=""
  if [[ -e "$SPOOL_ROOT/peer/restart.lock" ]] && ! flock -n "$SPOOL_ROOT/peer/restart.lock" true; then
    WD_BOX_BUSY="a restart holds peer/restart.lock"
  fi
  spl_wd_agents "$tick" > "$tick/agents"
  # named pids only: a bare `wait` also waits for ./run's tee process substitutions
  local -a jp=()
  while IFS=$'\t' read -r id pid pane; do
    while (( $(spl_wd_running "${jp[@]}") >= WD_JOBS )); do sleep 0.2; done
    spl_wd_one "$id" "$pid" "$pane" "$now" "$tick" > "$tick/out.$id" 2>>"$tick/err" &
    jp+=("$!")
  done < "$tick/agents"
  if (( ${#jp[@]} )); then wait "${jp[@]}" 2>/dev/null || true; fi
  while IFS=$'\t' read -r id _; do
    cat "$tick/out.$id" 2>/dev/null || true
  done < "$tick/agents" | tee -a "$WD_LOG.tmp.$$" || true
  if [[ -f "$WD_LOG.tmp.$$" ]]; then
    sed "s/^/$(date -u -d "@$now" +%FT%TZ) /" "$WD_LOG.tmp.$$" >> "$WD_LOG"
    rm -f "$WD_LOG.tmp.$$"
  fi
  spl_wd_log_trim
  return 0
}

# How many of <pid>... still run.
spl_wd_running() {
  local p n=0
  for p in "$@"; do if kill -0 "$p" 2>/dev/null; then n=$((n + 1)); fi; done
  echo "$n"
}

spl_wd_log() { echo "$(date -u +%FT%TZ) $*" >> "$WD_LOG"; }

# wd.log keeps a day or two: spl_wd_log_rotate copies it to wd.log.1 once a
# day (WD_LOG_KEEP) or past WD_LOG_MAX_BYTES. A line cap held about an hour on
# a busy box (5000 lines; 2026-10-06: ~5000/h on one box, ~600/h on another).
spl_wd_log_trim() {
  spl_wd_log_rotate "$WD_LOG" "$(spl_lease_now)"
}

# tmux, bounded: a hung server costs one call 5 s. ROTATE_TMUX replaces it in tests.
spl_wd_tmux() {
  if [[ -n "${ROTATE_TMUX:-}" ]]; then
    timeout -k 1 5 "$ROTATE_TMUX" "$@"
    return
  fi
  spool_tmux_argv
  timeout -k 1 5 "${SPOOL_TM[@]}" "$@"
}

# "pid ppid etimes comm" for every process. WD_PS_CMD replaces ps in tests.
spl_wd_ps() {
  local -a cmd=(ps -e -o "pid=,ppid=,etimes=,comm=")
  # shellcheck disable=SC2206 # a command line, split on purpose
  [[ -n "${WD_PS_CMD:-}" ]] && cmd=($WD_PS_CMD)
  "${cmd[@]}" 2>/dev/null | awk '{print $1, $2, $3, $4}' || true
}

# ---- who is checked -------------------------------------------------------------

# "<id>\t<pid>\t<pane>" for every local agent: a window named <id> or
# <id>@<this box> (a "<tag>: " prefix allowed), and every process that carries
# SPOOL_AGENT_ID. pid is the harness process (a claude/grok/agy/qwen comm
# first, else the lowest node/bun), "-" when none; pane "-" when none.
spl_wd_agents() {
  local tick="$1" re='^([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)$'
  local pane name id box
  : > "$tick/win"
  while IFS=$'\t' read -r pane _ _ name _; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:\  ]] && name="${name#*: }"
    name="${name%% *}"
    id="${name%%@*}"; box=""
    [[ "$name" == *@* ]] && box="${name#*@}"
    [[ "$id" =~ $re ]] || continue
    [[ -z "$box" || "$box" == "${SPOOL_BOX_TAG:-}" || "$box" == "$ROTATE_BOX" ]] || continue
    printf '%s\t%s\n' "$id" "$pane" >> "$tick/win"
  done < "$tick/panes"
  spl_wd_proc_ids "$tick" > "$tick/procs"
  awk -F'\t' -v w="$tick/win" '
    FILENAME == w { if (!($1 in wp)) { wp[$1] = $2; ids[$1] = 1 } ; next }
    { if (!($2 in pid)) { pid[$2] = $1; ids[$2] = 1 } }
    END { for (i in ids) {
            p = (i in pid) ? pid[i] : "-"; w = (i in wp) ? wp[i] : "-"
            # an id names files: a SPOOL_AGENT_ID of any other shape is not checked
            if (i ~ /^[A-Za-z][A-Za-z0-9-]*$/) print i "\t" p "\t" w } }' "$tick/win" "$tick/procs" |
    sort | spl_wd_only > "$tick/agents.raw"
  spl_wd_pane_of_pids "$tick"
}

# The agent lines whose id is in WD_ONLY; all of them when it is empty.
spl_wd_only() {
  if [[ -z "${WD_ONLY:-}" ]]; then cat; return 0; fi
  awk -F'\t' -v only=" ${WD_ONLY//,/ } " 'index(only, " " $1 " ")'
}

# The pane of an agent found by its process only: the pane whose pane_pid is
# the pid or one of its ancestors (the ps dump's ppid chain).
spl_wd_pane_of_pids() {
  local tick="$1"
  cut -f1,2 "$tick/panes" > "$tick/panepids"
  awk -F'\t' -v OFS='\t' -v ps="$tick/ps" -v pp_="$tick/panepids" '
    FILENAME == ps { split($0, a, " "); pp[a[1]] = a[2]; next }
    FILENAME == pp_ { pane[$2] = $1; next }
    { if ($3 == "-" && $2 != "-") {
        p = $2
        for (k = 0; k < 64 && p > 1; k++) { if (p in pane) { $3 = pane[p]; break }; p = pp[p] }
      }
      print $1, $2, $3 }' "$tick/ps" "$tick/panepids" "$tick/agents.raw"
}

# "<pid>\t<id>" per agent id: the harness process carrying SPOOL_AGENT_ID=<id>.
# Another user's environ goes through the owner hop (proc-owner.inc.sh).
spl_wd_proc_ids() {
  local tick="$1" root="${LEASE_PROC_ROOT:-/proc}" pid comm e
  local -a env other=()
  {
    while read -r pid _ _ comm; do
      case "$comm" in claude|grok|agy|qwen|node|bun) ;; *) continue ;; esac
      if [[ -r "$root/$pid/environ" ]]; then
        env=(); { mapfile -d '' -t env < "$root/$pid/environ"; } 2>/dev/null || continue
        for e in "${env[@]}"; do
          [[ "$e" == SPOOL_AGENT_ID=* ]] && { echo "$pid ${e#SPOOL_AGENT_ID=}"; break; }
        done
      else
        other+=("$pid")
      fi
    done < "$tick/ps"
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" 2>/dev/null || true
    fi
  } | awk -v ps="$tick/ps" 'FILENAME == ps { c[$1] = $4; next }
      $2 != "" { r = (c[$1] ~ /^(claude|grok|agy|qwen)$/) ? 0 : 1; print r, $1, $2 }' "$tick/ps" - |
    sort -k1,1n -k2,2n | awk '!seen[$3]++ { print $2 "\t" $3 }'
}

# ---- one agent -------------------------------------------------------------------

# Check one agent and print its verdict line.
spl_wd_one() {
  local id="$1" pid="$2" pane="$3" now="$4" tick="$5" ctx skip line
  ctx="$WD_DIR/ctx/$id"
  rm -rf "$ctx" && mkdir -p "$ctx"
  [[ "$pid" == - ]] && pid=""
  [[ "$pane" == - ]] && pane=""
  spl_wd_gather "$id" "$pid" "$pane" "$now" "$tick" "$ctx"
  skip="$(spl_wd_skip "$id" "$pid" "$now" "$tick" "$ctx")"
  if [[ -n "$skip" ]]; then
    rm -f "$WD_DIR/$id.hits"
    spl_wd_verdict "$id" OK "$now"
    echo "$id SKIP $skip"
    return 0
  fi
  spl_wd_run_scripts "$id" "$pid" "$pane" "$ctx"
  line="$(spl_wd_judge "$id" "$pid" "$pane" "$now" "$ctx")"
  echo "$id $line"
  return 0
}

# Every situation script at once, each under `timeout`: the agent costs at
# most WD_SCRIPT_TIMEOUT s whatever hangs (FR-014).
spl_wd_run_scripts() {
  local id="$1" pid="$2" pane="$3" ctx="$4" s
  local -a sp=()
  for s in "$WD_SITUATIONS"/s[0-9]*.sh; do
    [[ -f "$s" ]] || continue
    ( WD_CTX="$ctx" timeout -k 1 "$WD_SCRIPT_TIMEOUT" bash "$s" "$id" "${pid:--}" "${pane:--}" \
        > "$ctx/out.$(basename "$s" .sh)" 2>/dev/null 7>&- || true ) &
    sp+=("$!")
  done
  if (( ${#sp[@]} )); then wait "${sp[@]}" 2>/dev/null || true; fi
  return 0
}

# The context dir of one agent (situations/lib.inc.sh names the files).
spl_wd_gather() {
  local id="$1" pid="$2" pane="$3" now="$4" tick="$5" ctx="$6" ppid sess act rundir
  echo "$now" > "$ctx/now"
  cp "$SPOOL_ROOT/$id/heartbeat.json" "$ctx/heartbeat" 2>/dev/null || true
  cp "$SPOOL_ROOT/peer/$id/held" "$ctx/held" 2>/dev/null || true
  if awk -v i="$id" '$1 == i {f = 1} END {exit !f}' "$SPOOL_ROOT/peer/seats" 2>/dev/null; then echo "$id" > "$ctx/seat"; fi
  spl_wd_inbox "$SPOOL_ROOT/$id/inbox" > "$ctx/inbox"
  rundir="$(awk -F'\t' -v i="$id" '$1 == i {d = $4} END {print d}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true)"
  if [[ "$rundir" == /* && ! -d "$rundir" ]]; then echo "$rundir" > "$ctx/rundir_gone"; fi
  if [[ -n "$pid" ]]; then
    awk -v p="$pid" '$1 == p {print $3}' "$tick/ps" > "$ctx/proc_age"
    spl_wd_transcript "$pid" > "$ctx/transcript"
    spl_rotate_user "$pid" > "$ctx/user" 2>/dev/null || true
  fi
  [[ -n "$pane" ]] || return 0
  spl_wd_tmux capture-pane -p -t "$pane" > "$ctx/pane" 2>/dev/null || rm -f "$ctx/pane"
  IFS=$'\t' read -r ppid sess < <(awk -F'\t' -v p="$pane" '$1 == p {print $2 "\t" $3}' "$tick/panes") || true
  awk -F'\t' -v p="$pane" '$1 == p {print $5}' "$tick/panes" > "$ctx/fg"
  [[ -n "${ppid:-}" ]] && spl_wd_tree "$ppid" "$tick/ps" > "$ctx/tree"
  act="$(awk -v s="${sess:-none}" '$1 == s && $2 > m {m = $2} END {print m + 0}' "$tick/clients")"
  if (( act > 0 )); then echo $(( now - act )) > "$ctx/client_age"; fi
  spl_wd_since "$id" spin "$(grep -v '^[[:space:]]*$' "$ctx/pane" 2>/dev/null | tail -n 12 |
    grep -oE -- '…[[:space:]]*\([0-9][^)]*\)' | tail -1 | grep -oE '\(.*\)' || true)" "$now" "$ctx/spin_age"
  # shellcheck disable=SC2317 # called by spl_rotate_input
  ( spl_rotate_tmux() { spl_wd_tmux "$@"; }; spl_rotate_input "$pane" ) > "$ctx/input" 2>/dev/null || : > "$ctx/input"
  spl_wd_since "$id" input "$(cat "$ctx/input")" "$now" "$ctx/input_age"
  return 0
}

# "<mtime epoch> <file> <kind> <from>" per <dir>/*.json, one jq for the
# whole inbox; a file that does not parse reads "- -" (S1 counts it as a job).
spl_wd_inbox() {
  local dir="$1" q f
  local -a fs=()
  q='[.kind, .from] | map(. // "-" | tostring | gsub("[[:space:]]"; "") | if . == "" then "-" else . end)
    | "\(input_filename | sub(".*/"; "")) \(join(" "))"'
  mapfile -t fs < <(find "$dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null)
  (( ${#fs[@]} )) || return 0
  {
    # a file that does not parse stops jq: then one jq per file
    jq -r "$q" "${fs[@]}" 2>/dev/null ||
      for f in "${fs[@]}"; do jq -r "$q" "$f" 2>/dev/null || true; done
    echo "--"
    find "$dir" -maxdepth 1 -type f -name '*.json' -printf '%T@ %f\n' 2>/dev/null | sed 's/\.[0-9]* / /'
  } | awk '$0 == "--" {m = 1; next} !m {k[$1] = $2 " " $3; next}
      {print $1, $2, (($2 in k) ? k[$2] : "- -")}'
  return 0
}

# The transcript tail of <pid> (LEASE_TRANSCRIPT_CMD replaces it), bounded.
spl_wd_transcript() {
  ( spl_lease_transcript_tail "$1" ) 2>/dev/null | tail -n "${LEASE_TRANSCRIPT_TAIL:-400}" || true
}

# The comm of every process under <pid> (the pane's tree), from the ps dump.
spl_wd_tree() {
  awk -v root="$1" '{ pp[$1] = $2; c[$1] = $4 }
    END { for (p in pp) { q = p
            for (k = 0; k < 64 && q > 1; k++) { if (q == root) { print c[p]; break }; q = pp[q] } } }' "$2" | sort -u
}

# How long <id>'s <what> has held <text>: state <WD_DIR>/<id>.<what> keeps
# "<since epoch>\t<text hash>"; the age goes to <out>, nothing for empty text.
spl_wd_since() {
  local id="$1" what="$2" text="$3" now="$4" out="$5" f h since="" old=""
  f="$WD_DIR/$id.$what"
  if [[ -z "$text" ]]; then rm -f "$f"; return 0; fi
  h="$(printf '%s' "$text" | cksum | cut -d' ' -f1)"
  if [[ -f "$f" ]]; then IFS=$'\t' read -r since old < "$f" || true; fi
  if [[ "$old" != "$h" || ! "$since" =~ ^[0-9]+$ ]]; then
    since="$now"
    printf '%s\t%s\n' "$now" "$h" > "$f"
  fi
  echo $(( now - since )) > "$out"
  return 0
}

# Why <id> is out of the situations this tick (6.2); nothing when it is checked.
spl_wd_skip() {
  local id="$1" pid="$2" now="$3" tick="$4" ctx="$5" hid ht r age st hbt
  if [[ -s "$LEASE_DIR/rotate.hold" ]]; then
    read -r hid ht _ < "$LEASE_DIR/rotate.hold" || true
    if [[ "$hid" == "$id" && "$ht" =~ ^[0-9]+$ ]] && (( now - ht < ${ROTATE_HOLD_MAX:-1800} )); then
      echo "rotation: rotate.hold names it"; return 0
    fi
  fi
  r="$(spl_wd_rotating "$id" "$now")"
  if [[ -n "$r" ]]; then echo "rotation: $r"; return 0; fi
  age="$(cat "$ctx/proc_age" 2>/dev/null || true)"
  if [[ "$age" =~ ^[0-9]+$ ]] && (( age < WD_START_GRACE )); then
    echo "start grace: session ${age}s old"; return 0
  fi
  st="$(jq -r '.state // empty' "$ctx/heartbeat" 2>/dev/null || true)"
  hbt="$(jq -r '.ts // empty' "$ctx/heartbeat" 2>/dev/null || true)"
  hbt="$(date -u -d "${hbt:-x}" +%s 2>/dev/null || true)"
  if [[ "$st" == starting && "$hbt" =~ ^[0-9]+$ ]] && (( now - hbt < WD_START_GRACE )); then
    echo "start grace: SessionStart $((now - hbt))s ago"; return 0
  fi
  r="$(cat "$WD_DIR/resume" 2>/dev/null || true)"
  if [[ "$r" =~ ^[0-9]+$ ]] && (( now - r < WD_START_GRACE )); then
    echo "resume grace: box back $((now - r))s ago"; return 0
  fi
  return 0
}

# The phase of a rotation or takeover of <id> still in flight: the last
# rotate.log line whose run id ends in -<id>, when it is not final and is
# younger than 15 min.
spl_wd_rotating() {
  local id="$1" now="$2" ts rid phase res t
  [[ -f "$ROTATE_LOG" ]] || return 0
  read -r ts rid phase res _ < <(awk -v s="-$id" 'substr($2, length($2) - length(s) + 1) == s {l = $0} END {print l}' "$ROTATE_LOG") || return 0
  [[ -n "${rid:-}" ]] || return 0
  case "$phase" in DONE|FAIL|ABORT|ALERT) return 0 ;; esac
  [[ "$res" == FAIL ]] && return 0
  t="$(date -u -d "$ts" +%s 2>/dev/null || true)"
  [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < 900 )) && echo "$rid $phase $res"
  return 0
}

# ---- verdicts ----------------------------------------------------------------------

# The order a verdict is picked in when several situations hit. S8 is never
# the verdict: a silent hook is not a stuck agent (6.1).
WD_ORDER="S3 S2 S7 S4 S5 S1 S6"

# The debounce of a code in ticks (6.1): S2, S3 and S8 2, the rest 1 (S1 and
# S6 carry their own age).
spl_wd_need() { case "$1" in S2|S3|S8) echo 2 ;; *) echo 1 ;; esac; }

# Debounce, verdict file, act; prints the rest of the agent's verdict line.
spl_wd_judge() {
  local id="$1" pid="$2" pane="$3" now="$4" ctx="$5" code ev cnt need main="" mainev="" pend="" extra="" act
  cat "$ctx"/out.s* 2>/dev/null | grep -E '^HIT S[0-9]+( |$)' | sort -u > "$ctx/hits" || true
  : > "$WD_DIR/$id.hits.new"
  while read -r _ code ev; do
    cnt="$(awk -v c="$code" '$1 == c {print $2}' "$WD_DIR/$id.hits" 2>/dev/null || true)"
    cnt=$(( ${cnt:-0} + 1 ))
    echo "$code $cnt" >> "$WD_DIR/$id.hits.new"
    need="$(spl_wd_need "$code")"
    if (( cnt < need )); then pend+=" (pending $code $cnt/$need: $ev)"; continue; fi
    printf '%s\t%s\n' "$code" "$ev" >> "$ctx/confirmed"
  done < "$ctx/hits"
  mv -f "$WD_DIR/$id.hits.new" "$WD_DIR/$id.hits"
  spl_wd_episodes_end "$id" "$ctx/hits"
  for code in $WD_ORDER; do
    ev="$(awk -F'\t' -v c="$code" '$1 == c {print $2; exit}' "$ctx/confirmed" 2>/dev/null || true)"
    if awk -F'\t' -v c="$code" '$1 == c {f = 1} END {exit !f}' "$ctx/confirmed" 2>/dev/null; then
      main="$code"; mainev="$ev"; break
    fi
  done
  if [[ -n "$main" ]]; then
    spl_wd_verdict "$id" "HIT $main" "$now"
    act="$(spl_wd_act "$id" "$main" "$mainev" "$pane" "$now" "$ctx")"
    printf 'HIT %s %s%s' "$main" "$mainev" "${act:+ -> $act}"
  else
    spl_wd_verdict "$id" OK "$now"
    printf 'OK'
  fi
  ev="$(awk -F'\t' '$1 == "S8" {print $2; exit}' "$ctx/confirmed" 2>/dev/null || true)"
  if [[ -n "$ev" ]]; then
    act="$(spl_wd_act "$id" S8 "$ev" "$pane" "$now" "$ctx")"
    extra=" (S8 $ev${act:+ -> $act})"
  fi
  printf '%s%s\n' "$extra" "$pend"
  return 0
}

# <spool root>/dispatch/wd.<id>: "HIT <code> <epoch>" or "OK <epoch>", atomically.
spl_wd_verdict() {
  local f="$LEASE_DIR/wd.$1"
  printf '%s %s\n' "$2" "$3" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  return 0
}

# A code that no longer hits ends its episode: its once-flags and counters go.
spl_wd_episodes_end() {
  local id="$1" hits="$2" f code
  for f in "$WD_DIR/$id".ep.S*; do
    [[ -e "$f" ]] || continue
    code="${f#"$WD_DIR/$id".ep.}"; code="${code%%.*}"
    grep -qE "^HIT $code( |$)" "$hits" || rm -f "$f"
  done
  return 0
}

# ---- actions ------------------------------------------------------------------------

# Why the watchdog may not act on <id> now; nothing when it may (6.2, 6.3).
spl_wd_gate() {
  local id="$1" now="$2" ctx="$3" h c
  h="$(cat "$SPOOL_ROOT/$id/.human-hold" 2>/dev/null || true)"
  if [[ "$h" =~ ^[0-9]+$ ]] && (( h > now )); then echo "human hold for $(( (h - now + 59) / 60 )) min"; return 0; fi
  c="$(cat "$ctx/client_age" 2>/dev/null || true)"
  if [[ "$c" =~ ^[0-9]+$ ]] && (( c <= ${WD_HUMAN_IDLE:-120} )); then echo "a human client was active ${c}s ago"; return 0; fi
  h="$(cat "$WD_DIR/$id.heldout" 2>/dev/null || true)"
  if [[ -z "${WD_GATE_NO_HELDOUT:-}" && "$h" =~ ^[0-9]+$ ]] && (( now - h < 3600 )); then echo "held out after $WD_TAKEOVER_MAX takeovers in an hour"; return 0; fi
  if [[ -n "${WD_BOX_BUSY:-}" ]]; then echo "$WD_BOX_BUSY"; return 0; fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then echo "dry run"; return 0; fi
  return 0
}

# Act on one confirmed code; prints what was done (or would be).
spl_wd_act() {
  local id="$1" code="$2" ev="$3" pane="$4" now="$5" ctx="$6" age
  case "$code" in
    S1) age="${ev#age=}"; age="${age%% *}"
        # no progress signal at all (no heartbeat, no readable transcript):
        # "no progress" is unproven, so a ring, never a takeover
        if (( age >= 2 * WD_JOB_WAIT )) && [[ " $ev " != *" prog=unknown "* ]]; then spl_wd_once "$id" S1 takeover "$now" "$ctx" spl_wd_takeover "$id" S1 "$ev"
        else spl_wd_once "$id" S1 ring "$now" "$ctx" spl_wd_ring "$id"; fi ;;
    S2) if [[ "$ev" == kind=login* ]]; then
          spl_wd_once "$id" S2 dm "$now" "$ctx" spl_wd_send orchestrator blocker "$id" \
            "WATCHDOG (093 S2): $id cannot act, a login or access screen: ${ev#kind=login }. Harness $(spl_wd_harness "$id"), OS user $(spl_wd_user "$ctx"), box $ROTATE_BOX, pane ${pane:-none}. A restart does not fix a login: a human runs /login in that pane."
        else echo "not able until the reset; no restart"; fi ;;
    S3) spl_wd_once "$id" S3 takeover "$now" "$ctx" spl_wd_takeover "$id" S3 "$ev" ;;
    S4) spl_wd_s4 "$id" "$ev" "$pane" "$now" "$ctx" ;;
    S5) spl_wd_s5 "$id" "$ev" "$pane" "$now" "$ctx" ;;
    S6) if [[ "$ev" == poke=1* ]]; then spl_wd_once "$id" S6 repoke "$now" "$ctx" spl_wd_repoke "$id" "$pane"
        else echo "not poke-shaped: left alone"; fi ;;
    S7) if [[ "$ev" == modal=2* ]]; then spl_wd_s7_offer "$id" "$ev" "$pane" "$now" "$ctx" | paste -sd ';' -
        elif [[ "$ev" == modal=1* && ! -e "$WD_DIR/$id.ep.S7.esc" ]]; then spl_wd_once "$id" S7 esc "$now" "$ctx" spl_wd_key "$pane" Escape
        else spl_wd_once "$id" S7 note "$now" "$ctx" spl_wd_send peers note "$id" "WATCHDOG (093 S7): $id is blocked by a dialog (${ev#modal=? }) and is not able."; fi ;;
    S8) spl_wd_once "$id" S8 gap "$now" "$ctx" spl_wd_send peers note "$id" \
          "WATCHDOG (093 S8): GAP $id - its hook is silent ($ev). Progress is read from its transcript until spool-agent-hook.sh runs for it." ;;
  esac
  return 0
}

# spl_wd_once ID CODE TAG NOW CTX CMD...: run CMD once per episode of CODE,
# unless the gate says no ("would TAG (why)"). The flag
# <WD_DIR>/<id>.ep.<code>.<tag> holds the epoch it ran at.
spl_wd_once() {
  local id="$1" code="$2" tag="$3" now="$4" ctx="$5" f why
  shift 5
  f="$WD_DIR/$id.ep.$code.$tag"
  if [[ -e "$f" ]]; then echo "$tag done $(( now - $(cat "$f" 2>/dev/null || echo "$now") ))s ago"; return 0; fi
  why="$(spl_wd_gate "$id" "$now" "$ctx")"
  if [[ -n "$why" ]]; then echo "would $tag ($why)"; return 0; fi
  local out
  if out="$("$@")"; then echo "$now" > "$f"; echo "$tag"; else echo "$tag not done${out:+: $out}"; fi
  return 0
}

# S4: Escape once; still in the call 60 s later: takeover.
spl_wd_s4() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5" t
  t="$(cat "$WD_DIR/$id.ep.S4.esc" 2>/dev/null || true)"
  if [[ "$t" =~ ^[0-9]+$ ]] && (( now - t >= 60 )); then
    spl_wd_once "$id" S4 takeover "$now" "$ctx" spl_wd_takeover "$id" S4 "$ev"
  else
    spl_wd_once "$id" S4 esc "$now" "$ctx" spl_wd_key "$pane" Escape
  fi
}

# S5: the hook warned at WD_LOOP_N repeats; WD_LOOP_N more: Escape and a note
# to the peers; WD_LOOP_N more again: takeover. Repeats are counted per call
# (<WD_DIR>/<id>.ep.S5.n: "<count> <last call ts>").
spl_wd_s5() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5" f n last sig res cnt=0 lts="" new
  f="$WD_DIR/$id.ep.S5.n"
  n="$(grep -oE 'n=[0-9]+' <<<"$ev" | sed -n 1p)"; n="${n#n=}"
  last="$(grep -oE 'last=[^ ]+' <<<"$ev" | sed -n 1p)"; last="${last#last=}"
  sig="$(grep -oE 'sig=[^ ]+' <<<"$ev" | sed -n 1p)"; sig="${sig#sig=}"
  res="$(grep -oE 'res=[^ ]+' <<<"$ev" | sed -n 1p)"; res="${res#res=}"
  if [[ -f "$f" ]]; then read -r cnt lts < "$f" || true; fi
  if [[ -z "$lts" ]]; then cnt="${n:-0}"
  elif [[ "$last" != "$lts" ]]; then
    new="$(jq --arg s "$sig" --arg r "$res" --arg t "$lts" \
      '[(.calls // [])[] | select(.sig == $s and .res == $r and .ts > $t)] | length' "$ctx/heartbeat" 2>/dev/null || echo 1)"
    cnt=$(( cnt + ${new:-1} ))
  fi
  echo "$cnt $last" > "$f"
  if (( cnt >= 3 * WD_LOOP_N )); then
    spl_wd_once "$id" S5 takeover "$now" "$ctx" spl_wd_takeover "$id" S5 "$ev"
  elif (( cnt >= 2 * WD_LOOP_N )); then
    spl_wd_once "$id" S5 esc "$now" "$ctx" spl_wd_s5_esc "$id" "$pane" "$cnt"
  else
    echo "the hook warned ($cnt repeats)"
  fi
}

spl_wd_s5_esc() {
  spl_wd_key "$2" Escape &&
    spl_wd_send peers note "$1" "WATCHDOG (093 S5): $1 repeated the same call with the same result $3 times; Escape was sent once."
}

# S7 modal=2, "Make auto mode your default permission mode?". The owner allows
# bypassPermissions only (t1 4a1966d8): "The watchdog should change all of the
# settings to this most permissive mode, kill that non-starting orchestrator,
# and start a new one with the most permissive mode and dangerous skip
# permissions on." So: (1) the agent user's settings.json gets bypass back,
# (2) a takeover (spawn-claude.sh: --dangerously-skip-permissions), and only
# when the takeover is refused, or the dialog outlives it by WD_S7_FALLBACK s
# (300), (3) the answer "No, keep bypass permissions".
spl_wd_s7_offer() {
  local id="$1" ev="$2" pane="$3" now="$4" ctx="$5" f out t
  spl_wd_once "$id" S7 settings "$now" "$ctx" spl_wd_s7_settings "$(spl_wd_user "$ctx")" "$now"
  f="$WD_DIR/$id.ep.S7.takeover"
  if [[ ! -e "$f" ]]; then
    out="$(spl_wd_once "$id" S7 takeover "$now" "$ctx" spl_wd_takeover "$id" S7 "$ev")"
    echo "$out"
    [[ "$out" == takeover || "$out" == would* ]] && return 0
  else
    t="$(cat "$f" 2>/dev/null || echo "$now")"
    if (( now - t < ${WD_S7_FALLBACK:-300} )); then echo "takeover started $(( now - t ))s ago"; return 0; fi
  fi
  # held out bars takeovers, not the answer that keeps bypass
  WD_GATE_NO_HELDOUT=1 spl_wd_once "$id" S7 no "$now" "$ctx" spl_wd_s7_no "$id" "$pane"
}

# permissions.defaultMode = bypassPermissions and skipDangerousModePermission-
# Prompt = true in <user>'s ~/.claude/settings.json (other keys kept), written
# as that user, the old file kept as settings.json.bak-wd-<epoch>.
# WD_SETTINGS_HOME replaces the home (tests: no sudo).
spl_wd_s7_settings() {
  local user="$1" now="$2" home f
  local -a as=()
  [[ "$user" == unknown || -z "$user" ]] && user="${SPOOL_AGENT_USER:-$(id -un)}"
  home="${WD_SETTINGS_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
  [[ -n "$home" && -d "$home" ]] || { echo "no home for $user"; return 1; }
  f="$home/.claude/settings.json"
  if jq -e '.permissions.defaultMode == "bypassPermissions" and .skipDangerousModePermissionPrompt == true' "$f" >/dev/null 2>&1; then return 0; fi
  [[ -z "${WD_SETTINGS_HOME:-}" && "$user" != "$(id -un)" ]] && as=(sudo -n -u "$user")
  # shellcheck disable=SC2016 # expanded by the inner bash
  "${as[@]}" bash -c 'f="$1"; mkdir -p "${f%/*}" || exit 1
    if [ -f "$f" ]; then cp -p "$f" "$f.bak-wd-$2" || exit 1; fi
    { if [ -s "$f" ]; then cat "$f"; else echo "{}"; fi; } |
      jq ".permissions.defaultMode = \"bypassPermissions\" | .skipDangerousModePermissionPrompt = true" > "$f.tmp.$$" &&
      mv -f "$f.tmp.$$" "$f"' _ "$f" "$now" || { echo "settings not written: $f"; return 1; }
  spl_wd_log "S7 SETTINGS $user $f: defaultMode=bypassPermissions skipDangerousModePermissionPrompt=true"
  return 0
}

# The fallback: "No, keep bypass permissions". Never Escape, never Yes: Down
# while s7.sh reads the cursor on Yes, then Enter only once it reads the
# cursor on No, from a fresh capture each time.
spl_wd_s7_no() {
  local id="$1" pane="$2" cur _
  for _ in 1 2 3; do
    cur="$(spl_wd_s7_cursor "$id" "$pane")"
    case "$cur" in
      no) spl_wd_key "$pane" Enter; return ;;
      yes) spl_wd_key "$pane" Down || return 1; sleep "${WD_KEY_WAIT:-0.5}" ;;
      *) echo "cursor ${cur:-gone}, no key"; return 1 ;;
    esac
  done
  echo "cursor never reached No"
  return 1
}

# yes|no|? from s7.sh on a fresh capture of <pane>; nothing when it is gone.
spl_wd_s7_cursor() {
  local d out
  d="$(mktemp -d)"
  spl_wd_tmux capture-pane -p -t "$2" > "$d/pane" 2>/dev/null || true
  out="$(WD_CTX="$d" timeout -k 1 "$WD_SCRIPT_TIMEOUT" bash "$WD_SITUATIONS/s7.sh" "$1" act "$2" 2>/dev/null 7>&- || true)"
  rm -rf "$d"
  [[ "$out" =~ ^HIT\ S7\ modal=2\ cursor=([a-z?]+) ]] && echo "${BASH_REMATCH[1]}"
  return 0
}

# ---- the outside world (seams: ROTATE_TMUX, WD_SEND, WD_TAKEOVER_CMD) ---------------

spl_wd_key() {
  [[ -n "$1" ]] || return 1
  spl_wd_tmux send-keys -t "$1" "$2" >/dev/null 2>&1
}

spl_wd_ring() {
  bash "$WD_SEND" --poke-only --from "$WD_FROM" --to "$1" >/dev/null 2>&1 8>&- 7>&-
  return 0
}

# S6: empty the whole box (C-c: every row, spl_rotate_type's rule), then ring.
spl_wd_repoke() { spl_wd_key "$2" C-c && spl_wd_ring "$1"; }

# spl_wd_send TO KIND ID BODY: a spool message on task wd-<id>. spool-send.sh
# 1-9 = delivered (only the poke did not ring); 10+ or 2 = not delivered.
spl_wd_send() {
  local rc=0
  bash "$WD_SEND" --from "$WD_FROM" --to "$1" --kind "$2" --task "wd-$3" --body "$4" >/dev/null 2>&1 8>&- 7>&- || rc=$?
  (( rc < 10 && rc != 2 ))
}

spl_wd_harness() { awk -F'\t' -v i="$1" '$1 == i {k = $2} END {print (k == "" ? "unknown" : k)}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || echo unknown; }
spl_wd_user() { local u; u="$(cat "$1/user" 2>/dev/null || true)"; echo "${u:-unknown}"; }

# A takeover (6.3): at most WD_TAKEOVER_MAX per id per rolling hour; the next
# one is not done: the id is held out for an hour and the orchestrator gets
# ONE blocker naming the verdicts. The takeover itself is do_spl_wd_takeover
# (spec 8, T005), started detached; WD_TAKEOVER_CMD replaces it.
spl_wd_takeover() {
  local id="$1" code="$2" ev="$3" f now n
  f="$WD_DIR/$id.takeovers"; now="$(spl_lease_now)"
  touch "$f"
  awk -v n="$now" '$1 + 3600 > n' "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  n="$(grep -c . "$f" || true)"
  if (( n >= WD_TAKEOVER_MAX )); then
    echo "$now" > "$WD_DIR/$id.heldout"
    spl_wd_log "HELDOUT $id after $n takeovers in an hour: $code $ev"
    spl_wd_send orchestrator blocker "$id" "WATCHDOG (093 6.3): $id was taken over $n times in the last hour and hit $code again ($ev); it is held out of the watchdog for an hour. Recent verdicts: $(grep " $id HIT " "$WD_LOG" 2>/dev/null | tail -n 2 | cut -c1-200 | tr '\n' ';')" || true
    echo "held out: $n takeovers in the last hour"
    return 1
  fi
  if [[ -z "${WD_TAKEOVER_CMD:-}" ]] && ! declare -F do_spl_wd_takeover >/dev/null; then
    if [[ ! -e "$WD_DIR/$id.ep.$code.want" ]]; then
      echo "$now" > "$WD_DIR/$id.ep.$code.want"
      spl_wd_log "WANT-TAKEOVER $id $code $ev (do_spl_wd_takeover is not on this tree yet)"
    fi
    echo "do_spl_wd_takeover is not on this tree yet"
    return 1
  fi
  echo "$now" >> "$f"
  spl_wd_log "TAKEOVER $id $code $ev"
  # shellcheck disable=SC2086 # a command line, split on purpose
  ( ID="$id" REASON="$code" WD_EVIDENCE="$ev" setsid ${WD_TAKEOVER_CMD:-$ROTATE_RUN -a do_spl_wd_takeover} \
      >> "$WD_DIR/takeover.$id.out" 2>&1 < /dev/null 7>&- 8>&- 9>&- & )
  return 0
}
