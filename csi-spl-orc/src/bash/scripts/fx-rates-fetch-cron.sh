#!/usr/bin/env bash
# fx-rates-fetch-cron.sh - do_spl_fx_rates_fetch DRY_RUN=0 once a day, for
# each env in FX_RATES_ENVS (default "dev prd"), from the box user's crontab
# (SPL-2108: the daily exchange rates of the costs' second currency). The ECB
# publishes around 16:00 CET on working days and the Fed H.10 weekly, so a
# daily run picks up whatever is new; a re-post is an UPSERT. Installed by
# do_install_box_crons as the row fx-rates-fetch of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:fx-rates-fetch`). A
# cron job reads no profile: the PATH is set here.
#
# Exit: 0 every env posted, 1 an env failed (the others still ran), 2 a
# refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${FX_RATES_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
cd "$ORC" || exit 2

rc=0
for env in ${FX_RATES_ENVS:-dev prd}; do
  out="$(env ENV="$env" DRY_RUN=0 timeout 300 nice -n 10 ./run -a do_spl_fx_rates_fetch 2>&1)" || rc=1
  while IFS= read -r line; do
    case "$line" in *' fx '*|*OK*|*WARN*|*FATAL*) say "$env $line" ;; esac
  done <<<"$out"
done
[ "$rc" = 0 ] || { say "WARN do_spl_fx_rates_fetch failed for at least one env"; exit 1; }
exit 0
