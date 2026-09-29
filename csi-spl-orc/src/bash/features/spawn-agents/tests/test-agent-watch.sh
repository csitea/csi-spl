#!/usr/bin/env bash
# test-agent-watch.sh — agent-watch.sh --once on a private tmux server
# (specs/048, SPL-1160). Each fake agent pane runs a process whose argv is
# "spawn-<kind>.sh <ID>" and prints the screen a state is read from.
#
#   DIALOG is reported; TYPED is reported and never nudged; an idle agent with
#   unread spool mail is nudged with one shell-inert ": 'SPOOL <ID>: ..." line;
#   a legacy agent is read from its markdown inbox, and its own lone brief is
#   not "unread"; busy agents, orchestrators, the watcher's own agent and
#   non-agent panes are left alone.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE MCP_BOT_AGENT_ID
export SPOOL_LEGACY_INBOX_ROOT="$T_TMP/legacy" SPOOL_AGENT_ID=CLE-90
W="$T_SCRIPTS/agent-watch.sh"
fake() {  # KIND ID SCREEN
  printf "printf '%%s\\\\n' '%s'; exec -a 'spawn-%s.sh %s' sleep 600" "$3" "$1" "$2"
}
agent() { t_window "$1" "bash -c \"$(fake "$2" "$3" "$4")\""; }
t_tmux
P1="$(agent 'CLE-07 x' claude CLE-07 '❯ 1. Yes  Do you want to proceed?')"
P2="$(agent 'CLE-08 x' claude CLE-08 '❯ half a sentence')"
P3="$(agent 'CLE-09 x' claude CLE-09 '❯ ')"
P4="$(agent 'GRK-10 x' grok GRK-10 'esc to interrupt')"
P5="$(agent 'CLE-00 orc' claude CLE-00 '❯ ')"
P6="$(agent 'CLE-90 me' claude CLE-90 '❯ ')"
P7="$(agent 'AGY-11 x' agy AGY-11 'ready')"
P8="$(t_window 'CLE-12 plain' 'sleep 600')"
printf 'CLE-09\tclaude\t%%1\t/x\t20260101T000000Z\n' >"$SPOOL_ROOT/registry.tsv"
for id in CLE-07 CLE-08 CLE-09 GRK-10 CLE-00 CLE-90 CLE-12; do
  mkdir -p "$SPOOL_ROOT/$id/inbox"; echo '{}' >"$SPOOL_ROOT/$id/inbox/a.json"; echo '{}' >"$SPOOL_ROOT/$id/inbox/b.json"
done
mkdir -p "$SPOOL_LEGACY_INBOX_ROOT/AGY-11/inbox"
echo brief >"$SPOOL_LEGACY_INBOX_ROOT/AGY-11/inbox/20260101T000000Z--ORC--brief.md"
sleep 0.5
screen() { tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$1"; }

out="$(bash "$W" --once 2>&1)"
has "a dialog is reported" "DIALOG CLE-07" "$out"
has "typed text is reported" "TYPED CLE-08" "$out"
hasnt "... and never nudged" "SPOOL CLE-08" "$(screen "$P2")"
has "an idle agent with 2 unread spool messages is nudged" "MAIL  CLE-09 ($P3) idle with 2 unread" "$out"
has "... with one shell-inert line naming its spool inbox" ": 'SPOOL CLE-09: 2 unread message(s) in $SPOOL_ROOT/CLE-09/inbox/" "$(screen "$P3")"
hasnt "a busy agent is not nudged" "GRK-10" "$out"
hasnt "the orchestrator is skipped" "CLE-00" "$out"
hasnt "the watcher's own agent is skipped" "CLE-90" "$out"
hasnt "a pane with no launcher is not an agent" "CLE-12" "$out"
hasnt "a legacy agent's lone brief is not unread" "AGY-11" "$out"
echo 'next task' >"$SPOOL_LEGACY_INBOX_ROOT/AGY-11/inbox/20260102T000000Z--ORC--task.md"
out="$(bash "$W" --once 2>&1)"
has "a legacy agent with a real message is nudged from its markdown inbox" "MAIL  AGY-11 ($P7) idle with 2 unread" "$out"
has "... naming that inbox" "$SPOOL_LEGACY_INBOX_ROOT/AGY-11/inbox/" "$(screen "$P7")"
t_done
