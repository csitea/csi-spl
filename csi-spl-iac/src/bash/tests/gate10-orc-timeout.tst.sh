#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the orc-suite job of wf 10 has room to finish (spec 131 C3). On
#          2026-10-11 its test step ran 850..1,180 s on both shards whenever it
#          ran to the end, plus ~100 s of setup, and with a 20 min cap it timed
#          out 8 times in 11 started master runs; a timeout reads "cancelled"
#          and gives no verdict.
#   1. orc-suite declares timeout-minutes: 30
#   2. the measured worst case (1,180 s step + 100 s setup) is at most 75 % of
#      that cap: the line do_report_ci_gate (C4) prints AT RISK above
#   CONTROL a. the old cap of 20 min fails check 2 (1,280 s > 900 s)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W10="$APP_ROOT/.github/workflows/10_ci-quality.yml"
WORST_S=$((1180 + 100))
fails=0

# job_timeout <workflow> <job id> - its timeout-minutes, empty if none
job_timeout() {
  awk -v j="$2" '
    $0 ~ "^  " j ":[[:space:]]*$" { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    in_job && /^    timeout-minutes:/ { print $2; exit }' "$1"
}
# fits <minutes> - the worst case is at most 75 % of the cap
fits() { (( WORST_S * 100 <= 75 * $1 * 60 )); }

t=$(job_timeout "$W10" orc-suite)
[[ "$t" == 30 ]] && pass "1. orc-suite declares timeout-minutes: 30" \
  || fail "1. orc-suite timeout-minutes is '${t:-none}', want 30"
[[ -n "$t" ]] && fits "$t" && pass "2. the measured worst case ${WORST_S} s is <= 75 % of ${t} min" \
  || fail "2. ${WORST_S} s is over 75 % of '${t:-none}' min"

# --- CONTROL a. the old 20 min cap --------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
awk '/^  orc-suite:/ { j = 1 } j && /^    timeout-minutes:/ { sub(/[0-9]+/, "20"); j = 0 } { print }' "$W10" >"$T/w10-old.yml"
t_old=$(job_timeout "$T/w10-old.yml" orc-suite)
[[ "$t_old" == 20 ]] && ! fits "$t_old" \
  && pass "CONTROL a. the old 20 min cap fails check 2 (${WORST_S} s > 900 s)" \
  || fail "CONTROL a. the 20 min copy read '$t_old' or passed check 2: the test proves nothing"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all gate10-orc-timeout.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in gate10-orc-timeout.tst.sh"
fi
[[ $fails -eq 0 ]]
