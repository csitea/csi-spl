#!/usr/bin/env bash
# peer-ssh-gate.sh <from-box> - the forced command of a peer box's key
# (SPL-1766): do_box_peer_ssh_grant installs that key in this box's agent
# user's authorized_keys as
#   from="127.0.0.1,::1",restrict,command="bash <this file> <from-box>" <key>
# so whatever the peer asks for arrives here in SSH_ORIGINAL_COMMAND, and only
# the verbs below run. No shell, no pty, no forwarding (restrict).
#   ping   - "pong <user>@<box tag> from <from-box>"
#   lease  - the dispatch lease line (<spool root>/dispatch/lease)
# Anything else: "refused" on stderr, exit 3. Every call goes to syslog
# (tag spl-peer-ssh) when logger is there.
set -uo pipefail
from="${1:-?}"
req="${SSH_ORIGINAL_COMMAND:-}"
root="${SPOOL_ROOT:-/var/spool-hub}"
tag="$(sed -n 's/^SPOOL_BOX_TAG=\([a-z0-9-]*\)$/\1/p' "$root/box.env" 2>/dev/null | tail -n1)"

note() { command -v logger >/dev/null 2>&1 && logger -t spl-peer-ssh -- "from=$from $*"; return 0; }

case "$req" in
  ping)
    note "ok ping"
    echo "pong $(id -un)@${tag:-?} from $from" ;;
  lease)
    note "ok lease"
    cat "$root/dispatch/lease" ;;
  *)
    note "refused: ${req:0:80}"
    echo "peer-ssh-gate: refused '${req:0:80}' (allowed: ping, lease)" >&2
    exit 3 ;;
esac
