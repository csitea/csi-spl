#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_labels_translate_install_cron (spec 123 section 16.6.7,
# row L5) with a stub crontab and a stub cnf. Every check has a failing control.
#   1. the dry run prints the diff and changes nothing
#   2. install: ONE line at cnf env.cost.labels_translate_utc in box local
#      time, tagged `# csi-spl:cost-labels-translate-dev`, running
#      do_spl_cost_labels_translate with ENV and DRY_RUN=0 under flock; other
#      lines kept
#   3. install twice = one line (row L5's done test; its red control: a second
#      install that adds a line fails here); another env gets its own line
#   4. check names the schedule when installed, fails when not
#   5. remove: the tagged line goes, the others stay
#   6. no ENV, a bad cnf time, a bad schedule and a linked worktree are refused
#   7. no override: the log dir is spl_var_app_subdir's
#      $SPL_VAR_APP_DIR/cost-labels-translate
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CT="$T/crontab"
printf '0 8 * * * /opt/other/run-me.sh # other:job\n0 9 * * * x # csi-spl:cost-labels-translate-dev-not-this\n0 2 * * * y # csi-spl:cost-rollup-dev\n' >"$CT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
cnf_time() { printf 'env:\n  cost:\n    rollup_utc: "02:00"\n    labels_translate_utc: "%s"\n' "$1" >"$T/cnf.yaml"; }
cnf_time "03:00"
cron() {
  SNIPPET='do_spl_cloud_cnf() { spl_require_cloud_env && SPL_CNF="$CNF"; }; do_spl_cost_labels_translate_install_cron' \
    in_orc TZ=Europe/Helsinki CNF="$T/cnf.yaml" COST_LABELS_TRANSLATE_CRONTAB="$T/fake-crontab" COST_LABELS_TRANSLATE_ALLOW_WORKTREE=1 \
    COST_LABELS_TRANSLATE_CRON_LOG_DIR="$T/log" "$@" 2>&1
}
tagged() { grep -c " # csi-spl:cost-labels-translate${1-"-dev"}\$" "$CT"; }
local_sched="$(TZ=Europe/Helsinki date -d "$(date -u +%F) 03:00 UTC" '+%-M %-H * * *')"

# 1. dry run
cp "$CT" "$T/ct.0"
out="$(cron)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$CT" "$T/ct.0" && grep -q '^PLAN cron' <<<"$out" && grep -qF "  +$local_sched cd " <<<"$out" \
  && pass "1. the dry run prints the diff and changes nothing" || fail "1. ($rc: $out)"

# 2. install
out="$(cron DRY_RUN=0)"; rc=$?
line="$(grep ' # csi-spl:cost-labels-translate-dev$' "$CT")"
[ "$rc" -eq 0 ] && [ "$(tagged)" = 1 ] && [[ "$line" == "$local_sched cd $PROJ_ROOT && "* ]] && [[ "$local_sched" != "0 3 * * *" ]] \
  && [[ "$line" == *"flock -n $T/log/cost-labels-translate-dev.lock env ENV=dev DRY_RUN=0 ./run -a do_spl_cost_labels_translate >> $T/log/cron-dev.out 2>&1 # csi-spl:cost-labels-translate-dev" ]] \
  && pass "2. one line at 03:00 UTC in box local time ($local_sched) running the translate under flock" || fail "2. ($rc: $out; $line)"
grep -q 'other:job$' "$CT" && grep -q 'cost-labels-translate-dev-not-this$' "$CT" && grep -q 'cost-rollup-dev$' "$CT" && [ -d "$T/log" ] \
  && pass "2. ...the other lines kept (a longer tag and the rollup too), the log dir made" || fail "2. others ($(cat "$CT"))"

# 3. install twice = one line; prd is its own line
cp "$CT" "$T/ct.1"
out="$(cron DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tagged)" = 1 ] && cmp -s "$CT" "$T/ct.1" && grep -q 'OK cron: nothing to change' <<<"$out" \
  && pass "3. install twice = one line, the crontab unchanged" || fail "3. a second install changed the crontab: $(tagged) tagged line(s) ($out)"
out="$(cron DRY_RUN=0 COST_LABELS_TRANSLATE_CRON_SCHEDULE='15 4 * * *')"
[ "$(tagged)" = 1 ] && grep -q '^15 4 \* \* \* cd .* # csi-spl:cost-labels-translate-dev$' "$CT" \
  && pass "3. a new time replaces the line, still one" || fail "3. new time ($(cat "$CT"))"
out="$(cron DRY_RUN=0)"
out="$(cron DRY_RUN=0 ENV=prd)"
[ "$(tagged)" = 1 ] && [ "$(tagged "")" = 1 ] && grep -q 'env ENV=prd DRY_RUN=0 ./run -a do_spl_cost_labels_translate' "$CT" \
  && pass "3. control: ENV=prd adds its own line, the dev one stays" || fail "3. control ($(cat "$CT"))"

# 4. check names the schedule
out="$(cron COST_LABELS_TRANSLATE_CRON_ACTION=check)"; rc=$?
[ "$rc" -eq 0 ] && grep -qF "OK the cost labels translate cron is installed, schedule '$local_sched' box local" <<<"$out" && ! grep -q 'not the cnf time' <<<"$out" \
  && pass "4. check passes and names the schedule ($local_sched)" || fail "4. ($rc: $out)"
cnf_time "04:30"
out="$(cron COST_LABELS_TRANSLATE_CRON_ACTION=check)"
grep -q 'not the cnf time now' <<<"$out" && pass "4. check names a line that is not at the cnf time" || fail "4. drift ($out)"
cnf_time "03:00"

# 5. remove
out="$(cron DRY_RUN=0 COST_LABELS_TRANSLATE_CRON_ACTION=remove)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tagged)" = 0 ] && [ "$(tagged "")" = 1 ] && grep -q 'other:job$' "$CT" && grep -q 'cost-labels-translate-dev-not-this$' "$CT" && grep -q 'cost-rollup-dev$' "$CT" \
  && pass "5. remove: the dev line goes, the others stay" || fail "5. ($rc: $(cat "$CT"))"
out="$(cron COST_LABELS_TRANSLATE_CRON_ACTION=check)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NOT installed' <<<"$out" && pass "4. control: check fails when not installed" || fail "4. control ($rc: $out)"

# 6. refusals
cp "$CT" "$T/ct.2"
out1="$(cron DRY_RUN=0 ENV=)"; rc1=$?
cnf_time "3am"
out2="$(cron DRY_RUN=0)"; rc2=$?
cnf_time "03:00"
out3="$(cron DRY_RUN=0 COST_LABELS_TRANSLATE_CRON_SCHEDULE='0 3 * *')"; rc3=$?
[ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ "$rc3" -ne 0 ] && grep -q 'labels_translate_utc must be HH:MM' <<<"$out2" \
  && grep -q 'must be five cron fields' <<<"$out3" && cmp -s "$CT" "$T/ct.2" \
  && pass "6. no ENV, a bad cnf time and a bad schedule are refused, nothing written" || fail "6. ($rc1 $out1 / $rc2 $out2 / $rc3 $out3)"
# Only a linked worktree can be refused: in a main checkout or an exported
# tree (CI) the same call installs for real, so it runs only where it must fail.
if [ "$(git -C "$PROJ_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null)" != "$(git -C "$PROJ_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then
  out4="$(cron DRY_RUN=0 COST_LABELS_TRANSLATE_ALLOW_WORKTREE=0)"; rc4=$?
  [ "$rc4" -ne 0 ] && grep -q 'linked worktree' <<<"$out4" && cmp -s "$CT" "$T/ct.2" \
    && pass "6. a linked worktree is refused, nothing written" || fail "6. worktree ($rc4: $out4)"
else
  pass "6. (the main checkout: the linked-worktree refusal is not reachable here)"
fi

# 7. no override: the log dir derives from SPL_VAR_APP_DIR
out="$(cron COST_LABELS_TRANSLATE_CRON_LOG_DIR= SPL_VAR_APP_DIR="$T/var")"; rc=$?
[ "$rc" -eq 0 ] && grep -qF "flock -n $T/var/cost-labels-translate/cost-labels-translate-dev.lock " <<<"$out" && grep -qF ">> $T/var/cost-labels-translate/cron-dev.out 2>&1" <<<"$out" && [ ! -e "$T/var" ] \
  && pass "7. no log dir override: the lock and cron-dev.out under \$SPL_VAR_APP_DIR/cost-labels-translate, a dry run creates nothing" || fail "7. default log dir ($rc: $out)"

echo "spl-cost-labels-translate-install-cron: ${fails} failure(s)"
[ "$fails" -eq 0 ]
