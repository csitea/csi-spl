#!/usr/bin/env bash
# issue-close-landed-cron.sh - the standing run of do_spl_issue_close_landed
# (t1 dee4081d: a fix landed on master moves the issues it names to done),
# every 5 min from the box user's crontab. Installed by do_install_box_crons as
# the row issue-close-landed of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:issue-close-landed`), the same line on every box.
#
# ONE box acts: the box of the dispatch lease holder (SPL-2631, sat-alone
# panel row 03), so the sweep follows the lease when a box goes away. The
# action runs in holder mode (ISSUE_CLOSE_HOLDER=1): the cursor and the ledger
# that stops a reopened issue being closed again travel through the env's box
# state store; the holder adopts the newest, sweeps and publishes its own,
# every other box only publishes what it holds, so no issue gets two comments.
# The desk that comments and moves: the responder (SPL_RSP_AGENT on box-rsp,
# seated on every box with a responder); ISSUE_CLOSE_AGENT / ISSUE_CLOSE_BOX
# override it. A cron job reads no profile: the PATH is set here.
#
# Exit: 0 ran (or not this box, or another run held the lock), 1 the action
# failed, 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${ISSUE_CLOSE_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
# shellcheck source=../../../lib/bash/funcs/spl-desk-agents.func.sh disable=SC1091
. "$ORC/lib/bash/funcs/spl-desk-agents.func.sh"

env_name="${ISSUE_CLOSE_ENV:-prd}" tenant="${ISSUE_CLOSE_TENANT:-t1}"
oa="$(basename "$ORC")"; oa="${oa%-orc}"
state="${ISSUE_CLOSE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$oa/issue-close-landed/$env_name-$tenant}"
mkdir -p "$state" || { say "FATAL cannot create $state"; exit 1; }
lock="$state/run.lock"
exec 9>"$lock"
flock -n 9 || { say "OK another issue-close-landed run holds $lock"; exit 0; }
say "START issue-close-landed $env_name $tenant"
( cd "$ORC" && env ENV="$env_name" TENANT_ID="$tenant" DESK_AGENT="${ISSUE_CLOSE_AGENT:-$SPL_RSP_AGENT}" \
    DESK_BOX="${ISSUE_CLOSE_BOX:-box-rsp}" ISSUE_CLOSE_STATE_DIR="$state" ISSUE_CLOSE_HOLDER=1 DRY_RUN=0 \
    timeout 900 ./run -a do_spl_issue_close_landed ); rc=$?
say "STOP issue-close-landed rc=$rc"
[ "$rc" = 0 ] || exit 1
