#!/bin/bash
#
# @file do_box_peer_ssh_grant.func.sh
# @brief Grant SSH access from a peer box (e.g., sat) to this box (e.g., tnk).
# @description Fetch the agent user's public key from a peer box and install it in this box's authorized_keys with restrictions.
#
# @param PEER (required) - The peer box tag (e.g., "sat").
# @param PEER_SSH_DEST (required) - The SSH destination for the peer box (e.g., "satellite").
# @param AGENT_USER (optional) - The agent user (default: "ai-usr").
# @param BACKUP (optional) - Backup the authorized_keys file before editing (default: "yes").
#
# @example PEER=sat PEER_SSH_DEST=satellite ./run -a do_box_peer_ssh_grant
#
# @exit 0 - Success.
# @exit 1 - Missing parameters or failure.

set -euo pipefail

# --- Parameters ---
PEER="${PEER:-}"
PEER_SSH_DEST="${PEER_SSH_DEST:-}"
AGENT_USER="${AGENT_USER:-ai-usr}"
BACKUP="${BACKUP:-yes}"

# --- Validate ---
[[ -z "$PEER" || -z "$PEER_SSH_DEST" ]] && {
    echo "do_box_peer_ssh_grant: ERROR PEER and PEER_SSH_DEST are required"
    exit 1
}

# --- Paths ---
SSH_DIR="/home/$AGENT_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
BACKUP_FILE="$SSH_DIR/authorized_keys.backup.$(date +%Y%m%d%H%M%S)"

# --- Backup ---
if [[ "$BACKUP" == "yes" && -f "$AUTH_KEYS" ]]; then
    cp "$AUTH_KEYS" "$BACKUP_FILE"
    echo "do_box_peer_ssh_grant: BACKUP $AUTH_KEYS -> $BACKUP_FILE"
fi

# --- Fetch peer public key ---
echo "do_box_peer_ssh_grant: FETCHING public key from $PEER_SSH_DEST"
PEER_KEY="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$PEER_SSH_DEST" "sudo -u $AGENT_USER cat /home/$AGENT_USER/.ssh/id_ed25519.pub" 2>/dev/null)" || {
    echo "do_box_peer_ssh_grant: ERROR Failed to fetch public key from $PEER_SSH_DEST"
    exit 1
}

# --- Install key with restrictions ---
RESTRICTED_KEY="from=\"$(dig +short "$PEER_SSH_DEST" || echo "$PEER_SSH_DEST")\" $PEER_KEY"

if grep -q "$PEER_KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "do_box_peer_ssh_grant: KEY already installed for $PEER"
else
    echo "$RESTRICTED_KEY" >> "$AUTH_KEYS"
    chown "$AGENT_USER:$AGENT_USER" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    echo "do_box_peer_ssh_grant: INSTALLED key for $PEER"
fi

echo "do_box_peer_ssh_grant: DONE"
exit 0