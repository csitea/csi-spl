#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_rollup_install_cron (spec 123 section 4.5) with a stub
# crontab and a stub cnf. Every check has a failing control.
#   1. the dry run prints the diff and changes nothing
#   2. install: ONE line at cnf env.cost.rollup_utc in box local time, tagged
#      `# csi-spl:cost-rollup-dev`, running do_spl_cost_rollup_daily with ENV
#      and DRY_RUN=0 under flock; other lines kept
#   3. a second install changes nothing; another env gets its own line
#   4. check: passes when installed, fails when not
#   5. remove: the tagged line goes, the others stay
#   6. no ENV, a bad cnf time, and a linked worktree are refused
#   7. COST_SOURCES lands in the line (a box without the billing export runs
#      only its box sources); a bad list is refused, nothing written
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CT="$T/crontab"
printf '0 8 * * * /opt/other/run-me.sh # other:job\n0 9 * * * x # csi-spl:cost-rollup-dev-not-this\n' >"$CT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
printf 'env:\n  cost:\n    rollup_utc: "02:00"\n' >"$T/cnf.yaml"
cron() {
  SNIPPET='do_spl_cloud_cnf() { spl_require_cloud_env && SPL_CNF="$CNF"; }; do_spl_cost_rollup_install_cron' \
    in_orc TZ=Europe/Helsinki CNF="$T/cnf.yaml" COST_ROLLUP_CRONTAB="$T/fake-crontab" COST_ROLLUP_ALLOW_WORKTREE=1 \
    COST_ROLLUP_CRON_LOG_DIR="$T/log" "$@" 2>&1
}
tagged() { grep -c " # csi-spl:cost-rollup${1-"-dev"}\$" "$CT"; }
local_sched="$(TZ=Europe/Helsinki date -d "$(date -u +%F) 02:00 UTC" '+%-M %-H * * *')"

# 1. dry run
cp "$CT" "$T/ct.0"
out="$(cron)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$CT" "$T/ct.0" && grep -q '^PLAN cron' <<<"$out" && grep -qF "  +$local_sched cd " <<<"$out" \
  && pass "1. the dry run prints the diff and changes nothing" || fail "1. ($rc: $out)"

# 2. install
out="$(cron DRY_RUN=0)"; rc=$?
line="$(grep ' # csi-spl:cost-rollup-dev$' "$CT")"
[ "$rc" -eq 0 ] && [ "$(tagged)" = 1 ] && [[ "$line" == "$local_sched cd $PROJ_ROOT && "* ]] && [[ "$local_sched" != "0 2 * * *" ]] \
  && [[ "$line" == *"flock -n $T/log/cost-rollup-dev.lock env ENV=dev DRY_RUN=0 ./run -a do_spl_cost_rollup_daily >> $T/log/cron-dev.out 2>&1 # csi-spl:cost-rollup-dev" ]] \
  && pass "2. one line at 02:00 UTC in box local time ($local_sched) running the rollup under flock" || fail "2. ($rc: $out; $line)"
grep -q 'other:job$' "$CT" && grep -q 'cost-rollup-dev-not-this$' "$CT" && [ -d "$T/log" ] \
  && pass "2. ...the other lines kept (a longer tag too), the log dir made" || fail "2. others ($(cat "$CT"))"

# 3. idempotent; prd is its own line
cp "$CT" "$T/ct.1"
out="$(cron DRY_RUN=0)"
cmp -s "$CT" "$T/ct.1" && grep -q 'OK cron: nothing to change' <<<"$out" && pass "3. a second install changes nothing" || fail "3. ($out)"
out="$(cron DRY_RUN=0 ENV=prd)"
[ "$(tagged)" = 1 ] && [ "$(tagged "")" = 1 ] && grep -q 'env ENV=prd DRY_RUN=0' "$CT" \
  && pass "3. control: ENV=prd adds its own line, the dev one stays" || fail "3. control ($(cat "$CT"))"

# 4. check
out="$(cron COST_ROLLUP_CRON_ACTION=check)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'OK the cost rollup cron is installed' <<<"$out" && ! grep -q 'not the cnf time' <<<"$out" \
  && pass "4. check passes when installed at the cnf time" || fail "4. ($rc: $out)"
printf 'env:\n  cost:\n    rollup_utc: "03:30"\n' >"$T/cnf.yaml"
out="$(cron COST_ROLLUP_CRON_ACTION=check)"
grep -q 'not the cnf time now' <<<"$out" && pass "4. check names a line that is not at the cnf time" || fail "4. drift ($out)"
printf 'env:\n  cost:\n    rollup_utc: "02:00"\n' >"$T/cnf.yaml"

# 5. remove
out="$(cron DRY_RUN=0 COST_ROLLUP_CRON_ACTION=remove)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tagged)" = 0 ] && [ "$(tagged "")" = 1 ] && grep -q 'other:job$' "$CT" && grep -q 'cost-rollup-dev-not-this$' "$CT" \
  && pass "5. remove: the dev line goes, the others stay" || fail "5. ($rc: $(cat "$CT"))"
out="$(cron COST_ROLLUP_CRON_ACTION=check)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NOT installed' <<<"$out" && pass "4. control: check fails when not installed" || fail "4. control ($rc: $out)"

# 6. refusals
cp "$CT" "$T/ct.2"
out1="$(cron DRY_RUN=0 ENV=)"; rc1=$?
printf 'env:\n  cost:\n    rollup_utc: "2am"\n' >"$T/cnf.yaml"
out2="$(cron DRY_RUN=0)"; rc2=$?
printf 'env:\n  cost:\n    rollup_utc: "02:00"\n' >"$T/cnf.yaml"
[ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && grep -q 'rollup_utc must be HH:MM' <<<"$out2" && cmp -s "$CT" "$T/ct.2" \
  && pass "6. no ENV and a bad cnf time are refused, nothing written" || fail "6. ($rc1 $out1 / $rc2 $out2)"
# Only a linked worktree can be refused: in a main checkout or an exported
# tree (CI) the same call installs for real, so it runs only where it must fail.
if [ "$(git -C "$PROJ_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null)" != "$(git -C "$PROJ_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then
  out3="$(cron DRY_RUN=0 COST_ROLLUP_ALLOW_WORKTREE=0)"; rc3=$?
  [ "$rc3" -ne 0 ] && grep -q 'linked worktree' <<<"$out3" && cmp -s "$CT" "$T/ct.2" \
    && pass "6. a linked worktree is refused, nothing written" || fail "6. worktree ($rc3: $out3)"
else
  pass "6. (the main checkout: the linked-worktree refusal is not reachable here)"
fi

# 7. COST_SOURCES
out="$(cron DRY_RUN=0 COST_SOURCES='fleet_tokens agent_hours')"; rc=$?
line="$(grep ' # csi-spl:cost-rollup-dev$' "$CT")"
[ "$rc" -eq 0 ] && [ "$(tagged)" = 1 ] && [[ "$line" == *"env ENV=dev COST_SOURCES='fleet_tokens agent_hours' DRY_RUN=0 ./run -a do_spl_cost_rollup_daily >> "* ]] \
  && pass "7. COST_SOURCES lands in the one tagged line" || fail "7. ($rc: $out; $line)"
[ "$(sh -c "env ENV=dev COST_SOURCES='fleet_tokens agent_hours' sh -c 'printf %s \"\$COST_SOURCES\"'")" = "fleet_tokens agent_hours" ] \
  && pass "7. the line's quoting gives the rollup both names in one COST_SOURCES" || fail "7. quoting"
out="$(cron DRY_RUN=0)"
! grep -q 'COST_SOURCES' "$CT" && [ "$(tagged)" = 1 ] && pass "7. control: without it the line carries none (the cnf list)" || fail "7. control ($(cat "$CT"))"
cp "$CT" "$T/ct.3"
out="$(cron DRY_RUN=0 COST_SOURCES='gcp;rm -rf x')"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FATAL COST_SOURCES must be' <<<"$out" && cmp -s "$CT" "$T/ct.3" \
  && pass "7. a bad COST_SOURCES is refused, nothing written" || fail "7. bad ($rc: $out)"

echo "spl-cost-rollup-install-cron: ${fails} failure(s)"
[ "$fails" -eq 0 ]
