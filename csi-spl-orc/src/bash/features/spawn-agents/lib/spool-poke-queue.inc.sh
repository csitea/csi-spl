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
#   1. a notice STRIP, split into the agent's own window down its RIGHT-HAND
#      side (default on an agent that paints a TUI). It is the only PERSISTENT
#      in-window surface such a pane has: the notices stand there in blue
#      NEWEST FIRST (013/CLE-3425 - a terminal appends, so the pane is
#      repainted by spool-notice-pane.sh), and nothing is ever sent to the
#      agent's input.
#
#      RIGHT, not BOTTOM, and that is a correctness matter as well as the
#      owner's instruction (2026-09-22). Measured on tmux 3.5a against a pane
#      on the ALTERNATE screen, 189x51, with 51 numbered rows drawn:
#
#        split -v -l 8  -> agent 189x42: the top 9 rows are GONE and every
#                          surviving row has moved up 9. A TUI that repaints
#                          only its own live frame - which is what a
#                          partially-redrawing CLI does on SIGWINCH - then
#                          paints that frame over a screen whose anchor moved,
#                          and the bottom of the terminal is the corruption
#                          the owner reported.
#        split -h -l 48 -> agent 140x51: all 51 rows still there, ROW-001 still
#                          on line 1, ROW-END still last. Nothing moved.
#
#      So the width knob does not merely rotate the bug: the row anchor, which
#      is the thing a partial redraw depends on, survives a width change and
#      does not survive a height change.
#
#      BUT -h IS NOT FREE EITHER, and the proof script measures that too, with
#      a subject shaped like a real agent CLI - a static transcript plus a live
#      frame repainted on SIGWINCH:
#
#        -v -l 8   top transcript row TX-001 -> TX-010 (nine rows destroyed,
#                  everything under them moved up), 38 of 47 line ends survive
#        -h -l 48  top transcript row still TX-001, live frame on the right row,
#                  and 0 of 47 line ends survive - every transcript line lost
#                  whatever sat past the new width, permanently, because no
#                  process holds a copy of it to repaint
#
#      So for an ALREADY-RUNNING CLI this is better, not perfect: it trades a
#      moved screen for clipped line tails. The complete fix is not to resize a
#      live TUI at all, which is why spawn-window.sh splits the strip BEFORE
#      the CLI paints. An agent already running when its strip arrives takes
#      exactly one width change, once. Reproduce all of it with
#      scripts/spool-strip-resize-proof.sh.
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
#   SPOOL_POKE            1 (default) or 0 to leave the PROMPT alone entirely
#                         (read by spool-notify.sh; the pane still shows it).
#                         BOX-wide: it is the notifier's environment, inherited
#                         from the one `hub-run` sidecar that serves the whole
#                         box, so it cannot say "this agent yes, that one no".
#                         Per-AGENT muting is the .no-poke marker below.
#   SPOOL_SHOW_PANE       auto (default: a notice pane when the agent's pane is
#                         on the alternate screen) | 1 always | 0 never
#   SPOOL_SHOW_PANE_COLS  notice STRIP width in columns, default 48. The strip
#                         is a RIGHT-HAND column (owner, 2026-09-22), so width
#                         is the knob height used to be; it is clamped to at
#                         most half the window so the agent always keeps the
#                         larger half
#   SPOOL_SHOW_PANE_LINES kept ONLY for a caller that still sets it, and only as
#                         the width when SPOOL_SHOW_PANE_COLS is unset and it is
#                         wide enough to be a column (>= 20). A bottom bar's 8
#                         is not a column, so the default width is used instead
#   SPOOL_SHOW_PANE_MAX   notices kept in the pane, newest first, default 50
#   SPOOL_SHOW_MS         status-line dwell, default 20000 (0 = until a key)
#   SPOOL_SHOW_BODY_MAX   body excerpt, default 400
#   SPOOL_SHOW_COLOUR     1 (default) or 0; NO_COLOR in the environment wins

# 0 when THIS agent has asked for its prompt to be left alone, whatever the
# box-wide SPOOL_POKE says: the marker file $SPOOL_ROOT/<ID>/.no-poke.
#
# A per-agent knob is needed because SPOOL_POKE is not one. One `hub-run`
# sidecar serves every agent on a box and the notifier inherits its
# environment, so the only way to spare ONE pane used to be to mute the whole
# box - which is exactly what happened on 2026-09-22: the orchestrator's own
# seat wanted a quiet prompt, every seat got one, and two owner DMs reached
# nobody. The file makes "spare that pane" cost one pane instead of all of them.
#
# A file, not another variable: the sidecar reads its environment once at exec,
# so a variable could not be changed without restarting delivery for everyone.
spool_poke_muted() {  # ID
  [ -e "$SPOOL_ROOT/$1/.no-poke" ]
}

# TEXT with tmux format syntax neutralised: display-message EXPANDS #{...} and
# #(...) in its argument, so a message body is a format-injection surface.
spool_show_escape() {  # TEXT
  printf '%s' "${1//\#/##}"
}

# 0 when the notice should carry colour at all.
spool_show_colour() {
  [ -z "${NO_COLOR:-}" ] && [ "${SPOOL_SHOW_COLOUR:-1}" = 1 ]
}

# The command a notice pane runs. Not a `tail`: a terminal appends, and the
# newest notice belongs on TOP (013/CLE-3425), so the pane is repainted by
# spool-notice-pane.sh.
#
# TWO versions, because they answer two different questions and conflating them
# throws away messages for no reason.
#
#   SPOOL_NOTICE_PANE_V    the RENDERER. Bump it whenever spool-notice-pane.sh
#                          changes what it paints, so a pane still running the
#                          old renderer is respawned instead of going stale.
#                          A notice pane is a LONG-LIVED process started from a
#                          path; editing the renderer does not reach the panes
#                          already running it, and without a bump the fleet
#                          keeps the old one indefinitely while the code claims
#                          otherwise. (Same shape as the bottom bars that could
#                          not be respawned into strips.)
#   SPOOL_NOTICE_RECORD_V  the LOG FORMAT. Only this one may rotate the log:
#                          records written in an older format repaint as
#                          nonsense, so they are moved aside. A renderer change
#                          reads the SAME records perfectly well, and rotating
#                          for it would blank every notice on screen to no
#                          purpose. A pane carrying no record version predates
#                          the option and is treated as 1, which is what it is -
#                          <head>TAB<body> has not changed since v4.
SPOOL_NOTICE_PANE_V=6
SPOOL_NOTICE_RECORD_V=1

spool_notice_pane_cmd() {  # LOG
  printf 'exec %q --log %q --max %s' \
    "$SPOOL_FEATURE_DIR/scripts/spool-notice-pane.sh" "$1" "${SPOOL_SHOW_PANE_MAX:-50}"
}

# The WIDTH of the notice strip, in columns, given the window it goes into.
# Prints a number. Clamped to [20, window/2] so the agent always keeps the
# larger half of its own window, whatever an operator asks for.
#
# SPOOL_SHOW_PANE_LINES was the bottom bar's HEIGHT and its default was 8. A
# caller that still sets it is honoured only when the value could plausibly be
# a column (>= 20); 8 columns is not a chat strip, it is the old default
# arriving in the new knob, so it is ignored rather than obeyed.
spool_strip_cols() {  # WINDOW_WIDTH
  local win="${1:-0}" want="${SPOOL_SHOW_PANE_COLS:-}" cap
  if [ -z "$want" ] && [[ "${SPOOL_SHOW_PANE_LINES:-}" =~ ^[0-9]+$ ]] &&
     [ "${SPOOL_SHOW_PANE_LINES}" -ge 20 ]; then
    want="$SPOOL_SHOW_PANE_LINES"
  fi
  [[ "$want" =~ ^[0-9]+$ ]] || want=48
  [[ "$win" =~ ^[0-9]+$ ]] && [ "$win" -gt 0 ] || win=$(( want * 2 ))
  cap=$(( win / 2 )); [ "$cap" -lt 20 ] && cap=20
  [ "$want" -gt "$cap" ] && want="$cap"
  [ "$want" -lt 20 ] && want=20
  printf '%s' "$want"
}

# 0 when PANE is already a RIGHT-HAND strip rather than a bottom bar. A pane
# split with -h starts at a column past 0; one split with -v starts at column
# 0 and only its row differs. That one number is the whole test, and it is the
# one tmux keeps whatever the window is later resized to.
spool_strip_is_right() {  # PANE
  local left
  left="$("${SPOOL_TM[@]}" display-message -p -t "$1" '#{pane_left}' 2>/dev/null)"
  [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -gt 0 ]
}

# The notice strip of ID: an existing one, or a new split of ID's own window.
# Prints the pane id, or nothing when one cannot be made.
spool_show_notice_pane() {  # ID AGENT_PANE
  local id="$1" agent_pane="$2" p mark ver rver pane cols win log cmd
  spool_tmux_argv
  log="$(spool_poke_queue_dir "$id")/notices.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 1
  : >>"$log" || return 1
  cmd="$(spool_notice_pane_cmd "$log")"
  while IFS=' ' read -r p mark ver rver; do
    [ "$mark" = "$id" ] || continue
    # A BOTTOM BAR left behind by an older version of this feature cannot be
    # respawned into the right shape: respawn-pane replaces the process, never
    # the geometry. It is killed here and re-split below, so one delivery is
    # enough to move every pane the fleet is still carrying. The agent's own
    # pane grows back to full height at that moment - a resize it would have
    # taken anyway, and the LAST one it takes.
    if ! spool_strip_is_right "$p"; then
      "${SPOOL_TM[@]}" kill-pane -t "$p" 2>/dev/null
      break
    fi
    # An older renderer (or none) in a pane we own: replace it in place, so the
    # agent's window keeps the same layout and the same pane id.
    if [ "$ver" != "$SPOOL_NOTICE_PANE_V" ]; then
      # A log in an OLDER RECORD FORMAT would repaint as nonsense, so it is
      # kept beside the new one rather than deleted: this is a delivery hint,
      # the inbox is the record. A pane that is merely running an older
      # RENDERER keeps its log - the records are fine, and blanking a pane the
      # owner is reading is a cost with nothing bought.
      if [ "${rver:-1}" != "$SPOOL_NOTICE_RECORD_V" ]; then
        [ -s "$log" ] && mv -f "$log" "$log.v${ver:-0}" 2>/dev/null
        : >>"$log" 2>/dev/null
      fi
      "${SPOOL_TM[@]}" respawn-pane -k -t "$p" "$cmd" 2>/dev/null &&
        "${SPOOL_TM[@]}" set-option -p -t "$p" @spool_notices_v "$SPOOL_NOTICE_PANE_V" 2>/dev/null &&
        "${SPOOL_TM[@]}" set-option -p -t "$p" @spool_notices_rv "$SPOOL_NOTICE_RECORD_V" 2>/dev/null
    fi
    printf '%s' "$p"; return 0
  done < <("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id} #{@spool_notices} #{@spool_notices_v} #{@spool_notices_rv}' 2>/dev/null)
  win="$("${SPOOL_TM[@]}" display-message -p -t "$agent_pane" '#{window_width}' 2>/dev/null)"
  cols="$(spool_strip_cols "$win")"
  # -h puts the new pane to the RIGHT of the target (owner, 2026-09-22), and
  # -d means it never takes focus, so the agent keeps the keyboard.
  pane="$("${SPOOL_TM[@]}" split-window -d -h -l "$cols" -t "$agent_pane" -P -F '#{pane_id}' \
            "$cmd" 2>/dev/null)" || return 1
  [ -n "$pane" ] || return 1
  "${SPOOL_TM[@]}" set-option -p -t "$pane" @spool_notices "$id" 2>/dev/null
  "${SPOOL_TM[@]}" set-option -p -t "$pane" @spool_notices_v "$SPOOL_NOTICE_PANE_V" 2>/dev/null
  "${SPOOL_TM[@]}" set-option -p -t "$pane" @spool_notices_rv "$SPOOL_NOTICE_RECORD_V" 2>/dev/null
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
      # One RECORD per line, <head>TAB<body>: the renderer decides the order and
      # the colour, so the newest can be put on top without re-parsing escapes.
      # Both fields went through spool_notify_clean, which leaves no tab or
      # newline in either, so a line is exactly one record.
      printf '%s\t%s\n' "$head" "$body" >>"$log" 2>/dev/null &&
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
