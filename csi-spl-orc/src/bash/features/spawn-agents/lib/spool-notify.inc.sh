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

# ── sanitising ──────────────────────────────────────────────────────────────
# TEXT -> one line that is safe inside a single-quoted shell argument and
# cannot submit early. poke-line.md §2 fixes the order of these five steps.
spool_notify_clean() {  # TEXT
  local esc=$'\033'
  printf '%s' "${1:-}" \
    | sed -E "s/${esc}\[[0-9;?]*[A-Za-z]//g; s/${esc}[]()#%][^${esc}]*//g; s/${esc}//g" \
    | tr '\t\n\r' '   ' \
    | tr -d '\000-\010\013\014\016-\037\177' \
    | tr "'" '"' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Cut TEXT to N characters, appending " …" when it was cut.
spool_notify_cut() {  # TEXT N
  local t="${1:-}" n="${2:-600}"
  if [ "${#t}" -gt "$n" ]; then printf '%s …' "${t:0:$n}"; else printf '%s' "$t"; fi
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

# ── the doorbell ────────────────────────────────────────────────────────────
# Ring TO's pane with LINE. Prints one `poke:` line. Exit codes: poke-line.md §3
# (0 poked, 5 no window, 6 refused - unsent text, 7 only shells).
spool_notify_poke() {  # TO LINE
  local to="$1" line="$2" pane pane_tty tty_cmds last typed esc=$'\033'

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
  # spool_pane_of asked tmux for this pane's tty in the SAME list-panes -F it
  # used to find the pane, so the tmux round trip a `display-message -p
  # '#{pane_tty}'` costs here is already paid (CLE-3435); it is only asked for
  # when a caller resolved the pane some other way.
  pane_tty="${SPOOL_PANE_TTY:-}"
  [ -n "$pane_tty" ] || pane_tty="$("${SPOOL_TM[@]}" display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null || true)"
  if [ -n "$pane_tty" ]; then
    tty_cmds="$(ps -t "${pane_tty#/dev/}" -o comm= 2>/dev/null | sort -u | tr '\n' ' ')"
    if [ -n "$tty_cmds" ] && ! printf '%s\n' $tty_cmds | grep -qvxE 'bash|sh|zsh|dash|login'; then
      echo "poke: skipped - ${to} pane ${pane} runs only shells (${tty_cmds% }); the agent has exited"
      return 7
    fi
  fi

  # Never type over a human's (or the agent's) unsent input: send-keys appends
  # to the input line and submits it, so the poke would carry that text with
  # it. The TUI's own greyed-out suggestion is drawn DIM (ESC[2m) and is not
  # input: capture WITH escapes, drop dim runs, then strip the remaining ones.
  last="$("${SPOOL_TM[@]}" capture-pane -p -e -t "$pane" 2>/dev/null | grep -E '❯|^> ' | tail -1 || true)"
  last="$(printf '%s' "$last" | sed -E "s/${esc}\[2m[^${esc}]*//g; s/${esc}\[[0-9;]*[A-Za-z]//g")"
  typed="$(printf '%s' "$last" | sed -E 's/^.*(❯|^>) ?//; s/[[:space:]]+$//')"
  if [ -n "$last" ] && [ -n "$typed" ] && [ "${typed#: \'SPOOL }" = "$typed" ]; then
    echo "poke: REFUSED - ${to} pane ${pane} holds unsent text; the message waits in its inbox"
    return 6
  fi

  # The line lands on the agent's SCREEN with this call: that is the instant
  # the delivery+visible budget is measured to (CLE-3435). The gap that
  # follows is the TUI's paste debounce, not visibility - submit too early
  # and the CLI reads a half-typed line - so it is bounded and tunable
  # rather than removed, and it is deliberately NOT part of the number.
  "${SPOOL_TM[@]}" send-keys -t "$pane" -l "$line" \
    && sleep "${SPOOL_NOTIFY_ENTER_DELAY:-0.3}" \
    && "${SPOOL_TM[@]}" send-keys -t "$pane" Enter
  echo "poke: ${pane} (${to})"
  return 0
}

# Render and ring in one call. Same exit codes as spool_notify_poke.
spool_notify() {  # TO KIND FROM TASK MSGID BODY
  local _line
  spool_notify_render _line "$@"
  spool_notify_poke "$1" "$_line"
}
