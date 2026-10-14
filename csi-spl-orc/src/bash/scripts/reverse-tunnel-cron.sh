#!/usr/bin/env bash
# reverse-tunnel-cron.sh - keep this box's recorded reverse ssh tunnels up
# (SPL-1766): `REVERSE_TUNNEL_CMD=reconcile do_setup_reverse_tunnel` every
# minute from the box user's crontab. Installed by do_install_box_crons as the
# row reverse-tunnel of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:reverse-tunnel`). A box with no tunnel recorded (no
# `DRY_RUN=0 ./run -a do_setup_reverse_tunnel` ran there) does nothing.
# A cron job reads no profile: the PATH is set here.
#
# Exit: 0 reconciled (a tunnel that would not start is logged, the next minute
# retries), 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${REVERSE_TUNNEL_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
ls "${REVERSE_TUNNEL_STATE_DIR:-/var/csi/csi-spl/reverse-tunnel}"/*.conf >/dev/null 2>&1 || exit 0

cd "$ORC" || exit 2
out="$(env REVERSE_TUNNEL_CMD=reconcile DRY_RUN=0 timeout 50 ./run -a do_setup_reverse_tunnel 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *started*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || say "WARN do_setup_reverse_tunnel rc=$rc"
exit 0
