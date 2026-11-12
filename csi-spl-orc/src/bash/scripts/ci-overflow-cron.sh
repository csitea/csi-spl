#!/usr/bin/env bash
# ci-overflow-cron.sh - route wf 10 to the local runners while the
# GitHub-hosted ones are overwhelmed, and back, from the box user's crontab
# every 5 minutes. Installed by do_setup_ci_overflow_cron as ONE line tagged
# `# <org>-<app>:ci-overflow`.
#
#   ci-overflow-cron.sh
#
# gh's GH_TOKEN, unless set, is ALL_CSI_GITHUB_TOKEN from $HOME/.github/.csi/crs
# (lib/bash/funcs/gh-box-token.func.sh); without it the run refuses (exit 2).
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
# gh reads GH_TOKEN from the box's one GitHub credential file (SPL-5366)
. "$SELF/../../../lib/bash/funcs/gh-box-token.func.sh"
gh_box_token_export || { say "FATAL no GitHub token for gh: set GH_TOKEN or put $(gh_box_token_var) in $(gh_box_token_file)"; exit 2; }

( cd "$ORC" && DRY_RUN=0 ./run -a do_route_ci_overflow ) | while IFS= read -r l; do say "$l"; done
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { say "FAIL CI overflow route rc=$rc"; exit 1; }
