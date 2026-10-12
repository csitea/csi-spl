#!/usr/bin/env bash
# ci-overflow-cron.sh - route wf 10 to the local runners while the
# GitHub-hosted ones are overwhelmed, and back, from the box user's crontab
# every 5 minutes. Installed by do_setup_ci_overflow_cron as ONE line tagged
# `# <org>-<app>:ci-overflow`.
#
#   ci-overflow-cron.sh
#
# CI_OVERFLOW_GH_TOKEN_FILE (default $HOME/.github/token) gives gh its GH_TOKEN when
# gh has no login and no GH_TOKEN is set.
#
# Exit: 0 applied or nothing to do, 1 the apply failed, 2 a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
case "$ORC" in
  *-wt/*)
    [ "${CI_OVERFLOW_CRON_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
# cron has no gh login of its own: the box user's token file, as ci-red-note
tf="${CI_OVERFLOW_GH_TOKEN_FILE:-$HOME/.github/token}"
if [ -z "${GH_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1 && [ -r "$tf" ]; then
  GH_TOKEN="$(cat "$tf")"; export GH_TOKEN
fi

( cd "$ORC" && DRY_RUN=0 ./run -a do_route_ci_overflow ) | while IFS= read -r l; do say "$l"; done
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { say "FAIL CI overflow route rc=$rc"; exit 1; }
