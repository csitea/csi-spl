#!/usr/bin/env bash
# test-tmux-sort-windows.sh — the window sorter (ported from the frozen box
# engine, specs/048 SPL-1160), on a private tmux server.
#
#   1. natural order, agents first: CLE-10 before CLE-422, plain windows last
#   2. the tag is display only: "tbx: CLE-07 x" ranks as CLE-07
#   3. the window the human is looking at stays current
#   4. idempotent: a second pass swaps nothing
#   5. sparse indices: occupants move, the index set is never renumbered
#   6. @window-sort-enabled 0 pauses it; agents-last honoured
#   7. the rendered tmux snippet's hook sorts a renamed window by itself
#   8. spec 061 ids: c-NNN and legacy CLE-NNNN are ONE kind, numerically;
#      a-/q- sort with AGY/QWN; <ID>@<box> and "<tag>: " prefixes are display only
#   9. a hook on a test's server (SPOOL_TEST=1, no SPOOL_ROOT of its own) sorts
#      that server and never trips the live-root guard; with no socket it no-ops
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE
export TMUX_WINDOWS_LOCK_DIR="$T_TMP"
SUT="$T_SCRIPTS/tmux-sort-windows.sh"
tm() { tmux -S "$SPOOL_TMUX_SOCKET" "$@"; }
order() { tm list-windows -t t -F '#{window_name}' | tr '\n' '|'; }
sortit() { bash "$SUT" --socket "$SPOOL_TMUX_SOCKET" "$@"; }
t_tmux
tm set -g renumber-windows off
for n in 'zsh' 'CLE-422 b' 'tbx: CLE-07 x' 'CLE-10 a' 'AGY-01' 'GRK-3'; do t_window "$n" 'sleep 600' >/dev/null; done
tm select-window -t "$(tm list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="CLE-10"{print $1}')"
active="$(tm display-message -p -t t '#{window_id}')"

sortit
eq "1+2. agents first, natural, tag ignored; plain windows last" "AGY-01|CLE-07 x|CLE-10 a|CLE-422 b|GRK-3|home|zsh|" \
  "$(order | sed 's/tbx: //')"
eq "3. the window being looked at is still current" "$active" "$(tm display-message -p -t t '#{window_id}')"
idx_before="$(tm list-windows -t t -F '#{window_index}' | tr '\n' ' ')"
tm set-hook -g after-select-window 'run-shell "echo x >> '"$T_TMP"'/moved"'
out="$(sortit --dry-run)"
eq "4. a second pass has nothing to swap" "" "$out"
eq "5. the index set is untouched" "$idx_before" "$(tm list-windows -t t -F '#{window_index}' | tr '\n' ' ')"

tm kill-window -t "$(tm list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="CLE-422"{print $1}')"
tm kill-window -t "$(tm list-windows -t t -F '#{window_id}	#{window_name}' | awk -F'\t' '$2 ~ /CLE-07/{print $1}')"
want_idx="$(tm list-windows -t t -F '#{window_index}' | tr '\n' ' ')"
tm rename-window -t "$(tm list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="zsh"{print $1}')" 'CLE-02 z'
sortit
eq "5. with holes in the index set, occupants are reordered" "AGY-01|CLE-02 z|CLE-10 a|GRK-3|home|" "$(order)"
eq "5. ... and the sparse index set is kept, never renumbered" "$want_idx" "$(tm list-windows -t t -F '#{window_index}' | tr '\n' ' ')"
t_window 'zsh' 'sleep 600' >/dev/null

tm set -g @window-sort-enabled 0
t_window 'AAA-1' 'sleep 600' >/dev/null
before="$(order)"; sortit
eq "6. paused: nothing moves" "$before" "$(order)"
tm set -g @window-sort-enabled 1
tm set -g @window-sort-order agents-last
sortit
eq "6. agents-last puts plain windows first" "home" "$(tm list-windows -t t -F '#{window_name}' | sed -n 1p)"
tm set -g @window-sort-order agents-first

tm new-session -d -s m -n bash
for n in 'sudo' 'CLE-77973@bx1' 'c-005@bx1 wip' 'bx1: c-004 dbcut1' 'CLE-100006@sat x' \
         'q-007' 'GRK-02' 'QWN-05' 'CLE-003@bx1' 'a-010' 'AGY-4444@bx1'; do
  tm new-window -d -t m -n "$n"
done
sortit --session m
eq "8. c-NNN and CLE-NNNN sort as one kind, numerically, tags and @box ignored" \
  "a-010|AGY-4444@bx1|CLE-003@bx1|bx1: c-004 dbcut1|c-005@bx1 wip|CLE-77973@bx1|CLE-100006@sat x|GRK-02|QWN-05|q-007|bash|sudo|" \
  "$(tm list-windows -t m -F '#{window_name}' | tr '\n' '|')"
eq "8. ... and a second pass has nothing to swap" "" "$(sortit --session m --dry-run)"
tm kill-session -t m

sed "s#{{HARNESS_DIR}}#$T_FEAT#g" "$T_FEAT/assets/tmux-agent-status.conf" >"$T_TMP/snippet.conf"
AGENT_TOP_PIDFILE="$T_TMP/p.pid" tm source-file "$T_TMP/snippet.conf"
w="$(tm list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="zsh"{print $1}')"
tm rename-window -t "$w" 'AAB-2'
for _ in $(seq 1 30); do [ "$(tm list-windows -t t -F '#{window_name}' | sed -n 2p)" = AAB-2 ] && break; sleep 0.2; done
eq "7. the snippet's after-rename hook sorts the renamed window" "AAB-2" "$(tm list-windows -t t -F '#{window_name}' | sed -n 2p)"
kill "$(cat "$T_TMP/p.pid" 2>/dev/null)" 2>/dev/null

# 9. what a box tmux.conf hook does on a scratch server a test started: the
# server env carries SPOOL_TEST=1 but not the test's SPOOL_ROOT.
mkdir -p "$T_TMP/live"; : >"$T_TMP/guard.log"
for h in after-new-window after-rename-window window-linked window-unlinked; do tm set-hook -gu "$h"; done
mkdir -p "$T_TMP/l9"
tm rename-window -t "$(tm list-windows -t t -F '#{window_id} #{window_name}' | awk '$2=="AAB-2"{print $1}')" 'ZZZ-9'
hook9() {
  env -u SPOOL_ROOT -u SPOOL_TMUX_SOCKET SPOOL_TEST=1 SPOOL_LIVE_ROOT="$T_TMP/live" \
    SPOOL_TEST_GUARD_LOG="$T_TMP/guard.log" WINDOW_SORT_DEBOUNCE=0 TMUX_WINDOWS_LOCK_DIR="$T_TMP/l9" "$@" bash "$SUT" --hook 2>&1
}
out="$(hook9 TMUX="$SPOOL_TMUX_SOCKET,1,0")"; rc=$?
eq "9. a test-server hook with no spool root exits 0" "0" "$rc"
eq "9. ... logs no live-root refusal" "" "$(cat "$T_TMP/guard.log")$out"
eq "9. ... and sorts its own server" "ZZZ-9" "$(tm list-windows -t t -F '#{window_name}' | grep -E '^[A-Z]+-[0-9]' | tail -1)"
out="$(hook9 TMUX=)"; rc=$?
eq "9. with no socket named it is a no-op, not a refusal" "0|" "$rc|$(cat "$T_TMP/guard.log")$out"
t_done
