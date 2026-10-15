#!/usr/bin/env bash
# token-burn-collect-cron.sh - the live token burn collector (spec 140 T022,
# T023) from the box user's crontab: every minute, TOKEN_BURN_TICKS (2) ticks
# of do_spl_token_burn_collect TOKEN_BURN_TICK_S (30) s apart (spec 140 2.1:
# every 30 s, inside the 60 s lag budget of 1.2), at nice 10 and the lowest
# best-effort IO priority: the agents' turns go first on a loaded box.
# Installed by do_install_box_crons as the row token-burn of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:token-burn`).
# A tick sources the two func files instead of `./run` (whose start alone is
# ~0.8 s on a loaded box, more than the tick's budget); only the hourly
# refresh of the hub settings (push.env) goes through ./run.
# A cron job reads no profile: the PATH is set here.
#
# Exit: 0 ticked (a failed tick or push included: it logs a WARN line),
# 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${TOKEN_BURN_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
cd "$ORC" || exit 2
renice -n 10 -p $$ >/dev/null 2>&1 || true
ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true

dir="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}"
if [ "${TOKEN_BURN_PUSH:-1}" = 1 ] && { [ ! -s "$dir/push.env" ] || [ $(( $(date +%s) - $(stat -c %Y "$dir/push.env") )) -ge 3600 ]; }; then
  out="$(timeout 120 ./run -a do_spl_token_burn_push_env 2>&1)" || say "WARN do_spl_token_burn_push_env: $(tail -1 <<<"$out")"
fi

# shellcheck source=../run/spl-cost-tokens-read.func.sh
source "$ORC/src/bash/run/spl-cost-tokens-read.func.sh"
# shellcheck source=../run/spl-token-burn-collect.func.sh
source "$ORC/src/bash/run/spl-token-burn-collect.func.sh"
i=0
while [ "$i" -lt "${TOKEN_BURN_TICKS:-2}" ]; do
  [ "$i" -gt 0 ] && sleep "${TOKEN_BURN_TICK_S:-30}"
  i=$((i + 1))
  out="$(do_spl_token_burn_collect 2>&1)"
  rc=$?
  say "$(tr '\n' ' ' <<<"$out")"
  [ "$rc" = 0 ] || say "WARN do_spl_token_burn_collect rc=$rc"
done
exit 0
