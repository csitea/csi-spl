#!/usr/bin/env bash
# prune-go-build-cache-cron.sh - prune Go build caches from the box user's
# crontab, every 5 min. Installed by do_setup_go_cache_prune_cron as ONE line
# tagged `# <org>-<app>:go-cache-prune`, the same way as the box-stats line.
#
# The action decides. GO_CACHE_GATE=1 prunes on the hourly tick (minute 0)
# and on any tick where the filesystem that holds the cache is at or over
# GO_CACHE_PRUNE_AT_PCT (default 85). Every other tick deletes nothing.
#
#   prune-go-build-cache-cron.sh
#
# Exit: 0 pruned or nothing to do, 1 the prune failed, 2 a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
case "$ORC" in
  *-wt/*)
    [ "${GO_CACHE_CRON_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

app="$(basename "$ORC")"
app="${app%-orc}"
org="${app%%-*}"
lockdir="${GO_CACHE_LOG_DIR:-/var/${org}/${app}/go-cache-prune}"
mkdir -p "$lockdir" 2>/dev/null || true

( cd "$ORC" && DRY_RUN=0 GO_CACHE_GATE=1 GO_CACHE_LOCK_FILE="$lockdir/prune.lock" ./run -a do_prune_go_build_cache )
rc=$?
[ "$rc" = 0 ] || { say "FAIL go build cache prune rc=$rc"; exit 1; }
