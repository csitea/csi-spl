#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_disk_headroom and do_check_disk_headroom_install_cron on a
# fixture df, a stub sender and a fixture crontab.
#   1. the check: pseudo filesystems and a second row of one device are
#      skipped, /tmp is checked although it is tmpfs; the dry run (default)
#      plans the notes and sends / writes nothing; DRY_RUN=0 sends ONE note
#      per crossing, a second tick sends none, a mount back under its limit
#      is CLEAR and warns again on its next crossing; a failed send is
#      retried next tick; df failing is a WARN and a note.
#      CONTROLS: the same fixture under the limits sends nothing and exits 0;
#      a lower env limit turns a quiet mount into a crossing; the real df
#      measures this box's / .
#   2. the install: the dry run prints the line and writes nothing; DRY_RUN=0
#      adds ONE tagged line, every other line kept; a second install is a
#      no-op; check passes; remove restores the crontab byte for byte
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DF="$T/df.rows" SENT="$T/sent.log" ST="$T/state"
rows() {  # <data blocks%> <tmp inodes%>
  printf '%s\n' 'Filesystem     Type     Use% IUse% Mounted on' \
    "/dev/sda1      ext4     40%  10%   /" \
    "/dev/sdb1      xfs      $1  5%    /data" \
    "/dev/sdb1      xfs      $1  5%    /srv/data-bind" \
    "tmpfs          tmpfs    20%  $2   /tmp" \
    "tmpfs          tmpfs    99%  99%  /run" \
    "overlay        overlay  99%  99%  /var/lib/docker/overlay2/x/merged" \
    "/dev/sda15     vfat     5%   -    /boot/efi" >"$DF"
}
printf '#!/bin/sh\n[ -e %q ] && { echo "df: boom" >&2; exit 1; }\ncat %q\n' "$T/df.fail" "$DF" >"$T/df"
printf '#!/bin/sh\n[ -e %q ] && exit 1\necho "$*" >>%q\n' "$T/send.fail" "$SENT" >"$T/send"
chmod +x "$T/df" "$T/send"
chk() { SNIPPET='do_check_disk_headroom' in_orc DISK_HEADROOM_DF="$T/df" DISK_HEADROOM_SEND="$T/send" DISK_HEADROOM_STATE_DIR="$ST" "$@" 2>&1; }
sends() { [ -f "$SENT" ] && grep -c . "$SENT" || echo 0; }

rows 50% 20%
out="$(chk DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ "$(sends)" = 0 ] && grep -q 'CHECK .* mounts=4 skipped=3 high=0 /=40%b/10%i /data=50%b/5%i /tmp=20%b/20%i /boot/efi=5%b/-%i$' <<<"$out" \
  && pass "1. CONTROL: all under the limits - no note, exit 0, one CHECK line" || fail "1. control quiet (rc $rc: $out)"
[ "$(grep -c . <<<"$out")" = 1 ] && pass "1. ...exactly one log line per check" || fail "1. lines: $out"
out="$(chk DRY_RUN=0 DISK_HEADROOM_BLOCK_PCT=50)"; rc=$?
[ "$rc" = 1 ] && [ "$(sends)" = 1 ] && grep -q 'WARN /data (xfs, /dev/sdb1) blocks 50% >= 50%' <<<"$out" \
  && pass "1. CONTROL: a lower env limit turns the same mount into a crossing" || fail "1. env limit (rc $rc: $out)"
rm -rf "$ST" "$SENT"

rows 90% 85%
out="$(chk)"; rc=$?
[ "$rc" = 1 ] && grep -q 'PLAN note to orchestrator: /data (xfs, /dev/sdb1) blocks 90% >= 85%' <<<"$out" \
  && grep -q 'PLAN note to orchestrator: /tmp (tmpfs, tmpfs) inodes 85% >= 80%' <<<"$out" \
  && [ "$(sends)" = 0 ] && [ ! -e "$ST/crossings" ] \
  && pass "1. the dry run (default) plans both notes and sends / writes nothing" || fail "1. dry run (rc $rc: $out)"
! grep -qE '/run|overlay|data-bind' <<<"$(grep -E 'WARN|PLAN' <<<"$out")" \
  && pass "1. tmpfs /run, overlay and the bind row of /dev/sdb1 are not checked" || fail "1. skipped mounts warned: $out"

out="$(chk DRY_RUN=0)"; rc=$?
[ "$rc" = 1 ] && [ "$(sends)" = 2 ] && grep -q -- '--to orchestrator --kind note --task disk-headroom --body DISK HEADROOM .*/data (xfs, /dev/sdb1) blocks 90% >= 85%' "$SENT" \
  && grep -q -- '/tmp (tmpfs, tmpfs) inodes 85% >= 80%' "$SENT" \
  && pass "1. DRY_RUN=0 sends ONE note per crossing to the orchestrator" || fail "1. live (rc $rc: $out / $(cat "$SENT" 2>/dev/null))"
out="$(chk DRY_RUN=0)"
[ "$(sends)" = 2 ] && grep -q 'WARN /data' <<<"$out" && pass "1. the next tick still WARNs but sends nothing" || fail "1. repeat ($(cat "$SENT"))"

rows 50% 85%
out="$(chk DRY_RUN=0)"
grep -q 'CLEAR blocks:/data is back under its limit' <<<"$out" && [ "$(sends)" = 2 ] \
  && pass "1. a mount back under its limit is CLEAR" || fail "1. clear ($out)"
rows 91% 85%
chk DRY_RUN=0 >/dev/null
[ "$(sends)" = 3 ] && pass "1. ...and its next crossing sends again" || fail "1. re-cross ($(cat "$SENT"))"

rows 50% 20%; chk DRY_RUN=0 >/dev/null; rows 92% 20%
touch "$T/send.fail"; out="$(chk DRY_RUN=0)"; rm -f "$T/send.fail"
grep -q 'WARN could not tell orchestrator about blocks:/data: retried next tick' <<<"$out" && [ "$(sends)" = 3 ] \
  && pass "1. a failed send is loud" || fail "1. send fail ($out)"
chk DRY_RUN=0 >/dev/null
[ "$(sends)" = 4 ] && pass "1. ...and retried on the next tick" || fail "1. retry ($(cat "$SENT"))"

touch "$T/df.fail"; out="$(chk DRY_RUN=0)"; rc=$?; rm -f "$T/df.fail"
[ "$rc" = 1 ] && grep -q 'WARN df failed, nothing was measured: df: boom' <<<"$out" && grep -q 'df failed' "$SENT" \
  && pass "1. df failing is a WARN and a note, never silent" || fail "1. df fail (rc $rc: $out)"
out="$(chk DRY_RUN=7)"; rc=$?
[ "$rc" = 2 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. DRY_RUN is checked" || fail "1. DRY_RUN=7 ($out)"

out="$(SNIPPET='do_check_disk_headroom' in_orc DISK_HEADROOM_SEND="$T/send" DISK_HEADROOM_STATE_DIR="$T/real" DISK_HEADROOM_BLOCK_PCT=100 DISK_HEADROOM_INODE_PCT=100 2>&1)"
grep -qE 'CHECK .* mounts=[1-9][0-9]* .* /=[0-9]+%b/' <<<"$out" \
  && pass "1. CONTROL: the real df measures this box's /" || fail "1. real df ($out)"

# 2. the installer ------------------------------------------------------------
SH="$T/shared"; mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh"; chmod +x "$SH/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh"
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/box-stats-cron.sh >> /l/cron.out 2>&1 # csi-spl:box-stats' \
  '* * * * * /x/y.sh # csi-spl:disk-headroom-other' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
inst() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" DISK_HEADROOM_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/check-disk-headroom-install-cron.func.sh"
    do_check_disk_headroom_install_cron' 2>&1
}
want="7-59/15 * * * * DRY_RUN=0 $SH/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh >> $T/log/cron.out 2>&1 # csi-spl:disk-headroom"
out="$(inst)"; rc=$?
[[ $rc -eq 0 && "$out" == *'DRY_RUN nothing was touched'* && "$out" == *"+$want"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" \
  && pass "2. the dry run prints the every-15-min line and writes nothing" || fail "2. dry (rc=$rc): $out"
out="$(inst DISK_HEADROOM_CRON_ACTION=check)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *'NOT installed'* ]] && pass "2. CONTROL: check fails while it is not installed" || fail "2. check before (rc=$rc): $out"
out="$(inst DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c ' # csi-spl:disk-headroom$' "$T/crontab")" -eq 1 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 && -d "$T/log" ]] \
  && pass "2. DRY_RUN=0 adds ONE tagged line and the log dir" || fail "2. install (rc=$rc): $out / $(cat "$T/crontab")"
cmp -s <(grep -v ' # csi-spl:disk-headroom$' "$T/crontab") "$T/crontab.orig" \
  && pass "2. ...every other line kept (the -other tag too)" || fail "2. kept: $(cat "$T/crontab")"
cp "$T/crontab" "$T/crontab.once"; inst DRY_RUN=0 >/dev/null
cmp -s "$T/crontab" "$T/crontab.once" && pass "2. a second install changes no byte" || fail "2. reinstall: $(cat "$T/crontab")"
out="$(inst DISK_HEADROOM_CRON_ACTION=check)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *'is installed and its script is executable'* ]] && pass "2. check passes once installed" || fail "2. check (rc=$rc): $out"
out="$(inst DESK_CRON_SRC=/opt/x-wt/c-1)"; rc=$?
[ "$rc" = 1 ] && pass "2. an agent worktree is refused" || fail "2. worktree (rc=$rc): $out"
inst DRY_RUN=0 DISK_HEADROOM_CRON_ACTION=remove >/dev/null
cmp -s "$T/crontab" "$T/crontab.orig" && pass "2. remove restores the crontab byte for byte" || fail "2. remove: $(cat "$T/crontab")"

echo "check-disk-headroom: ${fails} failure(s)"
[ "$fails" -eq 0 ]
