#!/usr/bin/env bash
# agent-steps-log-cron.sh - keeps the steps files of the named agents current
# (spec 160 section 3.9, SPL-4693): every minute from the box user's crontab
# it runs do_spl_agent_steps_log for the ids of spl_agent_steps_log_ids (box.env
# AGENT_STEPS_LOG_AGENTS, else cnf env.box.agent_steps_log.agents). No id =
# exits 0 at once and logs nothing. Installed by do_install_box_crons as the
# row agent-steps-log of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:agent-steps-log`). A cron job reads no profile: the
# PATH is set here. First it re-attaches the full-output log pipe of every
# agent whose <id>.log is a cnf file stream (do_spl_agent_log_pipe, SPL-4718):
# a rotation starts a new pane without one.
#
# The installed line runs it under cron-no-stack.sh (one run at a time).
#
# Exit: 0 ran (or nothing to do), 1 the action
# failed, 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${AGENT_STEPS_LOG_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

# shellcheck source=../run/spl-agent-steps-log.func.sh
source "$ORC/src/bash/run/spl-agent-steps-log.func.sh"
pout="$(cd "$ORC" && timeout 20 ./run -a do_spl_agent_log_pipe 2>&1)"; prc=$?
grep -E 'OK agent-log-pipe|FATAL|ERROR' <<<"$pout" | while IFS= read -r l; do say "$l"; done
[ "$prc" = 0 ] || say "WARN do_spl_agent_log_pipe rc=$prc"

ids="$(spl_agent_steps_log_ids)"
[ -n "${ids// /}" ] || exit 0

out="$(cd "$ORC" && AGENT_ID="$ids" timeout 50 ./run -a do_spl_agent_steps_log 2>&1)"; rc=$?
# one line per minute only when something was written or failed
grep -vE '^[a-z]-[0-9]{3} OK agent-steps-log: 0 line' <<<"$out" | grep -E 'OK agent-steps-log|FATAL|ERROR' | while IFS= read -r l; do say "$l"; done
[ "$rc" = 0 ] || { say "WARN do_spl_agent_steps_log rc=$rc"; exit 1; }
exit 0
