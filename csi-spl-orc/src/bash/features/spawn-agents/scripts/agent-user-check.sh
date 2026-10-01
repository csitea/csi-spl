#!/usr/bin/env bash
# agent-user-check.sh — the check after a spawn: no agent CLI runs as the box
# user when the box config says agents run as someone else (CLE-77907). A CLI
# started as the box user shares that user's login and quota.
#
# Matches the CLI binary itself (argv[0] ends in /<cli> or is <cli>), never a
# launcher shell whose command line merely mentions it.
# Usage: agent-user-check.sh [CLI ...]   (default: claude)
# Exit: 0 clean (or agent user == box user: nothing to check), 1 a box-user
#       CLI is running (its "pid args" lines on stdout).
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

[ "$SPOOL_AGENT_USER" = "$SPOOL_BOX_USER" ] && { echo "agent-user-check: agents run as the box user ${SPOOL_BOX_USER}: nothing to check" >&2; exit 0; }
[ $# -gt 0 ] || set -- claude
re="$(IFS='|'; printf '%s' "$*")"
hits="$(ps -u "$SPOOL_BOX_USER" -o pid=,args= 2>/dev/null | awk -v re="(^|/)(${re})\$" '$2 ~ re')"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "agent-user-check: FAIL $(printf '%s\n' "$hits" | wc -l) agent CLI(s) run as box user ${SPOOL_BOX_USER}, want ${SPOOL_AGENT_USER}" >&2
  exit 1
fi
echo "agent-user-check: OK no $* process runs as ${SPOOL_BOX_USER} (agents: ${SPOOL_AGENT_USER})" >&2
