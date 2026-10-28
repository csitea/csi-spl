#!/usr/bin/env bash
# issue-close-landed-cron.sh - the standing run of do_spl_issue_close_landed
# (t1 dee4081d: a fix landed on master moves the issues it names to done),
# every 5 min from the box user's crontab. Installed by do_install_box_crons as
# the row issue-close-landed of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:issue-close-landed`), the same line on every box.
#
# ONE box acts: the box of the dispatch lease holder (SPL-2631, sat-alone
# panel row 03), so the sweep follows the lease when a box goes away. The
# action runs in holder mode (ISSUE_CLOSE_HOLDER=1): the cursor and the ledger
# that stops a reopened issue being closed again travel through the env's box
# state store; the holder adopts the newest, sweeps and publishes its own,
# every other box only publishes what it holds, so no issue gets two comments.
# The desk that comments and moves: the responder (SPL_RSP_AGENT), seated on
# THIS box's responder desk, SPOOL_RSP_BOX of <SPOOL_ROOT>/box.env, else
# box-rsp (SPL-2688: a fixed box-rsp is no desk on a box whose responder is
# sat-rsp); ISSUE_CLOSE_AGENT / ISSUE_CLOSE_BOX override it. A cron job reads
# no profile: the PATH is set here.
#
# Alert (SPL-2688): after ISSUE_CLOSE_ALERT_AFTER (default 6, 30 min)
# consecutive red ticks, ONE spool blocker to the orchestrator on task
# dispatch-issue-closer, again at most once an hour while still red; a green
# tick resets the count. Sent from ISSUE_CLOSE_ALERT_FROM, else the first of
# the dispatch holder, the orch holder and the lease.conf role seats
# (LEASE_ORCH, LEASE_FAILOVER, LEASE_MASTER) that THIS box announces
# (SPL-3984): the holder may sit on another box, and the fleet relay refuses a
# sender this box does not announce (its SPL-3865 check, spool-send exit 13,
# nothing sent), so the next id is tried; none: one WARN.
# ISSUE_CLOSE_SEND replaces spool-send.sh (tests).
#
# Workspaces (owner HUM-10 msgs ca8a036d, dbead7a1): after that run, each
# workspace of the box map ($SPOOL_ROOT/workspace-repos.tsv,
# workspace-repo.inc.sh) whose clone is on THIS box gets its own run in
# workspace mode (ISSUE_CLOSE_WORKSPACE=<tenant>): its repo's trunk closes
# that workspace's issues, as the map's desk. A red one is logged and counts
# as a red tick; the others still run. ISSUE_CLOSE_WS_RUN replaces the
# action for them (tests).
#
# Exit: 0 ran (or not this box, or another run held the lock), 1 the action
# failed, 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${ISSUE_CLOSE_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
# shellcheck source=../../../lib/bash/funcs/spl-desk-agents.func.sh disable=SC1091
. "$ORC/lib/bash/funcs/spl-desk-agents.func.sh"

env_name="${ISSUE_CLOSE_ENV:-prd}" tenant="${ISSUE_CLOSE_TENANT:-t1}"
oa="$(basename "$ORC")"; oa="${oa%-orc}"
state="${ISSUE_CLOSE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$oa/issue-close-landed/$env_name-$tenant}"
mkdir -p "$state" || { say "FATAL cannot create $state"; exit 1; }
lock="$state/run.lock"
exec 9>"$lock"
flock -n 9 || { say "OK another issue-close-landed run holds $lock"; exit 0; }
root="${SPOOL_ROOT:-/var/spool-hub}"

# box_env KEY -> the value of KEY in the box config (quotes dropped), or nothing.
box_env() { sed -n "s/^$1=['\"]\{0,1\}\([A-Za-z0-9][A-Za-z0-9-]*\)['\"]\{0,1\}\r\{0,1\}\$/\1/p" "$root/box.env" 2>/dev/null | tail -n 1; }

# lease_id FILE [KEY]: the agent id a lease mirror (`<id>@<box> <exp>`) or,
# with KEY, a lease.conf row names; nothing when it names none.
lease_id() {
  local id
  if [ -n "${2:-}" ]; then id="$(sed -n "s/^$2=['\"]\{0,1\}\([A-Za-z0-9-]*\).*/\1/p" "$1" 2>/dev/null | tail -n 1)"
  else read -r id _ <"$1" 2>/dev/null; id="${id%@*}"; fi
  [[ "$id" =~ ^[a-z]-[0-9]{3}$ ]] && printf '%s\n' "$id"
}

# red_tick RC: count consecutive red ticks; at ISSUE_CLOSE_ALERT_AFTER of them
# send one blocker to the orchestrator, then at most one an hour while red.
red_tick() {
  local n now last after="${ISSUE_CLOSE_ALERT_AFTER:-6}" from send tried="" why="" src body
  if [ "$1" = 0 ]; then rm -f "$state/red.count" "$state/red.alerted"; return 0; fi
  [[ "$after" =~ ^[1-9][0-9]*$ ]] || after=6
  n="$(cat "$state/red.count" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1)); printf '%s\n' "$n" >"$state/red.count"
  (( n >= after )) || return 0
  now="$(date -u +%s)"; last="$(cat "$state/red.alerted" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last >= 3600 )) || return 0
  send="${ISSUE_CLOSE_SEND:-$ORC/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  body="ISSUE CLOSER RED on box $(box_env SPOOL_BOX_TAG): the last $n ticks of do_spl_issue_close_landed ($env_name $tenant) failed, so no landed fix closes its issue. The FATAL lines are in the closer's cron log (crontab row csi-spl:box-cron:issue-close-landed)."
  if [ -n "${ISSUE_CLOSE_ALERT_FROM:-}" ]; then src="$ISSUE_CLOSE_ALERT_FROM"
  else
    src="$(lease_id "$root/dispatch/lease"; lease_id "$root/dispatch/lease.orch"
           for k in LEASE_ORCH LEASE_FAILOVER LEASE_MASTER; do lease_id "$root/dispatch/lease.conf" "$k"; done)"
  fi
  for from in $src; do
    [[ " $tried " == *" $from "* ]] && continue
    tried="${tried:+$tried }$from"
    why="$(SPOOL_ROOT="$root" bash "$send" --from "$from" --to orchestrator --kind blocker --task dispatch-issue-closer \
             --body "$body" 2>&1 >/dev/null)"
    case $? in
      0) printf '%s\n' "$now" >"$state/red.alerted"; say "INFO told the orchestrator: $n red ticks in a row (as $from)"; return 0 ;;
      13) why="$(grep -v '^ERROR' <<<"$why" | tail -n 1)" ;;
      *) say "WARN $n red ticks in a row and the blocker to the orchestrator was not sent (from '$from'): $(tail -n 1 <<<"$why"); the next tick retries"; return 0 ;;
    esac
  done
  say "WARN $n red ticks in a row and no id this box announces could send the blocker to the orchestrator (tried ${tried:-<none>}): ${why:-no lease names an id}; the next tick retries"
}

rsp="$(box_env SPOOL_RSP_BOX)"
say "START issue-close-landed $env_name $tenant"
( cd "$ORC" && env ENV="$env_name" TENANT_ID="$tenant" DESK_AGENT="${ISSUE_CLOSE_AGENT:-$SPL_RSP_AGENT}" \
    DESK_BOX="${ISSUE_CLOSE_BOX:-${rsp:-box-rsp}}" ISSUE_CLOSE_STATE_DIR="$state" ISSUE_CLOSE_HOLDER=1 DRY_RUN=0 \
    timeout 900 ./run -a do_spl_issue_close_landed ); rc=$?
say "STOP issue-close-landed rc=$rc"

wrl="$ORC/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh"
if [ -r "$wrl" ]; then
  # shellcheck source=../features/spawn-agents/lib/workspace-repo.inc.sh disable=SC1091
  . "$wrl"
else
  wr_tenants() { :; }
fi
while read -r ws; do
  [ -n "$ws" ] || continue
  row="$(SPOOL_ROOT="$root" wr_row "$ws")" || { say "WARN workspace $ws: its map row is malformed, skipped"; rc=1; continue; }
  [ -d "$(wr_field "$row" 3)/.git" ] || continue
  say "START issue-close-landed workspace $ws"
  if [ -n "${ISSUE_CLOSE_WS_RUN:-}" ]; then
    SPOOL_ROOT="$root" ISSUE_CLOSE_WORKSPACE="$ws" $ISSUE_CLOSE_WS_RUN; wrc=$?
  else
    ( cd "$ORC" && env SPOOL_ROOT="$root" ISSUE_CLOSE_WORKSPACE="$ws" DRY_RUN=0 timeout 900 ./run -a do_spl_issue_close_landed ); wrc=$?
  fi
  say "STOP issue-close-landed workspace $ws rc=$wrc"
  [ "$wrc" = 0 ] || rc=1
done < <(SPOOL_ROOT="$root" wr_tenants)
red_tick "$rc"
[ "$rc" = 0 ] || exit 1
