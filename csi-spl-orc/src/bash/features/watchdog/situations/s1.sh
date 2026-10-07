#!/usr/bin/env bash
# S1 (spec 093 6.1): a job waits past the heartbeat. Seats: a job in the
# hub's held set (peer/<id>/held) while the agent is not fresh. Lanes: the
# oldest inbox JOB that arrived after the last progress, older than
# WD_JOB_WAIT s (120), while the agent is not fresh. age=<s> is how long the
# job has waited: the watchdog rings at 120 s and takes over at 240 s. A
# seat (listed in peer/seats) is judged by its held set only.
# Not a job (spec 2: a message that needs an agent): a kind=note (FYI), and
# a message the agent's own id sent itself (the asks journal's re-raise: the
# asks it names are their own inbox files). prog=unknown: no heartbeat and no
# readable transcript progress, so "no progress" is unproven: ring only.
# A tool call that still runs (wd_s1_tool_held: under WD_S1_TOOL_CAP, a
# heartbeat newer than WD_HUNG) holds the hit: it prints "S1 HELD tool=<t>
# since=<s>" instead, which is no HIT. Past the cap S1 hits as before.
# Usage: s1.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
wait_max="${WD_JOB_WAIT:-120}"
wd_fresh && exit 0
# A hit that a running tool holds: the HELD line, and no HIT.
s1_held() {
  local h
  h="$(wd_s1_tool_held)" || return 0
  echo "S1 HELD tool=${h% *} since=${h##* }"
  exit 0
}
p="$(wd_progress)"
p="${p:-0}"
unk=""
(( p > 0 )) || unk=" prog=unknown"
if wd_has held; then
  n="$(grep -c . "$WD_CTX/held")"
  s1_held
  echo "HIT S1 age=$((WD_NOW - p))$unk holds $n job(s), last progress $( (( p > 0 )) && echo "$((WD_NOW - p))s ago" || echo unknown)"
  exit 0
fi
# a seat's inbox holds stubs, reconciled by its poll loop (spec 4.5): never aged
wd_has seat && exit 0
wd_has inbox || exit 0
read -r t f < <(awk -v p="$p" -v me="$WD_ID" -v box="${WD_BOX:-}" '
  $1 + 0 > p + 0 && $3 != "note" && $4 != me && !(box != "" && $4 == me "@" box)' "$WD_CTX/inbox" | sort -n | sed -n 1p)
[[ "${t:-}" =~ ^[0-9]+$ ]] || exit 0
(( WD_NOW - t > wait_max )) || exit 0
s1_held
echo "HIT S1 age=$((WD_NOW - t))$unk inbox $f unread $((WD_NOW - t))s, last progress $( (( p > 0 )) && echo "$((WD_NOW - p))s ago" || echo unknown)"
