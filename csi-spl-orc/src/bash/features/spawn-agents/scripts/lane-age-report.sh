#!/usr/bin/env bash
# lane-age-report.sh — the live worker lanes on THIS machine that have run past
# the 30-minute checkpoint (agent-token-focus-plan.md, practice 11). Read-only.
# One line per lane, oldest first:
#   <ID> <age-min> <last-push-age-min> <last-spool-msg-age-min>
#   age            now - the spawn time of the id's LATEST registry.tsv row
#   last-push      now - the last commit time in the lane's worktree (rundir)
#   last-spool-msg now - the newest file mtime in $SPOOL_ROOT/<ID>/outbox
# "-" where there is no commit or no outbox file. A lane is live when its
# rundir still exists and, when tmux answers, its pane does too. Role seats
# (ids 001-003 and whatever lease.conf names) are left out: they rotate, they
# are not lanes. File names and mtimes only; no message body is opened.
#
# Usage: lane-age-report.sh
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET, LANE_AGE_MIN (default 30),
#      LANE_AGE_NOW (epoch seconds, default now; for tests).
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

R="$SPOOL_ROOT"
min="${LANE_AGE_MIN:-30}"
now="${LANE_AGE_NOW:-$(date +%s)}"
[[ "$min" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] ||
  { echo "lane-age-report.sh: LANE_AGE_MIN and LANE_AGE_NOW must be integers" >&2; exit 64; }
[ -r "$R/registry.tsv" ] || { echo "lane-age-report.sh: no $R/registry.tsv" >&2; exit 1; }

is_role_seat() {  # ID
  [[ "$1" =~ ^[A-Za-z]+-00[1-3]$ ]] && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$R/dispatch/lease.conf" 2>/dev/null
}

# _age_min EPOCH — whole minutes from EPOCH to now, "-" when EPOCH is empty.
_age_min() {
  if [ -z "$1" ]; then echo -; else echo $(((now - ${1%.*}) / 60)); fi
}

spool_tmux_argv
panes="$("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id}' 2>/dev/null || true)"

# The latest row per id (registry.tsv: id kind pane rundir spawned-utc, and
# an optional requester appended last). The extra field goes to its own
# variable: bash `read` would otherwise glue it onto spawned.
awk -F'\t' 'NF >= 5 { row[$1] = $0 } END { for (i in row) print row[i] }' "$R/registry.tsv" |
while IFS=$'\t' read -r id _kind pane rundir spawned _; do
  is_role_seat "$id" && continue
  [ -d "$rundir" ] || continue
  [ -z "$panes" ] || grep -qxF -- "$pane" <<<"$panes" || continue
  [[ "$spawned" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] || continue
  t0="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s)"
  age=$(((now - t0) / 60))
  [ "$age" -gt "$min" ] || continue
  push="$(git -C "$rundir" log -1 --format=%ct 2>/dev/null || true)"
  msg="$(find "$R/$id/outbox" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 || true)"
  printf '%s %s %s %s\n' "$id" "$age" "$(_age_min "$push")" "$(_age_min "$msg")"
done | sort -k2,2nr -k1,1
