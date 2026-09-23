#!/usr/bin/env bash
# spool-notify.inc.sh — the ONE renderer and the ONE doorbell.
#
# specs/028-spool-terminal-delivery, contracts/poke-line.md. Sourced by
# scripts/spool-send.sh (which sends first, then rings) and by
# scripts/spool-notify.sh (which only rings: the message is already in the
# inbox, written by `spool send` or by the hub sidecar).
#
# Requires lib/spool-env.inc.sh to have been sourced and spool_env_resolve run:
# it uses spool_pane_of, spool_tmux_argv and $SPOOL_ROOT.
#
#   SPOOL_NOTIFY_BODY_MAX   body excerpt cut, in characters   default 600
#   SPOOL_NOTIFY_LINE_MAX   whole-line backstop cut           default 1200
#   SPOOL_NOTIFY_ENTER_DELAY  seconds between typing the line and Enter,
#                           the TUI's paste debounce             default 0.3
#   SPOOL_POKE_STYLE        auto (default) | body | line. What a TUI prompt is
#                           given: `body` = the sender's message VERBATIM, the
#                           way a human types into a chat box (owner,
#                           2026-09-22); `line` = the shell-inert `: 'SPOOL …'`
#                           poke line; `auto` = body from a HUMAN sender
#                           (HUM-*/GST-*), line from an agent
#   SPOOL_NOTIFY_PROMPT_MAX verbatim body cut, in characters    default 4000
#   SPOOL_TRACE             latency trace file (CLE-3435); the spool binary
#                           sets it, with SPOOL_TRACE_MSG_ID / _TO. Unset = off

# ── sanitising ──────────────────────────────────────────────────────────────
# TEXT -> one line that is safe inside a single-quoted shell argument and
# cannot submit early. poke-line.md §2 fixes the order of these five steps.
spool_notify_clean() {  # TEXT
  local esc=$'\033'
  # One `sed -z`, not a five-stage pipeline (CLE-3435). The steps and their
  # ORDER are unchanged - poke-line.md §2 fixes both, and the hostile-body
  # test pins the result - but this is called once per field, six times per
  # message, and each stage was a process: 30 forks, 35 ms of a 314 ms leg.
  #
  # -z is what lets one sed do the whole job: it reads to NUL rather than to
  # newline, so the newline-to-space step is an ordinary substitution instead
  # of a `tr` the line-based sed could never have performed.
  printf '%s' "${1:-}" | sed -zE "
    s/${esc}\[[0-9;?]*[A-Za-z]//g
    s/${esc}[]()#%][^${esc}]*//g
    s/${esc}//g
    s/[\t\n\r]/ /g
    s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g
    s/'/\"/g
    s/[[:space:]]+/ /g
    s/^ //
    s/ \$//"
}

# Cut TEXT to N characters, appending " …" when it was cut.
spool_notify_cut() {  # TEXT N
  local t="${1:-}" n="${2:-600}"
  if [ "${#t}" -gt "$n" ]; then printf '%s …' "${t:0:$n}"; else printf '%s' "$t"; fi
}

# TEXT -> one line that is safe to TYPE AT A TUI PROMPT, and nothing more.
#
# The five steps of spool_notify_clean exist to make a body safe inside a
# single-quoted SHELL argument. A TUI prompt is not a shell: `send-keys -l`
# puts the bytes in the CLI's input buffer and nothing parses them, so the one
# step that mangles the human's words - `'` becomes `"` - buys nothing here and
# costs every apostrophe in the message ("don't" -> "don"t"). It is the only
# step dropped. Newlines still become spaces: `send-keys -l` treats a newline
# as Enter, so a two-line body would submit half a sentence.
spool_notify_clean_prompt() {  # TEXT
  local esc=$'\033'
  printf '%s' "${1:-}" | sed -zE "
    s/${esc}\[[0-9;?]*[A-Za-z]//g
    s/${esc}[]()#%][^${esc}]*//g
    s/${esc}//g
    s/[\t\n\r]/ /g
    s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g
    s/[[:space:]]+/ /g
    s/^ //
    s/ \$//"
}

# The body a person reads, in every surface that shows the message: the WUI
# row, the agent's left pane (the prompt), and the notice strip. One string.
# spool_notify_clean is NOT this — it rewrites apostrophes so a poke line can
# sit inside single quotes, and that rewrite is what made the strip say
# it"s while the web UI and the prompt said it's.
# Empty after cleaning -> empty. The prompt caller then keeps the poke line.
spool_notify_shown_body() {  # TEXT
  spool_notify_cut "$(spool_notify_clean_prompt "${1:-}")" "${SPOOL_NOTIFY_PROMPT_MAX:-4000}"
}

# Render BODY into VAR as the line a TUI prompt is given verbatim.
# Empty after cleaning -> VAR is empty and the caller keeps the poke line: an
# agent must never be handed a blank prompt and an Enter.
spool_notify_render_prompt() {  # VAR BODY
  local __var="$1" body
  body="$(spool_notify_shown_body "${2:-}")"
  printf -v "$__var" '%s' "$body"
}

# 0 when ID is a human sender: a signed-in WUI member (HUM-) or a door-off
# guest (GST-). Only a human's message is typed verbatim under SPOOL_POKE_STYLE
# auto - an agent's is not, because the `from` and the `spool recv` tail in the
# poke line ARE the inter-agent protocol, and a bare body would strip both.
spool_notify_is_human() {  # ID
  case "${1:-}" in HUM-*|GST-*) return 0 ;; *) return 1 ;; esac
}

# Render the poke line into VAR. Every field is cleaned, not just the body:
# a hostile `from` would otherwise be the way out of the quoted argument.
spool_notify_render() {  # VAR TO KIND FROM TASK MSGID BODY
  local __var="$1" to kind from task msgid body line
  to="$(spool_notify_clean "${2:-}")"
  kind="$(spool_notify_clean "${3:-}")"; kind="${kind:-ping}"
  from="$(spool_notify_clean "${4:-}")"; from="${from:-?}"
  task="$(spool_notify_clean "${5:-}")"
  msgid="$(spool_notify_clean "${6:-}")"
  body="$(spool_notify_clean "${7:-}")"
  body="$(spool_notify_cut "$body" "${SPOOL_NOTIFY_BODY_MAX:-600}")"
  [ -n "$body" ] || body='(no body)'
  line=": 'SPOOL ${to}: ${kind} from ${from}${task:+ task ${task}}${msgid:+ msg ${msgid}}"
  line="${line} :: ${body} :: run: spool recv --as ${to}'"
  line="$(spool_notify_cut "$line" "${SPOOL_NOTIFY_LINE_MAX:-1200}")"
  # The cut may have dropped the closing quote; a line that is not inert is
  # worse than a shorter one, so close it again.
  case "$line" in *"'") ;; *) line="${line}'" ;; esac
  printf -v "$__var" '%s' "$line"
}

# ── the stopwatch ───────────────────────────────────────────────────────────
# One NDJSON line into $SPOOL_TRACE, the same file internal/trace writes, so
# the box-side hops can be subtracted from one clock (CLE-3435). Off unless
# the spool binary set SPOOL_TRACE for this call; never fails the poke.
spool_notify_trace() {  # STAGE
  [ -n "${SPOOL_TRACE:-}" ] || return 0
  printf '{"stage":"%s","ts_nano":%s,"msg_id":"%s","to":"%s"}\n' \
    "$1" "$(date +%s%N)" "${SPOOL_TRACE_MSG_ID:-}" "${SPOOL_TRACE_TO:-}" \
    >> "$SPOOL_TRACE" 2>/dev/null || :
  return 0
}

# 0 when CMD is one of the shells that, alone on a pane, means the agent has
# gone. An EMPTY cmd is treated as a shell: unknown must fall through to the
# `ps` scan, never silently count as alive.
spool_notify_is_shell() {  # CMD
  case "${1:-}" in
    bash|sh|zsh|dash|login|'') return 0 ;;
    *) return 1 ;;
  esac
}

# ── the doorbell ────────────────────────────────────────────────────────────
# Ring TO's pane with LINE. Prints one `poke:` line. Exit codes: poke-line.md §3
# (0 poked, 5 no window, 6 refused - unsent text, 7 only shells).
#
# BODY and FROM are optional and decide WHAT the prompt is given (§1.1): with
# SPOOL_POKE_STYLE auto/body, a pane that is a TUI is typed the body VERBATIM
# instead of the poke line. The line actually chosen is left in
# SPOOL_POKE_LINE, so a caller that queues a refusal queues what it would have
# typed rather than re-deriving it.
# 0 when LINE (CSI already stripped) is real unsent input.
# A grok input row is "│ ❯ │". The trailing bar survived the trim, so every
# human message was refused while that box was on screen. Measured on the
# dev desk 2026-09-23: three notes from a human sat in the inbox and the
# retry log said the pane held unsent text; the remnant was the one character │.
spool_notify_has_unsent() {  # LINE
  local last="${1:-}" typed
  typed="${last##*❯}"
  [ "$typed" = "$last" ] && typed="${last##*> }"
  typed="${typed//[│╭╰╮╯─┌┐└┘├┤┬┴┼]/}"
  # Claude draws an empty composer as ❯, a NBSP, then DIM ghost text.
  # The dim run is removed before this runs. NBSP is not [:space:] in the
  # C locale, so the gap alone counted as typed text and every note was
  # refused. Measured on the dev desk 2026-09-23: capture-pane -e of an
  # idle Claude pane was ❯, C2 A0, ESC[2m, "hello from HUM-9", ESC[0m.
  # Two notes sat in the inbox until the retry dropped them at 300s.
  typed="${typed//$'\u00a0'/}"
  typed="${typed//$'\u200b'/}"
  typed="${typed//$'\u2009'/}"
  typed="${typed//$'\u202f'/}"
  typed="${typed//$'\ufeff'/}"
  typed="${typed#"${typed%%[![:space:]]*}"}"
  typed="${typed%"${typed##*[![:space:]]}"}"
  [ -n "$typed" ] && [ "${typed#: \'SPOOL }" = "$typed" ]
}
spool_notify_poke() {  # TO LINE [BODY] [FROM]
  local to="$1" line="$2" body="${3:-}" from="${4:-}"
  local pane pane_tty tty_cmds last alt prompt esc=$'\033'
  SPOOL_POKE_LINE="$line"

  # _var, not $( ): the subshell would fork and would lose SPOOL_PANE_TTY.
  spool_pane_of_var pane "$to"
  if [ -z "$pane" ]; then
    echo "poke: none - no live window carries ${to}; the message waits in ${SPOOL_ROOT}/${to}/inbox/"
    return 5
  fi
  spool_tmux_argv

  # A pane whose tty runs nothing but shells has lost its agent: the poke would
  # land in a bare shell (harmless, it is inert) and reach nobody. `sudo` and
  # `su` are NOT shells here: the launcher hops to the agent user through them,
  # and sudo runs the CLI on its OWN pty, so a live agent's pane tty shows just
  # "bash sudo" (measured in the 4444 dogfood: every poke to a live agent was
  # skipped while sudo was on this list).
  #
  # `ps -t` is the authority, and it is also the single most expensive thing
  # the notifier does - 78 ms of a 314 ms leg on this box, because it scans the
  # whole process table (CLE-3435). It is not needed to CONFIRM life: tmux
  # already reported the pane's foreground command in the list-panes -F
  # spool_pane_of ran, at no extra cost, and a foreground command that is not a
  # shell means the agent is there. So the scan now runs only when the cheap
  # answer is ambiguous - a shell in front, which is exactly the dead-agent
  # shape it exists to catch. A live agent pays nothing; a dead one is decided
  # by the same `ps` as before, on the same evidence.
  pane_tty="${SPOOL_PANE_TTY:-}"
  [ -n "$pane_tty" ] || pane_tty="$("${SPOOL_TM[@]}" display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null || true)"
  if spool_notify_is_shell "${SPOOL_PANE_CMD:-}" && [ -n "$pane_tty" ]; then
    tty_cmds="$(ps -t "${pane_tty#/dev/}" -o comm= 2>/dev/null | sort -u | tr '\n' ' ')"
    if [ -n "$tty_cmds" ] && ! printf '%s\n' $tty_cmds | grep -qvxE 'bash|sh|zsh|dash|login'; then
      echo "poke: skipped - ${to} pane ${pane} runs only shells (${tty_cmds% }); the agent has exited"
      return 7
    fi
  fi

  # WHAT the prompt is given. The owner's rule, 2026-09-22: "the communication
  # would be as a human would be typing into this chat textbox" - so a message
  # from a human is the human's words, nothing wrapped round them.
  #
  # Gated on `alternate_on`, and that gate is the whole safety argument. The
  # `: 'SPOOL …'` line is shell-INERT by construction; a raw body is not, and a
  # pane sitting at a shell prompt would EXECUTE it. A full-screen CLI paints
  # on the alternate screen buffer and every live agent pane on this box
  # reports 1, the one bare shell 0 (measured 2026-09-21, poke-queue lib). So
  # the verbatim body reaches a TUI input buffer, which parses nothing, and
  # never a shell.
  case "${SPOOL_POKE_STYLE:-auto}" in
    line) ;;
    body) spool_notify_render_prompt prompt "$body" ;;
    *)    spool_notify_is_human "$from" && spool_notify_render_prompt prompt "$body" ;;
  esac
  if [ -n "${prompt:-}" ]; then
    alt="$("${SPOOL_TM[@]}" display-message -p -t "$pane" '#{alternate_on}' 2>/dev/null)"
    [ "$alt" = 1 ] && line="$prompt" && SPOOL_POKE_LINE="$line"
  fi

  # Never type over a human's (or the agent's) unsent input: send-keys appends
  # to the input line and submits it, so the poke would carry that text with
  # it. The TUI's own greyed-out suggestion is drawn DIM (ESC[2m) and is not
  # input: capture WITH escapes, drop dim runs, then strip the remaining ones.
  # One pipeline, not three: the two `$(printf | sed)` passes that followed
  # were four more processes run one after another, where sed can just be the
  # last stage of the capture that already runs (CLE-3435). Same three
  # substitutions, same order.
  last="$("${SPOOL_TM[@]}" capture-pane -p -e -t "$pane" 2>/dev/null \
    | grep -E '❯|^> ' | tail -1 \
    | sed -E "s/${esc}\[2m[^${esc}]*//g; s/${esc}\[[0-9;]*[A-Za-z]//g" || true)"
  if spool_notify_has_unsent "$last"; then
    echo "poke: REFUSED - ${to} pane ${pane} holds unsent text; the message waits in its inbox"
    return 6
  fi

  # The message is already on the box websocket. A human body is pasted as
  # one bracketed paste and Enter is sent immediately: there is no notice-file
  # wait and no 0.3s debounce in front of it. send-keys -l dribbles characters
  # and needed that sleep so the CLI did not read a half line; a paste does not.
  # The shell poke line stays on send-keys, because it is one short inert line
  # and the sleep is what the existing measurements were taken around.
  if [ "${line#: \'SPOOL }" = "$line" ]; then
    # Enter before the paste is in the composer leaves the body sitting there,
    # and the next message is refused as unsent text. Wait until the words
    # are visible, then Enter. While the agent is in a turn, that Enter queues
    # the follow-up instead of sending it now.
    spool_notify_paste "$pane" "$line" \
      && spool_notify_trace notify_visible \
      && spool_notify_wait_composer "$pane" "$line" \
      && "${SPOOL_TM[@]}" send-keys -t "$pane" Enter
  else
    "${SPOOL_TM[@]}" send-keys -t "$pane" -l "$line" \
      && spool_notify_trace notify_visible \
      && sleep "${SPOOL_NOTIFY_ENTER_DELAY:-0.3}" \
      && "${SPOOL_TM[@]}" send-keys -t "$pane" Enter
  fi
  echo "poke: ${pane} (${to})"
  return 0
}


# Wait until PANE shows the start of TEXT. Capped at about 0.3s.
# Always returns 0: Enter still happens if the TUI is slow to paint.
spool_notify_wait_composer() {  # PANE TEXT
  local pane="$1" text="$2" needle i shown
  needle="${text:0:24}"
  [ -n "$needle" ] || return 0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    shown="$("${SPOOL_TM[@]}" capture-pane -p -t "$pane" 2>/dev/null || true)"
    printf '%s' "$shown" | grep -qF -- "$needle" && return 0
    sleep 0.02
  done
  return 0
}

# Paste TEXT into PANE as one bracketed paste. 0 when tmux accepted it.
spool_notify_paste() {  # PANE TEXT
  local pane="$1" text="$2" buf="spool-poke-$$" rc
  printf '%s' "$text" | "${SPOOL_TM[@]}" load-buffer -b "$buf" - || return 1
  "${SPOOL_TM[@]}" paste-buffer -p -b "$buf" -t "$pane"
  rc=$?
  "${SPOOL_TM[@]}" delete-buffer -b "$buf" 2>/dev/null || true
  return "$rc"
}

# Render and ring in one call. Same exit codes as spool_notify_poke.
spool_notify() {  # TO KIND FROM TASK MSGID BODY
  local _line
  spool_notify_render _line "$@"
  spool_notify_poke "$1" "$_line" "${6:-}" "${3:-}"
}
