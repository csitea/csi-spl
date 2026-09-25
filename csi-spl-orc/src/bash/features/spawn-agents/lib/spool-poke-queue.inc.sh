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
#
# v7 adds the OUTBOUND treatment: a record whose head begins "SPOOL -> " is a
# message this agent SENT, and the renderer paints it in a third colour. That
# is a RENDERING change and nothing else - an outbound record is the same
# <head>TAB<body> line an inbound one has always been - so PANE_V moves and
# RECORD_V does NOT. Bumping RECORD_V here would have rotated every live log
# aside to re-read records that were never in a different format.
#
# v8 (2026-09-25) paints SEVERAL logs in one strip, each record tagged with its
# env: one agent seated on the dev AND the prd desk has two notices logs, one
# per env's spool root, and a v7 strip showed whichever it was split for. The
# records gained an optional third field, the write time, which only orders
# records across logs; a v7 renderer would print it after the body, which is
# why PANE_V moves. RECORD_V does NOT: every existing <head>TAB<body> line
# still reads correctly, and rotating would blank the strip for nothing.
SPOOL_NOTICE_PANE_V=8
SPOOL_NOTICE_RECORD_V=1

spool_notice_pane_cmd() {  # LOG [LOG ...]
  local l a=""
  for l in "$@"; do a+=" --log $(printf '%q' "$l")"; done
  printf 'exec %q%s --max %s' \
    "$SPOOL_FEATURE_DIR/scripts/spool-notice-pane.sh" "$a" "${SPOOL_SHOW_PANE_MAX:-50}"
}

# One notices-log RECORD line: <head>TAB<body>TAB<epoch>. The epoch orders
# records ACROSS the logs one strip merges (dev + prd); the renderer never
# paints it. $EPOCHREALTIME costs no process; a comma locale is normalised.
spool_notice_line() {  # HEAD BODY
  local ts="${EPOCHREALTIME:-}"
  ts="${ts/,/.}"
  [ -n "$ts" ] || ts="$(date +%s)"
  printf '%s\t%s\t%s\n' "$1" "$2" "$ts"
}

# The log SET a strip should tail, ':'-joined, given the log this delivery
# writes (LOG), the set the pane is marked with (@spool_notices_logs) and, for
# a strip older than that option, its start command (whose --log words are the
# set it was started with). Kept in order, missing files dropped, LOG added
# last when absent. One strip per agent whatever the number of envs: a second
# split would re-run the specs/028 resize of the agent's alternate screen.
spool_notice_log_set() {  # LOG MARKED START
  local log="$1" marked="$2" start="$3" w prev="" out=""
  local -a have=() words=()
  if [ -n "$marked" ]; then
    IFS=':' read -r -a have <<<"$marked"
  elif [ -n "$start" ]; then
    start="${start#\"}"; start="${start%\"}"
    read -r -a words <<<"$start"
    for w in "${words[@]}"; do
      [ "$prev" = --log ] && have+=("$w")
      prev="$w"
    done
  fi
  for w in "${have[@]}"; do
    [ -n "$w" ] && [ -f "$w" ] && [ "$w" != "$log" ] || continue
    case ":$out:" in *":$w:"*) continue ;; esac
    out="${out:+$out:}$w"
  done
  printf '%s' "${out:+$out:}$log"
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
#
# The strip tails EVERY env's log this agent has been delivered on (v8): a
# strip whose set lacks this delivery's log is respawned in place with the
# union, so the second env's first message is what switches it over.
spool_show_notice_pane() {  # ID AGENT_PANE
  local id="$1" agent_pane="$2" p mark ver rver marked start pane cols win log cmd lset=""
  local -a logs=()
  spool_tmux_argv
  log="$(spool_poke_queue_dir "$id")/notices.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 1
  : >>"$log" || return 1
  lset="$log"
  while IFS=$'\t' read -r p mark ver rver marked start; do
    # Every option field is printed behind a "=" (below): a TAB is IFS
    # whitespace, so an EMPTY field would collapse into its neighbour and shift
    # every later one left. (#{?x,...} is no help: it reads "0" as unset.)
    mark="${mark#=}"; ver="${ver#=}"; rver="${rver#=}"; marked="${marked#=}"
    [ "$mark" = "$id" ] || continue
    lset="$(spool_notice_log_set "$log" "$marked" "$start")"
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
    if [ "$ver" != "$SPOOL_NOTICE_PANE_V" ] || [ "$lset" != "$marked" ]; then
      # A log in an OLDER RECORD FORMAT would repaint as nonsense, so it is
      # kept beside the new one rather than deleted: this is a delivery hint,
      # the inbox is the record. A pane that is merely running an older
      # RENDERER keeps its log - the records are fine, and blanking a pane the
      # owner is reading is a cost with nothing bought.
      if [ "${rver:-1}" != "$SPOOL_NOTICE_RECORD_V" ]; then
        [ -s "$log" ] && mv -f "$log" "$log.v${ver:-0}" 2>/dev/null
        : >>"$log" 2>/dev/null
      fi
      IFS=':' read -r -a logs <<<"$lset"
      "${SPOOL_TM[@]}" respawn-pane -k -t "$p" "$(spool_notice_pane_cmd "${logs[@]}")" 2>/dev/null &&
        "${SPOOL_TM[@]}" set-option -p -t "$p" @spool_notices_v "$SPOOL_NOTICE_PANE_V" 2>/dev/null &&
        "${SPOOL_TM[@]}" set-option -p -t "$p" @spool_notices_rv "$SPOOL_NOTICE_RECORD_V" 2>/dev/null &&
        "${SPOOL_TM[@]}" set-option -p -t "$p" @spool_notices_logs "$lset" 2>/dev/null
    fi
    printf '%s' "$p"; return 0
  done < <("${SPOOL_TM[@]}" list-panes -a -F \
             $'#{pane_id}\t=#{@spool_notices}\t=#{@spool_notices_v}\t=#{@spool_notices_rv}\t=#{@spool_notices_logs}\t#{pane_start_command}' 2>/dev/null)
  IFS=':' read -r -a logs <<<"$lset"
  cmd="$(spool_notice_pane_cmd "${logs[@]}")"
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
  "${SPOOL_TM[@]}" set-option -p -t "$pane" @spool_notices_logs "$lset" 2>/dev/null
  "${SPOOL_TM[@]}" set-option -p -t "$pane" remain-on-exit off 2>/dev/null
  printf '%s' "$pane"
}

# ── the RECORD: one writer, two directions ──────────────────────────────────
# Until now the strip was INBOUND ONLY, and on the LOCAL send path it was not
# written at all. Measured 2026-09-22 in the tests' own sandbox: one
# `spool-send.sh --from CLE-90 --to CLE-91` left NEITHER agent with a
# .pokes/notices.log (n=1). spool_poke_show is reached only through
# scripts/spool-notify.sh, which the spool binary runs on delivery - and
# spool-send.sh deliberately runs the binary with SPOOL_NOTIFY_CMD=off so it
# can ring the pane itself and report the outcome as its exit code. So a peer
# message between two agents on this box rang a prompt and recorded nothing.
#
# The owner asked (2026-09-22) for "all the post and replies" in the strip. A
# column that shows what an agent was sent and never what it said is not a
# conversation, so a send now records BOTH sides: the sender's own copy, and -
# on a LOCAL delivery, where no notifier will ever run - the recipient's.
#
# EXACTLY ONE writer per side. The recipient's record is written by whichever
# leg actually reached it and never by both: spool_poke_show on the notifier's
# path, spool-send.sh on the local path (which it takes only when `spool send`
# reported delivery "local").

# The head of an INBOUND record: a message this agent was SENT.
spool_notice_head_in() {  # TO KIND FROM TASK MSGID
  printf 'SPOOL %s: %s from %s%s%s' \
    "$1" "$2" "$3" "${4:+ task $4}" "${5:+ msg $5}"
}

# The head of an OUTBOUND record: a message this agent SENT to someone.
#
# The direction marker is the SEVENTH column, not a word buried mid-line: in a
# 48-column strip a distinction that arrives after the ids is one a reader
# scanning the column will miss. It is also the distinction that survives
# NO_COLOR=1, which is the point - the colour in the renderer is the fast path,
# the arrow is the one that always works.
#
# The sender's own id is not in the head. This record only ever lands in that
# agent's OWN log, so naming it would spend two of the forty-eight columns
# repeating whose column this is.
spool_notice_head_out() {  # TO KIND TASK MSGID
  printf 'SPOOL -> %s: %s%s%s' \
    "$1" "$2" "${3:+ task $3}" "${4:+ msg $4}"
}

# Prints 1 when PANE holds a full-screen UI, 0 when it is a bare terminal.
#
# A TUI is normally recognised by the alternate screen (#{alternate_on} = 1),
# but not every agent CLI uses it: the agy CLI paints its UI on the NORMAL
# screen. Measured 2026-09-25 on this box (CLE-222, master afd104f, n=16
# windows): AGY-3493's pane reported alternate_on 0, every CLE/GRK pane 1. So
# the agy window never got a strip, and step 3 of spool_poke_show wrote each
# notice into its tty - over agy's own UI. The pane option @spool_strip is the
# per-pane answer, set by the launcher that knows what it started:
#   @spool_strip 1  a TUI whatever alternate_on says (strip, never the tty)
#   @spool_strip 0  a bare terminal whatever alternate_on says (no strip)
#   unset           an AGY-* agent id is a TUI (panes spawned before the
#                   mark existed, e.g. AGY-3493); otherwise alternate_on decides
spool_pane_is_tui() {  # PANE [ID]
  local v
  v="$("${SPOOL_TM[@]}" display-message -p -t "$1" '#{@spool_strip}/#{alternate_on}' 2>/dev/null)"
  case "$v" in
    1/*) echo 1 ;;
    0/*) echo 0 ;;
    */1) echo 1 ;;
    *)   case "${2:-}" in AGY-*) echo 1 ;; *) echo 0 ;; esac ;;
  esac
}

# 0 when a notice STRIP should be SPLIT for a pane in this state. An existing
# strip is adopted whatever this says - the gate is about creating one, and a
# pane that already has a strip has already answered the question.
spool_strip_wanted() {  # PANE [ID]
  case "${SPOOL_SHOW_PANE:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ "$(spool_pane_is_tui "$1" "${2:-}")" = 1 ]
}

# Append one record to ID's notices log, ensuring ID's strip where it has a
# live window. 0 when the record was written.
#
# The record is written even when no strip exists and even when none can be
# made: the renderer reads the log from the beginning (not `-n 0`), so a strip
# opened later paints everything that was missed. A record costs a line; the
# alternative is a hole in the conversation.
spool_notice_record() {  # ID HEAD BODY
  local id="$1" head="$2" body="$3" pane log
  [ "${SPOOL_SHOW:-1}" = 1 ] || return 1
  [ -n "$id" ] && [ -n "$head" ] || return 1
  spool_tmux_argv
  log="$(spool_poke_queue_dir "$id")/notices.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 1
  pane="$(spool_pane_of "$id")"
  if [ -n "$pane" ] && spool_strip_wanted "$pane" "$id"; then
    spool_show_notice_pane "$id" "$pane" >/dev/null 2>&1
  fi
  # One RECORD per line, <head>TAB<body>TAB<epoch>: the renderer decides the order and
  # the colour, so the newest can be put on top without re-parsing escapes.
  # Both fields went through spool_notify_clean, which leaves no tab or newline
  # in either, so a line is exactly one record.
  spool_notice_line "$head" "$body" >>"$log" 2>/dev/null
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
  # Same body the prompt is typed and the WUI row shows. SPOOL_SHOW_BODY_MAX
  # still overrides the bound; the default is the prompt bound, not 400.
  body="$(spool_notify_shown_body "$body")"
  [ -n "$body" ] || body='(no body)'
  head="$(spool_notice_head_in "$to" "$kind" "$from" "$task" "$msgid")"
  plain="${head} :: ${body}"
  if spool_show_colour; then
    blue="${esc}[1;38;5;39m"; dim="${esc}[38;5;110m"; off="${esc}[0m"
  fi
  # "alt" here means "a UI owns this pane's screen": the alternate screen, or
  # the launcher's @spool_strip opt-in (spool_pane_is_tui, the agy case).
  alt="$(spool_pane_is_tui "$pane" "$to")"

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
      spool_notice_line "$head" "$body" >>"$log" 2>/dev/null &&
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
