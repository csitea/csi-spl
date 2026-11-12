#!/usr/bin/env bash
# gh-runner-cpu-budget-cron.sh - re-size the runners' CPUQuota to the box load
# from the box user's crontab, every minute. Installed by
# do_setup_gh_runner_cpu_budget_cron as ONE line tagged
# `# <org>-<app>:gh-runner-cpu-budget`.
#
#   gh-runner-cpu-budget-cron.sh
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
    [ "${CPU_BUDGET_CRON_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
# cron has no gh login of its own: the box user's token file, as ci-red-note
# gh reads GH_TOKEN from the box's one GitHub credential file (SPL-5366)
. "$SELF/../../../lib/bash/funcs/gh-box-token.func.sh"
gh_box_token_export || { say "FATAL no GitHub token for gh: set GH_TOKEN or put $(gh_box_token_var) in $(gh_box_token_file)"; exit 2; }

( cd "$ORC" && DRY_RUN=0 ./run -a do_apply_gh_runner_cpu_budget ) | while IFS= read -r l; do say "$l"; done
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { say "FAIL runner CPU budget rc=$rc"; exit 1; }
