#!/bin/bash
#
# @file test-setup-reverse-tunnel.func.sh
# @brief Test the reverse SSH tunnel setup.
# @description Verify that the reverse tunnel can be established and used.
#
# @exit 0 - Success.
# @exit 1 - Failure.

set -euo pipefail

# --- Setup ---
PROJ_ROOT="/opt/csi/csi-spl-wt/m-464"
RUN="$PROJ_ROOT/csi-spl-orc/src/bash/run/run.sh"
TEST_DIR="$PROJ_ROOT/csi-spl-orc/src/bash/tests"
TUNNEL_PORT="2222"
AGENT_USER="ai-usr"

# --- Test Tunnel Establishment ---
echo "=== Testing tunnel establishment ==="
if ! "$RUN" -a do_setup_reverse_tunnel &>/dev/null & 
then
    echo "test-setup-reverse-tunnel: FAILED to start tunnel"
    exit 1
fi

# Give the tunnel time to establish
sleep 5

# --- Test Tunnel Usage ---
echo "=== Testing tunnel usage ==="
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$TUNNEL_PORT" "$AGENT_USER@localhost" true 2>/dev/null; then
    echo "test-setup-reverse-tunnel: FAILED to use tunnel"
    kill "$(cat /var/run/setup-reverse-tunnel.pid)" 2>/dev/null || true
    exit 1
fi

# --- Cleanup ---
kill "$(cat /var/run/setup-reverse-tunnel.pid)" 2>/dev/null || true
rm -f /var/run/setup-reverse-tunnel.pid

echo "test-setup-reverse-tunnel: PASSED"
exit 0