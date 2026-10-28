#!/usr/bin/env bash
# vendor-terms-check-cron.sh - do_spl_vendor_terms_check DRY_RUN=0 once a month
# from the box user's crontab (spec 159 row T9, SPL-4097: monthly vendor terms watch).
# Fetches the nine URLs of spec 159 section 4.1, compares the quoted sentences,
# and opens an issue when one changes or goes missing. Installed by
# do_install_box_crons as the row vendor-terms-check of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:vendor-terms-check`).
#
# Exit: 0 checked and clean, 1 issue opened or check failed, 2 refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${VENDOR_TERMS_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
cd "$ORC" || exit 2

out="$(env DRY_RUN=0 timeout 300 nice -n 10 ./run -a do_spl_vendor_terms_check 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *'vendor terms'*|*OK*|*WARN*|*FATAL*|*PLAN*|*ISSUE*|*ALERT*) say "$line" ;; esac
done <<<"$out"
exit "$rc"
