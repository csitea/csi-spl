#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Stop THIS tree's running pre-push gate (do_check_pre_push) by its
# @description pid, never by a pattern. The gate writes its pid, process group
# @description and start time to a pidfile keyed by the checkout it gates (one
# @description per tree, so two lanes on one box never stop each other); this
# @description action sends TERM to exactly that pid and every process below it,
# @description then KILL to whatever is still alive after the grace period.
# @description Why not `pkill -f do_check_pre_push`: on 2026-10-06 that pattern
# @description matched every agent's argv (the action name is in each seed
# @description prompt) and killed 15 claude sessions in 0.7 s.
# @description A stale pidfile (the pid is gone, or the pid was re-used: the
# @description start time differs) is removed and nothing is signalled.
# @param PRE_PUSH_TREE (optional) - checkout root of the run to stop, default $APP_PATH
# @param PRE_PUSH_PIDFILE (optional) - pidfile, default ~/.cache/csi-spl/pre-push.<tree-hash>.pid
# @param PRE_PUSH_STOP_GRACE (optional) - seconds between TERM and KILL, default 5
# @example ./run -a do_stop_pre_push
# @example PRE_PUSH_TREE=/opt/csi/csi-spl-wt/<ID> ./run -a do_stop_pre_push
#------------------------------------------------------------------------------

declare -F _pp_pidfile >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/check-pre-push.func.sh"

# The pid and every descendant of it, the root first.
_pp_proc_tree() {  # <pid>
  ps -e -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      q[0] = root; n = 1
      for (i = 0; i < n; i++) {
        print q[i]
        m = split(kids[q[i]], c, " ")
        for (j = 1; j <= m; j++) q[n++] = c[j]
      }
    }'
}

do_stop_pre_push() {
  local tree="${PRE_PUSH_TREE:-$APP_PATH}"
  local pf="${PRE_PUSH_PIDFILE:-$(_pp_pidfile "$tree")}"
  local grace="${PRE_PUSH_STOP_GRACE:-5}" pid pgid start ptree now p i
  if [[ ! -s "$pf" ]]; then
    do_log "INFO stop-pre-push: no pre-push run recorded for $tree ($pf) -- nothing to stop"
    return 0
  fi
  read -r pid pgid start ptree <"$pf"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    do_log "WARN stop-pre-push: $pf is not a pidfile (first field '$pid') -- removed, nothing signalled"
    rm -f "$pf"; return 0
  fi
  now="$(_pp_starttime "$pid")" || now=""
  if [[ -z "$now" || "$now" != "$start" ]]; then
    do_log "INFO stop-pre-push: pid $pid from $pf is ${now:+re-used (start time $now, recorded $start)}${now:-gone} -- stale pidfile removed, nothing signalled"
    rm -f "$pf"; return 0
  fi
  do_log "INFO stop-pre-push: stopping the pre-push run on ${ptree:-$tree}: pid $pid (pgid $pgid) and its descendants"
  # Two passes: a part may fork between the scan and the signal.
  for i in 1 2; do
    for p in $(_pp_proc_tree "$pid"); do kill -TERM "$p" 2>/dev/null || true; done
  done
  for ((i = 0; i < grace * 10; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null && [[ "$(_pp_starttime "$pid")" == "$start" ]]; then
    do_log "WARN stop-pre-push: pid $pid still alive after ${grace}s -- KILL"
    for p in $(_pp_proc_tree "$pid"); do kill -KILL "$p" 2>/dev/null || true; done
  fi
  rm -f "$pf"
  do_log "INFO stop-pre-push: stopped pid $pid"
  return 0
}
