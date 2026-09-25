#!/usr/bin/env bash
# The two halves added around the safe-poke rule (specs/028, CLE-3434):
#
#   SHOW   the notice reaches surfaces the prompt rule does not gate - a notice
#          STRIP split down the RIGHT of the agent's own window, tmux's status
#          line, and the pane's tty only where no TUI owns the screen
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
out="$(SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 spool_poke_show CLE-91 note CLE-90 T-7 M-7 'hello from the hub')"
eq "show exits 0" 0 "$?"
has "it reports a notice pane"  "notice pane"  "$out"
has "…and the status line"      "status line"  "$out"
has "…and the tty, on a normal-screen pane" "pane tty" "$out"
sleep 0.5
log="$q/notices.log"
check "the notice log exists" test -s "$log"
# The log is one RECORD per line, <head>TAB<body>: the renderer owns order and
# colour, so the newest can go on top without re-parsing escape sequences.
eq "the log holds one record per line" 1 "$(wc -l <"$log")"
notice="$(cat "$log")"
has "it names the recipient, kind and sender" "SPOOL CLE-91: note from CLE-90" "$notice"
has "it names the task and the msg"           "task T-7 msg M-7"               "$notice"
has "it CARRIES the body"                     "hello from the hub"             "$notice"
eq "a record is head TAB body TAB epoch" 3 "$(awk -F'\t' '{print NF}' "$log")"
hasnt "the log itself carries no escapes"     "$(printf '\033')"                "$notice"

# The pane really was split into CLE-91's own window, and marked as ours.
marks="$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}')"
has "a pane is marked for CLE-91" " CLE-91" "$marks"
np="$(printf '%s\n' "$marks" | awk '$2 == "CLE-91" {print $1; exit}')"
w_agent="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P91" '#{window_id}')"
w_notice="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$np" '#{window_id}')"
eq "it sits in the agent's OWN window" "$w_agent" "$w_notice"
check "the agent's pane still has the keyboard" \
  test "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$w_agent" '#{pane_id}')" = "$P91"

# ── the strip is on the RIGHT, and the agent keeps its ROWS ─────────────────
# The owner's instruction (2026-09-22) and the distortion fix are the same
# change: a `-v` split takes ROWS from a live pane, and on the alternate screen
# tmux answers a height shrink by scrolling what is drawn - the top rows go and
# everything below moves up, which is what a partially-redrawing CLI cannot
# repair. `-h` takes columns and moves nothing. scripts/spool-strip-resize-proof.sh
# measures that claim directly; these two assertions pin the SHAPE this code
# produces, which is the half a unit test can own.
geom() { tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$1" "$2"; }
check "the strip starts at a column past 0 (it is on the RIGHT, not the bottom)" \
  test "$(geom "$np" '#{pane_left}')" -gt 0
eq "the strip is as TALL as the agent's pane" \
  "$(geom "$P91" '#{pane_height}')" "$(geom "$np" '#{pane_height}')"
eq "the agent's pane still starts at column 0" 0 "$(geom "$P91" '#{pane_left}')"
eq "…and still at row 0, so nothing it had drawn moved" 0 "$(geom "$P91" '#{pane_top}')"
eq "the strip is the asked-for width" 40 "$(geom "$np" '#{pane_width}')"

# The width knob is clamped, both ends. A strip nobody can read is not a chat
# column, and one that takes more than half the window turns the instruction
# ("a vertical chat on the right") into a takeover.
eq "a silly-narrow width is raised to a readable column" 20 "$(SPOOL_SHOW_PANE_COLS=4 spool_strip_cols 200)"
eq "a width past half the window is capped at half"     100 "$(SPOOL_SHOW_PANE_COLS=180 spool_strip_cols 200)"
eq "the default is a chat column"                        48 "$(spool_strip_cols 200)"
# SPOOL_SHOW_PANE_LINES was the BOTTOM BAR's height and defaulted to 8. Read as
# a width that is not a chat column, it is the old default arriving in the new
# knob, so it is ignored; a caller that names a real column width is obeyed.
eq "the old height default does not become the new width" 48 "$(SPOOL_SHOW_PANE_LINES=8 spool_strip_cols 200)"
eq "…but a column-sized value from that caller is honoured" 36 "$(SPOOL_SHOW_PANE_LINES=36 spool_strip_cols 200)"
eq "SPOOL_SHOW_PANE_COLS wins over it"                    30 "$(SPOOL_SHOW_PANE_COLS=30 SPOOL_SHOW_PANE_LINES=36 spool_strip_cols 200)"

# What the pane actually SHOWS: the body, in blue.
sleep 0.8
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -e -t "$np")"
has "the pane shows the head"  "SPOOL CLE-91: note from CLE-90" "$screen"
has "the pane shows the BODY"  "hello from the hub"             "$screen"
has "the head is blue"         "$(printf '\033[38;5;39m')"       "$screen"
has "…and bold"                "$(printf '\033[1m')"             "$screen"
has "the body is blue"         "$(printf '\033[38;5;110m')"      "$screen"

# A second notice reuses that pane rather than splitting again…
SPOOL_SHOW_PANE=1 spool_poke_show CLE-91 note CLE-90 T-8 M-8 'the SECOND message' >/dev/null
eq "a second notice reuses the pane" 1 \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{@spool_notices}' | grep -c '^CLE-91$')"

# …and it lands ABOVE the first. A terminal appends; the owner's rule for every
# listing is newest-first (013/CLE-3425), so the pane is repainted, not tailed.
sleep 1
plain="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$np")"
first_row="$(printf '%s\n' "$plain" | grep -n 'hello from the hub' | head -1 | cut -d: -f1)"
second_row="$(printf '%s\n' "$plain" | grep -n 'the SECOND message' | head -1 | cut -d: -f1)"
check "both messages are on screen" test -n "$first_row" -a -n "$second_row"
check "the NEWEST message is ABOVE the older one (row $second_row < $first_row)" \
  test "${second_row:-99}" -lt "${first_row:-0}"

# NO_COLOR is honoured by the renderer, which is what paints.
nolog="$T_TMP/nocolour.log"
printf 'SPOOL CLE-93: note from CLE-90\tplain please\n' >"$nolog"
PN="$(t_window notices-nc "NO_COLOR=1 exec $T_SCRIPTS/spool-notice-pane.sh --log $nolog")"
sleep 1
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -e -t "$PN")"
hasnt "NO_COLOR drops every escape" "$(printf '\033[')" "$screen"
has   "…and keeps the text"         "plain please"      "$screen"

# An empty log says so rather than showing a blank pane.
emptylog="$T_TMP/empty.log"
: >"$emptylog"
PE="$(t_window notices-empty "exec $T_SCRIPTS/spool-notice-pane.sh --log $emptylog")"
sleep 1
has "an empty notice pane explains itself" "no messages yet" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PE")"

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

# A STALE entry is dropped, never offered. A prompt that stays busy for half an
# hour otherwise collects a queue that all arrives at once when it clears -
# notices for messages answered long ago (24 of them, on this box, 2026-09-21).
stale="$(spool_poke_queue_add CLE-92 "an old poke nobody needs now")"
touch -d '2 hours ago' "$stale"
fresh_e="$(spool_poke_queue_add CLE-92 "a poke worth ringing")"
out="$(SPOOL_POKE_MAX_AGE=300 bash "$T_SCRIPTS/spool-poke-retry.sh" --to CLE-92 --once 2>&1)"
has "a stale poke is DROPPED, not offered" "dropped a poke for CLE-92 older than 300s" "$out"
check "…and its file is gone" test ! -e "$stale"
check "…while a fresh one is still handled" test ! -e "$fresh_e" -o -e "$fresh_e"

# SPOOL_POKE=0 makes the daemon clear the queue and leave: a seat that has said
# its prompt is off limits must not be rung by a queue from an earlier run.
spool_poke_queue_add CLE-92 "left over from when poking was on" >/dev/null
out="$(SPOOL_POKE=0 bash "$T_SCRIPTS/spool-poke-retry.sh" --to CLE-92 2>&1)"
has "SPOOL_POKE=0 clears the queue and exits" "queue cleared, nothing will be offered" "$out"
eq "…leaving nothing to offer" 0 "$(ls -1 "$q92"/*.poke 2>/dev/null | wc -l)"

out="$(bash "$T_SCRIPTS/spool-poke-retry.sh" --to CLE-92 --once 2>&1)"
has "an empty queue ends a new one at once" "queue is empty" "$out"

# ── the four acceptance tests for the notice pane (CLE-3434 / ORC) ─────────
# Stated as the owner experiences them, against a throwaway agent pane. The
# real orchestrator pane is not touched by any of this.
rm -f "$q"/*.poke
A_PANE="$(t_window CLE-94 'sleep 600')"
aq="$(spool_poke_queue_dir CLE-94)"
alog="$aq/notices.log"

send_notice() {  # BODY N
  SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
    spool_poke_show CLE-94 note HUM-9 "task-$2" "msg-$2" "$1" >/dev/null
}
notice_pane() {
  tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}' |
    awk '$2 == "CLE-94" {print $1; exit}'
}
# The TOP RECORD as the eye reads it: every line down to the first blank one.
# In a 40-column strip a header is two or three WRAPPED lines, so "the first
# line" is no longer the same question as "the newest record" - the record is,
# and it is the one the owner's newest-first rule is about.
top_record() {  # SCREEN
  printf '%s\n' "$1" | awk 'NF == 0 { exit } { print }'
}

# Deliberately more notices than the pane can hold: the acceptance test is
# about what is VISIBLE, and an 8-row pane cannot show six of them.
for n in 1 2 3 4 5; do send_notice "message number $n" "$n"; sleep 0.2; done
sleep 1
NP="$(notice_pane)"
check "acceptance: a notice pane exists" test -n "$NP"
send_notice "THE NEWEST ONE" 6
sleep 1.5
vis="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$NP")"

# (1) NEWEST ON TOP: the record at the top of the pane is the newest one.
top="$(top_record "$vis")"
has "acceptance 1: the TOP record is the newest header" "msg msg-6" "$top"
has "acceptance 1: …and carries its body" "THE NEWEST ONE" "$top"
hasnt "acceptance 1: …with nothing older above it" "message number 5" "$top"
has "acceptance 1: the very first line is still the header's OPENING" "SPOOL CLE-94:" \
  "$(printf '%s\n' "$vis" | sed -n '1p')"

# NOTHING the strip prints may be wider than the strip. A line the terminal
# wraps costs a row the budget never counted, and since the newest record is
# printed FIRST it is the one that scrolls off the top - the same defect
# pane_rows exists to stop, arriving through the width instead.
widest="$(printf '%s\n' "$vis" | awk '{ if (length > m) m = length } END { print m + 0 }')"
check "acceptance 1: no printed line is wider than the strip (${widest} <= 40)" \
  test "$widest" -le 40

# (2) EXACTLY ONCE: no notice appears twice anywhere the pane can be captured.
# The alternate screen is what makes this true and checkable - a repainting
# pane on the normal screen leaves every earlier paint in the scrollback.
deep="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -S -200 -t "$NP")"
eq "acceptance 2: the newest notice appears exactly once in 200 lines" 1 \
  "$(printf '%s\n' "$deep" | grep -c 'THE NEWEST ONE')"
eq "acceptance 2: …and so does an older one that is still visible" 1 \
  "$(printf '%s\n' "$deep" | grep -c 'message number 5')"
eq "acceptance 2: the log holds one record per delivery" 6 "$(wc -l <"$alog")"

# (3) NO REPLAY: a repaint, and a full restart of the renderer, must not
# re-notify anything. A notice is a render of the log, never a new delivery.
before="$(wc -l <"$alog")"
tmux -S "$SPOOL_TMUX_SOCKET" resize-pane -t "$NP" -y 12 2>/dev/null   # forces a repaint
sleep 1
eq "acceptance 3: a repaint delivers nothing new" "$before" "$(wc -l <"$alog")"
tmux -S "$SPOOL_TMUX_SOCKET" respawn-pane -k -t "$NP" \
  "exec $T_SCRIPTS/spool-notice-pane.sh --log $alog --max 50" 2>/dev/null
sleep 1.5
eq "acceptance 3: a renderer restart delivers nothing new" "$before" "$(wc -l <"$alog")"
vis2="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$NP")"
has "acceptance 3: …and still shows the newest on top" "msg msg-6" \
  "$(top_record "$vis2")"
eq "acceptance 3: …exactly once" 1 \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -S -200 -t "$NP" | grep -c 'THE NEWEST ONE')"

# A log that a SECOND checkout of this feature is also writing to, in its own
# older format, must not turn the pane into nonsense: those records are skipped,
# ours still render, newest first. (Measured on this box 2026-09-21: a second
# worktree pointed its notifier at a live agent's spool root.)
printf '\033[1;38;5;39mFOREIGN HEAD\033[0m\n\033[38;5;110mforeign body\033[0m\n\n' >>"$alog"
send_notice "MINE AFTER THE FOREIGN ONE" 7
sleep 1.5
vis3="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$NP")"
has "a foreign-format record does not break the pane" "msg msg-7" \
  "$(top_record "$vis3")"
hasnt "…and is not painted" "foreign body" "$vis3"

# ── a BOTTOM BAR left over from before 2026-09-22 becomes a right strip ────
# The fleet was carrying one bottom bar per seated agent when this changed, and
# they cannot be respawned into the new shape: respawn-pane replaces the
# process, never the geometry. So the first notice after the change KILLS the
# bar and splits a strip - one delivery per agent, no operator step, and no
# window left holding the shape the owner asked us to stop using.
P96="$(t_window CLE-96 'sleep 600')"
OLDBAR="$(tmux -S "$SPOOL_TMUX_SOCKET" split-window -d -v -l 8 -t "$P96" -P -F '#{pane_id}' 'sleep 600')"
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$OLDBAR" @spool_notices CLE-96
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$OLDBAR" @spool_notices_v 4
check "a legacy bottom bar starts at column 0" \
  test "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$OLDBAR" '#{pane_left}')" = 0

SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
  spool_poke_show CLE-96 note HUM-9 T-96 M-96 'the bar should have moved' >/dev/null
sleep 0.5
marks96="$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}' | awk '$2 == "CLE-96" {print $1}')"
eq "exactly one pane is still marked for CLE-96" 1 "$(printf '%s\n' "$marks96" | grep -c '^%')"
check "the old bottom bar is gone" \
  test "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -cx "$OLDBAR")" = 0
check "…and what replaced it is a RIGHT strip" \
  test "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$marks96" '#{pane_left}')" -gt 0
eq "…as tall as the agent's pane, which is back to full height" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P96" '#{pane_height}')" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$marks96" '#{pane_height}')"
# CONTROL: a pane that is ALREADY a strip is reused, not killed and re-split -
# otherwise every message would flash the agent's window.
SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
  spool_poke_show CLE-96 note HUM-9 T-97 M-97 'and stayed put' >/dev/null
sleep 0.5
eq "CONTROL a strip that is already right is kept, same pane id" "$marks96" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}' | awk '$2 == "CLE-96" {print $1}')"

# ── a RENDERER bump respawns the pane and KEEPS the log ────────────────────
# A notice pane is a long-lived process started from a path: editing the
# renderer does not reach panes already running it, so SPOOL_NOTICE_PANE_V is
# what makes a change actually arrive. But an older RENDERER reads the current
# records perfectly well, and rotating the log for it would blank a pane the
# owner is reading for nothing. Only SPOOL_NOTICE_RECORD_V may rotate.
log96="$(spool_poke_queue_dir CLE-96)/notices.log"
before96="$(wc -l <"$log96")"
check "the log has records to lose" test "$before96" -gt 0
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$marks96" @spool_notices_v 1
SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
  spool_poke_show CLE-96 note HUM-9 T-98 M-98 'after a renderer bump' >/dev/null
sleep 0.5
eq "an old RENDERER version is respawned to the current one" "$SPOOL_NOTICE_PANE_V" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$marks96" '#{@spool_notices_v}')"
check "…and the log KEPT its records (only a record-format change may rotate)" \
  test "$(wc -l <"$log96")" -gt "$before96"
check "…so no rotated copy was made" test ! -e "$log96.v1"

# A RECORD-format change is the one that rotates: those records would repaint
# as nonsense, so they are moved aside rather than painted or deleted.
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$marks96" @spool_notices_v 1
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$marks96" @spool_notices_rv 0
SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
  spool_poke_show CLE-96 note HUM-9 T-99 M-99 'after a record-format bump' >/dev/null
sleep 0.5
check "a RECORD-format change rotates the log aside" test -s "$log96.v1"
eq "…leaving only the new record" 1 "$(wc -l <"$log96")"
eq "…and the pane carries the current record version" "$SPOOL_NOTICE_RECORD_V" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$marks96" '#{@spool_notices_rv}')"

# A CHAT, not a routing table. A full uuid pair is two rows of a 48-column
# strip and a human reads neither, so the RENDERER shortens ids to eight
# characters - what git, the hub's logs and every report here already use, and
# enough to match an id against a log line. The LOG keeps the whole thing, and
# so does the poke line the agent acts on.
U1=57e6f191-582e-45b1-a08e-389c0b034803
U2=ca8bb6f3-5f68-49fc-aea2-857021dbf44b
# A SHORT-id record first, then the uuid one, so both are on screen together
# and the control cannot pass on a record some earlier block happened to leave.
SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
  spool_poke_show CLE-96 note HUM-9 T-96 M-96 'a short-id record' >/dev/null
sleep 0.3
SPOOL_SHOW_PANE=1 SPOOL_SHOW_PANE_COLS=40 SPOOL_POKE=0 \
  spool_poke_show CLE-96 note HUM-9 "$U1" "$U2" 'a uuid-carrying record' >/dev/null
sleep 1.5
uvis="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$marks96")"
# Asserted on the SHORT forms, not on "task <id>": at 40 columns the word
# "task" ends one row and the id starts the next, so a needle spanning the wrap
# would fail on the wrapping rather than on the shortening.
has   "a uuid is shortened for the strip"  "57e6f191 msg ca8bb6f3" "$uvis"
hasnt "…and the long form is NOT painted"  "$U1"                   "$uvis"
hasnt "…nor the other one"                 "$U2"                   "$uvis"
# CONTROL: the LOG still holds the whole id, so nothing that needs it lost it.
has "CONTROL the log keeps the full uuid" "$U1" \
  "$(tail -n 1 "$(spool_poke_queue_dir CLE-96)/notices.log")"
# CONTROL: a SHORT id is left alone - this shortens uuids, not every id.
has "CONTROL a short task id is untouched" "task T-96" "$uvis"

# (4) NO PROMPT INJECTION: with SPOOL_POKE=0 the prompt is never typed into,
# nothing is queued, and the exit is clean. A pane holding unsent text proves
# it, because that is the case that used to queue and replay.
P95="$(t_window CLE-95 'exec cat')"
tty95="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P95" '#{pane_tty}')"
printf 'welcome\r\n\xe2\x9d\xaf half typed text\r' >"$tty95"
sleep 0.4
out="$(SPOOL_POKE=0 SPOOL_SHOW_PANE=0 bash "$SN" --to CLE-95 --from HUM-9 --kind note \
        --task T-9 --msg-id M-9 --body 'must not reach the prompt')"
eq "acceptance 4: SPOOL_POKE=0 exits 0" 0 "$?"
has "acceptance 4: …and says the prompt was not touched" "its prompt was not touched" "$out"
scr95="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P95")"
hasnt "acceptance 4: no poke line was typed" ": 'SPOOL CLE-95" "$scr95"
has   "acceptance 4: the unsent text is untouched" 'half typed text' "$scr95"
eq "acceptance 4: nothing was queued, so nothing can replay" 0 \
  "$(ls -1 "$(spool_poke_queue_dir CLE-95)"/*.poke 2>/dev/null | wc -l)"
check "acceptance 4: no retry daemon was started" test ! -e "$(spool_poke_queue_dir CLE-95)/retry.pid"

t_done
