#!/usr/bin/env bash
# uplink-probe-cron.sh - one sample of do_spl_uplink_probe (gateway ping, hub
# DNS, hub TCP 443) from the box user's crontab, every minute, under nice, the
# same on every box. Installed by do_install_box_crons as the row uplink-probe
# of cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:uplink-probe`).
# A cron job reads no profile: the PATH is set here. The hub host comes from
# the cnf of UPLINK_PROBE_ENV (default prd), never from this line.
#
# Exit: 0 sampled (a down link included: a probe never fails its cron),
# 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${UPLINK_PROBE_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

cd "$ORC" || exit 2
out="$(env ENV="${UPLINK_PROBE_ENV:-prd}" UPLINK_PROBE_CMD=probe timeout 25 nice -n 10 ./run -a do_spl_uplink_probe 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in uplink-probe*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || say "WARN do_spl_uplink_probe rc=$rc"
exit 0
