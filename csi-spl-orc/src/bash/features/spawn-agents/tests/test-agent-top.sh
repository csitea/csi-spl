#!/usr/bin/env bash
# test-agent-top.sh — the fleet view, status line and badges (specs/048,
# SPL-1160). A private tmux server; each fake agent's pane runs a process whose
# argv is "spawn-<kind>.sh <ID>" (what the launchers leave in the tree) and
# prints the screen text a state is read from.
#
#   1. rows: only agent windows; id + kind from the launcher argv; a window
#      with no launcher is "ended"; an xxx-00 window is "orc"
#   2. states from the screen: busy, dialog, idle; "awaiting" = idle + a
#      report the orchestrator has not seen (spool inbox newer than its
#      agent-inbox mark, or a legacy outbox file); agent-inbox.sh clears it
#   3. the status line counts
#   4. badges: "<tag>: <ID> <badge> <title>", the title and the tag kept, a
#      right badge renames nothing, the orchestrator is never renamed; the
#      tag is inferred from the windows when none is configured
#   5. --ensure-badge-loop starts one loop, a second call starts none
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_LEGACY_INBOX_ROOT
export XDG_CONFIG_HOME="$T_TMP/cfg" SPOOL_ORCHESTRATOR_ID=CLE-01 AGENT_TOP_PIDFILE="$T_TMP/loop.pid"
TOP="$T_SCRIPTS/agent-top.sh"
fake() {  # KIND ID SCREEN-TEXT -> a command whose argv the launcher check sees
  printf "printf '%%s\\\\n' '%s'; exec -a 'spawn-%s.sh %s' sleep 600" "$3" "$1" "$2"
}
t_tmux
P1="$(t_window 'tbx: CLE-07 build x' "bash -c \"$(fake claude CLE-07 'esc to interrupt')\"")"
P2="$(t_window 'tbx: GRK-08 ask'     "bash -c \"$(fake grok GRK-08 'Do you want to proceed?')\"")"
P3="$(t_window 'tbx: QWN-09 quiet'   "bash -c \"$(fake qwen QWN-09 'ready')\"")"
P4="$(t_window 'tbx: CLE-10 gone'    'sleep 600')"
P5="$(t_window 'tbx: CLE-00 orc'     'sleep 600')"
P6="$(t_window 'tbx: AGY-11 legacy'  "bash -c \"$(fake agy AGY-11 'ready')\"")"
t_window 'notes' 'sleep 600' >/dev/null
sleep 0.5
mkdir -p "$SPOOL_ROOT/CLE-01/inbox" "$T_TMP/legacy/AGY-11/outbox"
state_of() { bash "$TOP" 2>/dev/null | awk -v id="$1" '$1 == id { print $3 }'; }

# --- 1 + 2 ------------------------------------------------------------------------
out="$(bash "$TOP" 2>&1)"
eq "1. six agent rows, the plain window left out" "n=6" "$(printf '%s\n' "$out" | tail -1 | cut -d' ' -f1)"
eq "1. kind from the launcher argv" "qwen" "$(printf '%s\n' "$out" | awk '$1=="QWN-09"{print $2}')"
eq "1. no launcher -> ended" ended "$(state_of CLE-10)"
eq "1. an xxx-00 window -> orc" orc "$(state_of CLE-00)"
eq "2. busy screen -> busy" busy "$(state_of CLE-07)"
eq "2. a dialog -> dialog" dialog "$(state_of GRK-08)"
eq "2. quiet -> idle" idle "$(state_of QWN-09)"
echo '{}' >"$SPOOL_ROOT/CLE-01/inbox/20260101T000000Z--QWN-09--report-abc.json"
eq "2. an unseen report in the orchestrator's inbox -> awaiting" awaiting "$(state_of QWN-09)"
SPOOL_ROOT="$SPOOL_ROOT" bash "$T_SCRIPTS/agent-inbox.sh" --as CLE-01 >/dev/null 2>&1
eq "2. ... agent-inbox.sh marks it seen -> idle again" idle "$(state_of QWN-09)"
echo report >"$T_TMP/legacy/AGY-11/outbox/r.md"
eq "2. without the legacy root a legacy outbox is not read" idle "$(state_of AGY-11)"
eq "2. with it, a legacy outbox file -> awaiting" awaiting "$(SPOOL_LEGACY_INBOX_ROOT="$T_TMP/legacy" bash "$TOP" | awk '$1=="AGY-11"{print $3}')"

# --- 3 ------------------------------------------------------------------------------
eq "3. the status line" "agents 6  >1 ?1 !1 .2  orc=1" "$(bash "$TOP" --status-line)"

# --- 4 ------------------------------------------------------------------------------
name() { tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$1" '#{window_name}'; }
bash "$TOP" --badges >/dev/null 2>&1
eq "4. busy -> '>' after the id, tag + title kept" "tbx: CLE-07 > build x" "$(name "$P1")"
eq "4. dialog -> '?'" "tbx: GRK-08 ? ask" "$(name "$P2")"
eq "4. ended -> '!'" "tbx: CLE-10 ! gone" "$(name "$P4")"
eq "4. idle keeps no badge" "tbx: QWN-09 quiet" "$(name "$P3")"
eq "4. the orchestrator is never renamed" "tbx: CLE-00 orc" "$(name "$P5")"
tmux -S "$SPOOL_TMUX_SOCKET" set-hook -g window-renamed 'run-shell "echo x >> '"$T_TMP"'/renames"'
bash "$TOP" --badges >/dev/null 2>&1
check "4. a second pass renames nothing" test ! -s "$T_TMP/renames"
tmux -S "$SPOOL_TMUX_SOCKET" set-hook -gu window-renamed
tmux -S "$SPOOL_TMUX_SOCKET" rename-window -t "$P1" '> tbx: CLE-07 build x'
bash "$TOP" --badges >/dev/null 2>&1
eq "4. a badge written in front of the tag moves after the id" "tbx: CLE-07 > build x" "$(name "$P1")"
SPOOL_BOX_TAG=zzz bash "$TOP" --badges >/dev/null 2>&1
eq "4. a configured tag wins over the inferred one" "zzz: CLE-07 > build x" "$(name "$P1")"

# --- 5 ------------------------------------------------------------------------------
bash "$TOP" --ensure-badge-loop --interval 60; p1="$(cat "$AGENT_TOP_PIDFILE" 2>/dev/null)"
check "5. --ensure-badge-loop starts a loop" kill -0 "${p1:-0}"
bash "$TOP" --ensure-badge-loop --interval 60
eq "5. a second call starts none" "$p1" "$(cat "$AGENT_TOP_PIDFILE" 2>/dev/null)"
sleep 0.5; kill "$p1" 2>/dev/null; sleep 0.2
t_done
