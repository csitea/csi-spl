#!/usr/bin/env bash
# gc-cron.sh - start this box's GC agent (do_spl_gc GC_CMD=start) at the slot
# minutes of cnf/gc/gc.conf (`slot 00 claude`, `slot 30 grok`; owner HUM-10,
# t1 91a36ace, msgs 5b2b16c9 and 9c595541). Installed by do_install_box_crons
# as the row gc of cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:gc`),
# every minute on every box: a minute that is no slot exits here, before
# ./run, so the slots live in the cnf only. A cron job reads no profile: the
# PATH is set here and the tools are checked first. GC_CRON_DRY_RUN=1 makes
# the start a plan only; GC_CRON_MINUTE replaces the clock's minute (tests).
#
# Exit: 0 started, skipped or not a slot, 1 the start failed, 2 a refusal, 3 a missing tool.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
CONF="${GC_CONF:-$ORC/cnf/gc/gc.conf}"
m="${GC_CRON_MINUTE:-$(date -u +%M)}"
awk -v m="$m" '$1 == "slot" && $2 == m {f = 1} END {exit !f}' "$CONF" 2>/dev/null || exit 0

missing=""
for t in jq tmux flock timeout setsid; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
[ -z "$missing" ] || { say "FATAL these tools are not on the PATH:$missing (PATH=$PATH)"; exit 3; }
case "$ORC" in
  *-wt/*) [ "${GC_CRON_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

( cd "$ORC" && env SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" DRY_RUN="${GC_CRON_DRY_RUN:-0}" GC_CMD=start ./run -a do_spl_gc 2>&1 ) |
  grep -vE '^\[?(INFO|DEBUG)' | grep . || true
rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || { say "FAIL gc start rc=$rc"; exit 1; }
