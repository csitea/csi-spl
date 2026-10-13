#!/usr/bin/env bash
# do_spl_unanswered_sweep (SPL-1632): the live proof's hidden test channel
# #probe is skipped by default, so the posts wf 30 makes after every WUI deploy
# never reach a dispatcher. Hermetic: the rows come from SWEEP_ROWS_FILE, no
# hub, no Postgres, nothing delivered (no DELIVER).
#
# Controls: the same human post in #dev is listed open, so a skip that drops
# everything would fail; SWEEP_SKIP_CHANNELS set without probe lists #probe,
# so the default is what does it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; fails=0
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

now="$(date +%s)"; old=$((now - 3600))
# tenant tname channel task msg ts from to by topic cstate files body first_ts first_msg
row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    t1 t1 "$1" "$2" "$3" "$old" HUM-51 ALL-0 human live channel "" "$4" "$old" "$3"
}
{
  row probe 00000000-0000-4000-8000-0000000000a1 10000000-0000-4000-8000-0000000000a1 '[spool-probe] L1 channel x'
  row dev 00000000-0000-4000-8000-0000000000a2 10000000-0000-4000-8000-0000000000a2 'a real question in dev'
} >"$T/rows"

sweep() { # <env assignments...>
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" ENV=dev SWEEP_ROWS_FILE="$T/rows" SWEEP_TO=c-002 \
    SWEEP_NOW="$now" HOME="$T/home" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    do_spl_unanswered_sweep' >"$T/o" 2>&1
}

sweep
grep -q '^| open | t1 | #dev | 00000000-0000-4000-8000-0000000000a2 |' "$T/o" &&
  pass "CONTROL: the #dev post is listed open" || fail "the #dev post is not listed: $(cat "$T/o")"
grep -q '0000000000a1' "$T/o" &&
  fail "the #probe post is listed by default: $(grep 0000000000a1 "$T/o")" || pass "#probe is skipped by default"

sweep SWEEP_SKIP_CHANNELS="issues tasks"
grep -q '^| open | t1 | #probe | 00000000-0000-4000-8000-0000000000a1 |' "$T/o" &&
  pass "CONTROL: with probe left out of SWEEP_SKIP_CHANNELS, #probe is listed" || fail "#probe not listed without the default: $(cat "$T/o")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
