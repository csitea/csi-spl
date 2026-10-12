#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the owner acceptance cases of the NOTICE pane (spec 031 OA-10..13,
#          spec 028), driven through the real notifier (spool-notify.sh) and
#          the real renderer (spool-notice-pane.sh) on a PRIVATE tmux server
#          and a throwaway spool root (SPOOL_TEST=1). The box tmux, the live
#          spool root and $HOME are never touched.
#   OA-10 the NEWEST notice is the FIRST visible line of the notice pane.
#         CONTROL: the same check rejects a pane that merely tails the log
#   OA-11 each notice is rendered EXACTLY ONCE, and is not re-notified by a
#         repaint (resize), a restart of the renderer, or the next delivery
#         after a stale renderer is respawned. CONTROL: a planted duplicate
#         record is counted twice, so "once" is a measurement
#   OA-12 the notice lands in the NOTICE pane and the show half types nothing
#         into the agent's own prompt (SPOOL_POKE=0, and a per-agent .no-poke
#         with the poke on). CONTROL: with the poke on and no marker the
#         doorbell DOES type (028 FR-009), so the typed-input detector works
#   OA-13 inbound notices are BLUE (CONTROL: an outbound record is not), and
#         the history is bounded: the log is trimmed to --max and the pane
#         shows no record past it. CONTROL: under the bound nothing is trimmed
# Needs a real tmux; without one this FAILS (a skipped pane test proves nothing).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

FEAT="$PROJ_ROOT/src/bash/features/spawn-agents"
SN="$FEAT/scripts/spool-notify.sh"
PANE_SH="$FEAT/scripts/spool-notice-pane.sh"

# A run from inside a live agent's pane inherits its tmux, pane and id.
unset TMUX TMUX_PANE MCP_BOT_AGENT_ID SPOOL_AGENT_ID SPOOL_NOTIFY_CMD NO_COLOR SPOOL_POKE
export SPOOL_ROOT="$T/spool" SPOOL_TMUX_SOCKET="$T/tmux.sock" SPOOL_BOX_TAG=""
SPOOL_BOX_USER="$(id -un)"; SPOOL_AGENT_USER="$SPOOL_BOX_USER"
export SPOOL_BOX_USER SPOOL_AGENT_USER
# No retry daemon may outlive the test: a refused poke would start one.
export SPOOL_POKE_RETRY_CMD="$T/no-retry"
mkdir -p "$SPOOL_ROOT"

TM=(tmux -u -S "$SPOOL_TMUX_SOCKET")
if ! command -v tmux >/dev/null 2>&1; then
  fail "no tmux on PATH: the notice pane cases did not run and prove nothing"
  echo "---- $(basename "$0"): $fails failed"; exit 1
fi
"${TM[@]}" -f /dev/null new-session -d -s t -n home -x 200 -y 50 'sleep 600' ||
  { fail "could not start a private tmux server"; exit 1; }
trap '"${TM[@]}" kill-server 2>/dev/null; rm -rf "$T"' EXIT

# An agent window: a pane marked as a TUI (@spool_strip 1, as the launcher
# marks it) whose program records every byte typed into it.
agent() {  # ID -> pane id
  local p
  p="$("${TM[@]}" new-window -d -t t: -n "$1" -P -F '#{pane_id}' "cat >'$T/typed.$1'")"
  "${TM[@]}" set-option -p -t "$p" @spool_strip 1
  printf '%s' "$p"
}
strip_of() {  # ID -> the notice pane marked for it
  "${TM[@]}" list-panes -a -F '#{pane_id} #{@spool_notices}' | awk -v id="$1" '$2 == id { print $1; exit }'
}
notify() {  # ID N [ENV=VAL ...]   one note from c-900, msg M-N
  local id="$1" n="$2"; shift 2
  env "$@" bash "$SN" --to "$id" --from c-900 --kind note --task T-1 --msg-id "M-$n" \
    --body "notice body $n" >>"$T/notify.log" 2>&1
}
cap() { "${TM[@]}" capture-pane -p -t "$1" 2>/dev/null; }
# Wait until PANE shows TEXT: the renderer repaints from tail -F, asynchronously.
wait_for() {  # PANE TEXT
  local i
  for (( i = 0; i < 50; i++ )); do
    cap "$1" | grep -F -- "$2" >/dev/null && return 0
    sleep 0.1
  done
  return 1
}
# The ids of the HEAD lines on screen, top to bottom.
heads() { cap "$1" | grep -oE 'msg [A-Z]-[0-9]+' | awk '{print $2}' | paste -sd' '; }
first_line() { cap "$1" | awk 'NF { print; exit }'; }
# How many times msg ID appears anywhere in PANE, scrollback included.
copies() { "${TM[@]}" capture-pane -p -S -500 -t "$1" | grep -cE "msg $2( |\$)"; }

# --- OA-10 the newest notice is the first visible line ------------------------
agent c-901 >/dev/null
for n in 1 2 3; do notify c-901 "$n" SPOOL_POKE=0; done
S="$(strip_of c-901)"
if [[ -n "$S" ]] && wait_for "$S" 'msg M-3'; then
  pass "OA-10 a notice strip ($S) was split into c-901's window and painted"
else
  fail "OA-10 no notice strip painted for c-901: $(cat "$T/notify.log")"
fi
[[ "$(first_line "$S")" == *"SPOOL c-901: note from c-900 task T-1 msg M-3"* ]] &&
  pass "OA-10 the FIRST visible line is the newest notice's head (M-3)" ||
  fail "OA-10 the first line is not the newest notice: '$(first_line "$S")'"
[[ "$(heads "$S")" == "M-3 M-2 M-1" ]] &&
  pass "OA-10 the notices read newest first: M-3 M-2 M-1" ||
  fail "OA-10 order on screen: '$(heads "$S")'"
# CONTROL: a pane that just tails the same log (a terminal appends) puts the
# OLDEST first, and the same checks must reject it.
LOG="$SPOOL_ROOT/c-901/.pokes/notices.log"
TAILP="$("${TM[@]}" new-window -d -t t: -n tailctl -P -F '#{pane_id}' "tail -n +1 -f '$LOG'")"
wait_for "$TAILP" 'msg M-3' >/dev/null
[[ "$(first_line "$TAILP")" != *"msg M-3"* && "$(heads "$TAILP")" == "M-1 M-2 M-3" ]] &&
  pass "OA-10 CONTROL a tailing pane shows M-1 first, and the newest-first check rejects it" ||
  fail "OA-10 CONTROL the check cannot tell a tail from the strip: '$(heads "$TAILP")'"

# --- OA-11 exactly once, across repaint / restart / respawn --------------------
once_each() {  # PANE LABEL
  local n c bad=""
  for n in M-1 M-2 M-3; do c="$(copies "$1" "$n")"; [[ "$c" == 1 ]] || bad+=" $n=$c"; done
  [[ -z "$bad" ]] && pass "OA-11 $2: each notice is on the pane exactly once, scrollback included" ||
    fail "OA-11 $2: copies off:$bad"
}
[[ "$(grep -c . "$LOG")" == 3 ]] && pass "OA-11 three deliveries wrote three records, one each" ||
  fail "OA-11 the log holds $(grep -c . "$LOG") records for 3 deliveries"
once_each "$S" "after three deliveries"
# repaint: each resize is a SIGWINCH repaint
for w in 40 60 48; do "${TM[@]}" resize-pane -t "$S" -x "$w" 2>/dev/null; sleep 0.3; done
wait_for "$S" 'msg M-3' >/dev/null
once_each "$S" "after three repaints"
# restart: the renderer is restarted in place and re-reads the log from the top
CMD="$("${TM[@]}" display-message -p -t "$S" '#{pane_start_command}')"
CMD="${CMD#\"}"; CMD="${CMD%\"}"
"${TM[@]}" respawn-pane -k -t "$S" "$CMD"
sleep 0.5; wait_for "$S" 'msg M-3' >/dev/null
once_each "$S" "after a renderer restart"
# reconnect: a strip running a stale renderer is respawned by the next delivery
"${TM[@]}" set-option -p -t "$S" @spool_notices_v 0
notify c-901 4 SPOOL_POKE=0
wait_for "$S" 'msg M-4' >/dev/null
[[ "$(strip_of c-901)" == "$S" && "$(heads "$S")" == "M-4 M-3 M-2 M-1" ]] &&
  pass "OA-11 the next delivery respawned the stale strip in place: M-4 on top, nothing replayed" ||
  fail "OA-11 after the respawn: strip $(strip_of c-901), heads '$(heads "$S")'"
once_each "$S" "after the respawn"
[[ "$(copies "$S" M-4)" == 1 && "$(grep -c . "$LOG")" == 4 ]] &&
  pass "OA-11 the new notice is painted once and logged once (4 records)" ||
  fail "OA-11 M-4 copies $(copies "$S" M-4), records $(grep -c . "$LOG")"
# CONTROL: a duplicate record (two writers for one delivery) IS counted twice.
grep -m1 'msg M-2' "$LOG" >>"$LOG"
for (( i = 0; i < 30; i++ )); do [[ "$(copies "$S" M-2)" == 2 ]] && break; sleep 0.1; done
[[ "$(copies "$S" M-2)" == 2 ]] &&
  pass "OA-11 CONTROL a planted duplicate record shows twice, so 'exactly once' is measured" ||
  fail "OA-11 CONTROL the duplicate was not seen ($(copies "$S" M-2)): the once-check proves nothing"

# --- OA-12 the notice goes to the notice pane, never into the prompt -----------
B="$(agent c-902)"
notify c-902 1 SPOOL_POKE=0
SB="$(strip_of c-902)"
[[ -n "$SB" ]] && wait_for "$SB" 'msg M-1' &&
  pass "OA-12 SPOOL_POKE=0: the notice is in c-902's NOTICE pane ($SB)" ||
  fail "OA-12 SPOOL_POKE=0: no notice in a strip for c-902"
sleep 0.3
[[ ! -s "$T/typed.c-902" ]] && ! cap "$B" | grep 'notice body' >/dev/null &&
  pass "OA-12 SPOOL_POKE=0: nothing was typed into c-902's prompt" ||
  fail "OA-12 SPOOL_POKE=0: c-902's prompt got input: '$(cat "$T/typed.c-902" 2>/dev/null)'"
C="$(agent c-903)"
mkdir -p "$SPOOL_ROOT/c-903"; touch "$SPOOL_ROOT/c-903/.no-poke"
notify c-903 1 SPOOL_POKE=1
SC="$(strip_of c-903)"
[[ -n "$SC" ]] && wait_for "$SC" 'msg M-1' &&
  pass "OA-12 .no-poke with the poke ON: the notice is in c-903's NOTICE pane" ||
  fail "OA-12 .no-poke: no notice in a strip for c-903"
sleep 0.3
[[ ! -s "$T/typed.c-903" ]] && ! cap "$C" | grep 'notice body' >/dev/null &&
  pass "OA-12 .no-poke with the poke ON: nothing was typed into c-903's prompt" ||
  fail "OA-12 .no-poke: c-903's prompt got input: '$(cat "$T/typed.c-903" 2>/dev/null)'"
# CONTROL: the doorbell with the poke on and no marker DOES type (028 FR-009),
# so an empty typed file above is evidence and not a broken detector.
agent c-904 >/dev/null
notify c-904 1 SPOOL_POKE=1
for (( i = 0; i < 30; i++ )); do [[ -s "$T/typed.c-904" ]] && break; sleep 0.1; done
grep -q 'notice body 1' "$T/typed.c-904" 2>/dev/null &&
  pass "OA-12 CONTROL with the poke on, c-904's prompt received the line: the detector sees typing" ||
  fail "OA-12 CONTROL the poke typed nothing ($(tail -2 "$T/notify.log")): the detector proves nothing"

# --- OA-13 blue, and bounded ----------------------------------------------------
line_of() { "${TM[@]}" capture-pane -e -p -t "$1" | grep -F -- "$2" | sed -n 1p; }
blue="$(line_of "$S" 'msg M-4')"
[[ "$blue" == *"38;5;39m"* ]] &&
  pass "OA-13 an inbound notice head is painted BLUE (SGR 38;5;39)" ||
  fail "OA-13 the inbound head is not blue: $(printf '%q' "$blue")"
# CONTROL: an outbound record (this agent SENT it) is painted in another colour.
printf 'SPOOL -> c-905: note task T-1 msg M-9\tsent body\t%s\n' "$(date +%s).9" >>"$LOG"
wait_for "$S" 'msg M-9' >/dev/null
out="$(line_of "$S" 'msg M-9')"
[[ -n "$out" && "$out" != *"38;5;39m"* && "$out" == *"38;5;114m"* ]] &&
  pass "OA-13 CONTROL an outbound head is green, not blue: the colour check discriminates" ||
  fail "OA-13 CONTROL outbound head: $(printf '%q' "$out")"

# The bound: a renderer with --max 5 started over 13 records (more than 2x the
# bound) trims the log to the 5 newest and never paints a record past the
# bound, scrollback included. All 13 are written BEFORE it starts: the trim
# runs on the wake-up, so a record appended after the first trim would land
# under 2x the bound and stay, which is the bound working, not a fixed count.
BL="$T/bound/notices.log"; mkdir -p "$T/bound"
for n in $(seq 1 13); do printf 'SPOOL c-906: note from c-900 msg B-%s\tb%s\t%s.0\n' "$n" "$n" "$((1000 + n))"; done >"$BL"
BP="$("${TM[@]}" new-window -d -t t: -n bound -P -F '#{pane_id}' "exec '$PANE_SH' --log '$BL' --max 5")"
wait_for "$BP" 'msg B-13' >/dev/null
for (( i = 0; i < 30; i++ )); do [[ "$(grep -c . "$BL")" == 5 ]] && break; sleep 0.1; done
sleep 0.3
shown="$("${TM[@]}" capture-pane -p -S -500 -t "$BP" | grep -oE 'msg B-[0-9]+' | awk '{print $2}' | paste -sd' ')"
[[ "$shown" == "B-13 B-12 B-11 B-10 B-9" ]] &&
  pass "OA-13 --max 5: the pane holds the 5 newest records only, scrollback included" ||
  fail "OA-13 --max 5: the pane holds '$shown'"
[[ "$(grep -c . "$BL")" == 5 && "$(head -1 "$BL")" == *"msg B-9"* ]] &&
  pass "OA-13 a log past 2x the bound is trimmed to the 5 newest records" ||
  fail "OA-13 the log holds $(grep -c . "$BL") records, first: $(head -1 "$BL")"
# CONTROL: under the bound nothing is trimmed and every record is painted.
UL="$T/under/notices.log"; mkdir -p "$T/under"
for n in 1 2 3; do printf 'SPOOL c-907: note from c-900 msg U-%s\tu%s\t%s.0\n' "$n" "$n" "$((1000 + n))"; done >"$UL"
UP="$("${TM[@]}" new-window -d -t t: -n under -P -F '#{pane_id}' "exec '$PANE_SH' --log '$UL' --max 5")"
wait_for "$UP" 'msg U-3' >/dev/null
printf 'SPOOL c-907: note from c-900 msg U-4\tu4\t1004.0\n' >>"$UL"
wait_for "$UP" 'msg U-4' >/dev/null; sleep 0.3
[[ "$(grep -c . "$UL")" == 4 && "$(heads "$UP")" == "U-4 U-3 U-2 U-1" ]] &&
  pass "OA-13 CONTROL under the bound: 4 records kept and 4 painted, so the trim above is the bound" ||
  fail "OA-13 CONTROL under the bound: $(grep -c . "$UL") records, painted '$(heads "$UP")'"

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
