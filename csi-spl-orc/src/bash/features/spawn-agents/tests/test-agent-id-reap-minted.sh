#!/usr/bin/env bash
# agent-id-reap.sh --minted (SPL-3263): an id spool-mcp minted for a session
# the spool did not start is retired once no pid its minted file records runs,
# and kept while a window, a registry row, a live record or a recorded pid
# holds it. A stub /proc (AI_PROC_ROOT) stands for ps; a private tmux server;
# the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/agent-id-reap.sh"
export RETIRE_LANE=0 AI_PROC_ROOT="$T_TMP/proc"
unset DRY_RUN
R="$SPOOL_ROOT"
mkdir -p "$AI_PROC_ROOT/1"
t_tmux

minted() {  # ID PIDS-TEXT: a spool dir with spool-mcp's record
  mkdir -p "$R/$1/inbox"
  printf 'minted 2026-10-02T10:00:00Z by spool-mcp for a grok session the spool did not start (%s)\n' "$2" >"$R/$1/minted"
}
alive() { mkdir -p "$AI_PROC_ROOT/$1"; }

minted g-010 'ppid 4100, pid 4101'      # both pids gone: reaped
minted g-011 'ppid 4110'                # the old record, ppid only, gone: reaped
minted g-012 'ppid 4120, pid 4121'; alive 4121   # the box half runs
minted g-013 'ppid 4130, pid 4131'; alive 4130   # the CLI runs
minted g-014 'ppid 4140, pid 4141'; P14="$(t_window 'tg: g-014 hand' 'sleep 600')"
minted g-015 'ppid 4150, pid 4151'; printf 'g-015\tgrok\t%%9\t/x\t20261001T080000Z\n' >>"$R/registry.tsv"
mkdir -p "$R/g-016/inbox"; echo 'minted by hand' >"$R/g-016/minted"   # no pid recorded
mkdir -p "$R/g-017/inbox"                                             # not minted at all
minted g-001 'ppid 4190'                                              # a role id

# --- RED CONTROL: the ordinary reaper leaves a just-ended minted id held -----------
out="$(bash "$REAP" --apply 2>&1)"
has "CONTROL the 6 h reaper only stamps g-010 dead (it holds the line for hours)" "KEEP g-010: dead 0 min" "$out"
check "...and g-010 is still held" test -d "$R/g-010/inbox"

# --- the dry run: plans, retires nothing -----------------------------------------
out="$(bash "$REAP" --minted 2>&1)"; eq "the dry run exits 0" 0 "$?"
has "it plans g-010 (both pids gone)" "PLAN g-010: minted, no pid of its session (4100 4101) runs" "$out"
has "it plans g-011 (an old record, its ppid gone)" "PLAN g-011: minted, no pid of its session (4110) runs" "$out"
has "...through agent-id-retire's own plan" "PLAN move" "$out"
check "the dry run moved nothing" test -d "$R/g-010/inbox" -a ! -e "$R/.retired"

# --- apply ----------------------------------------------------------------------
out="$(DRY_RUN=0 bash "$REAP" --minted 2>&1)"; eq "DRY_RUN=0 exits 0" 0 "$?"
has "g-010 is reaped" "REAP g-010: minted, no pid of its session (4100 4101) runs" "$out"
check "...its spool dir went to .retired/" test ! -e "$R/g-010" -a -f "$R/.retired/"g-010.*/minted
check "g-011 is retired" test ! -e "$R/g-011"
has "...and quarantined in registry.retired.tsv" "g-011	grok" "$(cat "$R/registry.retired.tsv")"
has "g-012 is kept: its box half runs" "KEEP g-012: minted, its session's pid 4121 runs" "$out"
has "g-013 is kept: its CLI runs" "KEEP g-013: minted, its session's pid 4130 runs" "$out"
hasnt "g-014 (a window carries it) is not reaped" "REAP g-014" "$out"
has "...its window is the reason" "KEEP g-014: minted, but a tmux window carries it" "$out"
has "g-015 is kept: a registry row names it" "KEEP g-015: minted, but a registry.tsv row names it" "$out"
has "g-016 is kept: no pid recorded decides nothing" "KEEP g-016: its minted file records no pid" "$out"
hasnt "g-017 (no minted file) is not a candidate" "g-017" "$out"
hasnt "the role id is never reaped" "g-001" "$out"
check "the kept ids are untouched" test -d "$R/g-012/inbox" -a -d "$R/g-013/inbox" -a -d "$R/g-014/inbox" -a -d "$R/g-015/inbox" -a -d "$R/g-016/inbox" -a -d "$R/g-017/inbox"
has "the 6 h reaper's stamp of g-010 stays its own" "g-010" "$(cat "$R/.reap/dead-since.tsv")"

# --- the session ends later: the next pass retires it ---------------------------
rm -rf "${AI_PROC_ROOT:?}/4121"
out="$(bash "$REAP" --minted --apply 2>&1)"
has "g-012 is reaped once its box half is gone" "REAP g-012" "$out"
check "...and retired" test ! -e "$R/g-012"

# --- blind views decide nothing ---------------------------------------------------
rm -rf "${AI_PROC_ROOT:?}/1"
out="$(bash "$REAP" --minted --apply 2>&1)"; eq "a /proc that hides pid 1 is exit 1" 1 "$?"
has "...and says why" "shows no pid 1 (hidepid?)" "$out"
mkdir -p "$AI_PROC_ROOT/1"; rm -rf "${AI_PROC_ROOT:?}/4130"
out="$(SPOOL_TMUX_SOCKET="$T_TMP/none.sock" bash "$REAP" --minted --apply 2>&1)"; eq "tmux unreachable is exit 1" 1 "$?"
check "...and g-013 (its CLI now gone) is still held" test -d "$R/g-013/inbox"
tmux -S "$SPOOL_TMUX_SOCKET" kill-window -t "$P14"

t_done
