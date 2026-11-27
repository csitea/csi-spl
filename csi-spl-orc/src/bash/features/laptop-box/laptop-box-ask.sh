#!/usr/bin/env bash
#------------------------------------------------------------------------------
# laptop-box-ask.sh - the end-of-hours question on the member's own desktop
# (SPL-6680, spec 037 "Laptop box"; the DSK answer of form 3d4ecf66, 5a).
# Runs in HER graphical session every minute (a global systemd user timer
# with ConditionUser=<her>, installed root-owned by do_spl_laptop_box_install
# as /usr/local/lib/spl-laptop-box/ask.sh). When the tick has left a question
# (ask-pending) and no answer yet, it shows one pop-up with two buttons,
# "Continue 1 h" and "Stop", and writes her click to the state dir's answer
# file: "continue <epoch>" or "stop <epoch>". A pop-up she closes writes
# nothing: after 15 min without an answer the tick moves the agents anyway.
# Env (tests): SPOOL_ROOT, LAPTOP_STATE_DIR, LAPTOP_NOTIFY (default
# notify-send), LAPTOP_NOW.
#------------------------------------------------------------------------------
set -uo pipefail
D="${LAPTOP_STATE_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/laptop-box}"
[[ -s "$D/ask-pending" && ! -e "$D/answer" ]] || exit 0
a="$(${LAPTOP_NOTIFY:-notify-send} --app-name='Fleet agents' --urgency=critical --wait \
  --action=continue='Continue 1 h' --action=stop='Stop' \
  'Your working hours are over' "$(cat "$D/ask-pending")" 2>/dev/null)"
case "$a" in
  continue|stop) printf '%s %s\n' "$a" "${LAPTOP_NOW:-$(date +%s)}" >"$D/answer" ;;
esac
exit 0
