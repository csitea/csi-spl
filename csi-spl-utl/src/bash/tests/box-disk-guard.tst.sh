#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for the box disk guard (SPL-2235): do_box_disk_guard_install on a
# fixture crontab, box-disk-inventory.sh on fixture rows, disk-growers.sh on a
# fixture record. The live crontab and the live disks are untouched.
#   1. install: --check on an empty crontab = 3 missing, exit 1; the dry run
#      prints the 3 lines and writes nothing; DRY_RUN=0 adds them, every other
#      line kept; a second install changes no byte; --check = 3 installed;
#      a hand-edited line reads "differs" and an install puts it back in place;
#      the disk-headroom line moves the desk checkout under the desk-cron lock,
#      byte for byte the orc installer's prefix (SPL-2672), DESK_CRON_TRUNK honoured;
#      the SPL-2053 box-disk-sweep line reads "installed" as is, its unlocked
#      disk-headroom line "differs";
#      remove restores the crontab byte for byte; through the ./run harness.
#   2. inventory: a dir row gives size, file count and oldest date; a glob row
#      with no match is "absent"; no file name ever reaches the table;
#      DRY_RUN=1 writes no record, DISK_INV_GROWTH=1 one line per row, once
#      per day; a bad row name is refused.
#   3. growers: top 3 by bytes per day, inside the window only, a row that
#      shrank is not a grower; no record is a line, not a failure.
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 1. the installer -------------------------------------------------------------
mkdir -p "$T/bin" "$T/src/csi-spl-orc/src/bash/scripts" "$T/src-desk-cron/csi-spl-utl"
printf '#!/bin/sh\n' >"$T/src/csi-spl-orc/src/bash/scripts/box-disk-sweep.sh"
printf '#!/bin/sh\n' >"$T/src-desk-cron/csi-spl-utl/run"
chmod +x "$T/src/csi-spl-orc/src/bash/scripts/box-disk-sweep.sh" "$T/src-desk-cron/csi-spl-utl/run"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then [ -s "$FAKE_CRONTAB" ] || { echo "no crontab for x" >&2; exit 1; }; cat "$FAKE_CRONTAB"; exit 0; fi
cat >"$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
CT="$T/crontab"
inst() {
  env PROJ_PATH="$T/fake/csi-spl-utl" PATH="$T/bin:$PATH" FAKE_CRONTAB="$CT" \
    DISK_GUARD_SRC="$T/src" DISK_GUARD_VAR="$T/var" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    source "'"$UTL_ROOT"'/src/bash/run/box-disk-guard-install.func.sh"
    do_box_disk_guard_install' 2>&1
}
mkdir -p "$T/fake/csi-spl-utl"
: >"$CT"
out="$(inst DISK_GUARD_CHECK=true)"; rc=$?
[ "$rc" = 1 ] && [ "$(grep -c '^missing ' <<<"$out")" = 3 ] \
  && pass "1. CONTROL: --check on an empty crontab reads 3 missing, exit 1" || fail "1. check empty (rc $rc): $out"
printf '%s\n' '# keep me' '*/5 * * * * /x/a.sh # csi-spl:box-stats' '* * * * * /x/y.sh # csi-spl:disk-headroom-other' >"$CT"
cp "$CT" "$T/crontab.orig"
out="$(inst)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^> ' <<<"$out")" = 3 ] && grep -q 'DRY_RUN nothing was touched' <<<"$out" && cmp -s "$CT" "$T/crontab.orig" \
  && pass "1. the dry run (default) prints the 3 lines and writes nothing" || fail "1. dry (rc $rc): $out"
out="$(inst DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && for t in disk-headroom box-disk-sweep disk-growth; do [ "$(grep -c " # csi-spl:$t\$" "$CT")" = 1 ] || rc=9; done
[ "$rc" = 0 ] && cmp -s <(head -n 3 "$CT") "$T/crontab.orig" && [ -d "$T/var/box-disk-sweep" ] \
  && pass "1. DRY_RUN=0 adds ONE line per tag, every other line kept (the -other tag too)" || fail "1. install (rc $rc): $out / $(cat "$CT")"
grep -q "^23 3 \* \* \* cd $T/src-desk-cron/csi-spl-utl && DRY_RUN=0 ./run -a do_box_disk_inventory >> $T/var/box-disk-sweep/growth.cron.out 2>&1 # csi-spl:disk-growth\$" "$CT" \
  && pass "1. the growth line calls the csi-spl-utl action daily, never a raw script" || fail "1. growth line: $(cat "$CT")"
cp "$CT" "$T/crontab.once"; inst DRY_RUN=0 >/dev/null
cmp -s "$CT" "$T/crontab.once" && pass "1. a second install changes no byte" || fail "1. reinstall: $(cat "$CT")"
out="$(inst DISK_GUARD_CHECK=true)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^installed ' <<<"$out")" = 3 ] && pass "1. --check reads 3 installed, exit 0" || fail "1. check (rc $rc): $out"
sed -i 's/^11-59\/15 /13-59\/15 /' "$CT"
out="$(inst DISK_GUARD_CHECK=true)"; rc=$?
[ "$rc" = 1 ] && grep -q '^differs   csi-spl:box-disk-sweep' <<<"$out" && grep -q '  have: 13-59/15' <<<"$out" \
  && pass "1. a hand-edited line reads differs, with have and want" || fail "1. differs (rc $rc): $out"
inst DRY_RUN=0 >/dev/null
cmp -s "$CT" "$T/crontab.once" && pass "1. ...and an install puts it back in place" || fail "1. repair: $(cat "$CT")"
inst DRY_RUN=0 DISK_GUARD_ACTION=remove >/dev/null
cmp -s "$CT" "$T/crontab.orig" && pass "1. remove restores the crontab byte for byte" || fail "1. remove: $(cat "$CT")"
# the disk-headroom line moves the desk checkout under the ONE desk-cron lock (SPL-2672)
source "$UTL_ROOT/../csi-spl-orc/lib/bash/funcs/spl-desk-cron-lock.func.sh"
inst DRY_RUN=0 >/dev/null
hl="$(grep ' # csi-spl:disk-headroom$' "$CT")"
pre="$(spl_desk_cron_update_pre "$T/src-desk-cron" master)"
[ "$hl" = "7-59/15 * * * * ${pre}DRY_RUN=0 $T/src-desk-cron/csi-spl-orc/src/bash/scripts/cron-no-stack.sh $T/var/disk-headroom/cron.lock $T/src-desk-cron/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh >> $T/var/disk-headroom/cron.out 2>&1 # csi-spl:disk-headroom" ] \
  && grep -q "^7-59/15 \* \* \* \* cd $T/src-desk-cron && flock -w " <<<"$hl" \
  && pass "1. CONTROL: the disk-headroom line fetches + checks out under the desk-cron flock, the job behind cron-no-stack.sh (SPL-4495)" || fail "1. headroom lock: $hl"
out="$(inst DESK_CRON_TRUNK=main)"
grep -q "^> 7-59/15 .*git fetch -q origin main && git checkout -q --detach origin/main'" <<<"$out" \
  && pass "1. DESK_CRON_TRUNK sets the trunk the line follows" || fail "1. trunk: $out"
out="$(inst DESK_CRON_TRUNK='m;x')"; rc=$?
[ "$rc" = 1 ] && grep -q 'not a branch name' <<<"$out" && pass "1. a bad DESK_CRON_TRUNK is refused" || fail "1. bad trunk (rc $rc): $out"
inst DRY_RUN=0 DISK_GUARD_ACTION=remove >/dev/null
# the SPL-2053 hand-installed lines, as they read on both boxes (2026-10-16)
D=/opt/csi/csi-spl-desk-cron V=/var/csi/csi-spl
printf '%s\n' \
  "7-59/15 * * * * cd $D && git fetch -q origin master && git checkout -q --detach origin/master; DRY_RUN=0 $D/csi-spl-orc/src/bash/scripts/check-disk-headroom.sh >> $V/disk-headroom/cron.out 2>&1 # csi-spl:disk-headroom" \
  "11-59/15 * * * * DRY_RUN=0 BOX_SWEEP_GATE=1 BOX_SWEEP_LOCK=$V/box-disk-sweep/box-disk-sweep.lock bash /opt/csi/csi-spl/csi-spl-orc/src/bash/scripts/box-disk-sweep.sh >> $V/box-disk-sweep/box-disk-sweep.log 2>&1 # csi-spl:box-disk-sweep" >"$CT"
out="$(inst DISK_GUARD_CHECK=true DISK_GUARD_SRC= DISK_GUARD_VAR=)"; rc=$?
grep -q '^differs   csi-spl:disk-headroom' <<<"$out" && grep -q '^installed csi-spl:box-disk-sweep' <<<"$out" && grep -q '^missing   csi-spl:disk-growth' <<<"$out" \
  && pass "1. the boxes' SPL-2053 lines: box-disk-sweep installed, the unlocked disk-headroom differs (defaults)" || fail "1. live form: $out"
out="$(inst DISK_GUARD_ACTION=bogus)"; rc=$?
[ "$rc" = 1 ] && grep -q 'must be install, check or remove' <<<"$out" && pass "1. a bad action is refused" || fail "1. bad action (rc $rc): $out"
out="$(cd "$UTL_ROOT" && env PATH="$T/bin:$PATH" FAKE_CRONTAB="$CT" ./run -a do_box_disk_guard_install --check 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q '^missing   csi-spl:disk-growth' <<<"$out" && pass "1. ./run -a do_box_disk_guard_install --check maps the flag" || fail "1. ./run (rc $rc): $out"

# 2. the inventory -------------------------------------------------------------
INV="$UTL_ROOT/src/bash/scripts/box-disk-inventory.sh"
mkdir -p "$T/d/sub"
head -c 4096 /dev/zero >"$T/d/secret-name-1.txt"; head -c 4096 /dev/zero >"$T/d/sub/secret-name-2.txt"
touch -d '2020-01-02 12:00 UTC' "$T/d/sub/secret-name-2.txt"
printf '%s\n' '# c' "fix | dir | $T/d" "gone | dir | $T/nope/* $T/nope2" >"$T/rows"
inv() { env DISK_INV_ROWS="$T/rows" DISK_INV_GROWTH_TSV="$T/g.tsv" DISK_INV_SUDO=0 DISK_INV_BOX=bx "$@" bash "$INV" 2>&1; }
out="$(inv)"; rc=$?
[ "$rc" = 0 ] && grep -qE '^\| fix \| [0-9.]+kB \| 2 \| 2020-01-02 \|  \|$' <<<"$out" \
  && pass "2. a dir row: size, file count 2, oldest 2020-01-02" || fail "2. dir row (rc $rc): $out"
grep -q '^| gone | 0B | 0 | - | absent |$' <<<"$out" && pass "2. a row with no existing path is absent" || fail "2. absent: $out"
! grep -q secret-name <<<"$out" && pass "2. no file name reaches the table" || fail "2. name leaked: $out"
[ ! -e "$T/g.tsv" ] && pass "2. without DISK_INV_GROWTH=1 no record is written" || fail "2. record written"
inv DISK_INV_GROWTH=1 DISK_INV_DAY=2026-10-01 >/dev/null; out="$(inv DISK_INV_GROWTH=1 DISK_INV_DAY=2026-10-01)"
[ "$(grep -c . "$T/g.tsv")" = 2 ] && grep -q '^SKIP' <<<"$out" && grep -qP '^2026-10-01\tbx\tfix\t[0-9]+\t2$' "$T/g.tsv" \
  && pass "2. the record: one line per row, once per day per box" || fail "2. record: $(cat "$T/g.tsv") / $out"
printf 'Bad_Name | dir | /x\n' >"$T/rows"; out="$(inv)"; rc=$?
[ "$rc" = 2 ] && grep -q "bad row name" <<<"$out" && pass "2. a bad row name is refused" || fail "2. bad name (rc $rc): $out"

# 3. the growers ---------------------------------------------------------------
GR="$UTL_ROOT/src/bash/scripts/disk-growers.sh"
gr() { env DISK_GROWERS_TSV="$T/gr.tsv" DISK_GROWERS_BOX=bx DISK_GROWERS_TODAY=2026-10-16 "$@" bash "$GR" 2>&1; }
out="$(gr)"; rc=$?
[ "$rc" = 0 ] && grep -q '^no growth record' <<<"$out" && pass "3. CONTROL: no record is a line, exit 0" || fail "3. none (rc $rc): $out"
{
  printf '2026-10-01\tbx\told\t0\t1\n2026-10-02\tbx\told\t900000000000\t1\n'
  for r in a:1000000000:3000000000 b:0:7000000 c:5000000:1000000 d:0:2000000000 e:0:1000; do
    IFS=: read -r n x y <<<"$r"
    printf '2026-10-12\tbx\t%s\t%s\t1\n2026-10-16\tbx\t%s\t%s\t1\n' "$n" "$x" "$n" "$y"
  done
  printf '2026-10-12\tother\tz\t0\t1\n2026-10-16\tother\tz\t999999999999\t1\n'
} >"$T/gr.tsv"
out="$(gr)"
[ "$out" = "top growers 7d: a +500.0MB/d, d +500.0MB/d, b +1.8MB/d" ] \
  && pass "3. top 3 by bytes per day; old rows, other boxes and a shrinking row are not growers" || fail "3. top: $out"
out="$(gr DISK_GROWERS_TOP=1)"
[ "$out" = "top growers 7d: a +500.0MB/d" ] && pass "3. DISK_GROWERS_TOP=1 names one" || fail "3. top1: $out"

echo "box-disk-guard: ${fails} failure(s)"
[ "$fails" -eq 0 ]
