#!/usr/bin/env bash
# lane-map.sh — the fleet-wide lane map from anywhere: who owns what on EVERY
# machine of the fleet (CLE-77920, specs/058 G4 / N2). A thin front for the
# orc actions do_spl_lane_map / do_spl_lane_put, so the spawn path, the seed
# prompt and exit-clean name one command instead of `git worktree list`,
# which sees this machine's lanes only.
#
# Usage:
#   lane-map.sh [list] [--check <path,...>] [--agent <ID>] [--json] [--all]
#       print the live lanes (<ID>@<box>, state, age, repo, branch, topic,
#       files, scope, src); --check exits 3 when another live lane owns an
#       overlapping path (--agent: the caller, never its own collision)
#   lane-map.sh put --agent <ID> [--repo R] [--branch B] [--scope S] [--files P,...] [--topic T]
#       write that agent's row, state live (the spawn path)
#   lane-map.sh done --agent <ID>
#       set it done, keeping its other fields (exit-clean)
#
# The action runs as $SPOOL_BOX_USER (the desk keys that sign the hub call are
# theirs). Exit codes: the action's own (0 ok, 1 refused, 2 hub did not take a
# write, 3 collision); 64 usage.
#
# LANE_MAP_ORC (tests): the csi-spl-orc dir whose ./run is called.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() { sed -n '9,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

verb=list
case "${1:-}" in list|put|done) verb="$1"; shift ;; -h|--help) usage ;; esac
vars=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check)  vars+=("LANE_CHECK=${2:-}"); shift 2 ;;
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

orc="${LANE_MAP_ORC:-$(cd "$_here/../../../../.." && pwd)}"
[ -x "$orc/run" ] || { echo "lane-map.sh: no orc ./run at $orc" >&2; exit 1; }
# The caller's fleet settings, passed through the user hop.
for k in LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_BOX LANE_REPO_DIRS SPOOL_DESK_BOX SPOOL_BOX_ENV; do
  [ -n "${!k:-}" ] && vars+=("$k=${!k}")
done
vars+=("SPOOL_ROOT=$SPOOL_ROOT")
if [ "$(id -un)" != "$SPOOL_BOX_USER" ] && [ -z "${LANE_MAP_ORC:-}" ]; then
  home="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)"
  cd "$orc" && exec sudo -n -u "$SPOOL_BOX_USER" env HOME="$home" "${vars[@]}" ./run -a "$action"
fi
cd "$orc" && exec env "${vars[@]}" ./run -a "$action"
