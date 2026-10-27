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
# A tool call that still runs (wd_s1_tool_held: under WD_S1_TOOL_CAP, the
# heartbeat's pid the live harness PID) holds the hit: it prints "S1 HELD tool=<t>
# since=<s>" instead, which is no HIT. Past the cap S1 hits as before.
# A lane's own unfinished plan is a job too (spec 110, vibe 2.26.0; c-001@sat
# 2026-10-09, n=2: m-617 and m-618 sat 85 / 78 min at the prompt after a
# Stop, inbox empty): the heartbeat says idle (the turn ended), no spinner
# moves, and the bottom WD_S1_PLAN_TAIL (4) lines of the pane carry vibe's
# todo summary with a step still open ("▶ 2/7 · ..." in progress, "☐ 0/7 ·
# ..." pending; vibe's todo_tracker.py). age= is the time since the last
# progress, so a wake that starts a turn ends it; one that starts none is
# taken over at 240 s. A finished list ("☑ 7/7 · All todos complete") is not.
# An idle wait is no job (SPL-3737; c-001 msgs 1c76e2c8, n=2, and 86512295,
# n=1): a standing seat (the gathered `standing`, the lane rotation's
# lifetime/standing marker) or a lane whose result is out with no job after it
# (the gathered `result_wait`) is not hit on its plan while its inbox holds no
# job; it prints "S1 IDLE <why>" instead, which is no HIT. A job in its inbox
# hits as before.
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
# The unfinished plan of an idle lane: a HIT and exit, or nothing.
s1_plan() {
  local line base="$p"
  [[ "$(wd_hb state)" == idle ]] || return 0
  wd_spin_moving && return 0
  line="$(wd_foot | tail -n "${WD_S1_PLAN_TAIL:-4}" | grep -m1 -E '^[[:space:]]*(▶|☐) [0-9]+/[0-9]+ · ' || true)"
  [[ -n "$line" ]] || return 0
  (( base > 0 )) || base="$(wd_epoch "$(wd_hb ts)")"
  [[ "$base" =~ ^[0-9]+$ ]] && (( WD_NOW - base > wait_max )) || return 0
  s1_idle_wait "$line"
  echo "HIT S1 age=$((WD_NOW - base))$unk plan $(sed -E 's/^[[:space:]]*//' <<<"$line" | wd_short 80) open at an idle prompt, last progress $( (( p > 0 )) && echo "$((WD_NOW - p))s ago" || echo unknown)"
  exit 0
}
# The inbox jobs that arrived after epoch $1 (0: all), one line each.
s1_jobs() {
  wd_has inbox || return 0
  awk -v p="${1:-0}" -v me="$WD_ID" -v box="${WD_BOX:-}" '
    $1 + 0 > p + 0 && $3 != "note" && $4 != me && !(box != "" && $4 == me "@" box)' "$WD_CTX/inbox"
}
# An idle wait with no job in the inbox: the IDLE line and exit, or nothing.
# $1 is the open plan line.
s1_idle_wait() {
  local t task to step
  step="$(sed -E 's/^[[:space:]]*//' <<<"$1" | wd_short 80)"
  [[ -n "$(s1_jobs)" ]] && return 0
  if [[ -e "$WD_CTX/standing" ]]; then
    echo "S1 IDLE standing seat, inbox empty: plan $step"
    exit 0
  fi
  wd_has result_wait || return 0
  read -r t task to < "$WD_CTX/result_wait" || true
  [[ "$t" =~ ^[0-9]+$ ]] || return 0
  echo "S1 IDLE result sent $((WD_NOW - t))s ago on $task to $to, no job since: plan $step"
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
t=""
read -r t f < <(s1_jobs "$p" | sort -n | sed -n 1p) || true
if ! [[ "${t:-}" =~ ^[0-9]+$ ]] || (( WD_NOW - t <= wait_max )); then s1_plan; exit 0; fi
s1_held
echo "HIT S1 age=$((WD_NOW - t))$unk inbox $f unread $((WD_NOW - t))s, last progress $( (( p > 0 )) && echo "$((WD_NOW - p))s ago" || echo unknown)"
