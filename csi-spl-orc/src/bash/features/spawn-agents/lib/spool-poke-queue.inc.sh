#!/usr/bin/env bash
# spool-poke-queue.inc.sh — the DEFERRED half of the doorbell.
#
# specs/028-spool-terminal-delivery, contracts/poke-line.md §3. The safe-poke
# rule is right: a notifier must never type over a half-written line, so a pane
# that holds unsent text is left alone (exit 6). One-shot, that rule also means
# the message is never announced at all - and for an agent whose ONLY input is
# its prompt line, "left alone" and "swallowed" are the same thing. Measured
# 2026-09-21: an owner DM reached the agent's inbox and its pane never showed
# it, because the pane held one line of the owner's own typing.
#
# So a refused line is not dropped: it is queued under the recipient's own spool
# dir and re-offered by a per-agent daemon until the prompt is clear. The rule
# is unchanged - nothing is ever typed over unsent text - and the message still
# arrives, seconds after the prompt frees up.
#
# The inbox file stays the record (002). This queue is a delivery hint: losing
# it loses a notification, never a message.
#
# Requires lib/spool-env.inc.sh (spool_env_resolve) and lib/spool-notify.inc.sh.
#
#   SPOOL_POKE_RETRY_SECS   how long a daemon keeps offering   default 1800
#   SPOOL_POKE_RETRY_EVERY  seconds between sweeps             default 2
#   SPOOL_POKE_RETRY_CMD    the retry script (default: this feature's)

# The queue dir of an agent, created on demand.
spool_poke_queue_dir() {  # ID
  printf '%s/%s/.pokes' "$SPOOL_ROOT" "$1"
}

# Queue one already-rendered poke line for ID. Prints the entry path.
spool_poke_queue_add() {  # ID LINE
  local id="$1" line="$2" dir f
  dir="$(spool_poke_queue_dir "$id")"
  mkdir -p "$dir" 2>/dev/null || return 1
  # The name sorts oldest-first and stays unique per process and nanosecond.
  f="$dir/$(date -u +%Y%m%dT%H%M%S)-$(date +%N)-$$.poke"
  printf '%s\n' "$line" >"$f" || return 1
  printf '%s' "$f"
}

# 0 when a retry daemon for ID is already running.
spool_poke_retry_alive() {  # ID
  local pidf pid
  pidf="$(spool_poke_queue_dir "$1")/retry.pid"
  pid="$(cat "$pidf" 2>/dev/null)" || return 1
  [ -n "$pid" ] && [ -d "/proc/$pid" ] 2>/dev/null
}

# Start the retry daemon for ID unless one is already up. It is detached with
# setsid AND every descriptor above fd 2 is closed in the child: the notifier
# is run by the spool binary under a deadline (internal/notify: CommandContext
# + WaitDelay), so a daemon that stayed in its process group or held its output
# pipe would be killed with it, or would hold the binary's Wait open.
spool_poke_retry_ensure() {  # ID
  local id="$1" dir script log
  spool_poke_retry_alive "$id" && return 0
  script="${SPOOL_POKE_RETRY_CMD:-$SPOOL_FEATURE_DIR/scripts/spool-poke-retry.sh}"
  [ -x "$script" ] || return 1
  dir="$(spool_poke_queue_dir "$id")"
  mkdir -p "$dir" 2>/dev/null || return 1
  log="$dir/retry.log"
  setsid bash -c '
    log="$1"; shift
    exec </dev/null >>"$log" 2>&1
    for f in /proc/$$/fd/*; do
      n="${f##*/}"
      case "$n" in 0|1|2) continue ;; esac
      eval "exec $n>&-" 2>/dev/null || true
    done
    exec "$@"' _ "$log" "$script" --to "$id" &
  return 0
}

# ── the VISIBLE half: render without ever injecting input ───────────────────
# The prompt is not the only surface a terminal has, and on an agent pane it is
# the WORST one: it is the single surface the safe-poke rule has to guard. This
# half renders the notice on surfaces that rule does not gate, so a pane whose
# prompt holds half a sentence still SHOWS the message.
#
# Three surfaces, in the order they are taken:
#
#   1. a notice pane, split into the agent's own window (default on an agent
#      that paints a TUI). It is the only PERSISTENT in-window surface such a
#      pane has: the notices scroll there in blue, the agent's own pane just
#      redraws a few rows shorter, and nothing is ever sent to its input.
#   2. tmux's status line for that window (display-message). Instant, coloured,
#      impossible to corrupt - it is tmux's own chrome, not the pane's canvas -
#      but it fades after its dwell, so it is the flash, not the record.
#   3. the pane's tty, ONLY when the pane is on the NORMAL screen. A full-screen
#      TUI paints on the ALTERNATE screen buffer, and text written to that tty
#      is drawn into the TUI's canvas: overwritten by the next redraw, and until
#      then it corrupts the frame. Measured 2026-09-21 on this box: every live
#      agent pane reported `#{alternate_on}` = 1 and the one bare shell reported
#      0. So this surface is for shells and log panes, never for an agent CLI.
#
# Every surface is driven by the delivery itself (the spool binary runs the
# notifier the moment it writes the inbox file). Nothing here polls.
#
#   SPOOL_SHOW            1 (default) or 0 to skip the visible half entirely
#   SPOOL_SHOW_PANE       auto (default: a notice pane when the agent's pane is
#                         on the alternate screen) | 1 always | 0 never
#   SPOOL_SHOW_PANE_LINES notice pane height, default 8
#   SPOOL_SHOW_MS         status-line dwell, default 20000 (0 = until a key)
#   SPOOL_SHOW_BODY_MAX   body excerpt, default 400
#   SPOOL_SHOW_COLOUR     1 (default) or 0; NO_COLOR in the environment wins

# TEXT with tmux format syntax neutralised: display-message EXPANDS #{...} and
# #(...) in its argument, so a message body is a format-injection surface.
spool_show_escape() {  # TEXT
  printf '%s' "${1//\#/##}"
}

# 0 when the notice should carry colour at all.
spool_show_colour() {
  [ -z "${NO_COLOR:-}" ] && [ "${SPOOL_SHOW_COLOUR:-1}" = 1 ]
}

# The notice pane of ID: an existing one, or a new split of ID's own window.
# Prints the pane id, or nothing when one cannot be made.
spool_show_notice_pane() {  # ID AGENT_PANE
  local id="$1" agent_pane="$2" p mark pane lines log
  spool_tmux_argv
  while IFS=' ' read -r p mark; do
    [ "$mark" = "$id" ] && { printf '%s' "$p"; return 0; }
  done < <("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id} #{@spool_notices}' 2>/dev/null)
  lines="${SPOOL_SHOW_PANE_LINES:-8}"
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=8
  log="$(spool_poke_queue_dir "$id")/notices.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 1
  : >>"$log" || return 1
  # -d: the new pane never takes focus, so the agent keeps the keyboard.
  pane="$("${SPOOL_TM[@]}" split-window -d -v -l "$lines" -t "$agent_pane" -P -F '#{pane_id}' \
            "exec tail -n 50 -f '$log'" 2>/dev/null)" || return 1
  [ -n "$pane" ] || return 1
  "${SPOOL_TM[@]}" set-option -p -t "$pane" @spool_notices "$id" 2>/dev/null
  "${SPOOL_TM[@]}" set-option -p -t "$pane" remain-on-exit off 2>/dev/null
  printf '%s' "$pane"
}

# Show the notice for ID. Prints one `show:` line. 0 shown somewhere, 5 no live
# window, 1 nothing would take it. Never types, never touches the prompt.
spool_poke_show() {  # TO KIND FROM TASK MSGID BODY
  local to="$1" kind="$2" from="$3" task="$4" msgid="$5" body="$6"
  local pane alt tty head text plain notice log shown="" esc=$'\033' blue="" dim="" off=""
  [ "${SPOOL_SHOW:-1}" = 1 ] || return 0
  pane="$(spool_pane_of "$to")"
  if [ -z "$pane" ]; then
    echo "show: none - no live window carries ${to}"
    return 5
  fi
  spool_tmux_argv
  kind="$(spool_notify_clean "$kind")"; kind="${kind:-ping}"
  from="$(spool_notify_clean "$from")"; from="${from:-?}"
  task="$(spool_notify_clean "$task")"; msgid="$(spool_notify_clean "$msgid")"
  body="$(spool_notify_cut "$(spool_notify_clean "$body")" "${SPOOL_SHOW_BODY_MAX:-400}")"
  [ -n "$body" ] || body='(no body)'
  head="SPOOL ${to}: ${kind} from ${from}${task:+ task ${task}}${msgid:+ msg ${msgid}}"
  plain="${head} :: ${body}"
  if spool_show_colour; then
    blue="${esc}[1;38;5;39m"; dim="${esc}[38;5;110m"; off="${esc}[0m"
  fi
  alt="$("${SPOOL_TM[@]}" display-message -p -t "$pane" '#{alternate_on}' 2>/dev/null)"

  # 1. the notice pane - the persistent surface
  case "${SPOOL_SHOW_PANE:-auto}" in
    1) notice=1 ;;
    0) notice=0 ;;
    *) notice=$([ "$alt" = 1 ] && echo 1 || echo 0) ;;
  esac
  if [ "$notice" = 1 ]; then
    local np
    np="$(spool_show_notice_pane "$to" "$pane")"
    if [ -n "$np" ]; then
      log="$(spool_poke_queue_dir "$to")/notices.log"
      printf '%s%s%s\n%s%s%s\n\n' "$blue" "$head" "$off" "$dim" "$body" "$off" >>"$log" 2>/dev/null &&
        shown="notice pane ${np}"
    fi
  fi

  # 2. the status line - the flash
  if "${SPOOL_TM[@]}" display-message -d "${SPOOL_SHOW_MS:-20000}" -t "$pane" \
       "$(spool_show_colour && printf '#[fg=colour39,bold]')$(spool_show_escape "$plain")" 2>/dev/null; then
    shown="${shown:+$shown, }status line"
  fi

  # 3. the pane's own tty - only where no TUI owns the screen
  if [ "$alt" = 0 ]; then
    tty="$("${SPOOL_TM[@]}" display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null)"
    if [ -n "$tty" ] && [ -w "$tty" ]; then
      printf '\r\n%s%s%s\r\n%s%s%s\r\n' "$blue" "$head" "$off" "$dim" "$body" "$off" >"$tty" 2>/dev/null &&
        shown="${shown:+$shown, }pane tty"
    fi
  fi

  if [ -n "$shown" ]; then
    echo "show: ${pane} (${to}) ${shown}"
    return 0
  fi
  echo "show: nothing would take the notice for ${to} (${pane})"
  return 1
}
