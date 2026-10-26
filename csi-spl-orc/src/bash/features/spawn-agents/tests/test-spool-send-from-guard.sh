#!/usr/bin/env bash
# spool-send.sh refuses --from <role seat> when the caller is an agent that is
# not a seat (SPL-3654): m-857 sent itself ACCEPTED as c-296 and c-001. The
# caller is read from a FAKE /proc (SPOOL_FROM_GUARD_PROC) built here, and the
# pane leg from a private tmux server; the live fleet is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
P="$T_TMP/proc"

# A fake process: PID, its parent, its comm, then NAME=VAL environ entries.
mkproc() {  # PID PPID COMM [ENV...]
  local pid="$1" ppid="$2" comm="$3"
  shift 3
  mkdir -p "$P/$pid"
  printf '%s\n' "$comm" >"$P/$pid/comm"
  printf 'Name:\t%s\nPPid:\t%s\n' "$comm" "$ppid" >"$P/$pid/status"
  if [ "$#" -gt 0 ]; then printf '%s\0' "$@" >"$P/$pid/environ"; else : >"$P/$pid/environ"; fi
}
# spool-send.sh as the fake process PID; stdout+stderr, rc in $rc.
send_as() {  # PID ARGS...
  local pid="$1"
  shift
  out="$(SPOOL_FROM_GUARD_PROC="$P" SPOOL_FROM_GUARD_PID="$pid" bash "$SS" "$@" 2>&1)"; rc=$?
}
jsons() { find "$SPOOL_ROOT" -name '*.json' -newer "$T_TMP/mark" 2>/dev/null | wc -l; }

t_tmux
P78="$(t_window c-778 'sleep 600')"
printf 'c-778\tclaude\t%s\t/x\t20260101T000000Z\n' "$P78" >>"$SPOOL_ROOT/registry.tsv"
mkdir -p "$SPOOL_ROOT/c-778/inbox" "$SPOOL_ROOT/dispatch"

mkproc 99 1 'tmux: server'
# a lane: its agent process carries SPOOL_AGENT_ID=c-777 (the harness sets it)
mkproc 100 99 claude SPOOL_AGENT_ID=c-777 MCP_BOT_AGENT_ID=c-777
mkproc 101 100 bash SPOOL_AGENT_ID=c-777
mkproc 102 101 bash SPOOL_AGENT_ID=c-777
mkproc 103 101 bash SPOOL_AGENT_ID=c-002 MCP_BOT_AGENT_ID=c-002
mkproc 104 101 sudo
mkproc 105 104 bash
# a role seat: c-002's agent process, its Bash tool, a sudo hop, an action
mkproc 200 99 claude SPOOL_AGENT_ID=c-002
mkproc 201 200 bash SPOOL_AGENT_ID=c-002
mkproc 202 201 bash SPOOL_AGENT_ID=c-002
mkproc 203 201 sudo
mkproc 204 203 bash
mkproc 205 202 bash SPOOL_AGENT_ID=c-002 PROJ_PATH=/x
# cron: no agent anywhere in the chain
mkproc 300 1 cron
mkproc 301 300 sh
mkproc 302 301 bash

# ---- red control: a lane sends as a role seat --------------------------
: >"$T_TMP/mark"
send_as 102 --from c-002 --to c-778 --kind result --task dispatch-t --body 'ACCEPTED forged-302'
eq "a lane --from c-002: refused, exit 10" 10 "$rc"
has "…the line names the caller and how it was read" "this caller is c-777 (by its environ)" "$out"
has "…and says nothing was sent" "Nothing was sent." "$out"
eq "…nothing written anywhere in the spool root" 0 "$(jsons)"
check "…no copy in c-002's outbox" test ! -d "$SPOOL_ROOT/c-002/outbox"
check "…no keystroke logged for c-778" test ! -e "$SPOOL_ROOT/c-778/lifetime/input.log"
sleep 0.3
hasnt "…and c-778's pane was not rung" "forged-302" "$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P78")"

send_as 103 --from c-002 --to c-778 --kind result --no-poke --body 'ACCEPTED env-forged'
eq "a lane that sets SPOOL_AGENT_ID=c-002 on its child: refused (its agent process is c-777)" 10 "$rc"
send_as 105 --from c-002 --to c-778 --kind result --no-poke --body 'ACCEPTED via-sudo'
eq "a lane through sudo (environment stripped): refused" 10 "$rc"
send_as 102 --from c-001 --to c-778 --kind result --no-poke --body 'ACCEPTED as orch'
eq "a lane --from c-001: refused" 10 "$rc"
send_as 102 --from g-003 --to c-778 --kind note --no-poke --body x
eq "a lane --from g-003 (any vendor letter): refused" 10 "$rc"
send_as 102 --from CLE-002 --to c-778 --kind note --no-poke --body x
eq "a lane --from CLE-002 (legacy seat id): refused" 10 "$rc"
echo 'LEASE_MASTER=c-555' >"$SPOOL_ROOT/dispatch/lease.conf"
send_as 102 --from c-555 --to c-778 --kind result --no-poke --body 'ACCEPTED lease'
eq "a lane --from c-555, the lease.conf master: refused" 10 "$rc"
send_as 102 --from c-002 --to c-778 --kind result --accept 11111111-2222-3333-4444-555555555555 --no-poke --body 'ACCEPTED'
eq "a lane's --accept as c-002: refused before any hub leg" 10 "$rc"
eq "no refused send wrote a file" 0 "$(jsons)"

# ---- green: what keeps working ------------------------------------------
send_as 102 --from c-777 --to c-778 --kind note --no-poke --body 'own id'
eq "a lane --from its own id: delivered" 0 "$rc"
send_as 102 --from c-779 --to c-778 --kind note --no-poke --body 'another lane id'
eq "a lane --from another lane's id: not this guard's (delivered)" 0 "$rc"
send_as 202 --from c-002 --to c-778 --kind result --no-poke --body 'ACCEPTED from the seat'
eq "the seat's own session --from c-002: delivered" 0 "$rc"
check "…it is in c-778's inbox" grep -lqF 'ACCEPTED from the seat' "$SPOOL_ROOT/c-778/inbox/"*.json
send_as 204 --from c-002 --to c-778 --kind note --no-poke --body 'seat via sudo'
eq "the seat through sudo (environment stripped): delivered" 0 "$rc"
send_as 205 --from c-001 --to c-778 --kind note --no-poke --body 'queued, position 1'
eq "an action the seat runs, --from seat 1 (ASK_BY default): delivered" 0 "$rc"
send_as 302 --from c-001 --to c-778 --kind note --no-poke --body 'cron note'
eq "cron (no agent in the chain) --from c-001: delivered" 0 "$rc"
send_as 205 --from c-555 --to c-778 --kind note --no-poke --body 'seat as lease id'
eq "a seat --from the lease.conf id: delivered" 0 "$rc"

# ---- the pane leg: no agent id in the chain, its tmux window names it ----
P02="$(t_window 'c-002@box rotate' 'sleep 600')"
P79="$(t_window 'c-779@box' 'sleep 600')"
pp02="$(tmux -S "$SPOOL_TMUX_SOCKET" display -p -t "$P02" '#{pane_pid}')"
pp79="$(tmux -S "$SPOOL_TMUX_SOCKET" display -p -t "$P79" '#{pane_pid}')"
mkproc "$pp02" 99 sh; mkproc 400 "$pp02" bash
mkproc "$pp79" 99 sh; mkproc 401 "$pp79" bash
send_as 400 --from c-002 --to c-778 --kind note --no-poke --body 'seat pane'
eq "no id in the chain, the c-002 window's pane: delivered" 0 "$rc"
send_as 401 --from c-002 --to c-778 --kind result --no-poke --body 'ACCEPTED lane pane'
eq "no id in the chain, the c-779 window's pane: refused" 10 "$rc"
has "…read by its pane" "this caller is c-779 (by its pane)" "$out"

# ---- the real /proc: a process whose own agent id is a lane ---------------
# Above it is this run's own chain: a lane, CI (no id) or, rarely, a seat;
# only a seat there would let it through.
outer_seat=0
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
  grep -qzE '^(SPOOL_AGENT_ID|MCP_BOT_AGENT_ID)=[acgmq]-00[1-3]' "/proc/$p/environ" 2>/dev/null && outer_seat=1
  p="$(awk '/^PPid:/ { print $2; exit }' "/proc/$p/status" 2>/dev/null)"
done
if [ "$outer_seat" = 1 ]; then
  ok "SKIP the real /proc case: this run is itself under a role seat"
else
  out="$(env SPOOL_AGENT_ID=c-777 SPOOL_FROM_GUARD_PROC=/proc bash "$SS" --from c-002 --to c-778 --kind result --no-poke --body 'ACCEPTED real proc' 2>&1)"; rc=$?
  eq "the real /proc: a lane process --from c-002: refused" 10 "$rc"
fi

# Under SPOOL_TEST=1 with no SPOOL_FROM_GUARD_PROC there is no chain to judge:
# every other test that sends as a seat from inside a lane keeps working.
out="$(SPOOL_AGENT_ID=c-777 bash "$SS" --from c-002 --to c-778 --kind note --no-poke --body 'no proc' 2>&1)"; rc=$?
eq "SPOOL_TEST=1 and no SPOOL_FROM_GUARD_PROC: not judged (delivered)" 0 "$rc"

t_cleanup
t_done
