#!/usr/bin/env bash
# cron-heartbeat-snitch.func.sh — dead-man's snitch for the box's tagged cron
# jobs. Strictly report and alert only: it never edits a crontab and never
# starts, kills or restarts anything.
#
# Part of Reliability Round Row 11 (feat(rel-11-cron-heartbeat-snitch)).
# Tracked by SPL-2665 (Refs: SPL-2364).
#
# Two parts in this one file:
# - The beat (the shared wrapper a cron line calls): run directly, not
#   sourced, it writes `<heartbeat dir>/<tag>` when the job ends:
#     bash cron-heartbeat-snitch.func.sh --wrap <tag> -- <command> [args...]
#       runs the command, writes the beat with its exit code, exits with it.
#     bash cron-heartbeat-snitch.func.sh --beat <tag> [rc]
#       writes the beat only, for a line that ends in `; ...--beat <tag> $?`.
#   A beat is written on success and on failure: it proves the job ran.
# - The check, `do_cron_heartbeat_snitch`: reads the crontab (`crontab -l`),
#   takes every active line tagged `# csi-spl:<tag>`, derives the longest gap
#   between two runs from its schedule, and compares the age of its beat with
#   that gap + grace. Per line:
#     OK         beat age <= period + grace
#     SILENT     beat age >  period + grace (alerted)
#     LOG-OK     no beat yet; the line's `>> <log>` is fresh (weak evidence)
#     LOG-STALE  no beat yet; the log is old. Not alerted: a job that logs only
#                on output (gc) has an old log while it runs fine.
#     NO-DATA    no beat and no readable log
#     BOOT       @reboot, not periodic, not checked
#     UNSCHED    a schedule this check cannot read (names, L, W, #)
#   It also checks the cron daemon is alive: the pid in /run/crond.pid names
#   a live cron process (pgrep -x cron|crond when there is no pidfile).
#
# Alert: with DRY_RUN=0, one spool note to the orchestrator per NEW silent
# set (daemon down or SILENT tags); the same set is not sent again until it
# changes or clears.
#
# Exit: 0 nothing silent, 1 a SILENT line or no cron daemon, 2 no crontab.
#
# Environment variables:
#   DRY_RUN: 1 (default) logs the plan only; 0 sends the note and keeps the stamp.
#   CRON_HB_CRONTAB_FILE: read this file instead of `crontab -l`.
#   CRON_HB_STATE_DIR: state dir (default $SPL_STATE_DIR or ~/.local/state/csi-spl).
#   CRON_HB_DIR: beat dir (default $CRON_HB_STATE_DIR/heartbeat).
#   CRON_HB_GRACE_MIN_S: smallest grace in seconds (default 300, so a 1 min job
#     is SILENT after 6 min).
#   CRON_HB_GRACE_PCT: grace as a percentage of the period, when larger
#     (default 25: hourly 15 min, daily 6 h).
#   CRON_HB_PERIOD_OVERRIDES: "tag=seconds ..." for a line whose command gates
#     itself (an hourly line that acts weekly).
#   CRON_HB_DAEMON_CHECK: 1 (default) checks the cron daemon; 0 skips it.
#   CRON_HB_PIDFILE: cron's pidfile (default /run/crond.pid).
#   CRON_HB_PROC_DIR: proc root (default /proc).
#   CRON_HB_PGREP_BIN: pgrep binary, used only without a pidfile (default pgrep).
#   CRON_HB_NOW: current epoch override (tests).
#   CRON_HB_STAMP_FILE: last alerted set (default $state_dir/cron-heartbeat-snitch.stamp).
#   CRON_HB_ALERT_TO: spool recipient (default "orchestrator").
#   CRON_HB_ALERT_FROM: spool sender (default $SPOOL_AGENT_ID or cron-heartbeat-snitch@<box>).
#   CRON_HB_ALERT_TASK: spool task id (default "cron-heartbeat-snitch").
#   CRON_HB_ALERT_SEND_BIN: spool-send.sh or a compatible tool.
#
# @example ./run -a do_cron_heartbeat_snitch
# @example DRY_RUN=0 ./run -a do_cron_heartbeat_snitch
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# _chs_hb_dir: the beat dir, the same for the wrapper and the check.
_chs_hb_dir() {
  local state_dir="${CRON_HB_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}}"
  printf '%s' "${CRON_HB_DIR:-$state_dir/heartbeat}"
}

# _chs_beat <tag> [rc]: write the beat file for a tag ('/' becomes '_').
_chs_beat() {
  local tag="$1" rc="${2:-0}" dir
  [[ -n "$tag" ]] || return 2
  dir="$(_chs_hb_dir)"
  mkdir -p "$dir" || return 2
  printf 'ts=%s rc=%s\n' "${EPOCHSECONDS:-$(date +%s)}" "$rc" > "$dir/${tag//\//_}"
}

# _chs_expand <field> <min> <max>: set _CHS_SET to the sorted values of one
# cron field (*, a, a-b, */n, a-b/n, lists). Returns 1 when it cannot read it.
_chs_expand() {
  local field="$1" min="$2" max="$3" part range step lo hi v rest
  local -a seen=()
  if [[ "$field" == "*" ]]; then
    case "$min-$max" in
      0-59) _CHS_SET=({0..59}) ;;
      0-23) _CHS_SET=({0..23}) ;;
      *) _CHS_SET=({0..7}) ;;
    esac
    return 0
  fi
  _CHS_SET=()
  # split on commas by hand: word splitting would glob a `*`
  rest="$field,"
  while [[ -n "$rest" ]]; do
    part="${rest%%,*}" rest="${rest#*,}"
    range="${part%%/*}" step=1
    [[ "$part" == */* ]] && step="${part#*/}"
    [[ "$step" =~ ^[0-9]+$ && "$step" -gt 0 ]] || return 1
    if [[ "$range" == "*" ]]; then
      lo=$min hi=$max
    elif [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      lo=$((10#${BASH_REMATCH[1]})) hi=$((10#${BASH_REMATCH[2]}))
    elif [[ "$range" =~ ^[0-9]+$ ]]; then
      lo=$((10#$range)) hi=$lo
      [[ "$part" == */* ]] && hi=$max
    else
      return 1
    fi
    (( lo >= min && hi <= max && lo <= hi )) || return 1
    for ((v = lo; v <= hi; v += step)); do seen[v]=1; done
  done
  # an indexed array lists its indices in ascending order
  _CHS_SET=("${!seen[@]}")
  (( ${#_CHS_SET[@]} ))
}

# _chs_maxgap <cycle> <sorted values...>: the longest cyclic gap between two
# consecutive values; one value gives the whole cycle.
_chs_maxgap() {
  local cycle="$1" first prev v gap max=0
  shift
  first="$1" prev="$1"
  shift
  for v in "$@"; do
    gap=$((v - prev)); (( gap > max )) && max=$gap
    prev=$v
  done
  gap=$((cycle - prev + first)); (( gap > max )) && max=$gap
  _CHS_GAP=$max
}

# _chs_period <m> <h> <dom> <mon> <dow>: set _CHS_PERIOD to the longest gap
# in seconds between two runs of a five-field schedule, or empty when it
# cannot be read. A day-of-month or month restriction is rounded up to 31 or
# 366 days: an upper bound only slows detection, it never raises a false
# SILENT.
_chs_period() {
  local m="$1" h="$2" dom="$3" mon="$4" dow="$5" mins hours x y key="$*"
  # a crontab repeats a few schedules many times: work each out once
  if [[ -n "${_CHS_PCACHE[$key]+x}" ]]; then
    _CHS_PERIOD="${_CHS_PCACHE[$key]}"
    return 0
  fi
  _chs_period_calc "$@"
  _CHS_PCACHE[$key]="$_CHS_PERIOD"
}

_chs_period_calc() {
  local m="$1" h="$2" dom="$3" mon="$4" dow="$5" mins hours x y
  _CHS_PERIOD=""
  _chs_expand "$m" 0 59 || return 0
  mins=("${_CHS_SET[@]}")
  _chs_expand "$h" 0 23 || return 0
  hours=("${_CHS_SET[@]}")
  if [[ "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
    if [[ "$m" == "*" && "$h" == "*" ]]; then
      _CHS_GAP=1
    elif (( ${#hours[@]} == 24 )); then
      _chs_maxgap 60 "${mins[@]}"
    else
      local day=()
      for x in "${hours[@]}"; do for y in "${mins[@]}"; do day+=($((x * 60 + y))); done; done
      _chs_maxgap 1440 "${day[@]}"
    fi
    _CHS_PERIOD=$((_CHS_GAP * 60))
  elif [[ "$dom" == "*" && "$mon" == "*" ]]; then
    _chs_expand "$dow" 0 7 || return 0
    local -a dset=()
    local d
    for d in "${_CHS_SET[@]}"; do dset[d % 7]=1; done
    _chs_maxgap 7 "${!dset[@]}"
    _CHS_PERIOD=$((_CHS_GAP * 86400))
  elif [[ "$mon" == "*" ]]; then
    _CHS_PERIOD=$((31 * 86400))
  else
    _CHS_PERIOD=$((366 * 86400))
  fi
}

# _chs_log_path <command>: set _CHS_LOG to the last absolute `>> path` /
# `> path` target without a variable in it, or empty.
_chs_log_path() {
  local rest="$1"
  local re=">>?[[:space:]]*'?(/[^'[:space:];&|]+)"
  _CHS_LOG=""
  while [[ "$rest" =~ $re ]]; do
    _CHS_LOG="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  [[ "$_CHS_LOG" == *'$'* ]] && _CHS_LOG=""
  return 0
}

# _chs_send <from> <to> <task> <body>: one spool note; 0 when delivered.
_chs_send() {
  local from="$1" to="$2" task="$3" body="$4"
  local send_bin="${CRON_HB_ALERT_SEND_BIN:-}"
  local orc_send="${PROJ_PATH:-}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
  if [[ -z "$send_bin" ]]; then
    if [[ -n "${PROJ_PATH:-}" && -f "$orc_send" ]]; then
      send_bin="$orc_send"
    elif command -v spool-send.sh >/dev/null 2>&1; then
      send_bin="$(command -v spool-send.sh)"
    fi
  fi
  if [[ -z "$send_bin" || ! -f "$send_bin" ]]; then
    do_log "WARN no spool-send.sh found to send the cron alert"
    return 1
  fi
  if ! SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send_bin" \
    --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
    do_log "WARN failed to send spool note via $send_bin"
    return 1
  fi
}

# _chs_fmt_age <seconds>: set _CHS_AGE to 42s, 7m, 3h or 2d.
_chs_fmt_age() {
  local s="$1"
  if (( s < 120 )); then _CHS_AGE="${s}s"
  elif (( s < 7200 )); then _CHS_AGE="$((s / 60))m"
  elif (( s < 172800 )); then _CHS_AGE="$((s / 3600))h"
  else _CHS_AGE="$((s / 86400))d"; fi
}

# _chs_read_lines <crontab text>: fill _CHS_TAGS, _CHS_SCHEDS, _CHS_PERIODS
# and _CHS_LOGS from the active lines tagged `# csi-spl:<tag>`.
_chs_read_lines() {
  local tab="$1" line tag sched cmd f1 f2 f3 f4 f5 period ov
  local tag_re='#[[:space:]]*csi-spl:([^[:space:]]+)[[:space:]]*$'
  local f='([^[:space:]]+)[[:space:]]+'
  local five_re="^[[:space:]]*$f$f$f$f$f(.*)$" at_re="^[[:space:]]*(@[^[:space:]]+)[[:space:]]+(.*)$"
  local -A overrides=()
  for ov in ${CRON_HB_PERIOD_OVERRIDES:-}; do overrides[${ov%%=*}]="${ov#*=}"; done
  _CHS_TAGS=() _CHS_SCHEDS=() _CHS_PERIODS=() _CHS_LOGS=()
  declare -gA _CHS_PCACHE=()
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ $tag_re ]] || continue
    tag="${BASH_REMATCH[1]}"
    period="" cmd=""
    if [[ "$line" =~ $at_re ]]; then
      f1="${BASH_REMATCH[1]}" cmd="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ $five_re ]]; then
      f1="${BASH_REMATCH[1]}" f2="${BASH_REMATCH[2]}" f3="${BASH_REMATCH[3]}"
      f4="${BASH_REMATCH[4]}" f5="${BASH_REMATCH[5]}" cmd="${BASH_REMATCH[6]}"
    else
      continue
    fi
    case "$f1" in
      @reboot) period=boot ;;
      @hourly) period=3600 ;;
      @daily|@midnight) period=86400 ;;
      @weekly) period=604800 ;;
      @monthly) period=$((31 * 86400)) ;;
      @yearly|@annually) period=$((366 * 86400)) ;;
    esac
    if [[ "$f1" == @* ]]; then
      sched="$f1"
    else
      sched="$f1 $f2 $f3 $f4 $f5"
      _chs_period "$f1" "$f2" "$f3" "$f4" "$f5"
      period="$_CHS_PERIOD"
    fi
    [[ -n "${overrides[$tag]:-}" ]] && period="${overrides[$tag]}"
    _chs_log_path "$cmd"
    _CHS_TAGS+=("$tag") _CHS_SCHEDS+=("$sched") _CHS_PERIODS+=("$period") _CHS_LOGS+=("$_CHS_LOG")
  done <<< "$tab"
}

# The four steps of do_cron_heartbeat_snitch below share its state by bash's
# dynamic scope: the action declares the `local`s (hb_dir, now, mtime,
# daemon, count, silent, ...) and calls each helper plainly, never inside
# $(...), so the helper reads and fills the caller's variables.

# _chs_mtimes: fill the caller's `mtime` map with every beat and log mtime
# of the _CHS_* lines, in one stat call.
_chs_mtimes() {
  local paths=() i p mt
  for i in "${!_CHS_TAGS[@]}"; do
    p="$hb_dir/${_CHS_TAGS[$i]//\//_}"
    [[ -f "$p" ]] && paths+=("$p")
    [[ -n "${_CHS_LOGS[$i]}" && -f "${_CHS_LOGS[$i]}" ]] && paths+=("${_CHS_LOGS[$i]}")
  done
  if (( ${#paths[@]} )); then
    while read -r mt p; do mtime[$p]=$mt; done < <(stat -c '%Y %n' -- "${paths[@]}" 2>/dev/null)
  fi
  return 0
}

# _chs_daemon: set the caller's `daemon` to up, down or unchecked. The
# pidfile and /proc, no process scan (pgrep reads every /proc entry, ~80 ms
# on a busy box); pgrep only without a pidfile.
_chs_daemon() {
  daemon=unchecked
  [[ "${CRON_HB_DAEMON_CHECK:-1}" == "1" ]] || return 0
  local pidfile="${CRON_HB_PIDFILE:-/run/crond.pid}" proc="${CRON_HB_PROC_DIR:-/proc}" pid="" comm=""
  daemon=down
  if [[ -r "$pidfile" ]]; then
    read -r pid < "$pidfile"
    [[ "$pid" =~ ^[0-9]+$ && -r "$proc/$pid/comm" ]] && read -r comm < "$proc/$pid/comm"
    [[ "$comm" == cron || "$comm" == crond ]] && daemon=up
  else
    local pg="${CRON_HB_PGREP_BIN:-pgrep}"
    { "$pg" -x cron || "$pg" -x crond; } >/dev/null 2>&1 && daemon=up
  fi
  return 0
}

# _chs_verdicts: print one verdict line per tagged line and fill the
# caller's `count` map and its `silent` / `silent_lines` arrays.
_chs_verdicts() {
  local i st tag period age grace src last rc hbf hbline limit log
  for i in "${!_CHS_TAGS[@]}"; do
    tag="${_CHS_TAGS[$i]}" period="${_CHS_PERIODS[$i]}" log="${_CHS_LOGS[$i]}"
    hbf="$hb_dir/${tag//\//_}"
    src="-" age="-" grace="-" rc="-" last="never"
    if [[ "$period" == "boot" ]]; then
      st=BOOT
    elif [[ -z "$period" ]]; then
      st=UNSCHED
    else
      grace=$((period * grace_pct / 100)); (( grace < grace_min )) && grace=$grace_min
      limit=$((period + grace))
      if [[ -n "${mtime[$hbf]:-}" ]]; then
        src=hb age=$((now - mtime[$hbf]))
        hbline=""
        read -r hbline < "$hbf" 2>/dev/null
        [[ "$hbline" =~ rc=([0-9]+) ]] && rc="${BASH_REMATCH[1]}"
        if (( age > limit )); then st=SILENT; else st=OK; fi
      elif [[ -n "$log" && -n "${mtime[$log]:-}" ]]; then
        src=log age=$((now - mtime[$log]))
        if (( age > limit )); then st=LOG-STALE; else st=LOG-OK; fi
      else
        st=NO-DATA
      fi
      if [[ "$age" != "-" ]]; then
        (( age < 0 )) && age=0
        _chs_fmt_age "$age"
        last="$_CHS_AGE ago" age="${age}s"
      fi
      period="${period}s" grace="${grace}s"
    fi
    count[$st]=$(( ${count[$st]:-0} + 1 ))
    printf '%-9s %-40s sched="%s" period=%s grace=%s source=%s age=%s rc=%s\n' \
      "$st" "$tag" "${_CHS_SCHEDS[$i]}" "$period" "$grace" "$src" "$age" "$rc"
    if [[ "$st" == "SILENT" ]]; then
      silent+=("$tag")
      silent_lines+=("  - $tag: schedule \"${_CHS_SCHEDS[$i]}\", last beat $last, limit $period + $grace")
    fi
  done
  return 0
}

# _chs_alert: clear the stamp on a clean run (return 0), else print the CRON
# SILENT body and send it once per new set (DRY_RUN=0); return 1.
_chs_alert() {
  if [[ "$daemon" != "down" && ${#silent[@]} -eq 0 ]]; then
    [[ "$dry" == "0" && -f "$stamp_file" ]] && rm -f "$stamp_file"
    return 0
  fi

  local state="daemon=$daemon silent=${silent[*]}"
  local body sl=""
  (( ${#silent_lines[@]} )) && sl="$(printf '%s\n' "${silent_lines[@]}")"$'\n'
  body=$(printf 'CRON SILENT (no action taken)\nBox: %s\nCron daemon: %s\nSilent jobs: %d\n%sAdvice: read the job log and the crontab on the box; this check restarts nothing.\n' \
    "$box_name" "$daemon" "${#silent[@]}" "$sl")
  do_log "WARN cron silent: daemon=$daemon silent=${#silent[@]}"
  printf '%s\n' "$body"

  local prev=""
  [[ -f "$stamp_file" ]] && prev="$(sed -n 's/^STATE=//p' "$stamp_file")"
  if [[ "$prev" == "$state" ]]; then
    do_log "INFO alert already sent for this set ($stamp_file)"
    return 1
  fi
  if [[ "$dry" == "1" ]]; then
    do_log "INFO PLAN note to $to (DRY_RUN=1, not sent)"
    return 1
  fi
  if _chs_send "$from" "$to" "$task" "$body"; then
    mkdir -p "$(dirname "$stamp_file")"
    printf 'TIMESTAMP=%s\nSTATE=%s\n' "$now" "$state" > "$stamp_file"
    do_log "INFO alert sent to $to"
  fi
  return 1
}

do_cron_heartbeat_snitch() {
  local t0="${EPOCHREALTIME/[.,]/}"
  local dry="${DRY_RUN:-1}"
  local state_dir="${CRON_HB_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}}"
  local hb_dir
  hb_dir="$(_chs_hb_dir)"
  local stamp_file="${CRON_HB_STAMP_FILE:-$state_dir/cron-heartbeat-snitch.stamp}"
  local grace_min="${CRON_HB_GRACE_MIN_S:-300}" grace_pct="${CRON_HB_GRACE_PCT:-25}"
  local now="${CRON_HB_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  local box_name="${DEV_BOX:-$(hostname -s 2>/dev/null || echo "PC")}"
  local to="${CRON_HB_ALERT_TO:-orchestrator}"
  local from="${CRON_HB_ALERT_FROM:-${SPOOL_AGENT_ID:-cron-heartbeat-snitch@$box_name}}"
  local task="${CRON_HB_ALERT_TASK:-cron-heartbeat-snitch}"

  # 1. The crontab, read once, and its tagged active lines.
  local tab
  if [[ -n "${CRON_HB_CRONTAB_FILE:-}" ]]; then
    tab="$(< "$CRON_HB_CRONTAB_FILE")" || { do_log "WARN cannot read $CRON_HB_CRONTAB_FILE"; return 2; }
  else
    tab="$(crontab -l 2>/dev/null)" || { do_log "WARN no crontab for ${USER:-this user}"; return 2; }
  fi
  _chs_read_lines "$tab"

  # 2. Every beat and log mtime in one stat call. 3. The cron daemon.
  local -A mtime=() count=()
  local daemon silent=() silent_lines=()
  _chs_mtimes
  _chs_daemon

  # 4. One verdict per line, the summary, then the alert and its stamp.
  _chs_verdicts
  local ms=$(( (${EPOCHREALTIME/[.,]/} - t0) / 1000 ))
  do_log "INFO cron-heartbeat-snitch: lines=${#_CHS_TAGS[@]} ok=${count[OK]:-0} silent=${count[SILENT]:-0} log_ok=${count[LOG-OK]:-0} log_stale=${count[LOG-STALE]:-0} no_data=${count[NO-DATA]:-0} boot=${count[BOOT]:-0} unsched=${count[UNSCHED]:-0} daemon=$daemon hb_dir=$hb_dir elapsed_ms=$ms"
  _chs_alert
}

# Run directly: the beat wrapper.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --wrap)
      tag="${2:-}"
      [[ -n "$tag" && "${3:-}" == "--" && $# -ge 4 ]] || { echo "usage: $0 --wrap <tag> -- <command> [args...]" >&2; exit 2; }
      shift 3
      "$@"
      rc=$?
      _chs_beat "$tag" "$rc" || echo "WARN cron-heartbeat-snitch: cannot write the beat for $tag" >&2
      exit "$rc"
      ;;
    --beat)
      [[ -n "${2:-}" ]] || { echo "usage: $0 --beat <tag> [rc]" >&2; exit 2; }
      _chs_beat "$2" "${3:-0}"
      exit $?
      ;;
    *)
      echo "usage: $0 --wrap <tag> -- <command> [args...] | --beat <tag> [rc]" >&2
      exit 2
      ;;
  esac
fi

# Auto-register with run.sh's function map when sourced
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_cron_heartbeat_snitch"]="${BASH_SOURCE[0]}"
fi
