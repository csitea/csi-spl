#!/usr/bin/env bash
# spool-notify.sh: the orchestrator seat's prompt is typed a human's channel
# post only when the post names it (SPEC-spool-fleet-roles 2.1). Every other
# one stays in its inbox. Dispatcher seats, DMs and messages addressed to the
# orchestrator (the 2-minute backstop, the unanswered sweep) are typed as before.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SN="$T_SCRIPTS/spool-notify.sh"

. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
spool_env_resolve
D="$SPOOL_ROOT/dispatch"; mkdir -p "$D"

# ---- naming the seat --------------------------------------------------------
names() { spool_notify_names_seat "$1" "$2" && ok "$3" || nok "$3"; }
nnames() { spool_notify_names_seat "$1" "$2" && nok "$3" || ok "$3"; }
names  c-001 '@c-001 please look'           "@c-001 names the seat"
names  c-001 'ask c-001, it knows'          "the bare id names the seat"
names  c-001 'c-001@sat is slow'            "<id>@<box> names the seat"
names  c-001 'Hey ORCHESTRATOR: why?'       "the role word names it, any case"
nnames c-001 'the build is red'             "CONTROL: a post naming nobody does not"
nnames c-001 'ask c-0011 or xc-001'         "CONTROL: an id inside a longer word does not"
nnames c-001 'c-002 take this'              "CONTROL: another seat's id does not"
nnames c-001 'the orchestrators table'      "CONTROL: a longer word does not"

# ---- which seat is the orchestrator ----------------------------------------
spool_notify_is_orch_seat c-001 && nok "no lease.conf: no orch seat" || ok "no lease.conf: no orch seat"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$D/lease.conf"
spool_notify_is_orch_seat c-001 && ok "lease.conf LEASE_ORCH is the orch seat" || nok "lease.conf LEASE_ORCH is the orch seat"
spool_notify_is_orch_seat c-002 && nok "CONTROL: the master is not" || ok "CONTROL: the master is not"
echo 'c-004@sat 1791399727' >"$D/lease.orch"
spool_notify_is_orch_seat c-004 && ok "the orch lease holder is the orch seat" || nok "the orch lease holder is the orch seat"
echo 'c-001@sat 1791399734' >"$D/lease"
spool_notify_is_orch_seat c-001 && nok "an orch seat holding the dispatch lease is a dispatcher" \
  || ok "an orch seat holding the dispatch lease is a dispatcher"
echo 'c-002@sat 1791399734' >"$D/lease"; echo 'c-001@sat 1791399727' >"$D/lease.orch"

# ---- live, against a private tmux server -----------------------------------
t_tmux
tui() {  # ID -> pane on the alternate screen (the agent-TUI shape)
  local p
  p="$(t_window "$1" "sh -c 'printf \"\033[?1049h\"; sleep 600'")"
  printf '%s\tclaude\t%s\t/x\t20260101T000000Z\n' "$1" "$p" >>"$SPOOL_ROOT/registry.tsv"
  printf '%s' "$p"
}
P1="$(tui c-001)"; P2="$(tui c-002)"
sleep 0.4
msg() {  # TO-INBOX MSGID8 ADDRESSED-TO FROM BODY
  mkdir -p "$SPOOL_ROOT/$1/inbox"
  printf '{"body":"%s","from":"%s","kind":"msg","msg_id":"%s-0000-0000-0000-000000000000","task_id":"T-1","to":"%s","v":1}' \
    "$5" "$4" "$2" "$3" >"$SPOOL_ROOT/$1/inbox/20260101T000000Z--$4--x-$2.json"
}
notify() {  # TO FROM MSGID8 BODY
  bash "$SN" --to "$1" --from "$2" --kind msg --task T-1 --msg-id "$3-0000-0000-0000-000000000000" --body "$4"
}
screen() { sleep 0.6; tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$1" | tr -d '\n'; }

# 1. An owner post naming c-001 -> typed.
msg c-001 aaaaaaaa ALL-0 HUM-10 '@c-001 why so slow zz01'
notify c-001 HUM-10 aaaaaaaa '@c-001 why so slow zz01' >/dev/null
eq "a channel post naming the orch: exit 0" 0 "$?"
has "a channel post naming the orch is TYPED" "why so slow zz01" "$(screen "$P1")"

# 2. One not naming it -> not typed, still in the inbox.
rm -rf "$SPOOL_ROOT/c-001/.mirror/trigger"
msg c-001 bbbbbbbb ALL-0 HUM-10 'the build is red zz02'
out="$(notify c-001 HUM-10 bbbbbbbb 'the build is red zz02')"
eq "an unnamed channel post: exit 0" 0 "$?"
has "...the notifier says the orch filter held it" "poke: orch filter - c-001" "$out"
hasnt "an unnamed channel post is NOT typed into the orch pane" "zz02" "$(screen "$P1")"
check "...and it is still in the orch's inbox" test -s "$SPOOL_ROOT/c-001/inbox/20260101T000000Z--HUM-10--x-bbbbbbbb.json"
check "...and leaves no mirror trigger (nothing was typed)" test ! -e "$SPOOL_ROOT/c-001/.mirror/trigger"

# 3. The backstop / sweep escalation is a message addressed to c-001 -> typed.
msg c-001 cccccccc c-001 c-002 'unanswered 2 min: the build is red zz03'
notify c-001 c-002 cccccccc 'unanswered 2 min: the build is red zz03' >/dev/null
has "the backstop escalation (addressed to the orch) is TYPED" "zz03" "$(screen "$P1")"
# A human writing to the orch directly is not a channel post either.
msg c-001 dddddddd c-001 HUM-10 'dm to the orch zz04'
notify c-001 HUM-10 dddddddd 'dm to the orch zz04' >/dev/null
has "a human's DM to the orch is TYPED" "zz04" "$(screen "$P1")"

# 4. A dispatcher seat is typed the same unnamed post, as today.
msg c-002 bbbbbbbb ALL-0 HUM-10 'the build is red zz05'
notify c-002 HUM-10 bbbbbbbb 'the build is red zz05' >/dev/null
has "a dispatcher seat is TYPED the unnamed channel post" "zz05" "$(screen "$P2")"

# 5. CONTROL: with no orch seat named, the very same post reaches c-001 -
#    the filter, not something else, is what kept it out in 2.
rm -f "$D/lease.conf" "$D/lease.orch" "$D/lease"
msg c-001 eeeeeeee ALL-0 HUM-10 'the build is red zz06'
notify c-001 HUM-10 eeeeeeee 'the build is red zz06' >/dev/null
has "CONTROL: no lease.conf -> the unnamed post is typed (the check can fail)" "zz06" "$(screen "$P1")"

t_done
