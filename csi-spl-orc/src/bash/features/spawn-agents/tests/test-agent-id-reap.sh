#!/usr/bin/env bash
# agent-id-reap.sh (specs/061 §3.6): an agent dead past SPOOL_ID_REAP_H is
# retired the way agent-id-retire.sh does it; one alive, or dead for less, is
# left alone; the dry run retires nothing; a blind view or a gap in the ticks
# decides nothing. A private tmux server; the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/agent-id-reap.sh"
export RETIRE_LANE=0 SPOOL_ID_REAP_H=6
unset DRY_RUN
R="$SPOOL_ROOT"
t_tmux

# A record as agent-identity.py writes it (indent=1, sort_keys).
rec() {  # ID ALIVE UPDATED_AT
  mkdir -p "$R/agents"
  python3 -c 'import json,sys; json.dump({"v":1,"id":sys.argv[1],"kind":"claude","alive":sys.argv[2]=="true","pid":None,"updated_at":sys.argv[3]}, open(sys.argv[4],"w"), indent=1, sort_keys=True)' \
    "$1" "$2" "$3" "$R/agents/$1.json"
}
agent() {  # ID: a spool dir + a registry row
  mkdir -p "$R/$1/inbox"
  printf '%s\tclaude\t%%9\t/x\t20261001T080000Z\n' "$1" >>"$R/registry.tsv"
}
reap() { SPOOL_NOW="$1" bash "$REAP" "${@:2}" 2>&1; }

agent c-004; rec c-004 false 2026-10-02T04:00:00Z   # dead 8 h at 12:00
agent c-005; rec c-005 false 2026-10-02T10:00:00Z   # dead 2 h
agent c-006                                          # no record: the reaper's clock
agent c-007; rec c-007 true 2026-10-02T04:00:00Z    # record says alive, window open
agent c-001                                          # a role id
P7="$(t_window 'tg: c-007 busy' 'sleep 600')"

# --- the dry run: plans, retires nothing -----------------------------------------
out="$(reap 2026-10-02T12:00:00Z)"; eq "the dry run exits 0" 0 "$?"
has "it plans c-004 (dead 8 h >= 6 h)" "PLAN c-004: dead 8 h" "$out"
has "...through agent-id-retire's own plan" "PLAN move" "$out"
has "c-005, dead 2 h, is kept" "KEEP c-005: dead 120 min" "$out"
has "c-006 is stamped dead now" "KEEP c-006: dead 0 min" "$out"
hasnt "c-007 (a window carries it) is not a candidate" "c-007" "$out"
hasnt "the role id c-001 is never reaped" "c-001" "$out"
check "the dry run moved nothing" test -d "$R/c-004/inbox" -a -e "$R/agents/c-004.json" -a ! -e "$R/.retired"
eq "...and the registry is whole" 5 "$(wc -l <"$R/registry.tsv")"

# --- apply ------------------------------------------------------------------------
out="$(reap 2026-10-02T12:10:00Z --apply)"; eq "--apply exits 0" 0 "$?"
has "c-004 is reaped" "REAP c-004: dead 8 h (>= 6 h; its record went alive=false at 2026-10-02T04:00:00Z)" "$out"
has "the retirement is logged" "agent-id-retire: c-004 retired at 20261002T121000Z" "$out"
check "c-004's spool dir went to .retired/" test ! -e "$R/c-004" -a -d "$R/.retired/c-004.20261001T080000Z/inbox"
check "c-004's record went to agents/retired/" test ! -e "$R/agents/c-004.json" -a -s "$R/agents/retired/c-004.20261001T080000Z.json"
has "c-004's row is in registry.retired.tsv" "c-004	claude" "$(cat "$R/registry.retired.tsv")"
check "c-005 (dead < 6 h) is untouched" test -d "$R/c-005/inbox" -a -e "$R/agents/c-005.json"
check "c-006 (seen dead 10 min) is untouched" test -d "$R/c-006/inbox"
check "c-007 (alive) is untouched" test -d "$R/c-007/inbox" -a -e "$R/agents/c-007.json"
check "the role id is untouched" test -d "$R/c-001/inbox"
has "DRY_RUN=0 is --apply" "START reap (apply)" "$(DRY_RUN=0 SPOOL_NOW=2026-10-02T12:15:00Z bash "$REAP" 2>&1)"

# --- the reaper's own clock: ticks within the gap carry the stamp ---------------------
out=""; for t in 13 14 15 16 17; do out+="$(reap "2026-10-02T${t}:00:00Z" --apply)"; done
has "c-005 is reaped once its record is 6 h dead (16:00)" "2026-10-02T16:00:00Z REAP c-005: dead 6 h" "$out"
check "...and retired" test ! -e "$R/c-005"
out="$(reap 2026-10-02T18:00:00Z --apply)"
has "c-006, seen dead by the ticks since 12:00, is reaped at 18:00" "REAP c-006: dead 6 h (>= 6 h; first seen dead by the reaper at 2026-10-02T12:00:00Z)" "$out"
check "...and retired" test ! -e "$R/c-006"

# --- a gap in the ticks starts the clock again (a reboot reaps nobody) ----------------
agent c-008
reap 2026-10-02T18:30:00Z --apply >/dev/null
out="$(reap 2026-10-03T03:00:00Z --apply)"
has "after a gap the stamps start again" "every dead-since stamp starts again" "$out"
has "c-008, last seen 8.5 h ago across the gap, is kept" "KEEP c-008: dead 0 min" "$out"
check "...and not retired" test -d "$R/c-008/inbox"

# --- a window that closes later: alive clears the stamp --------------------------------
tmux -S "$SPOOL_TMUX_SOCKET" kill-window -t "$P7"
out="$(reap 2026-10-03T03:10:00Z --apply)"
has "c-007's record still says alive, its process is gone: reaper stamp now" "KEEP c-007: dead 0 min" "$out"

# --- a window still open but its record dead: retire refuses, SKIP not REAP -------------
agent c-009; rec c-009 false 2026-10-02T01:00:00Z
P9="$(t_window 'tg: c-009 shell' 'sleep 600')"
out="$(reap 2026-10-03T03:20:00Z --apply)"
hasnt "a window carrying the id keeps it whatever the record says" "c-009" "$out"
check "...untouched" test -d "$R/c-009/inbox"
tmux -S "$SPOOL_TMUX_SOCKET" kill-window -t "$P9"

# --- a blind view decides nothing ------------------------------------------------
out="$(SPOOL_TMUX_SOCKET="$T_TMP/none.sock" reap 2026-10-03T03:30:00Z --apply)"; eq "tmux unreachable is exit 1" 1 "$?"
has "...and says why" "could not be asked: nothing decided" "$out"
check "...and c-009 (dead 26 h by its record) is still held" test -d "$R/c-009/inbox"

# --- a desk id has no window by design: never reaped (specs/061 follow-up) ---------
. "$T_SCRIPTS/../../../../../lib/bash/funcs/spl-desk-agents.func.sh"
agent "$SPL_RSP_AGENT"; rec "$SPL_RSP_AGENT" false 2026-10-02T01:00:00Z
agent c-688; rec c-688 false 2026-10-02T01:00:00Z
out="$(reap 2026-10-03T03:40:00Z --apply)"
hasnt "the responder's desk id, dead 26 h by its record, is not a candidate" "$SPL_RSP_AGENT" "$out"
check "...untouched" test -d "$R/$SPL_RSP_AGENT/inbox"
has "CONTROL an ordinary id dead as long is reaped" "REAP c-688: dead 26 h" "$out"

# --- usage ---------------------------------------------------------------------
SPOOL_ID_REAP_H=0 bash "$REAP" >/dev/null 2>&1; eq "SPOOL_ID_REAP_H=0 is refused (2)" 2 "$?"
bash "$REAP" --bogus >/dev/null 2>&1; eq "an unknown argument is refused (2)" 2 "$?"

t_done
