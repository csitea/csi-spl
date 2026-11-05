#!/usr/bin/env bash
# box-link-watch-relay.sh — the cross-machine leg of a box link watcher alert
# (SPL-4880), pinned to the workspace of the topic that owns the box.
# box-link-watch.py hands spool-send.sh this script as SPOOL_FLEET_RELAY_CMD,
# so a seat or fallback on another machine is reached through THAT
# workspace's desk, never through lease.conf's LEASE_TENANT (owner, topic
# 0956269e msgs a3593e17 + 79a71171: the alert stays in the topic's
# workspace). A seat on this machine never reaches this script.
#
#   box-link-watch-relay.sh <workspace> <spool-fleet-relay.sh args...>
#
# It is spool_fleet_relay (lib/spool-fleet.inc.sh, the same desk user hop)
# with `--tenant <workspace>` added. BOX_LINK_WATCH_RELAY_CMD replaces the
# relay command (tests).
#
# Exit: the relay's (0 handed to the hub; 1 failed; 3 refused, nothing
# sent); 2 usage or a bad workspace, nothing sent.
set -uo pipefail

ws="${1:-}"
[[ "$ws" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
  { echo "box-link-watch-relay: bad workspace '$ws'. Nothing was sent." >&2; exit 2; }
shift
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../features/spawn-agents/lib"
# shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
. "$_here/spool-env.inc.sh"
# shellcheck source=../features/spawn-agents/lib/spool-fleet.inc.sh
. "$_here/spool-fleet.inc.sh"
spool_env_resolve
# shellcheck disable=SC2034 # read by spool_fleet_relay
SPOOL_FLEET_RELAY_CMD="${BOX_LINK_WATCH_RELAY_CMD:-}"
spool_fleet_relay "$@" --tenant "$ws"
