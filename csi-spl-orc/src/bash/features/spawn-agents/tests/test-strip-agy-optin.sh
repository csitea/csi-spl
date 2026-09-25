#!/usr/bin/env bash
# The agy CLI paints its UI on the NORMAL screen (#{alternate_on} = 0), so the
# notifier read its pane as a bare shell: no notice strip, and every notice
# written into the pane's tty - over agy's UI. Measured 2026-09-25 (CLE-222 /
# CLE-34973, master afd104f/8cb10967, n=16 windows): 15 CLE/GRK windows had a
# strip, AGY-3493 (alternate_on 0) had none. Owner: every agent window gets the
# strip, agy included, as part of its harness.
#
# The answer is per pane: @spool_strip 1 (set by the agy launcher) makes a
# normal-screen pane a TUI for the notifier; an unmarked AGY-* id does too.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
. "$T_FEAT/lib/spool-poke-queue.inc.sh"
spool_env_resolve
t_tmux SPAWN_DRY_RUN=1
TM=(tmux -S "$SPOOL_TMUX_SOCKET")
strips() { "${TM[@]}" list-panes -a -F '#{@spool_notices}' | grep -cx "$1"; }

# ── CONTROL: an unmarked normal-screen CLE pane is still a bare terminal ────
P1="$(t_window CLE-71 'sleep 600')"
eq "CONTROL a 'sleep' pane reads alternate_on 0" 0 "$("${TM[@]}" display-message -p -t "$P1" '#{alternate_on}')"
out="$(SPOOL_POKE=0 spool_poke_show CLE-71 note HUM-1 T-1 M-1 'to a bare shell')"
eq "CONTROL …gets no strip"               0 "$(strips CLE-71)"
has "CONTROL …and the tty write, as before" "pane tty" "$out"

# ── @spool_strip 1: a strip, and NEVER the tty ──────────────────────────────
P2="$(t_window CLE-72 'sleep 600')"
"${TM[@]}" set-option -p -t "$P2" @spool_strip 1
out="$(SPOOL_POKE=0 spool_poke_show CLE-72 note HUM-1 T-2 M-2 'to a marked pane')"
eq "@spool_strip 1 splits a strip on a normal-screen pane" 1 "$(strips CLE-72)"
has "…reports it"                       "notice pane" "$out"
hasnt "…and never writes into the tty"  "pane tty"    "$out"
check "…and the record is in the log" grep -q 'to a marked pane' "$(spool_poke_queue_dir CLE-72)/notices.log"
out="$(SPOOL_POKE=0 spool_poke_show CLE-72 note HUM-1 T-3 M-3 'second')"
eq "…a second notice adopts it (still one strip)" 1 "$(strips CLE-72)"

# ── @spool_strip 0 opts a pane OUT under auto ───────────────────────────────
P3="$(t_window AGY-73 'sleep 600')"
"${TM[@]}" set-option -p -t "$P3" @spool_strip 0
SPOOL_POKE=0 spool_poke_show AGY-73 note HUM-1 T-4 M-4 'opted out' >/dev/null
eq "@spool_strip 0 wins even for an AGY id" 0 "$(strips AGY-73)"

# ── an UNMARKED AGY-* id (spawned before the mark) is a TUI ────────────────
P4="$(t_window AGY-74 'sleep 600')"
out="$(SPOOL_POKE=0 spool_poke_show AGY-74 note HUM-1 T-5 M-5 'to an old agy')"
eq "an unmarked AGY pane gets the strip" 1 "$(strips AGY-74)"
hasnt "…and no tty write over its UI"    "pane tty" "$out"
# spool_notice_record (the send path) takes the same gate
P5="$(t_window AGY-75 'sleep 600')"
spool_notice_record AGY-75 "$(spool_notice_head_out CLE-1 note '' '')" 'agy sent this'
eq "the SEND path splits it for an AGY sender too" 1 "$(strips AGY-75)"

# ── the agy launcher marks its pane and splits the strip at spawn ──────────
WD="$T_TMP/wd"; mkdir -p "$WD"
out="$(bash "$T_SCRIPTS/spawn-window.sh" agy auto "$WD")"; read -r ID PANE <<<"$out"
eq "spawn-window.sh agy marks the pane @spool_strip 1" 1 \
  "$("${TM[@]}" display-message -p -t "$PANE" '#{@spool_strip}')"
eq "…and the strip is there before the first message" 1 "$(strips "$ID")"
out="$(bash "$T_SCRIPTS/spawn-window.sh" claude auto "$WD")"; read -r ID PANE <<<"$out"
eq "CONTROL a claude spawn is not marked" "" \
  "$("${TM[@]}" display-message -p -t "$PANE" '#{@spool_strip}')"

t_done
