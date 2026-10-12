#!/usr/bin/env bash
# qas-ci-accept-cron.sh - run do_spl_qas_ci_accept DRY_RUN=0 once an hour from
# the box user's crontab, so a UI-only qas issue whose CI browser proof is
# green and live leaves qas without anyone asking (owner, t1 0f2ed820 msg
# e768eb42). Installed by do_install_box_crons as the manifest row
# qas-ci-accept (cnf/box-crons/box-crons.manifest), tagged
# `# csi-spl:box-cron:qas-ci-accept`.
#
# It runs only where QAS_DESK_AGENT is seated (its desk dir exists): the one
# box that holds that seat moves the issues, every other box logs a skip.
#
#   qas-ci-accept-cron.sh [--check-tools]
#
# Env: QAS_CRON_TARGETS (default "prd:t1", space-separated <env>:<tenant>),
# QAS_DESK_AGENT (default c-002, the dispatch seat), QAS_PATH_EXTRA.
# Exit: 0 every target ran or was skipped, 1 a target failed (the others
# still ran), 2 usage or a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${QAS_PATH_EXTRA:-}" ] && PATH="${QAS_PATH_EXTRA}:${PATH}"
export PATH
QAS_TOOLS="${QAS_TOOLS:-git gh jq curl python3 yq}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $QAS_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; QAS_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "qas-ci-accept-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the run needs resolves: $QAS_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${QAS_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

agent="${QAS_DESK_AGENT:-c-002}"
oa="$(basename "$ORC")"; oa="${oa%-orc}"
rc=0
for target in ${QAS_CRON_TARGETS:-prd:t1}; do
  env_name="${target%%:*}"; tenant="${target#*:}"
  case "$env_name" in dev|prd) ;; *) say "FATAL QAS_CRON_TARGETS: '$target' is not <dev|prd>:<tenant>"; exit 2 ;; esac
  box="$(cd "$ORC" && bash -c 'source lib/bash/funcs/spl-desk-box.func.sh && spl_desk_box_default')"
  desk="${QAS_STATE_ROOT:-$HOME/.local/share/$oa/cloud}/$env_name/desk/$tenant/$box/spool/$agent"
  if [ ! -d "$desk" ]; then
    say "SKIP $target: $agent is not seated on $box here ($desk)"
    continue
  fi
  say "START qas ci accept ENV=$env_name TENANT_ID=$tenant DESK_AGENT=$agent"
  ( cd "$ORC" && env ENV="$env_name" TENANT_ID="$tenant" DESK_AGENT="$agent" DRY_RUN=0 ./run -a do_spl_qas_ci_accept ); r=$?
  say "STOP qas ci accept ENV=$env_name rc=$r"
  [ "$r" = 0 ] || rc=1
done
exit $rc
