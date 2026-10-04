#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_update_install_cron with a stub crontab. Every check
# has a failing control.
#   1. the dry run prints the diff and changes nothing
#   2. install: ONE line, `0 0,12 * * *`, tagged `# csi-spl:box-update`,
#      running do_spl_box_update with ENV and DRY_RUN=0; other lines kept
#   3. a second install changes nothing; a changed ENV replaces the line
#   4. check: passes when installed, fails when not
#   5. remove: the tagged line goes, the others stay
#   6. a missing ENV, and a linked worktree, are refused (nothing written)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CT="$T/crontab"
printf '0 8 * * * /opt/other/run-me.sh # other:job\n0 9 * * * x # csi-spl:box-update-not-this\n' >"$CT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
cron() {
  SNIPPET='do_spl_box_update_install_cron' in_orc BOX_UPDATE_CRONTAB="$T/fake-crontab" BOX_UPDATE_ALLOW_WORKTREE=1 \
    BOX_UPDATE_CRON_LOG_DIR="$T/log" "$@" 2>&1
}
tagged() { grep -c ' # csi-spl:box-update$' "$CT"; }

# 1. dry run
cp "$CT" "$T/ct.0"
out="$(cron)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$CT" "$T/ct.0" && grep -q '^PLAN cron' <<<"$out" && grep -q '^  +0 0,12 \* \* \* ' <<<"$out" \
  && pass "1. the dry run prints the diff and changes nothing" || fail "1. ($rc: $out)"

# 2. install
out="$(cron DRY_RUN=0)"; rc=$?
line="$(grep ' # csi-spl:box-update$' "$CT")"
[ "$rc" -eq 0 ] && [ "$(tagged)" = 1 ] && [[ "$line" == "0 0,12 * * * cd $PROJ_ROOT && "* ]] \
  && [[ "$line" == *"env ENV=dev DRY_RUN=0 ./run -a do_spl_box_update >> $T/log/cron.out 2>&1 # csi-spl:box-update" ]] \
  && [[ "$line" == *"flock -n $T/log/box-update.lock "* ]] && pass "2. one line at 00:00 and 12:00 running do_spl_box_update" || fail "2. ($rc: $out; $line)"
grep -q 'other:job$' "$CT" && grep -q 'csi-spl:box-update-not-this$' "$CT" && [ -d "$T/log" ] \
  && pass "2. ...the other lines kept (a longer tag too), the log dir made" || fail "2. others ($(cat "$CT"))"

# 3. idempotent; a changed ENV replaces
cp "$CT" "$T/ct.1"
out="$(cron DRY_RUN=0)"
cmp -s "$CT" "$T/ct.1" && grep -q 'OK cron: nothing to change' <<<"$out" && pass "3. a second install changes nothing" || fail "3. ($out)"
out="$(cron DRY_RUN=0 ENV=prd)"
[ "$(tagged)" = 1 ] && grep -q 'env ENV=prd DRY_RUN=0' "$CT" && pass "3. control: ENV=prd replaces the line in place" || fail "3. control ($(cat "$CT"))"

# 4. check
out="$(cron BOX_UPDATE_CRON_ACTION=check)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'OK the box update cron is installed' <<<"$out" && pass "4. check passes when installed" || fail "4. ($rc: $out)"

# 5. remove
out="$(cron DRY_RUN=0 BOX_UPDATE_CRON_ACTION=remove)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tagged)" = 0 ] && grep -q 'other:job$' "$CT" && grep -q 'box-update-not-this$' "$CT" \
  && pass "5. remove: the tagged line goes, the others stay" || fail "5. ($rc: $(cat "$CT"))"
out="$(cron BOX_UPDATE_CRON_ACTION=check)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NOT installed' <<<"$out" && pass "4. control: check fails when not installed" || fail "4. control ($rc: $out)"

# 6. refusals
cp "$CT" "$T/ct.2"
out="$(cron DRY_RUN=0 ENV=)"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$CT" "$T/ct.2" && grep -q 'FATAL ENV must be dev or prd' <<<"$out" && pass "6. a missing ENV is refused" || fail "6. env ($rc: $out)"
# a linked worktree, built here so the case runs the same in CI's main checkout
git init -q -b master "$T/main" && git -C "$T/main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T/main" worktree add -q --detach "$T/wt" && mkdir -p "$T/wt/csi-spl-orc" "$T/main/csi-spl-orc"
wt() {
  env PROJ_PATH="$1" BOX_UPDATE_CRONTAB="$T/fake-crontab" BOX_UPDATE_CRON_LOG_DIR="$T/log" ENV=dev DRY_RUN=0 \
    bash -c 'do_log() { echo "$*"; }; source "$0"; do_spl_box_update_install_cron' "$PROJ_ROOT/src/bash/run/spl-box-update-install-cron.func.sh" 2>&1
}
out="$(wt "$T/wt/csi-spl-orc")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'is a linked worktree' <<<"$out" && cmp -s "$CT" "$T/ct.2" && pass "6. a linked worktree is refused, nothing written" || fail "6. worktree ($rc: $out)"
out="$(wt "$T/main/csi-spl-orc")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tagged)" = 1 ] && grep -q "cd $T/main/csi-spl-orc && " "$CT" && pass "6. control: the main checkout installs" || fail "6. control ($rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
