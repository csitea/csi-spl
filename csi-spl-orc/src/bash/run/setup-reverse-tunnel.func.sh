#!/bin/bash
#
# @file setup-reverse-tunnel.func.sh
# @brief Establish and maintain a reverse SSH tunnel from tnk to sat.
# @description Start a reverse SSH tunnel from tnk to sat, and keep it alive with a reconcile loop.
#
# @param TUNNEL_DEST (required) - The SSH destination for sat (e.g., "satellite").
# @param TUNNEL_PORT (optional) - The local port on sat to forward (default: 2222).
# @param AGENT_USER (optional) - The agent user (default: "ai-usr").
# @param RECONCILE_INTERVAL (optional) - Seconds between checks (default: 60).
#
# @example TUNNEL_DEST=satellite ./run -a setup_reverse_tunnel
#
# @exit 0 - Success.
# @exit 1 - Missing parameters or failure.

set -euo pipefail

# --- Parameters ---
TUNNEL_DEST="${TUNNEL_DEST:-}"
TUNNEL_PORT="${TUNNEL_PORT:-2222}"
AGENT_USER="${AGENT_USER:-ai-usr}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-60}"

# --- Validate ---
[[ -z "$TUNNEL_DEST" ]] && {
    echo "setup-reverse-tunnel: ERROR TUNNEL_DEST is required"
    exit 1
}

# --- Paths ---
SSH_DIR="/home/$AGENT_USER/.ssh"
LOG_FILE="/var/log/csi-spl/setup-reverse-tunnel.log"
PID_FILE="/var/run/setup-reverse-tunnel.pid"

# --- Tunnel Command ---
TUNNEL_CMD="ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -N -R $TUNNEL_PORT:localhost:22 $TUNNEL_DEST -l $AGENT_USER"

# --- Reconcile ---
reconcile() {
    if [[ -f "$PID_FILE" ]]; then
        if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "$(date) setup-reverse-tunnel: STALE pid file, removing" >> "$LOG_FILE"
            rm -f "$PID_FILE"
        else
            echo "$(date) setup-reverse-tunnel: Tunnel already running (pid $(cat "$PID_FILE"))" >> "$LOG_FILE"
            return 0
        fi
    fi

    echo "$(date) setup-reverse-tunnel: STARTING tunnel to $TUNNEL_DEST" >> "$LOG_FILE"
    $TUNNEL_CMD &
    echo $! > "$PID_FILE"
    echo "$(date) setup-reverse-tunnel: STARTED tunnel (pid $!)" >> "$LOG_FILE"
}

# --- Main ---
main() {
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"
    touch "$LOG_FILE"
    chown "$AGENT_USER:$AGENT_USER" "$LOG_FILE" "$PID_FILE"
    chmod 640 "$LOG_FILE"
    chmod 644 "$PID_FILE"

    while true; do
        reconcile
        sleep "$RECONCILE_INTERVAL"
    done
}

main "$@"