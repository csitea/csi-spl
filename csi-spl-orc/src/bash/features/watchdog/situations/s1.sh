#!/usr/bin/env bash
# S1 (spec 093 6.1): a job waits past the heartbeat. Seats: a job in the
# hub's held set (peer/<id>/held) while the agent is not fresh. Lanes: the
# oldest inbox file that arrived after the last progress, older than
# WD_JOB_WAIT s (120), while the agent is not fresh. age=<s> is how long the
# job has waited: the watchdog rings at 120 s and takes over at 240 s. A
# seat (listed in peer/seats) is judged by its held set only.
# Usage: s1.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
wait_max="${WD_JOB_WAIT:-120}"
wd_fresh && exit 0
p="$(wd_progress)"
p="${p:-0}"
if wd_has held; then
  n="$(grep -c . "$WD_CTX/held")"
  echo "HIT S1 age=$((WD_NOW - p)) holds $n job(s), last progress $((WD_NOW - p))s ago"
  exit 0
fi
# a seat's inbox holds stubs, reconciled by its poll loop (spec 4.5): never aged
wd_has seat && exit 0
wd_has inbox || exit 0
read -r t f < <(awk -v p="$p" '$1 + 0 > p + 0' "$WD_CTX/inbox" | sort -n | sed -n 1p)
[[ "${t:-}" =~ ^[0-9]+$ ]] || exit 0
(( WD_NOW - t > wait_max )) || exit 0
echo "HIT S1 age=$((WD_NOW - t)) inbox $f unread $((WD_NOW - t))s, last progress $( (( p > 0 )) && echo "$((WD_NOW - p))s ago" || echo unknown)"
