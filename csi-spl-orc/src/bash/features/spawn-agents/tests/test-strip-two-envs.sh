#!/usr/bin/env bash
# ONE strip, TWO envs. An agent seated on the dev AND the prd desk has one
# notices log per env's spool root; the strip must paint both, tagged, newest
# first, and adopting it for the second env must not split a second pane.
#
# Measured 2026-09-25 on the owner's window before the change (n=1): the strip
# tailed .../cloud/dev/.../notices.log only; two prd records landed in
# .../cloud/prd/.../notices.log and were never painted, so the strip read as
# frozen. The adoption loop matched the pane on its @spool_notices mark and the
# renderer version and never looked at which log it tailed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
. "$T_FEAT/lib/spool-poke-queue.inc.sh"
spool_env_resolve
t_tmux

# ── the renderer merges two logs on the record time and tags each ───────────
dlog="$T_TMP/cloud/dev/spool/CLE-80/.pokes/notices.log"
plog="$T_TMP/cloud/prd/spool/CLE-80/.pokes/notices.log"
mkdir -p "$(dirname "$dlog")" "$(dirname "$plog")"
# An OLD record (no time field) first; then dev, prd, dev interleaved in time.
T0=$(( $(date +%s) - 1000 ))
printf 'SPOOL CLE-80: note from HUM-1\tancient dev line\n'                    >"$dlog"
printf 'SPOOL CLE-80: note from HUM-1\tdev first\t%s.5\n' $(( T0 + 10 ))        >>"$dlog"
printf 'SPOOL CLE-80: note from HUM-2\tprd second\t%s.25\n' $(( T0 + 20 ))      >"$plog"
printf 'SPOOL CLE-80: note from HUM-1\tdev third newest\t%s\n' $(( T0 + 30 ))   >>"$dlog"
PR="$(t_window merge "NO_COLOR=1 exec $T_SCRIPTS/spool-notice-pane.sh --log $dlog --log $plog")"
sleep 1
scr="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PR")"
has "a dev record is tagged [dev]" "[dev] SPOOL CLE-80: note from HUM-1" "$scr"
has "a prd record is tagged [prd]" "[prd] SPOOL CLE-80: note from HUM-2" "$scr"
hasnt "the time field is never painted" "$(( T0 + 20 )).25" "$scr"
order="$(printf '%s\n' "$scr" | grep -oE 'dev third newest|prd second|dev first|ancient dev line' | tr '\n' ',')"
eq "newest first ACROSS logs; an untimed line never jumps a timed one in its log" \
  "dev third newest,prd second,dev first,ancient dev line," "$order"

# A new prd record repaints: the tail wakes on EITHER log.
printf 'SPOOL CLE-80: note from HUM-2\tprd live one\t%s\n' $(( T0 + 50 )) >>"$plog"
sleep 1
scr="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PR")"
eq "a record appended to the SECOND log is painted on top" "prd live one" \
  "$(printf '%s\n' "$scr" | grep -oE 'prd live one|dev third newest' | head -n 1)"

# A log written ONLY by an older, untimed writer - the stale checkout's
# notifier, live when this shipped - is dated from its mtime: its last line
# is its last write, so a fresh untimed record still lands on top.
olog="$T_TMP/cloud/prd/spool/CLE-81/.pokes/notices.log"
mkdir -p "$(dirname "$olog")"
printf 'SPOOL CLE-81: note from HUM-2\tuntimed older\nSPOOL CLE-81: note from HUM-2\tuntimed newest\n' >"$olog"
touch -d "@$(( T0 + 60 ))" "$olog"
PO="$(t_window untimed "NO_COLOR=1 exec $T_SCRIPTS/spool-notice-pane.sh --log $dlog --log $olog")"
sleep 1
scr="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PO")"
eq "an untimed log's newest record sorts by the log's mtime" "untimed newest,untimed older,dev third newest," \
  "$(printf '%s\n' "$scr" | grep -oE 'untimed newest|untimed older|dev third newest' | tr '\n' ',')"
touch -d "@$(( T0 + 5 ))" "$olog"
# (an OLD timed dev record is the wake-up: it repaints and cannot top the list)
printf 'SPOOL CLE-80: note from HUM-1\tdev wake-up\t%s\n' $(( T0 + 1 )) >>"$dlog"; sleep 1
scr="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PO")"
eq "CONTROL …and below the timed records when its mtime is older" "dev third newest," \
  "$(printf '%s\n' "$scr" | grep -oE 'untimed newest|untimed older|dev third newest' | head -n 1 | tr '\n' ',')"

# CONTROL: one log paints exactly as before - no tag.
P1="$(t_window single "NO_COLOR=1 exec $T_SCRIPTS/spool-notice-pane.sh --log $dlog")"
sleep 1
one="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P1")"
hasnt "CONTROL a single-log strip carries no tag" "[dev]" "$one"
has   "CONTROL …and still paints the records"     "dev third newest" "$one"

# ── adoption: the SECOND env's first delivery switches the SAME strip ───────
P91="$(t_window CLE-91 'sleep 600')"
export SPOOL_ROOT="$T_TMP/cloud/dev/spool"
SPOOL_SHOW_PANE=1 SPOOL_POKE=0 spool_poke_show CLE-91 note HUM-1 T-1 M-1 'hello from dev' >/dev/null
sleep 0.5
strip="$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}' | awk '$2 == "CLE-91" {print $1}')"
eq "one strip after the dev delivery" 1 "$(printf '%s\n' "$strip" | grep -c .)"
d91="$SPOOL_ROOT/CLE-91/.pokes/notices.log"

export SPOOL_ROOT="$T_TMP/cloud/prd/spool"
SPOOL_SHOW_PANE=1 SPOOL_POKE=0 spool_poke_show CLE-91 note HUM-2 T-2 M-2 'hello from prd' >/dev/null
sleep 1
p91="$SPOOL_ROOT/CLE-91/.pokes/notices.log"
strips="$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}' | awk '$2 == "CLE-91" {print $1}')"
eq "STILL one strip after the prd delivery (no second split)" 1 "$(printf '%s\n' "$strips" | grep -c .)"
eq "…and it is the SAME pane" "$strip" "$strips"
eq "its log set is dev then prd" "$d91:$p91" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$strip" '#{@spool_notices_logs}')"
both="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$strip")"
has "the strip paints the dev message" "hello from dev" "$both"
has "…AND the prd one"                 "hello from prd" "$both"
has "…tagged by env"                   "[prd]"          "$both"

# A third delivery on an env already in the set does not respawn the strip.
pid1="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$strip" '#{pane_pid}')"
SPOOL_SHOW_PANE=1 SPOOL_POKE=0 spool_poke_show CLE-91 note HUM-2 T-3 M-3 'again from prd' >/dev/null
sleep 0.5
eq "a delivery on a known env keeps the running renderer" "$pid1" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$strip" '#{pane_pid}')"

# ── a v7 strip (the live fleet's shape) keeps the log it was started with ───
# No @spool_notices_logs, one --log in its start command: the owner's strip at
# the time of the fix. Its dev log must survive the switch to the union.
P92="$(t_window CLE-92 'sleep 600')"
d92="$T_TMP/cloud/dev/spool/CLE-92/.pokes/notices.log"
mkdir -p "$(dirname "$d92")"
printf 'SPOOL CLE-92: note from HUM-1\told dev record\n' >"$d92"
old="$(tmux -S "$SPOOL_TMUX_SOCKET" split-window -d -h -l 40 -t "$P92" -P -F '#{pane_id}' \
         "exec $T_SCRIPTS/spool-notice-pane.sh --log $d92 --max 50")"
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$old" @spool_notices CLE-92
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$old" @spool_notices_v 7
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$old" @spool_notices_rv 1
SPOOL_SHOW_PANE=1 SPOOL_POKE=0 spool_poke_show CLE-92 note HUM-2 T-4 M-4 'first prd for 92' >/dev/null
sleep 1
eq "a v7 strip is adopted in place" "$old" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id} #{@spool_notices}' | awk '$2 == "CLE-92" {print $1}')"
eq "…its set keeps the dev log from its start command, plus prd" \
  "$d92:$SPOOL_ROOT/CLE-92/.pokes/notices.log" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$old" '#{@spool_notices_logs}')"
v7="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$old")"
has "…and paints the old dev record" "old dev record"   "$v7"
has "…beside the new prd one"        "first prd for 92" "$v7"

t_done
