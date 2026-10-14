#!/bin/bash
#
# @file do_box_peer_ssh_check.func.sh
# @brief Check SSH access from a peer box (e.g., sat) to this box (e.g., tnk).
# @description Verify that the agent user can SSH from the peer box to this box.
#
# @param PEER (required) - The peer box tag (e.g., "sat").
# @param PEER_SSH_DEST (required) - The SSH destination for the peer box (e.g., "satellite").
# @param AGENT_USER (optional) - The agent user (default: "ai-usr").
# @param TARGET (optional) - The target box to check (default: this box).
#
# @example PEER=sat PEER_SSH_DEST=satellite ./run -a do_box_peer_ssh_check
#
# @exit 0 - Success.
# @exit 1 - Missing parameters or failure.

set -euo pipefail

# --- Parameters ---
PEER="${PEER:-}"
PEER_SSH_DEST="${PEER_SSH_DEST:-}"
AGENT_USER="${AGENT_USER:-ai-usr}"
TARGET="${TARGET:-}"

# --- Validate ---
[[ -z "$PEER" || -z "$PEER_SSH_DEST" ]] && {
    echo "do_box_peer_ssh_check: ERROR PEER and PEER_SSH_DEST are required"
    exit 1
}

# --- Check SSH access ---
echo "do_box_peer_ssh_check: CHECKING SSH access from $PEER_SSH_DEST to ${TARGET:-this box}"

if [[ -z "$TARGET" ]]; then
    # Check from peer to this box
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$PEER_SSH_DEST" "sudo -u $AGENT_USER ssh -o BatchMode=yes -o ConnectTimeout=10 \"$(hostname)\" true" 2>/dev/null && {
        echo "do_box_peer_ssh_check: SUCCESS SSH access from $PEER to this box"
        exit 0
    } || {
        echo "do_box_peer_ssh_check: FAILED SSH access from $PEER to this box"
        exit 1
    }
else
    # Check from this box to peer
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "sudo -u $AGENT_USER ssh -o BatchMode=yes -o ConnectTimeout=10 \"$PEER_SSH_DEST\" true" 2>/dev/null && {
        echo "do_box_peer_ssh_check: SUCCESS SSH access from this box to $PEER"
        exit 0
    } || {
        echo "do_box_peer_ssh_check: FAILED SSH access from this box to $PEER"
        exit 1
    }
fi