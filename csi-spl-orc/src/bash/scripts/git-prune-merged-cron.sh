#!/usr/bin/env bash
# git-prune-merged-cron.sh - delete every remote branch already merged into
# master, hourly from the box user's crontab, so the remote stays pruned after
# each landing (SPL-3609, owner msg 34b232f4: "for all of the merged already
# github branches - just delete them"). Installed by
# do_git_prune_merged_install_cron as ONE line tagged
# `# <org>-<app>:git-prune-merged`, on the one box whose git pushes to the
# remote (not a box-crons manifest row: that would put it on every box).
#
# It runs PRUNE_ALL_MERGED=1 DRY_RUN=0 ./run -a do_git_prune_round_branches in
# the shared checkout: a head goes only when git cherry shows no unlanded
# commit; master/main, ruleset*, protected and live lanes' heads are KEPT, and
# the action refuses to delete when the lane map or the protected list cannot
# be read whole. cron.out gets one START and one STOP line per run.
#
#   git-prune-merged-cron.sh
#
# gh's GH_TOKEN (the protected list), unless set, is ALL_CSI_GITHUB_TOKEN from
# $HOME/.github/.csi/crs (lib/bash/funcs/gh-box-token.func.sh); without it the
# run refuses (exit 2).
# GIT_PRUNE_CRON_RUN replaces the ./run call (tests).
#
# Exit: 0 ran (or another run held the lock), 1 the action failed, 2 a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
case "$ORC" in
  *-wt/*)
    [ "${GIT_PRUNE_CRON_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

app="$(basename "$ORC")"
app="${app%-orc}"
org="${app%%-*}"
logdir="${GIT_PRUNE_CRON_LOG_DIR:-/var/${org}/${app}/git-prune-merged}"
mkdir -p "$logdir" || { say "FATAL cannot create $logdir"; exit 2; }
exec 9>"$logdir/run.lock"
flock -n 9 || { say "OK another git-prune-merged run holds $logdir/run.lock"; exit 0; }

# cron has no gh login of its own: the box user's token file, as ci-overflow
# gh reads GH_TOKEN from the box's one GitHub credential file (SPL-5366)
. "$SELF/../../../lib/bash/funcs/gh-box-token.func.sh"
gh_box_token_export || { say "FATAL no GitHub token for gh: set GH_TOKEN or put $(gh_box_token_var) in $(gh_box_token_file)"; exit 2; }

say "START git-prune-merged pid=$$"
if [ -n "${GIT_PRUNE_CRON_RUN:-}" ]; then
  ( cd "$ORC" && PRUNE_ALL_MERGED=1 DRY_RUN=0 bash -c "$GIT_PRUNE_CRON_RUN" )
else
  ( cd "$ORC" && PRUNE_ALL_MERGED=1 DRY_RUN=0 timeout 1800 ./run -a do_git_prune_round_branches )
fi
rc=$?
say "STOP git-prune-merged rc=$rc"
[ "$rc" = 0 ] || exit 1
