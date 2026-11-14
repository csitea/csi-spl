#!/bin/bash
#------------------------------------------------------------------------------
# @description The 7-min box link watcher (SPL-4816; owner HUM-10, topic
# @description 0956269e msg 7e8d02b4: a problem in the relay or the connection
# @description for more than 7 minutes must reach the owner in the topic). A
# @description non-intelligence check, run every minute from cron (box-crons
# @description manifest row box-link-watch). READ-ONLY on the relay: it reads
# @description the hub's logs, the received box logs, the results dir and the
# @description process list, and never touches the relay or the box.
# @description For each box the hub serves it raises ONE incident when, for
# @description more than BOX_LINK_WATCH_LIMIT_MIN: (a) a sent bundle/command
# @description has no receipt (a command: no receipt, START or result); (b) a
# @description box apply or command was refused or timed out, with no later
# @description success; (c) the box log does not advance; (d) the link or
# @description session is down. One spool message (kind blocker) per incident
# @description to the live seat of the topic that owns the box (the lane map;
# @description else the dispatch lease holder), naming what, since when and
# @description the evidence lines; one note when it clears ("cleared after N
# @description min"). It never posts to the hub: the seat tells the owner.
# @description A seat or fallback on another machine is reached through the
# @description desk of the topic's own workspace (topics.tsv column 3, via
# @description box-link-watch-relay.sh), never lease.conf's LEASE_TENANT; no
# @description workspace -> nothing leaves this machine, a WARN (SPL-4880).
# @description The relay's paths are box-local, never in this tree: env, or
# @description the KEY=VALUE file BOX_LINK_WATCH_ENV. No relay configured ->
# @description nothing to watch, exit 0. A lock keeps two runs apart. Dry run
# @description unless DRY_RUN=0. Core: src/bash/scripts/box-link-watch.py.
# @description SPL-5522: a box stuck for more than BOX_LINK_WATCH_RESTART_AFTER_S
# @description has the link's own restart action run (`<HOME>/run -a
# @description <BOX_LINK_WATCH_RESTART_ACTION>`, box-local; unset = no restart),
# @description at most once per BOX_LINK_WATCH_RESTART_EVERY_S per box, and one
# @description LINK RESTARTED note with the state before and after it.
# @param BOX_LINK_WATCH_ENV (optional) - the box-local file, default $XDG_CONFIG_HOME/csi-spl/box-link-watch.env
# @param BOX_LINK_WATCH_ROOT (env or file) - the hub's box dirs (<root>/<box>/{inbound,outbound}); unset = nothing to watch
# @param BOX_LINK_WATCH_LOG_DIR (env or file, required with ROOT) - the hub's own logs
# @param BOX_LINK_WATCH_LOG_GLOB (env or file, optional) - the hub log names, default *.out.log
# @param BOX_LINK_WATCH_RESULTS (env or file, optional) - the run-on-box results dir (<dir>/<id>/result.json)
# @param BOX_LINK_WATCH_HOME (env or file, required with ROOT) - the relay checkout whose `run -a radiate` must run
# @param BOX_LINK_WATCH_LIMIT_MIN (optional) - minutes before an alert, default 7
# @param BOX_LINK_WATCH_RESTART_ACTION (env or file, optional) - the action of the relay checkout that restarts the link; unset = no restart
# @param BOX_LINK_WATCH_RESTART_AFTER_S (optional) - seconds stuck before the restart, default 600
# @param BOX_LINK_WATCH_RESTART_EVERY_S (optional) - at most one restart per box per this many seconds, default 1800
# @param BOX_LINK_WATCH_TOPICS (optional) - "box=topic8/workspace,...", default cnf/box-link-watch/topics.tsv
# @param BOX_LINK_WATCH_STATE (optional) - default $XDG_STATE_HOME/csi-spl/box-link-watch.json
# @param BOX_LINK_WATCH_FROM (optional) - the sender id, default LEASE_ORCH of the dispatch lease.conf
# @param BOX_LINK_WATCH_FALLBACK (optional) - the receiver when a topic has no live seat or a box has no topic row, default the dispatch lease holder
# @param BOX_LINK_WATCH_LANES_CMD (optional, tests) - prints the lane map JSON, default lane-map.sh list --json
# @param BOX_LINK_WATCH_SEND (optional, tests) - the sender script, default spawn-agents/scripts/spool-send.sh
# @param BOX_LINK_WATCH_RELAY (optional, tests) - the workspace relay, default src/bash/scripts/box-link-watch-relay.sh
# @param BOX_LINK_WATCH_PS_CMD (optional, tests) - the process list, default ps -eo args=
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_box_link_watch
# @example DRY_RUN=0 ./run -a do_spl_box_link_watch
#------------------------------------------------------------------------------
do_spl_box_link_watch() {
  do_require_bin python3 flock || return 1
  local dry="${DRY_RUN:-1}" lim="${BOX_LINK_WATCH_LIMIT_MIN:-7}"
  local st="${BOX_LINK_WATCH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/box-link-watch.json}"
  local cf="${BOX_LINK_WATCH_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/csi-spl/box-link-watch.env}"
  local sa="$PROJ_PATH/src/bash/features/spawn-agents/scripts" topics from home
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$lim" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL BOX_LINK_WATCH_LIMIT_MIN must be whole minutes, got: '$lim'"; return 1; }
  local rsa="${BOX_LINK_WATCH_RESTART_AFTER_S:-600}" rse="${BOX_LINK_WATCH_RESTART_EVERY_S:-1800}"
  [[ "$rsa" =~ ^[1-9][0-9]*$ && "$rse" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL BOX_LINK_WATCH_RESTART_AFTER_S and _EVERY_S must be whole seconds, got: '$rsa' '$rse'"; return 1; }
  spl_box_link_watch_env "$cf"
  [[ -z "${BOX_LINK_WATCH_RESTART_ACTION:-}" || "$BOX_LINK_WATCH_RESTART_ACTION" =~ ^[a-z][a-z0-9_-]*$ ]] ||
    { do_log "FATAL BOX_LINK_WATCH_RESTART_ACTION must be an action name, got: '$BOX_LINK_WATCH_RESTART_ACTION'"; return 1; }
  [[ -n "${BOX_LINK_WATCH_ROOT:-}" ]] ||
    { do_log "OK no relay configured on this box (no BOX_LINK_WATCH_ROOT, no $cf): nothing to watch"; return 0; }
  [[ -n "${BOX_LINK_WATCH_LOG_DIR:-}" && -n "${BOX_LINK_WATCH_HOME:-}" ]] ||
    { do_log "FATAL BOX_LINK_WATCH_LOG_DIR and BOX_LINK_WATCH_HOME must be set with BOX_LINK_WATCH_ROOT (env or $cf)"; return 1; }
  home="$BOX_LINK_WATCH_HOME"
  topics="${BOX_LINK_WATCH_TOPICS:-$(spl_box_link_watch_topics "$PROJ_PATH/cnf/box-link-watch/topics.tsv")}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  from="${BOX_LINK_WATCH_FROM:-}"
  if [[ -z "$from" ]]; then spl_lease_init ro >/dev/null 2>&1 && spl_lease_conf; from="${LEASE_ORCH:-}"; fi
  [[ "$dry" == 1 || "$from" =~ ^[A-Za-z0-9_-]+(@[a-z0-9-]+)?$ ]] ||
    { do_log "FATAL no sender id: set BOX_LINK_WATCH_FROM or LEASE_ORCH in the dispatch lease.conf"; return 1; }
  mkdir -p "$(dirname "$st")" || { do_log "FATAL cannot create the dir of $st"; return 1; }
  exec 8>"$st.lock"
  flock -n 8 || { do_log "INFO another box link watch run holds $st.lock - skipped"; exec 8>&-; return 0; }
  GW_ROOT="$BOX_LINK_WATCH_ROOT" GW_LOG_DIR="$BOX_LINK_WATCH_LOG_DIR" GW_LOG_GLOB="${BOX_LINK_WATCH_LOG_GLOB:-*.out.log}" \
    GW_RESULTS="${BOX_LINK_WATCH_RESULTS:-}" GW_STATE="$st" GW_LIMIT_MIN="$lim" \
    GW_TOPICS="$topics" GW_FROM="$from" GW_SEND="${BOX_LINK_WATCH_SEND:-$sa/spool-send.sh}" \
    GW_RELAY="${BOX_LINK_WATCH_RELAY:-$PROJ_PATH/src/bash/scripts/box-link-watch-relay.sh}" \
    GW_LANES_CMD="${BOX_LINK_WATCH_LANES_CMD:-bash $sa/lane-map.sh list --json}" \
    GW_FALLBACK="${BOX_LINK_WATCH_FALLBACK:-$(spl_box_link_watch_holder)}" \
    GW_RESTART_HOME="$home" GW_RESTART_ACTION="${BOX_LINK_WATCH_RESTART_ACTION:-}" GW_RESTART_AFTER_S="$rsa" GW_RESTART_EVERY_S="$rse" \
    GW_PS_CMD="${BOX_LINK_WATCH_PS_CMD:-ps -eo args=}" GW_RADIATE_RX="^\\S*bash ${home//./\\.}/run -a (do-)?radiate( |\$)" \
    DRY_RUN="$dry" SPOOL_ROOT="$SPOOL_ROOT" python3 "$PROJ_PATH/src/bash/scripts/box-link-watch.py"
  local rc=$?
  exec 8>&-
  (( rc == 0 )) && do_log "OK box link watch: ran$([[ "$dry" == 1 ]] && echo ' (DRY_RUN: nothing sent)')" ||
    do_log "WARN box link watch: rc $rc (an unsent alert is retried next run)"
  return "$rc"
}

# The box-local KEY=VALUE file: sets each BOX_LINK_WATCH_{ROOT,LOG_DIR,
# LOG_GLOB,RESULTS,HOME,RESTART_ACTION} the environment left unset. Read,
# never sourced.
spl_box_link_watch_env() {  # FILE
  local k v
  [[ -r "$1" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      BOX_LINK_WATCH_ROOT|BOX_LINK_WATCH_LOG_DIR|BOX_LINK_WATCH_LOG_GLOB|BOX_LINK_WATCH_RESULTS|BOX_LINK_WATCH_HOME|BOX_LINK_WATCH_RESTART_ACTION)
        [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "${v//\$HOME/$HOME}" ;;
    esac
  done < <(grep -E '^BOX_LINK_WATCH_[A-Z_]+=[^[:space:];|&`]+$' "$1")
}

# The topics file as "box=topic8/workspace,...": one `box<TAB>topic8<TAB>
# workspace` row per box. A bad or missing workspace is left empty: the
# watcher then sends nothing to another machine (SPL-4880).
spl_box_link_watch_topics() {  # FILE
  awk -F'\t' '!/^[[:space:]]*(#|$)/ && $2 ~ /^[0-9a-f]{8}/ {
    ws = ($3 ~ /^[a-z0-9][a-z0-9-]*$/ && length($3) <= 32) ? $3 : ""
    printf "%s%s=%s/%s", (n++ ? "," : ""), $1, substr($2, 1, 8), ws}' "$1" 2>/dev/null
}

# The dispatch lease holder (`<id>@<box>`), the fallback receiver; empty when
# the lease cannot be read.
spl_box_link_watch_holder() {
  local h
  h="$(LEASE_CMD=show do_spl_dispatch_lease 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ "$h" =~ ^[A-Za-z0-9_-]+(@[a-z0-9-]+)?$ && "$h" != none ]] && printf '%s' "$h"
}
