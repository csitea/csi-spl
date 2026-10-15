#!/usr/bin/env bash
# check-env-order.sh - the daily tick of do_check_env_order (SPL-1947): dev
# always equals or leads prd. It runs the read-only drift check from this
# checkout and prints its table with a timestamp. When prd leads dev in any
# row (exit 1) it sends ONE spool note with the table to the orchestrator;
# an unknown row (exit 2) is logged only. Nothing is applied: the check only
# plans (-lock=false) and reads /version, build.json and the cnf.
#
# Installed by do_check_env_order_install_cron as ONE line tagged
# `# <org>-<app>:env-order`.
#
#   DRY_RUN=1 (default) | 0     1: no note sent
#   ENV_ORDER_TO / _FROM        default orchestrator / the orch seat
#   ENV_ORDER_TASK              the spool topic, default env-order
#   ENV_ORDER_RUN               the action runner (tests), default <orc>/run
#   ENV_ORDER_SEND              the sender script (tests), default spool-send.sh
#
# Exit: the action's (0 fine, 1 prd leads, 2 unknown); 2 also on bad usage.
# spl_role_seat: the role seat ids in their live vendor letter (SPL-1695)
declare -F spl_role_seat >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
dry="${DRY_RUN:-1}"
to="${ENV_ORDER_TO:-orchestrator}"
from="${ENV_ORDER_FROM:-$(spl_role_seat 1)}"
task="${ENV_ORDER_TASK:-env-order}"
run="${ENV_ORDER_RUN:-$ORC/run}"
send="${ENV_ORDER_SEND:-$ORC/src/bash/features/spawn-agents/scripts/spool-send.sh}"
[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FATAL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }

out="$(cd "$ORC" && "$run" -a do_check_env_order 2>&1)"
rc=$?
say "CHECK do_check_env_order exit $rc"
printf '%s\n' "$out"
((rc == 1)) || exit "$rc"

table="$(grep -E '^(kind|tf|hub|wui|cnf) |^ENV_ORDER ' <<<"$out" | sed 's/^/    /')"
if [[ "$dry" == 1 ]]; then
  say "PLAN DRY_RUN: would tell $to that prd leads dev"
  exit "$rc"
fi
if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$from" --to "$to" --kind note --task "$task" \
    --body "ENV ORDER: prd leads dev (rule: dev always equals or leads prd; fix by applying or deploying dev first).

$table" >/dev/null 2>&1; then
  say "INFO told $to: prd leads dev"
else
  say "WARN could not tell $to: prd leads dev"
fi
exit "$rc"
