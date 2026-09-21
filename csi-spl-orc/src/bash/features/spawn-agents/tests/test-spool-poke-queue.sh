#!/usr/bin/env bash
# The two halves added around the safe-poke rule (specs/028, CLE-3434):
#
#   SHOW   the notice reaches surfaces the prompt rule does not gate - a notice
#          pane split into the agent's own window, tmux's status line, and the
#          pane's tty only where no TUI owns the screen
#   DEFER  a REFUSED line is queued and re-offered until the prompt is clear,
#          so the rule delays a message instead of swallowing it
#
# Everything runs against a private tmux server and a throwaway SPOOL_ROOT.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SN="$T_SCRIPTS/spool-notify.sh"

. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
. "$T_FEAT/lib/spool-poke-queue.inc.sh"
spool_env_resolve

# ---- format injection ------------------------------------------------------
# display-message EXPANDS its argument, so a body is an injection surface.
eq "a # is doubled for tmux"      'a ## b'        "$(spool_show_escape 'a # b')"
eq "a format is neutralised"      '##{pane_tty}'  "$(spool_show_escape '#{pane_tty}')"
eq "a shell format is too"        '##(whoami)'    "$(spool_show_escape '#(whoami)')"
eq "plain text is untouched"      'hello world'   "$(spool_show_escape 'hello world')"

# ---- the queue ------------------------------------------------------------
q="$(spool_poke_queue_dir CLE-91)"
eq "the queue lives under the recipient" "$SPOOL_ROOT/CLE-91/.pokes" "$q"
e1="$(spool_poke_queue_add CLE-91 "line one")"
e2="$(spool_poke_queue_add CLE-91 "line two")"
check "an entry is a file"  test -s "$e1"
eq "it holds the line"      "line one" "$(cat "$e1")"
check "entries are distinct" test "$e1" != "$e2"
eq "they sort oldest-first" "$e1
$e2" "$(ls -1 "$q"/*.poke | sort)"
rm -f "$q"/*.poke

# ---- SHOW, against a private tmux server ----------------------------------
t_tmux
P91="$(t_window CLE-91 'sleep 600')"

# The notice pane: the persistent surface for a pane that paints a TUI. A
# `sleep` pane is on the NORMAL screen, so ask for the pane explicitly.
out="$(SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_LINES=6 spool_poke_show CLE-91 note CLE-90 T-7 M-7 'hello from the hub')"
eq "show exits 0" 0 "$?"
has "it reports a notice pane"  "notice pane"  "$out"
has "…and the status line"      "status line"  "$out"
has "…and the tty, on a normal-screen pane" "pane tty" "$out"
sleep 0.5
log="$q/notices.log"
check "the notice log exists" test -s "$log"
notice="$(cat "$log")"
has "it names the recipient, kind and sender" "SPOOL CLE-91: note from CLE-90" "$notice"
has "it names the task and the msg"           "task T-7 msg M-7"               "$notice"
has "it CARRIES the body"                     "hello from the hub"             "$notice"
has "the head is blue"                        "$(printf '\033[1;38;5;39m')"     "$notice"
has "the body is blue"                        "$(printf '\033[38;5;110m')"      "$notice"

# The pane really was split into CLE-91's own window, and marked as ours.
marks="$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}')"
has "a pane is marked for CLE-91" " CLE-91" "$marks"
np="$(printf '%s\n' "$marks" | awk '$2 == "CLE-91" {print $1; exit}')"
w_agent="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P91" '#{window_id}')"
w_notice="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$np" '#{window_id}')"
eq "it sits in the agent's OWN window" "$w_agent" "$w_notice"
check "the agent's pane still has the keyboard" \
  test "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$w_agent" '#{pane_id}')" = "$P91"

# A second notice reuses that pane rather than splitting again.
SPOOL_SHOW_PANE=1 spool_poke_show CLE-91 note CLE-90 T-8 M-8 'second' >/dev/null
eq "a second notice reuses the pane" 1 \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{@spool_notices}' | grep -c '^CLE-91$')"

# NO_COLOR is honoured.
rm -f "$log"
NO_COLOR=1 SPOOL_SHOW_PANE=1 spool_poke_show CLE-91 note CLE-90 T-9 M-9 'plain please' >/dev/null
sleep 0.3
hasnt "NO_COLOR drops every escape" "$(printf '\033')" "$(cat "$log")"
has   "…and keeps the text"         "plain please"     "$(cat "$log")"

# No window for an id: reported, never fatal.
out="$(spool_poke_show CLE-99 note CLE-90 T M 'nobody home')"; rc=$?
eq "no live window -> 5" 5 "$rc"
has "…and it says so" "no live window carries CLE-99" "$out"

# ---- DEFER: a refused line is queued, then delivered ----------------------
# A pane that holds unsent text. `cat` is not a shell, so the poke is not
# skipped as an exited agent; the prompt-like line makes it REFUSE.
rm -f "$q"/*.poke "$log"
P92="$(t_window CLE-92 'exec cat')"
tty92="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P92" '#{pane_tty}')"
printf 'welcome\r\n\xe2\x9d\xaf half typed text\r' >"$tty92"
sleep 0.4

out="$(SPOOL_SHOW_PANE=0 SPOOL_POKE_RETRY_EVERY=1 bash "$SN" --to CLE-92 --from CLE-90 --kind note \
        --task T-1 --msg-id M-1 --body 'while you were typing')"
rc=$?
eq "a busy prompt still refuses (the rule is unchanged)" 6 "$rc"
has "…and says the line was queued" "poke: queued for CLE-92" "$out"
q92="$(spool_poke_queue_dir CLE-92)"
eq "exactly one entry is queued" 1 "$(ls -1 "$q92"/*.poke 2>/dev/null | wc -l)"
has "the queued line carries the body" 'while you were typing' "$(cat "$q92"/*.poke)"
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P92")"
# The POKE line is the one that would have submitted the half-written line; a
# SHOW render on the same pane's tty is a different surface and is expected.
hasnt "the poke line was NOT typed" ": 'SPOOL CLE-92" "$screen"
has   "the unsent text is still there" 'half typed text' "$screen"

# Clear the prompt: the daemon must deliver within seconds.
printf '\r\n\xe2\x9d\xaf \r' >"$tty92"
for i in $(seq 1 40); do
  [ -z "$(ls -1 "$q92"/*.poke 2>/dev/null)" ] && break
  sleep 0.5
done
eq "the queue drains once the prompt is clear" 0 "$(ls -1 "$q92"/*.poke 2>/dev/null | wc -l)"
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P92")"
has "…and the pane now shows the message" 'while you were typing' "$screen"
has "…as the poke line"                   "SPOOL CLE-92: note from CLE-90" "$screen"

# A drained daemon ends rather than spinning, and frees its lock.
# An empty pid file would make "/proc/$pid" read "/proc", which always exists.
daemon_gone() { local pid; pid="$(cat "$q92/retry.pid" 2>/dev/null)"; [ -z "$pid" ] || [ ! -e "/proc/$pid" ]; }
for i in $(seq 1 40); do daemon_gone && break; sleep 0.5; done
check "the drained daemon exited" daemon_gone
out="$(bash "$T_SCRIPTS/spool-poke-retry.sh" --to CLE-92 --once 2>&1)"
has "an empty queue ends a new one at once" "queue is empty" "$out"

t_done
