#!/usr/bin/env bash
# test-tmux-window-color.sh — /tmux-color's script (specs/069 Y5, ported from
# the frozen box engine). A private tmux server, fake agent windows; the live
# server is never touched.
#
#   1. --list prints the 10 colours; an unknown colour exits 1
#   2. --agent finds the window by its id in either name shape (<ID>@<box>,
#      "<tag>: <ID>"), sets both styles and @window-colour, and colours ONLY it
#   3. reset unsets all three
#   4. --target must be an id, never an index (1); a gone pane exits 2 and
#      colours nothing (display-message would have named the ACTIVE window)
#   5. no target at all exits 2
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SUT="$T_SCRIPTS/tmux-window-color.sh"
export SPOOL_BOX_TAG=tbox
t_tmux
TM=(tmux -S "$SPOOL_TMUX_SOCKET")
wopt() { "${TM[@]}" show-options -w -v -t "$1" "$2" 2>/dev/null; }

P1="$(t_window 'c-097@tbox wip' 'sleep 600')"
P2="$(t_window 'tbox: CLE-07 old shape' 'sleep 600')"
P3="$(t_window 'c-098@tbox bystander' 'sleep 600')"

# --- 1. ----------------------------------------------------------------------------
eq "1. --list prints the 10 colours" 10 "$(bash "$SUT" --list | wc -l)"
bash "$SUT" --agent c-097 mauve >/dev/null 2>&1; eq "1. an unknown colour exits 1" 1 "$?"

# --- 2. ----------------------------------------------------------------------------
bash "$SUT" --agent c-097 green >/dev/null 2>&1; eq "2. --agent c-097 green exits 0" 0 "$?"
eq "2. @window-colour is green" green "$(wopt "$P1" @window-colour)"
eq "2. the current style is set" "fg=black,bg=green,bold" "$(wopt "$P1" window-status-current-style)"
eq "2. the other style is tinted" "fg=green,bg=default" "$(wopt "$P1" window-status-style)"
eq "2. the bystander is not coloured" "" "$(wopt "$P3" @window-colour)"
bash "$SUT" --agent cle-07 RED >/dev/null 2>&1; eq "2. the legacy tagged shape resolves (any case)" red "$(wopt "$P2" @window-colour)"

# --- 3. ----------------------------------------------------------------------------
bash "$SUT" --agent c-097 reset >/dev/null 2>&1; eq "3. reset exits 0" 0 "$?"
eq "3. reset unsets @window-colour" "" "$(wopt "$P1" @window-colour)"
eq "3. reset unsets the current style" "" "$(wopt "$P1" window-status-current-style)"

# --- 4. ----------------------------------------------------------------------------
bash "$SUT" --target t:1 blue >/dev/null 2>&1; eq "4. an index target is refused (1)" 1 "$?"
"${TM[@]}" select-window -t "$P3"
bash "$SUT" --target %9999 blue >/dev/null 2>&1; eq "4. a gone pane exits 2" 2 "$?"
eq "4. ... and the ACTIVE window is not coloured" "" "$(wopt "$P3" @window-colour)"
bash "$SUT" --target "$P3" cyan >/dev/null 2>&1; eq "4. a pane id target works" cyan "$(wopt "$P3" @window-colour)"

# --- 5. ----------------------------------------------------------------------------
bash "$SUT" blue >/dev/null 2>&1; eq "5. no target exits 2" 2 "$?"
t_done
