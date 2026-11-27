#!/usr/bin/env bash
#------------------------------------------------------------------------------
# laptop-login-peer.sh <dest> <op> <args...> - do_spl_agent_cred_sync's peer
# command (CRED_PEER_CMD) on a laptop box (SPL-6680, spec 037 "Laptop box"):
# the op goes to the fleet box as plain words over ssh with the laptop's own
# key, where laptop-login-serve.sh (the key's forced command) serves the read
# ops only. A word that is not a plain path or jq path is refused here first.
# Env: LAPTOP_SSH_KEY (default ~/.ssh/spl-laptop-box), LAPTOP_SSH (tests: the
# ssh command, default ssh).
#------------------------------------------------------------------------------
set -uo pipefail
dest="${1:-}"; shift || true
for w in "$@"; do [[ "$w" =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "laptop-login-peer: refused word '$w'" >&2; exit 2; }; done
exec ${LAPTOP_SSH:-ssh} -i "${LAPTOP_SSH_KEY:-$HOME/.ssh/spl-laptop-box}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout="${LOGIN_SSH_TIMEOUT:-30}" "$dest" "$*"
