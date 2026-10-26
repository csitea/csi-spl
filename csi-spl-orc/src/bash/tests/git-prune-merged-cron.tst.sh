#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the standing merged-branch prune (SPL-3609): git-prune-merged-cron.sh
# and do_git_prune_merged_install_cron, on a fake orc tree and a fake crontab.
#   1. the script runs the action with PRUNE_ALL_MERGED=1 DRY_RUN=0 in the
#      orc dir, START and STOP rc=0 lines, exit 0
#   2. a failing action: STOP rc=<n>, exit 1
#   3. another run holds the lock: OK line, the action not run, exit 0
#   4. from an agent worktree path (*-wt/*): refused, exit 2, not run
#   5. install: the dry run plans ONE tagged line and changes nothing;
#      DRY_RUN=0 writes it, every other line kept; a second install is a
#      no-op; remove restores the crontab byte for byte; a bad DRY_RUN,
#      action or minute is refused
#   6. CONTROL: the script without PRUNE_ALL_MERGED=1 fails case 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SCRIPT="$PROJ_ROOT/src/bash/scripts/git-prune-merged-cron.sh"

# tree <dir> <script>: a fake orc tree <dir>/csi-spl-orc with ./run and the script
tree() {
  mkdir -p "$1/csi-spl-orc/src/bash/scripts"
  printf '#!/bin/sh\nexit 0\n' >"$1/csi-spl-orc/run" && chmod +x "$1/csi-spl-orc/run"
  cp "$2" "$1/csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh"
}
STUB='echo "ALL=${PRUNE_ALL_MERGED:-unset} DRY=${DRY_RUN:-unset} PWD=$PWD"'
cronrun() { env GH_TOKEN=x GIT_PRUNE_CRON_LOG_DIR="$T/log" "$@"; }

# 1. the action runs with the all-merged mode, for real --------------------------
tree "$T/main" "$SCRIPT"
M="$T/main/csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh"
out="$(cronrun GIT_PRUNE_CRON_RUN="$STUB" bash "$M" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"ALL=1 DRY=0 PWD=$T/main/csi-spl-orc"* && "$out" == *'START git-prune-merged'* && "$out" == *'STOP git-prune-merged rc=0'* ]] \
  && pass "1. the action runs with PRUNE_ALL_MERGED=1 DRY_RUN=0 in the orc dir" || fail "1. rc=$rc out=$out"

# 2. a failing action ------------------------------------------------------------
out="$(cronrun GIT_PRUNE_CRON_RUN='exit 3' bash "$M" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *'STOP git-prune-merged rc=3'* ]] && pass "2. a failing action: STOP rc=3, exit 1" || fail "2. rc=$rc out=$out"

# 3. the lock is held -------------------------------------------------------------
out="$(flock -x "$T/log/run.lock" env GH_TOKEN=x GIT_PRUNE_CRON_LOG_DIR="$T/log" GIT_PRUNE_CRON_RUN="$STUB" bash "$M" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *'another git-prune-merged run holds'* && "$out" != *ALL=* ]] \
  && pass "3. a held lock: OK, the action not run" || fail "3. rc=$rc out=$out"

# 4. an agent worktree path --------------------------------------------------------
tree "$T/x-wt/c-1" "$SCRIPT"
out="$(cronrun GIT_PRUNE_CRON_RUN="$STUB" bash "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *'agent worktree'* && "$out" != *ALL=* ]] && pass "4. a worktree path is refused, exit 2" || fail "4. rc=$rc out=$out"

# 5. the install action ------------------------------------------------------------
CT="$T/crontab"
printf '%s\n' '# m h dom mon dow command' '5 * * * * bash /x/other.sh # csi-spl:other' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_git_prune_merged_install_cron' in_orc GIT_PRUNE_CRONTAB="$T/fake-crontab" GIT_PRUNE_CRON_LOG_DIR="$T/clog" GIT_PRUNE_ALLOW_WORKTREE=1 "$@" 2>&1; }
want="47 \* \* \* \* bash $PROJ_ROOT/src/bash/scripts/git-prune-merged-cron.sh >> $T/clog/cron.out 2>&1 # csi-spl:git-prune-merged"
out="$(inst)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^  +[^+]' <<<"$out")" == 1 ]] && grep -q "^  +$want$" <<<"$out" && cmp -s "$CT" "$T/crontab.orig" \
  && pass "5. the dry run plans one tagged line, changes nothing" || fail "5. dry run rc=$rc out=$out"
out="$(inst DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c ' # csi-spl:git-prune-merged$' "$CT")" == 1 ]] && grep -q "^$want$" "$CT" \
  && cmp -s <(grep -v ' # csi-spl:git-prune-merged$' "$CT") "$T/crontab.orig" \
  && pass "5. DRY_RUN=0 writes the one line, every other line kept" || fail "5. install rc=$rc out=$out ct=$(cat "$CT")"
out="$(inst DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'nothing to change'* ]] && pass "5. a second install is a no-op" || fail "5. second install rc=$rc out=$out"
out="$(inst DRY_RUN=0 GIT_PRUNE_CRON_ACTION=remove)"; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$CT" "$T/crontab.orig" && pass "5. remove restores the crontab byte for byte" || fail "5. remove rc=$rc ct=$(cat "$CT")"
for args in DRY_RUN=2 GIT_PRUNE_CRON_ACTION=add GIT_PRUNE_CRON_MINUTE=60 GIT_PRUNE_CRON_MINUTE=x; do
  out="$(inst DRY_RUN=0 "$args")"; rc=$?
  [[ $rc -ne 0 && "$out" == *FATAL* ]] && cmp -s "$CT" "$T/crontab.orig" && pass "5. refused, nothing written: $args" || fail "5. $args rc=$rc out=$out"
done

# 6. CONTROL: without PRUNE_ALL_MERGED=1 case 1 fails ------------------------------
sed 's/PRUNE_ALL_MERGED=1 DRY_RUN=0 bash -c/DRY_RUN=0 bash -c/' "$SCRIPT" >"$T/noall.sh"
if cmp -s "$SCRIPT" "$T/noall.sh"; then
  fail "6. control: the sed did not drop PRUNE_ALL_MERGED=1"
else
  tree "$T/ctl" "$T/noall.sh"
  out="$(cronrun GIT_PRUNE_CRON_RUN="$STUB" bash "$T/ctl/csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh" 2>&1)"
  [[ "$out" == *'ALL=unset'* ]] && pass "6. control: without the mode the action runs as a round prune (ALL=unset), case 1 would fail" || fail "6. control: $out"
fi

if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
