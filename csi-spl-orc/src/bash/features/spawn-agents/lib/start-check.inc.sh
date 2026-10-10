#!/usr/bin/env bash
# start-check.inc.sh — did a freshly started claude session reach its input
# box, or is it parked on a dialog nobody will answer? (sourced, not executed)
#
#   spool_start_dialog            stdin: a screen; prints the name of a known
#                                 blocking dialog, nothing otherwise
#   spool_screen_input_box        stdin: a screen captured WITH -e; the text in
#                                 the CLI's input box, exit 1 when none is drawn
#   spool_start_check PANE WAIT CAPTURE [GONE]
#                                 polls CAPTURE PANE (a command that prints
#                                 `capture-pane -p -e` of PANE) every
#                                 START_CHECK_POLL s (default 1) up to WAIT s:
#                                 0 = the input box is drawn; 3 = a known dialog,
#                                 its name on stdout; 4 = neither within WAIT,
#                                 "no input box within <WAIT>s" on stdout;
#                                 5 = GONE PANE (a command) says the pane's
#                                 process ended first, "the pane ended ..." 
#
# Why: a start that sits on Claude's "Settings Warning" (an allow rule it
# rejects, 2026-10-07 17:29Z) never acks, and the rotation found out only
# after its 600 s ack wait (ROTATION FAILED failover ACK). Seen on the screen
# seconds after the start, the caller fails at once and names it. Nothing here
# answers a dialog: "Continue" on a Settings Warning drops a rule someone
# wrote, and "Yes" on the auto-mode offer writes defaultMode=auto.
#
# The texts, measured on claude 2.1.292 in a throwaway HOME (2026-10-07):
#   Settings Warning   "  Settings Warning" / "❯ 1. Continue"
#   trust prompt       "Quick safety check: Is this a project you created or one you trust?"
#                      / "❯ No, exit" / "Yes, I trust this folder"
#   auto-mode offer    " Make auto mode your default permission mode?"
#   not logged in      the input box IS drawn, its footer "Not logged in · Run /login"
# and, from the lease's stall pattern (LEASE_STALL_RE_DEFAULT), the usage
# limit and the login / API key failures.

# The known dialogs, "<name>|<extended regex>"; the first match wins.
SPOOL_START_DIALOGS=(
  'Settings Warning|^[[:space:]]*Settings Warning[[:space:]]*$'
  'trust prompt|Is this a project you created or one you trust|Yes, I trust this folder|Do you trust the files'
  'auto-mode offer|Make auto mode your default permission mode'
  'bypass-permissions confirm|Yes, I accept'
  'auth/login|Not logged in|Select login method|[Pp]lease run /login|Invalid API key|OAuth token (has )?expired'
  'usage limit|[Uu]sage limit reached|limit reached[[:space:]]*·|limit resets'
  'session ended|session .+ ended\. Pane kept open'
)

# spool_start_hint NAME: where to look for that dialog's cause, ", <hint>" or nothing.
spool_start_hint() {
  case "$1" in
    'Settings Warning') printf ', the allow rules in the agent user'"'"'s and the box user'"'"'s ~/.claude/settings.json' ;;
    'auto-mode offer') printf ', permissions.disableAutoMode in ~/.claude/settings.json' ;;
    'auth/login') printf ', the agent user'"'"'s claude login' ;;
  esac
}

spool_start_dialog() {
  local scr d esc=$'\033'
  scr="$(sed -E "s/${esc}\[[0-9;?]*[A-Za-z]//g")"
  for d in "${SPOOL_START_DIALOGS[@]}"; do
    if grep -qE -- "${d#*|}" <<<"$scr"; then printf '%s\n' "${d%%|*}"; return 0; fi
  done
  return 0
}

# The rows between the last two ─ rules, with the ❯ marker, the indent and the
# DIM ghost suggestion cut away. An empty box is "❯<NBSP>ESC[2mTry ...", three
# typed rows are "❯ a" / "  b" / "  c", and the slash menu draws ABOVE it
# (measured on a throwaway claude 2026-10-02).
# agy draws its running timers in a box of their own BELOW the prompt, one
# "● [17:34:10] Wait for c-844 running" row each (a-849 2026-10-10, n=1):
# those rows are skipped, and a box they alone filled is no box, so the
# prompt box above it is read. Every other row still counts.
spool_screen_input_box() {
  local esc=$'\033' nbsp=$'\302\240'
  sed -E "s/${esc}\[7m.*//; s/${esc}\[([0-9;]*;)?2m.*//; s/${esc}\[[0-9;]*[A-Za-z]//g; s/${nbsp}/ /g" |
    awk '/^ *● \[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] .* running *$/ { t = 1; next }
      /^─/ && t && n > 0 && r[n] == k { t = 0; next }
      { t = 0; l[++k] = $0 } /^─/ { r[++n] = k }
      END { if (n < 2) exit 1
        for (i = r[n - 1] + 1; i < r[n]; i++) {
          s = l[i]; sub(/^ */, "", s); sub(/^❯/, "", s); sub(/^ +/, "", s); sub(/ +$/, "", s)
          if (s != "") print s } }'
}

spool_start_check() {
  local pane="$1" wait="$2" cap="$3" gone="${4:-}" scr name t0=$SECONDS
  [[ "$wait" =~ ^[0-9]+$ ]] || { echo "the start check wait must be whole seconds, got '$wait'"; return 4; }
  while :; do
    scr="$("$cap" "$pane" 2>/dev/null || true)"
    if [[ -n "$scr" ]]; then
      # the dialog first: the not-logged-in footer shares a screen with a drawn box
      name="$(spool_start_dialog <<<"$scr")"
      [[ -n "$name" ]] && { printf '%s\n' "$name"; return 3; }
      spool_screen_input_box <<<"$scr" >/dev/null && return 0
    fi
    if [[ -n "$gone" ]] && "$gone" "$pane"; then echo "the pane ended before an input box was drawn"; return 5; fi
    (( SECONDS - t0 < wait )) || break
    sleep "${START_CHECK_POLL:-1}"
  done
  echo "no input box within ${wait}s"
  return 4
}
