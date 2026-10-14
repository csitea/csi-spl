#!/bin/bash
#
# @file do_setup_reverse_tunnel.func.sh
# @brief Named action to establish and maintain a reverse SSH tunnel from tnk to sat.
# @description Start a reverse SSH tunnel from tnk to sat, and keep it alive with a reconcile loop.
#
# @param TUNNEL_DEST (optional) - The SSH destination for sat (default: derived from BOX_SSH_SAT).
# @param TUNNEL_PORT (optional) - The local port on sat to forward (default: 2222).
# @param AGENT_USER (optional) - The agent user (default: "ai-usr").
# @param RECONCILE_INTERVAL (optional) - Seconds between checks (default: 60).
#
# @example ./run -a do_setup_reverse_tunnel
#
# @exit 0 - Success.
# @exit 1 - Failure.

set -euo pipefail

# --- Source the helper script ---
PROJ_ROOT="$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")"
source "$PROJ_ROOT/src/bash/run/setup-reverse-tunnel.func.sh"