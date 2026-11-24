#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_private_overlay_install_cron (spec 158 H4 + H5) with a stub
# crontab. Every check has a failing control.
#   1. the master box: the dry run prints the diff and changes nothing; with
#      no RESERVE_GH_TOKEN_FILE the install is refused (no default)
#   2. the master box, DRY_RUN=0: ONE line, every minute,
#      do_spl_tenant_host_reserve with the token file and DRY_RUN=0 under
#      flock, tagged `# csi-spl:tenant-host-reserve`; other lines kept; a
#      second install changes nothing
#   3. another box: ONE line, every 2 minutes, do_spl_private_overlay_pull
#      FROM_BOX=<master> under flock, tagged `# csi-spl:private-overlay-pull`;
#      it drops a reserve line (the box's role moved), needs no token
#   4. check: passes when this role's line is there, fails when it is not
#      and when the other role's line is there too
#   5. remove: the tagged line goes, the others stay
#   6. a linked worktree, a bad DRY_RUN or action, and a token file in the
#      cron line with shell characters are refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CT="$T/crontab"
printf '0 8 * * * /opt/other/run-me.sh # other:job\n0 9 * * * x # csi-spl:tenant-host-reserve-not-this\n' >"$CT"
cp "$CT" "$T/ct.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
mkdir -p "$T/tok"; printf 'synthetic\n' >"$T/tok/token"; chmod 600 "$T/tok/token"
cron() {
  SNIPPET='do_spl_private_overlay_install_cron' in_orc PRIVATE_OVERLAY_CRONTAB="$T/fake-crontab" PRIVATE_OVERLAY_ALLOW_WORKTREE=1 \
    PRIVATE_OVERLAY_CRON_LOG_DIR="$T/log" "$@" 2>&1
}
tagged() { grep -c " # csi-spl:$1\$" "$CT"; }

# 1. the master box: dry run, no token
out="$(cron SPOOL_DESK_BOX=sat RESERVE_GH_TOKEN_FILE="$T/tok/token")"; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$CT" "$T/ct.orig" && grep -q '^PLAN cron' <<<"$out" && grep -q '+\* \* \* \* \* cd .*do_spl_tenant_host_reserve' <<<"$out" &&
  pass "1. master box: the dry run prints the diff and changes nothing" || fail "1. dry ($rc: $out)"
out="$(cron SPOOL_DESK_BOX=sat DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 ]] && cmp -s "$CT" "$T/ct.orig" && grep -q 'RESERVE_GH_TOKEN_FILE is not set (no default)' <<<"$out" &&
  pass "1. master box: no token file -> refused, nothing written" || fail "1. no token ($rc: $out)"

# 2. the master box install
out="$(cron SPOOL_DESK_BOX=sat RESERVE_GH_TOKEN_FILE="$T/tok/token" DRY_RUN=0)"; rc=$?
line="$(grep ' # csi-spl:tenant-host-reserve$' "$CT")"
[[ $rc -eq 0 && "$(tagged tenant-host-reserve)" == 1 && "$line" == "* * * * * cd $PROJ_ROOT && "* ]] &&
  [[ "$line" == *"flock -n $T/log/reserve.lock env RESERVE_GH_TOKEN_FILE=$T/tok/token DRY_RUN=0 ./run -a do_spl_tenant_host_reserve >> $T/log/reserve.out 2>&1 # csi-spl:tenant-host-reserve" ]] &&
  grep -qxF '0 8 * * * /opt/other/run-me.sh # other:job' "$CT" && grep -q 'tenant-host-reserve-not-this$' "$CT" &&
  pass "2. master box: one line every minute, the reserve with its token file under flock; other lines kept" || fail "2. install ($rc: $out; $line)"
cp "$CT" "$T/ct.1"
out="$(cron SPOOL_DESK_BOX=sat RESERVE_GH_TOKEN_FILE="$T/tok/token" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$CT" "$T/ct.1" && pass "2. a second install changes nothing" || fail "2. idempotent ($rc: $out)"

# 4. check on the master box
out="$(cron SPOOL_DESK_BOX=sat PRIVATE_OVERLAY_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'tenant-host-reserve cron is installed' <<<"$out" && pass "4. check: installed -> OK" || fail "4. check ($rc: $out)"

# 3. the box changes role: another box pulls, the reserve line goes
out="$(cron SPOOL_DESK_BOX=boxb DRY_RUN=0)"; rc=$?
line="$(grep ' # csi-spl:private-overlay-pull$' "$CT")"
[[ $rc -eq 0 && "$(tagged private-overlay-pull)" == 1 && "$(tagged tenant-host-reserve)" == 0 && "$line" == "*/2 * * * * cd $PROJ_ROOT && "* ]] &&
  [[ "$line" == *"flock -n $T/log/pull.lock env DRY_RUN=0 FROM_BOX=sat ./run -a do_spl_private_overlay_pull >> $T/log/pull.out 2>&1 # csi-spl:private-overlay-pull" ]] &&
  grep -qxF '0 8 * * * /opt/other/run-me.sh # other:job' "$CT" &&
  pass "3. another box: one line every 2 min, the pull from sat under flock, no token; the reserve line dropped" || fail "3. pull install ($rc: $out; $(cat "$CT"))"
out="$(cron SPOOL_DESK_BOX=boxb SPL_PRIVATE_MASTER_BOX=box9 DRY_RUN=0)"
grep -q 'FROM_BOX=box9 ' "$CT" && [[ "$(tagged private-overlay-pull)" == 1 ]] && pass "3. the pull names SPL_PRIVATE_MASTER_BOX, still one line" || fail "3. master box9: $(cat "$CT")"

# 4. CONTROLS of check
out="$(cron SPOOL_DESK_BOX=sat PRIVATE_OVERLAY_CRON_ACTION=check)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no cron line tagged csi-spl:tenant-host-reserve' <<<"$out" &&
  pass "4. CONTROL: check on the master box with only a pull line -> FAIL" || fail "4. check missing ($rc: $out)"
printf '* * * * * x # csi-spl:tenant-host-reserve\n' >>"$CT"
out="$(cron SPOOL_DESK_BOX=boxb PRIVATE_OVERLAY_CRON_ACTION=check)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "also carries the csi-spl:tenant-host-reserve line" <<<"$out" &&
  pass "4. CONTROL: both roles' lines -> FAIL" || fail "4. check both ($rc: $out)"

# 5. remove
out="$(cron SPOOL_DESK_BOX=boxb PRIVATE_OVERLAY_CRON_ACTION=remove DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(tagged private-overlay-pull)" == 0 && "$(tagged tenant-host-reserve)" == 0 ]] &&
  grep -qxF '0 8 * * * /opt/other/run-me.sh # other:job' "$CT" && grep -q 'tenant-host-reserve-not-this$' "$CT" &&
  pass "5. remove drops both tagged lines only" || fail "5. remove ($rc: $(cat "$CT"))"

# 6. refusals
cp "$CT" "$T/ct.6"
# absolute, as the action reads them: from a subdir --git-dir is absolute and
# --git-common-dir relative, so a main checkout would read as a worktree
if [[ "$(git -C "$PROJ_ROOT" rev-parse --path-format=absolute --git-dir)" != "$(git -C "$PROJ_ROOT" rev-parse --path-format=absolute --git-common-dir)" ]]; then
  out="$(SNIPPET='do_spl_private_overlay_install_cron' in_orc PRIVATE_OVERLAY_CRONTAB="$T/fake-crontab" PRIVATE_OVERLAY_CRON_LOG_DIR="$T/log" \
    PROJ_PATH="$APP_ROOT/csi-spl-orc" SPOOL_DESK_BOX=boxb DRY_RUN=0 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && grep -q 'is a linked worktree' <<<"$out" && cmp -s "$CT" "$T/ct.6" &&
    pass "6. a linked worktree is refused, nothing written" || fail "6. worktree ($rc: $out)"
else
  pass "6. (main checkout: the worktree refusal is not reachable here)"
fi
for bad in "DRY_RUN=2" "PRIVATE_OVERLAY_CRON_ACTION=nope" "SPL_PRIVATE_MASTER_BOX=Sat;x"; do
  out="$(cron SPOOL_DESK_BOX=boxb "$bad")"; rc=$?
  [[ $rc -ne 0 ]] && cmp -s "$CT" "$T/ct.6" && pass "6. $bad refused" || fail "6. $bad ($rc: $out)"
done
mkdir -p "$T/tok dir"; cp "$T/tok/token" "$T/tok dir/token"; chmod 600 "$T/tok dir/token"
out="$(cron SPOOL_DESK_BOX=sat RESERVE_GH_TOKEN_FILE="$T/tok dir/token" DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 ]] && cmp -s "$CT" "$T/ct.6" && grep -q 'must be an absolute path of letters' <<<"$out" &&
  pass "6. a token path with a space (it goes into the cron line) is refused" || fail "6. token path ($rc: $out)"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
