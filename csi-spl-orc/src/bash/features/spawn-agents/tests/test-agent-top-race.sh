#!/usr/bin/env bash
# test-agent-top-race.sh — a spawn never renames another agent's window.
#
# 2026-10-01: every spawn shifted six to nine window names by one (the new
# window took its neighbour's name, that one the next, ...), while each
# process kept its own id. Cause: the badge pass read the window list once,
# then looked each pane up again BY INDEX; a spawn in between fired the
# sorter, which swap-windows and shifts every later index, so every badge
# landed on the neighbour's pane.
#
# Here a fixture session holds agent windows whose pane processes carry their
# id (the launcher argv agent-top reads). AGENT_TOP_AFTER_SNAPSHOT spawns a new
# window that sorts to the FRONT and runs the real sorter, exactly between the
# snapshot and the per-window work. Then every window's name must still carry
# the id of the process in it.
#
#   1. control: the pre-fix pass (snapshot by index, look the pane up by index
#      later) under the same interleave DOES shift names - else this proves nothing
#   2. fixed: no window carries an id other than its own process's
#   3. fixed: the windows that were due a badge got it (the pass still works)
#   4. a window renamed by someone else after the snapshot is left alone (CAS)
#   5. six --ensure-badge-loop calls at once start exactly ONE loop
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_LEGACY_INBOX_ROOT
export XDG_CONFIG_HOME="$T_TMP/cfg" SPOOL_ORCHESTRATOR_ID=CLE-01 AGENT_TOP_PIDFILE="$T_TMP/loop.pid"
export TMUX_WINDOWS_LOCK_DIR="$T_TMP"
TOP="$T_SCRIPTS/agent-top.sh"
SORT="$T_SCRIPTS/tmux-sort-windows.sh"
tm() { tmux -S "$SPOOL_TMUX_SOCKET" "$@"; }
fake() {  # ID SCREEN -> a pane command whose argv names the agent (spawn-claude.sh ID)
  printf "bash -c \"printf '%%s\\\\n' '%s'; exec -a 'spawn-claude.sh %s' sleep 600\"" "$2" "$1"
}

# Every agent window: does its name carry the id of the process in its pane?
# Prints "name-id process-id" for each window where they differ.
drift() {
  local pane pid wname nid aid
  while IFS='|' read -r pane pid wname; do
    nid="$(printf '%s' "$wname" | grep -oE '(CLE|GRK|AGY|QWN)-[0-9]+' | sed -n 1p)"
    [ -n "$nid" ] || continue
    aid="$(ps -o args= -g "$(ps -o sid= -p "$pid" | tr -d ' ')" 2>/dev/null | grep -oE 'spawn-claude\.sh (CLE|GRK|AGY|QWN)-[0-9]+' | sed -n 1p | awk '{print $2}')"
    [ -n "$aid" ] && [ "$aid" != "$nid" ] && printf '%s %s\n' "$nid" "$aid"
  done < <(tm list-panes -a -F '#{pane_id}|#{pane_pid}|#{window_name}')
  return 0
}

setup() {  # a fresh fixture session: CLE-20 .. CLE-60, busy screens (each due a '>' badge)
  tm kill-server 2>/dev/null; sleep 0.2
  t_tmux
  tm set -g renumber-windows off
  for n in 20 30 40 50 60; do t_window "CLE-$n lane $n" "$(fake "CLE-$n" 'esc to interrupt')" >/dev/null; done
  bash "$SORT" --socket "$SPOOL_TMUX_SOCKET" >/dev/null 2>&1
  sleep 0.5
}
# The interleave: a new agent that sorts FIRST, then the real sorter, between
# agent-top's snapshot and its per-window work.
# One-shot: --badges collects twice (badge pass + table).
SPAWN="[ -e '$T_TMP/spawned' ] && exit 0; : > '$T_TMP/spawned'; tmux -S '$SPOOL_TMUX_SOCKET' new-window -d -t t: -n 'CLE-10 new' \"$(fake CLE-10 'esc to interrupt' | sed 's/"/\\"/g')\"; sleep 0.3; bash '$SORT' --socket '$SPOOL_TMUX_SOCKET'"

# --- 1. control: the unfixed pass shifts names -----------------------------------
setup
# The unfixed pass, step for step: snapshot by index, the spawn + sort, then
# the per-row index lookup and rename it did (no seam needed to interleave).
snap="$(tm list-windows -a -F '#{session_name}:#{window_index}|#{window_name}')"
bash -c "$SPAWN" >/dev/null 2>&1; sleep 0.3
while IFS='|' read -r target wname; do
  case "$wname" in CLE-*) ;; *) continue ;; esac
  pane="$(tm list-panes -t "$target" -F '#{pane_id}' | sed -n 1p)"
  tm rename-window -t "$pane" "${wname%% *} > ${wname#* }"
done <<< "$snap"
d="$(drift)"
check "1. control: the index-addressed badge pass shifts names after a spawn" test -n "$d"
echo "       control drift (name-id process-id): $(printf '%s' "$d" | tr '\n' ';')"

# --- 2 + 3. fixed ----------------------------------------------------------------
rm -f "$T_TMP/spawned"; setup
AGENT_TOP_AFTER_SNAPSHOT="$SPAWN" bash "$TOP" --badges >/dev/null 2>&1
sleep 0.3
eq "2. fixed: every window carries the id of the process in it" "" "$(drift)"
eq "2. ... and the new agent kept its own name" "CLE-10 new" "$(tm list-windows -a -F '#{window_name}' | grep -E '^CLE-10' )"
badged="$(tm list-windows -a -F '#{window_name}' | grep -cE '^CLE-(20|30|40|50|60) > ')"
eq "3. the five windows due a badge got it" 5 "$badged"
# A second spawn, now with the loop's normal pass right after: still no drift.
SPAWN2="[ -e '$T_TMP/spawned2' ] && exit 0; : > '$T_TMP/spawned2'; tmux -S '$SPOOL_TMUX_SOCKET' new-window -d -t t: -n 'CLE-05 newer' \"$(fake CLE-05 'esc to interrupt' | sed 's/"/\\"/g')\"; sleep 0.3; bash '$SORT' --socket '$SPOOL_TMUX_SOCKET'"
AGENT_TOP_AFTER_SNAPSHOT="$SPAWN2" bash "$TOP" --badges >/dev/null 2>&1
eq "2. a second spawn mid-pass: still no drift" "" "$(drift)"

# --- 4. compare-and-set ----------------------------------------------------------
setup
w30="$(tm list-panes -a -F '#{pane_id} #{window_name}' | awk '$2=="CLE-30"{print $1}')"
AGENT_TOP_AFTER_SNAPSHOT="tmux -S '$SPOOL_TMUX_SOCKET' rename-window -t '$w30' 'CLE-30 renamed by hand'" bash "$TOP" --badges >/dev/null 2>&1
eq "4. a window renamed after the snapshot keeps the newer name" "CLE-30 renamed by hand" "$(tm display-message -p -t "$w30" '#{window_name}')"

# --- 5. one badge loop, however many hooks fire at once ---------------------------
# Deterministic under load (CLE-77907, flaky at load ~23): wait for the loop
# to come up (not a fixed sleep), and count only TOP-LEVEL loops - a $(...)
# the loop forks carries the same cmdline and pgrep -f matched it as a second.
# The interval is this run's own, so a sibling run's loop never matches.
#
# The loop must never outlive this test (SPL-1665). The loop and its
# `sleep "$IV"` (about 28 h) held the caller's pipes, so do_check_pre_push's
# tee never saw EOF: the push hung and kept its lock (2026-10-12/13, n=5).
# The reap was `pkill -f`, which the agent box's kill-guard shim
# (~/.local/bin/pkill, first on PATH under the hook) refuses with exit 2; a
# `2>/dev/null` hid that, so nothing was ever killed (red 3 of 3 with the
# shim on PATH, green without it). So no pattern kill at all:
#   - the six ensure calls run in a session of their own (setsid -w): the
#     loop, its forks and its sleep share one process group, the session id;
#   - that group is SIGKILLed on every exit path of this test (the EXIT trap;
#     TERM, INT and HUP exit through it);
#   - the session first closes every inherited fd above 2, so even a loop that
#     outlives a SIGKILL of this test holds none of the hook's pipes.
IV="$((100000 + $$ % 100000))"
SID_FILE="$T_TMP/loop.sid"
loop_group() { tr -d '[:space:]' 2>/dev/null <"$SID_FILE"; }
reap_group() {  # SIGKILL the loop's group, then wait until it is empty (<= 10 s)
  local g _; g="$(loop_group)"; [ -n "$g" ] || return 0
  for _ in $(seq 50); do
    kill -KILL -- "-$g" 2>/dev/null
    pgrep -g "$g" >/dev/null || return 0
    sleep 0.2
  done
}
trap 'reap_group; t_cleanup' EXIT
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
# shellcheck disable=SC2016 # expands in the session's own shell
setsid -w bash -c '
  for fd in /proc/$$/fd/*; do fd="${fd##*/}"; [ "$fd" -gt 2 ] && eval "exec $fd>&-"; done 2>/dev/null
  echo $$ > "$1"; shift
  for _ in 1 2 3 4 5 6; do bash "$@" & done; wait' \
  _ "$SID_FILE" "$TOP" --ensure-badge-loop --interval "$IV" </dev/null
eq "5. the ensure calls ran in a session of their own" 1 "$([ -n "$(loop_group)" ] && echo 1)"
# A fork that exits between pgrep and ps has no ppid: skipped, never counted.
loops_top() {
  local m p pp; m=" $(pgrep -g "$(loop_group)" -f "^bash \\S*agent-top.sh --badge-loop --interval $IV\$" | tr '\n' ' ')"
  for p in $m; do
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ -n "$pp" ] || continue
    case "$m" in *" $pp "*) ;; *) echo "$p" ;; esac
  done
}
for _ in $(seq 50); do [ -n "$(loops_top)" ] && break; sleep 0.2; done
sleep 1
eq "5. six concurrent ensure calls start one loop" 1 "$(loops_top | wc -l)"
eq "5. ... and it is the pidfile's loop" "$(cat "$AGENT_TOP_PIDFILE" 2>/dev/null)" "$(loops_top | sed -n 1p)"
# What this test holds open (its caller's pipes and files), and what the loop does.
fd_targets() { local f; for f in /proc/"$1"/fd/*; do readlink "$f"; done 2>/dev/null | grep -v '^/dev/null$' | sort -u; }
lp="$(loops_top | sed -n 1p)"
eq "5. ... and it holds none of this test's open pipes or files" "" \
  "$([ -n "$lp" ] && comm -12 <(fd_targets "$$") <(fd_targets "$lp") | tr '\n' ' ')"
reap_group
eq "5. ... and no process of its group is left behind" 0 "$(pgrep -g "$(loop_group)" | wc -l)"
eq "5. ... nor any loop or sleep with its interval" 0 \
  "$(pgrep -fc "^(bash \\S*agent-top.sh --badge-loop --interval|sleep) $IV\$")"

t_done
