#!/usr/bin/env bash
# lane-map.sh — the fleet-wide lane map from anywhere: who owns what on EVERY
# machine of the fleet (CLE-77920, specs/058 G4 / N2). A thin front for the
# orc actions do_spl_lane_map / do_spl_lane_put, so the spawn path, the seed
# prompt and exit-clean name one command instead of `git worktree list`,
# which sees this machine's lanes only.
#
# Usage:
#   lane-map.sh [list] [--check <path,...>] [--agent <ID>] [--json] [--all]
#       print the live lanes younger than 2 h (<ID>@<box>, state, age, repo,
#       branch, topic, files, scope, src); --all: every row, done ones too;
#       --check prints ONLY `free` (exit 0), or `<path> owned by <ID>@<box>
#       <branch>` per overlap (exit 3; an empty row's worktree edits count),
#       or `unknown: <ID>@<box> <branch> has no files recorded; ask it or read
#       its brief` per live lane, no files, no clean worktree (exit 4, NOT free)
#       (--agent: the caller, never its own)
#   lane-map.sh put --agent <ID> [--repo R] [--branch B] [--scope S] [--files P,...] [--topic T]
#       write that agent's row, state live (the spawn path)
#   lane-map.sh done --agent <ID>
#       set it done, keeping its other fields (exit-clean); a role seat
#       (c-001..c-003, or an id in the dispatch lease.conf) is a no-op: the
#       rotation successor carries the same id, so its lane never ends
#
# The action runs as $SPOOL_BOX_USER (the desk keys that sign the hub call are
# theirs). Exit codes: the action's own (0 ok, 1 refused, 2 hub did not take a
# write, 3 collision, 4 a live lane with no files: scope unknown); 64 usage, or a box setting that is not ONE box id.
#
# LANE_MAP_ORC (tests): the csi-spl-orc dir whose ./run is called.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() { sed -n '9,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

verb=list
case "${1:-}" in list|put|done) verb="$1"; shift ;; -h|--help) usage ;; esac
vars=()
quiet=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check)  vars+=("LANE_CHECK=${2:-}"); quiet=(--quiet); shift 2 ;;
    --agent)  vars+=("LANE_AGENT=${2:-}"); shift 2 ;;
    --repo)   vars+=("LANE_REPO=${2:-}"); shift 2 ;;
    --branch) vars+=("LANE_BRANCH=${2:-}"); shift 2 ;;
    --scope)  vars+=("LANE_SCOPE=${2:-}"); shift 2 ;;
    --files)  vars+=("LANE_FILES=${2:-}"); shift 2 ;;
    --topic)  vars+=("LANE_TOPIC=${2:-}"); shift 2 ;;
    --json)   vars+=("LANE_FORMAT=json"); shift ;;
    --all)    vars+=("LANE_ALL=1"); shift ;;
    *) echo "lane-map.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
action=do_spl_lane_map
case "$verb" in
  put)  action=do_spl_lane_put; vars+=("LANE_STATE=live") ;;
  done) action=do_spl_lane_put; vars+=("LANE_STATE=done") ;;
esac
_lane_agent=""
for _v in "${vars[@]}"; do case "$_v" in LANE_AGENT=*) _lane_agent="${_v#LANE_AGENT=}" ;; esac; done
if [ "$verb" != list ] && ! spl_is_agent_id "$_lane_agent"; then
  echo "lane-map.sh: $verb needs --agent <ID>" >&2; exit 64
fi

# A role seat's lane outlives the seat: the hourly rotation (spec 060) hands
# the same id to the successor, so marking it done would hide a live lane.
# The ids: 001-003 (next-agent-id.sh), and whatever lease.conf names.
lane_is_role_seat() {  # ID
  [[ "$1" =~ ^[A-Za-z]+-00[1-3]$ ]] && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null
}
if [ "$verb" = "done" ] && lane_is_role_seat "$_lane_agent"; then
  echo "INFO lane-map.sh: $_lane_agent is a role seat; its successor keeps the lane, nothing to mark done"
  exit 0
fi
# One box id per setting: a value such as "sat box-desk" is refused here, not
# by the hub's "box must be the agent's desk box id".
for k in LANE_DESK_BOX LANE_BOX SPOOL_DESK_BOX; do
  [ -z "${!k:-}" ] || [[ "${!k}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
    { echo "lane-map.sh: $k must be ONE box id ([a-z0-9-], up to 32), got '${!k}'" >&2; exit 64; }
done

orc="${LANE_MAP_ORC:-$(cd "$_here/../../../../.." && pwd)}"
[ -x "$orc/run" ] || { echo "lane-map.sh: no orc ./run at $orc" >&2; exit 1; }
# The caller's fleet settings, passed through the user hop.
for k in LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_BOX LANE_REPO_DIRS SPOOL_DESK_BOX SPOOL_BOX_ENV; do
  [ -n "${!k:-}" ] && vars+=("$k=${!k}")
done
vars+=("SPOOL_ROOT=$SPOOL_ROOT")
# --check answers one question, so stdout carries only the verdict: --quiet
# moves ./run's framework lines to stderr, and of those only a WARN / FATAL
# (the hub did not answer, a refusal) is passed on.
if [ ${#quiet[@]} -gt 0 ]; then exec 2> >(grep --line-buffered -E 'WARN|FATAL|NOK' >&2); fi
if [ "$(id -un)" != "$SPOOL_BOX_USER" ] && [ -z "${LANE_MAP_ORC:-}" ]; then
  home="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)"
  cd "$orc" && exec sudo -n -u "$SPOOL_BOX_USER" env HOME="$home" "${vars[@]}" ./run -a "$action" "${quiet[@]}"
fi
cd "$orc" && exec env "${vars[@]}" ./run -a "$action" "${quiet[@]}"
